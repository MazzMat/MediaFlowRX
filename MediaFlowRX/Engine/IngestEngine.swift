import AppKit
import Foundation

enum ListenPhase {
    case listening
    case live
    case interrupted
}

@MainActor
@Observable
final class IngestEngine {
    private(set) var phase: ListenPhase = .listening
    private(set) var hasSource = false
    private(set) var isRecording = false {
        didSet { recordingSince = isRecording ? (recordingSince ?? Date()) : nil }
    }
    private(set) var recordingSince: Date?
    private(set) var statusText = String(localized: "Listening")
    private(set) var listenError: String?
    private(set) var lastFileName: String?
    private(set) var countdown = 0
    private(set) var streamInfo = StreamInfo()
    var muted = false {
        didSet { preview.isMuted = muted }
    }
    let preview = PreviewPlayer()

    private var settings: AppSettings?
    private var started = false
    private var suppressed = false
    private var sessionClosedByTimeout = false
    private var lastFrameAt = Date()
    private var ticker: Timer?
    private var graceSeconds = 10
    private var measureStart: Date?
    private var videoBytes = 0
    private var audioBytes = 0
    private var videoFrames = 0
    private var sessionBytes = 0
    private var lastVideoDTS: UInt64?
    private var lastKeyDTS: UInt64?
    private var framesSinceKey = 0
    private var lastTransit: Double?
    private var jitter: Double = 0
    private var gopMeasured = false

    func start(_ settings: AppSettings) {
        self.settings = settings
        graceSeconds = settings.graceSeconds
        if started {
            return
        }
        if ticker == nil {
            // Task @MainActor instead of MainActor.assumeIsolated: the latter segfaulted
            // inside the timer callback (see crash report MediaFlowRX-*.ips).
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                let engine = self
                Task { @MainActor in
                    engine?.tick()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            ticker = timer
        }
        apply(settings)
        started = true
    }

    func apply(_ settings: AppSettings) {
        self.settings = settings
        graceSeconds = max(1, settings.graceSeconds)
        if let error = settings.validationError() {
            listenError = error
            statusText = error
            return
        }
        try? FileManager.default.createDirectory(at: settings.recordingFolder, withIntermediateDirectories: true)
        var config = mfrx_config()
        config.kind = Int32(settings.kind.rawValue)
        config.port = UInt16(settings.port)
        config.grace_ms = Int32(graceSeconds * 1000)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let result = settings.slug.withCString { slug in
            settings.streamKey.withCString { key in
                settings.username.withCString { user in
                    settings.password.withCString { pass in
                        settings.recordingFolderPath.withCString { directory in
                            config.slug = slug
                            config.key = key
                            config.username = user
                            config.password = pass
                            config.record_directory = directory
                            return mfrx_start(&config, ctx)
                        }
                    }
                }
            }
        }
        if result == 0 {
            listenError = nil
            hasSource = false
            isRecording = false
            suppressed = false
            sessionClosedByTimeout = false
            phase = .listening
            preview.reset()
            clearStream()
            refreshStatus()
        } else {
            let message = String(cString: mfrx_last_error())
            listenError = message.isEmpty ? String(localized: "Listening did not start") : Self.localizedEngineMessage(message)
            statusText = listenError ?? statusText
        }
    }

    func updateGrace(_ seconds: Int) {
        graceSeconds = max(1, seconds)
        mfrx_set_grace_ms(Int32(graceSeconds * 1000))
    }

    func updateFolder(_ path: String) {
        mfrx_set_record_directory(path)
    }

    func updateAutoRecord(_ enabled: Bool) {
        if enabled, phase == .live, !isRecording, !suppressed, !sessionClosedByTimeout {
            beginRecording()
        }
    }

    func toggleRecording() {
        if isRecording {
            suppressed = true
            isRecording = false
            mfrx_set_recording(0)
            refreshStatus()
            return
        }
        guard hasSource, !sessionClosedByTimeout || phase == .live else {
            if hasSource {
                sessionClosedByTimeout = false
                phase = .live
                suppressed = false
                beginRecording()
            }
            return
        }
        suppressed = false
        beginRecording()
    }

    var recordEnabled: Bool {
        hasSource
    }

    func shutdown() {
        ticker?.invalidate()
        ticker = nil
        preview.reset()
        mfrx_stop()
        hasSource = false
        isRecording = false
        phase = .listening
        clearStream()
    }

    fileprivate func applySource(_ present: Bool) {
        if present {
            notePublisher()
            hasSource = true
            sessionClosedByTimeout = false
            lastFrameAt = Date()
            phase = .live
            if settings?.autoRecord == true, !suppressed, !isRecording {
                beginRecording()
            }
        } else {
            hasSource = false
            isRecording = false
            suppressed = false
            sessionClosedByTimeout = false
            phase = .listening
            preview.reset()
            clearStream()
        }
        refreshStatus()
    }

    fileprivate func applyFrame(_ packet: MediaPacket) {
        let resumed = sessionClosedByTimeout || phase != .live || !hasSource
        lastFrameAt = Date()
        sessionClosedByTimeout = false
        // Observed properties are written only when they change. Every write
        // redraws the UI, and this runs on every video frame.
        if !hasSource { hasSource = true }
        if phase != .live { phase = .live }
        noteStream(packet)
        preview.consume(packet)
        if resumed, settings?.autoRecord == true, !suppressed, !isRecording {
            beginRecording()
        } else if resumed {
            refreshStatus()
        }
    }

    fileprivate func applyFile(_ path: String) {
        lastFileName = URL(fileURLWithPath: path).lastPathComponent
        if phase != .live {
            isRecording = false
            refreshStatus()
        }
    }

    fileprivate func applyError(_ message: String) {
        let text = Self.localizedEngineMessage(message)
        listenError = text
        statusText = text
    }

    private func beginRecording() {
        if mfrx_set_recording(1) != 0 {
            isRecording = true
            listenError = nil
        } else {
            isRecording = false
            let message = String(cString: mfrx_last_error())
            if !message.isEmpty {
                listenError = Self.localizedEngineMessage(message)
            }
        }
        refreshStatus()
    }

    private func tick() {
        if hasSource, !sessionClosedByTimeout {
            publishRates()
        }
        guard hasSource, !sessionClosedByTimeout else { return }
        let idle = Date().timeIntervalSince(lastFrameAt)
        if idle < 1 {
            if phase == .interrupted {
                phase = .live
                refreshStatus()
            }
            return
        }
        let remain = Double(graceSeconds) - idle
        if remain <= 0 {
            sessionClosedByTimeout = true
            if isRecording {
                isRecording = false
                mfrx_set_recording(0)
            }
            phase = .listening
            suppressed = false
            clearStream()
            refreshStatus()
            return
        }
        phase = .interrupted
        countdown = Int(ceil(remain))
        refreshStatus()
    }

    private func refreshStatus() {
        if let listenError, phase == .listening, !hasSource {
            statusText = listenError
            return
        }
        switch phase {
        case .listening:
            statusText = hasSource ? String(localized: "No signal") : String(localized: "Listening")
        case .live:
            statusText = isRecording ? String(localized: "Recording now") : String(localized: "On air")
        case .interrupted:
            statusText = String(localized: "Signal dropped, closing in \(countdown) s")
        }
    }

    /// Engine messages are English keys. Here they become the app language.
    private static func localizedEngineMessage(_ message: String) -> String {
        let prefix = "Could not open port "
        if message.hasPrefix(prefix) {
            let port = String(message.dropFirst(prefix.count))
            return String(localized: "Could not open port \(port)")
        }
        switch message {
        case "No stream to record":
            return String(localized: "No stream to record")
        case "Recording did not start":
            return String(localized: "Recording did not start")
        case "Slug, key and port are required":
            return String(localized: "Slug, key and port are required")
        default:
            return message
        }
    }

    /// Updates the stable stream fields only when they change, so the UI is not redrawn on every frame.
    private func noteStream(_ packet: MediaPacket) {
        if measureStart == nil { measureStart = Date() }
        var next = streamInfo
        sessionBytes += packet.data.count
        if next.connectedSince == nil {
            next.connectedSince = Date()
            if let settings { next.path = "\(settings.slug)/\(settings.streamKey)" }
        }
        if packet.isVideo {
            videoBytes += packet.data.count
            if !packet.isConfig, packet.dts != lastVideoDTS {
                videoFrames += 1
                noteVideoTiming(packet, into: &next)
            }
            if packet.codec != 0 { next.videoCodec = Self.codecName(packet.codec) }
            if packet.isConfig || (packet.isKey && next.videoProfile.isEmpty),
               let profile = VideoProfile.describe(packet.data, codec: packet.codec) {
                next.videoProfile = profile
            }
            if packet.width > 0 { next.width = Int(packet.width) }
            if packet.height > 0 { next.height = Int(packet.height) }
            if next.fps == 0, packet.fps > 0 { next.fps = Int(packet.fps) }
            if !gopMeasured, packet.gopMs > 0 { next.gopMs = Int(packet.gopMs) }
            if next.videoBitrateKbps == 0, packet.bitRate > 0 {
                next.videoBitrateKbps = Int(packet.bitRate) / 1000
            }
        } else {
            audioBytes += packet.data.count
            if packet.codec != 0 { next.audioCodec = Self.codecName(packet.codec) }
            if packet.sampleRate > 0 { next.sampleRate = Int(packet.sampleRate) }
            if packet.channels > 0 { next.channels = Int(packet.channels) }
            if packet.sampleBits > 0 { next.sampleBits = Int(packet.sampleBits) }
            if next.audioBitrateKbps == 0, packet.bitRate > 0 {
                next.audioBitrateKbps = Int(packet.bitRate) / 1000
            }
        }
        if next != streamInfo { streamInfo = next }
    }

    /// Gaps, jitter and GOP from the video timestamps. Called once per frame, not per NAL.
    private func noteVideoTiming(_ packet: MediaPacket, into next: inout StreamInfo) {
        let dts = packet.dts
        let fps = next.fps > 0 ? next.fps : Int(packet.fps)
        let interval = fps > 0 ? 1000 / Double(fps) : 33
        var discontinuity = false
        if let last = lastVideoDTS {
            let delta = Double(Int64(bitPattern: dts) - Int64(bitPattern: last))
            // A gap is a hole well past the normal cadence, or a timestamp that jumps backwards.
            if delta < 0 || delta > max(interval * 2.5, 100) {
                next.videoGaps += 1
                discontinuity = true
            }
        }
        lastVideoDTS = dts

        // Jitter as in RFC 3550: a moving average of the variation between arrival and timestamp.
        let transit = packet.arrival * 1000 - Double(dts)
        if discontinuity {
            lastTransit = nil
        } else if let lastTransit {
            jitter += (abs(transit - lastTransit) - jitter) / 16
        }
        lastTransit = transit

        if packet.isKey {
            if !discontinuity, let lastKeyDTS, dts > lastKeyDTS, dts - lastKeyDTS < 60_000 {
                next.gopMs = Int(dts - lastKeyDTS)
                next.gopFrames = framesSinceKey
                gopMeasured = true
            }
            lastKeyDTS = dts
            framesSinceKey = 0
        }
        framesSinceKey += 1
    }

    private func notePublisher() {
        guard streamInfo.publisher.isEmpty else { return }
        var buffer = [CChar](repeating: 0, count: 128)
        guard mfrx_copy_publisher(&buffer, buffer.count) != 0 else { return }
        streamInfo.publisher = String(cString: buffer)
    }

    /// The file in progress is hidden (".….mp4") in the subfolders the engine creates
    /// inside the recording folder. Search only there, not the whole folder.
    private func recordingFileSize() -> Int64? {
        guard isRecording, let settings else { return nil }
        let root = settings.recordingFolder
        let roots = [
            root.appending(path: "record/\(settings.slug)/\(settings.streamKey)"),
            root.appending(path: "__defaultVhost__/record/\(settings.slug)/\(settings.streamKey)"),
        ]
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        var newest: (date: Date, size: Int64)?
        for folder in roots {
            guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { continue }
            for case let url as URL in files where url.lastPathComponent.hasPrefix(".") && url.pathExtension == "mp4" {
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true,
                      let date = values.contentModificationDate,
                      let size = values.fileSize else { continue }
                if newest == nil || date > newest!.date {
                    newest = (date, Int64(size))
                }
            }
        }
        return newest?.size
    }

    /// Bitrate and fps measured over the second just elapsed. With no packets, the last values stay.
    private func publishRates() {
        guard let start = measureStart else { return }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed >= 1 else { return }
        let videoKbps = Int((Double(videoBytes) * 8 / elapsed / 1000).rounded())
        let audioKbps = Int((Double(audioBytes) * 8 / elapsed / 1000).rounded())
        let fps = videoFrames > 0 ? Int((Double(videoFrames) / elapsed).rounded()) : 0
        let sawVideo = videoBytes > 0
        let sawAudio = audioBytes > 0
        videoBytes = 0
        audioBytes = 0
        videoFrames = 0
        measureStart = Date()
        notePublisher()
        var next = streamInfo
        next.totalBytes = sessionBytes
        next.recordingBytes = recordingFileSize()
        if sawVideo {
            if fps > 0 { next.fps = fps }
            next.videoBitrateKbps = videoKbps
            next.jitterMs = Int(jitter.rounded())
        }
        if sawAudio {
            next.audioBitrateKbps = audioKbps
        }
        if next != streamInfo { streamInfo = next }
    }

    private func clearStream() {
        streamInfo = StreamInfo()
        measureStart = nil
        videoBytes = 0
        audioBytes = 0
        videoFrames = 0
        sessionBytes = 0
        lastVideoDTS = nil
        lastKeyDTS = nil
        framesSinceKey = 0
        lastTransit = nil
        jitter = 0
        gopMeasured = false
    }

    private static func codecName(_ codec: Int32) -> String {
        switch codec {
        case MFRX_CODEC_H264: "H.264"
        case MFRX_CODEC_H265: "HEVC"
        case MFRX_CODEC_AAC: "AAC"
        default: String(localized: "Other")
        }
    }
}

struct StreamInfo: Equatable {
    var videoCodec = ""
    var width = 0
    var height = 0
    var fps = 0
    var videoBitrateKbps = 0
    var gopMs = 0
    var gopFrames = 0
    var videoProfile = ""
    var videoGaps = 0
    var jitterMs = 0
    var audioCodec = ""
    var sampleRate = 0
    var channels = 0
    var sampleBits = 0
    var audioBitrateKbps = 0
    var publisher = ""
    var path = ""
    var connectedSince: Date?
    var totalBytes = 0
    var recordingBytes: Int64?

    var hasMedia: Bool {
        width > 0 || sampleRate > 0 || !videoCodec.isEmpty || !audioCodec.isEmpty
    }
}

@_cdecl("mfrx_swift_on_state")
func mfrxSwiftOnState(_ ctx: UnsafeMutableRawPointer?, _ state: Int32) {
    guard let ctx else { return }
    let engine = Unmanaged<IngestEngine>.fromOpaque(ctx).takeUnretainedValue()
    let present = state != 0
    Task { @MainActor in
        engine.applySource(present)
    }
}

@_cdecl("mfrx_swift_on_frame")
func mfrxSwiftOnFrame(_ ctx: UnsafeMutableRawPointer?, _ frame: UnsafePointer<mfrx_frame>?) {
    guard let ctx, let frame else { return }
    let raw = frame.pointee
    guard let dataPointer = raw.data, raw.size > 0 else { return }
    let packet = MediaPacket(
        codec: raw.codec,
        isVideo: raw.is_video != 0,
        isKey: raw.is_key != 0,
        isConfig: raw.is_config != 0,
        prefixSize: Int(raw.prefix_size),
        data: Data(bytes: dataPointer, count: raw.size),
        pts: raw.pts_ms,
        dts: raw.dts_ms,
        width: raw.width,
        height: raw.height,
        sampleRate: raw.sample_rate,
        channels: raw.channels,
        fps: raw.fps,
        bitRate: raw.bit_rate,
        sampleBits: raw.sample_bits,
        gopMs: raw.gop_ms,
        arrival: ProcessInfo.processInfo.systemUptime
    )
    let engine = Unmanaged<IngestEngine>.fromOpaque(ctx).takeUnretainedValue()
    Task { @MainActor in
        engine.applyFrame(packet)
    }
}

@_cdecl("mfrx_swift_on_file")
func mfrxSwiftOnFile(_ ctx: UnsafeMutableRawPointer?, _ path: UnsafePointer<CChar>?) {
    guard let ctx, let path else { return }
    let file = String(cString: path)
    let engine = Unmanaged<IngestEngine>.fromOpaque(ctx).takeUnretainedValue()
    Task { @MainActor in
        engine.applyFile(file)
    }
}

@_cdecl("mfrx_swift_on_error")
func mfrxSwiftOnError(_ ctx: UnsafeMutableRawPointer?, _ message: UnsafePointer<CChar>?) {
    guard let ctx, let message else { return }
    let text = String(cString: message)
    let engine = Unmanaged<IngestEngine>.fromOpaque(ctx).takeUnretainedValue()
    Task { @MainActor in
        engine.applyError(text)
    }
}
