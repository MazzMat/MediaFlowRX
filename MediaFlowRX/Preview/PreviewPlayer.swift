import AppKit
import AVFoundation
import CoreMedia
import SwiftUI
import VideoToolbox

struct MediaPacket: Sendable {
    var codec: Int32
    var isVideo: Bool
    var isKey: Bool
    var isConfig: Bool
    var prefixSize: Int
    var data: Data
    var pts: UInt64
    var dts: UInt64
    var width: Int32
    var height: Int32
    var sampleRate: Int32
    var channels: Int32
    var fps: Int32
    var bitRate: Int32
    var sampleBits: Int32
    var gopMs: Int32
    /// Arrival time from the engine, in seconds of uptime. Used to measure jitter.
    var arrival: TimeInterval
}

struct AudioLevel: Equatable {
    static let floor: Float = -60
    var peak: Float = AudioLevel.floor
    var rms: Float = AudioLevel.floor
}

@MainActor
final class PreviewPlayer {
    private weak var displayLayer: AVSampleBufferDisplayLayer?
    private var formatDescription: CMVideoFormatDescription?
    private var h264SPS: Data?
    private var h264PPS: Data?
    private var hevcVPS: Data?
    private var hevcSPS: Data?
    private var hevcPPS: Data?
    private var pendingPTS: UInt64?
    private var pendingDTS: UInt64?
    private var pendingKey = false
    private var pendingNALs: [Data] = []
    private var pendingCodec: Int32 = 0
    private var formatTokenSPS: Data?
    private var formatTokenPPS: Data?
    private var formatTokenVPS: Data?
    private var timebase: CMTimebase?
    private var clockReady = false
    private var anchorHost = CMTime.zero
    private var anchorPTS: UInt64 = 0
    private var lastVideoPTS: UInt64?
    private var needsKeyframe = false
    /// The encoder splits frames into slices (x264 zerolatency, for example).
    /// Slices are then joined, and the frame is sent only when the next one arrives.
    private var multiSlice = false

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var audioConverter: AVAudioConverter?
    private var compressedFormat: AVAudioFormat?
    private var audioFormat: AVAudioFormat?
    private var audioSpecificConfig = Data()
    private var audioReady = false
    private var audioStartFailed = false
    private var meterPeak = AudioLevel.floor
    private var meterRMS = AudioLevel.floor
    private var meterTime: TimeInterval = 0
    var isMuted = false {
        didSet { playerNode.volume = isMuted ? 0 : 1 }
    }

    init() {
        audioEngine.attach(playerNode)
    }

    func attach(_ layer: AVSampleBufferDisplayLayer) {
        displayLayer = layer
        layer.videoGravity = .resizeAspect
        if timebase == nil {
            var created: CMTimebase?
            CMTimebaseCreateWithSourceClock(
                allocator: kCFAllocatorDefault,
                sourceClock: CMClockGetHostTimeClock(),
                timebaseOut: &created
            )
            timebase = created
        }
        if layer.controlTimebase !== timebase {
            layer.controlTimebase = timebase
        }
    }

    func reset() {
        pendingPTS = nil
        pendingDTS = nil
        pendingKey = false
        pendingNALs.removeAll()
        clockReady = false
        lastVideoPTS = nil
        needsKeyframe = true
        multiSlice = false
        displayLayer?.flushAndRemoveImage()
        playerNode.stop()
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioReady = false
        audioStartFailed = false
        audioConverter = nil
        compressedFormat = nil
        audioFormat = nil
        audioSpecificConfig = Data()
        meterPeak = AudioLevel.floor
        meterRMS = AudioLevel.floor
    }

    /// Level to show now. Not observed: the view reads it on a timer.
    /// Measured on decoded samples, so it stays live while the audio is muted.
    func audioLevel(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> AudioLevel {
        let elapsed = Float(max(0, now - meterTime))
        return AudioLevel(
            peak: max(AudioLevel.floor, meterPeak - elapsed * Self.peakRelease),
            rms: max(AudioLevel.floor, meterRMS - elapsed * Self.rmsRelease)
        )
    }

    /// Fall in dB per second. The peak drops slowly so it stays readable; the average drops faster.
    private static let peakRelease: Float = 20
    private static let rmsRelease: Float = 30

    private func meter(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let frames = Int(buffer.frameLength)
        var peak: Float = 0
        var sum: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            let samples = channels[channel]
            for index in 0..<frames {
                let value = abs(samples[index])
                if value > peak { peak = value }
                sum += value * value
            }
        }
        let count = Float(frames * Int(buffer.format.channelCount))
        let now = ProcessInfo.processInfo.systemUptime
        let current = audioLevel(at: now)
        meterPeak = max(current.peak, Self.decibels(peak))
        meterRMS = max(current.rms, Self.decibels((sum / count).squareRoot()))
        meterTime = now
    }

    private static func decibels(_ amplitude: Float) -> Float {
        guard amplitude > 0 else { return AudioLevel.floor }
        return max(AudioLevel.floor, 20 * log10(amplitude))
    }

    func consume(_ packet: MediaPacket) {
        if packet.isVideo {
            consumeVideo(packet)
        } else if packet.codec == MFRX_CODEC_AAC {
            consumeAudio(packet)
        }
    }

    private func consumeVideo(_ packet: MediaPacket) {
        let nals = nalUnits(from: packet.data)
        guard !nals.isEmpty else { return }
        for nal in nals {
            storeParameterSet(nal, codec: packet.codec)
        }
        rebuildFormatIfNeeded(codec: packet.codec)
        if packet.isConfig {
            return
        }
        let picture = nals.filter { isPicture($0, codec: packet.codec) }
        guard !picture.isEmpty else { return }
        if !multiSlice, pendingPTS == nil, let lastVideoPTS, packet.pts == lastVideoPTS {
            // A second slice of a frame already sent: that frame was incomplete.
            // From here on, slices are joined, starting again from a clean keyframe.
            multiSlice = true
            needsKeyframe = true
            return
        }
        if let pendingPTS, pendingPTS != packet.pts {
            enqueuePending()
            clearPending()
        }
        if pendingPTS == nil {
            pendingPTS = packet.pts
            pendingDTS = packet.dts
            pendingKey = packet.isKey
            pendingCodec = packet.codec
        }
        pendingNALs.append(contentsOf: picture)
        if !multiSlice {
            enqueuePending()
            clearPending()
        }
    }

    private func clearPending() {
        pendingPTS = nil
        pendingDTS = nil
        pendingNALs.removeAll()
    }

    private func enqueuePending() {
        guard let layer = displayLayer, let formatDescription, !pendingNALs.isEmpty else { return }
        if layer.status == .failed {
            layer.flush()
            clockReady = false
            needsKeyframe = true
        }
        if needsKeyframe && !pendingKey {
            return
        }
        let pts = pendingPTS ?? 0
        let when = presentationTime(for: pts)
        guard let sample = makeSampleBuffer(
            nals: pendingNALs,
            format: formatDescription,
            pts: when,
            dts: decodeTime(for: pendingDTS ?? pts, presentation: when),
            duration: frameDuration(endingAt: pts)
        ) else { return }
        needsKeyframe = false
        lastVideoPTS = pts
        layer.enqueue(sample)
    }

    /// Playout delay: frames are shown this long after they arrive.
    /// A small fixed buffer keeps a late or bursty packet from showing up as a jump.
    private let playoutDelay = CMTime(value: 120, timescale: 1000)

    private func presentationTime(for pts: UInt64) -> CMTime {
        let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
        if !clockReady {
            anchorHost = CMTimeAdd(hostNow, playoutDelay)
            anchorPTS = pts
            clockReady = true
            if let timebase {
                CMTimebaseSetTime(timebase, time: hostNow)
                CMTimebaseSetRate(timebase, rate: 1)
            }
            return anchorHost
        }
        let deltaMs = Int64(bitPattern: pts) - Int64(bitPattern: anchorPTS)
        if deltaMs < 0 {
            anchorHost = CMTimeAdd(hostNow, playoutDelay)
            anchorPTS = pts
            return anchorHost
        }
        let when = CMTimeAdd(anchorHost, CMTime(value: deltaMs, timescale: 1000))
        let late = CMTimeGetSeconds(CMTimeSubtract(hostNow, when))
        if late > 0.02 {
            // The frame arrived after its time. Re-anchor the timeline on now plus the buffer.
            anchorHost = CMTimeSubtract(CMTimeAdd(hostNow, playoutDelay), CMTime(value: deltaMs, timescale: 1000))
            return CMTimeAdd(hostNow, playoutDelay)
        }
        return when
    }

    private func decodeTime(for dts: UInt64, presentation: CMTime) -> CMTime {
        let deltaMs = Int64(bitPattern: dts) - Int64(bitPattern: anchorPTS)
        let mapped = CMTimeAdd(anchorHost, CMTime(value: max(0, deltaMs), timescale: 1000))
        if CMTimeCompare(mapped, presentation) > 0 {
            return presentation
        }
        return mapped
    }

    private func frameDuration(endingAt pts: UInt64) -> CMTime {
        guard let lastVideoPTS, pts > lastVideoPTS else {
            return CMTime(value: 33, timescale: 1000)
        }
        let delta = min(pts - lastVideoPTS, 100)
        if delta == 0 {
            return CMTime(value: 33, timescale: 1000)
        }
        return CMTime(value: CMTimeValue(delta), timescale: 1000)
    }

    private func storeParameterSet(_ nal: Data, codec: Int32) {
        guard let first = nal.first else { return }
        if codec == MFRX_CODEC_H264 {
            switch first & 0x1F {
            case 7: h264SPS = nal
            case 8: h264PPS = nal
            default: break
            }
        } else if codec == MFRX_CODEC_H265 {
            switch (first & 0x7E) >> 1 {
            case 32: hevcVPS = nal
            case 33: hevcSPS = nal
            case 34: hevcPPS = nal
            default: break
            }
        }
    }

    private func rebuildFormatIfNeeded(codec: Int32) {
        if codec == MFRX_CODEC_H264, let sps = h264SPS, let pps = h264PPS {
            if formatDescription != nil, formatTokenSPS == sps, formatTokenPPS == pps, formatTokenVPS == nil {
                return
            }
            formatDescription = makeH264Format(sps: sps, pps: pps)
            formatTokenSPS = sps
            formatTokenPPS = pps
            formatTokenVPS = nil
        } else if codec == MFRX_CODEC_H265, let vps = hevcVPS, let sps = hevcSPS, let pps = hevcPPS {
            if formatDescription != nil, formatTokenVPS == vps, formatTokenSPS == sps, formatTokenPPS == pps {
                return
            }
            formatDescription = makeHEVCFormat(vps: vps, sps: sps, pps: pps)
            formatTokenVPS = vps
            formatTokenSPS = sps
            formatTokenPPS = pps
        }
    }

    private func isPicture(_ nal: Data, codec: Int32) -> Bool {
        guard let first = nal.first else { return false }
        if codec == MFRX_CODEC_H264 {
            let type = first & 0x1F
            return (1...5).contains(type)
        }
        if codec == MFRX_CODEC_H265 {
            let type = (first & 0x7E) >> 1
            return type <= 31
        }
        return false
    }

    private func nalUnits(from data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var headers: [(payload: Int, code: Int)] = []
        var index = 0
        while index + 3 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                headers.append((index + 3, index))
                index += 3
                continue
            }
            if index + 4 < bytes.count, bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 0, bytes[index + 3] == 1 {
                headers.append((index + 4, index))
                index += 4
                continue
            }
            index += 1
        }
        if headers.isEmpty {
            return data.isEmpty ? [] : [data]
        }
        var units: [Data] = []
        for offset in headers.indices {
            let begin = headers[offset].payload
            let end = offset + 1 < headers.count ? headers[offset + 1].code : bytes.count
            if begin < end {
                units.append(Data(bytes[begin..<end]))
            }
        }
        return units
    }

    private func makeH264Format(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        var description: CMVideoFormatDescription?
        sps.withUnsafeBytes { spsRaw in
            pps.withUnsafeBytes { ppsRaw in
                let pointers = [
                    spsRaw.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    ppsRaw.baseAddress!.assumingMemoryBound(to: UInt8.self),
                ]
                let sizes = [sps.count, pps.count]
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description
                )
            }
        }
        return description
    }

    private func makeHEVCFormat(vps: Data, sps: Data, pps: Data) -> CMVideoFormatDescription? {
        var description: CMVideoFormatDescription?
        vps.withUnsafeBytes { vpsRaw in
            sps.withUnsafeBytes { spsRaw in
                pps.withUnsafeBytes { ppsRaw in
                    let pointers = [
                        vpsRaw.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        spsRaw.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        ppsRaw.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    ]
                    let sizes = [vps.count, sps.count, pps.count]
                    CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 3,
                        parameterSetPointers: pointers,
                        parameterSetSizes: sizes,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &description
                    )
                }
            }
        }
        return description
    }

    private func makeSampleBuffer(nals: [Data], format: CMVideoFormatDescription, pts: CMTime, dts: CMTime, duration: CMTime) -> CMSampleBuffer? {
        var avcc = Data()
        for nal in nals {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }
            avcc.append(nal)
        }
        var block: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: 0,
            blockBufferOut: &block
        )
        guard createStatus == kCMBlockBufferNoErr, let block else { return nil }
        let replaceStatus = avcc.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: avcc.count
            )
        }
        guard replaceStatus == kCMBlockBufferNoErr else { return nil }
        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: pts,
            decodeTimeStamp: dts
        )
        var sampleSize = avcc.count
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample
        )
        guard status == noErr, let sample else { return nil }
        return sample
    }

    private func consumeAudio(_ packet: MediaPacket) {
        if packet.isConfig {
            configureAudio(asc: packet.data, fallbackRate: packet.sampleRate, fallbackChannels: packet.channels)
            return
        }
        if audioConverter == nil {
            // Some encoders, OBS included, never send the AAC sequence header to a
            // track that is already attached. Without it the audio was dropped silently.
            // Rebuild an AAC-LC AudioSpecificConfig from the frame's rate and channel count.
            guard let asc = Self.audioSpecificConfig(sampleRate: packet.sampleRate, channels: packet.channels) else { return }
            configureAudio(asc: asc, fallbackRate: packet.sampleRate, fallbackChannels: packet.channels)
            if audioConverter == nil { return }
        }
        let raw = stripADTS(packet.data)
        guard !raw.isEmpty, let buffer = decodeAAC(raw) else { return }
        meter(buffer)
        schedule(buffer)
    }

    private func configureAudio(asc: Data, fallbackRate: Int32, fallbackChannels: Int32) {
        guard asc != audioSpecificConfig else { return }
        // Marked immediately. A failed connection must not be retried on every packet,
        // or the main thread stays busy and the cursor spins.
        audioSpecificConfig = asc
        let parsed = parseASC(asc)
        let rate = Double(fallbackRate > 0 ? fallbackRate : Int32(parsed?.rate ?? 48000))
        let channels = AVAudioChannelCount(max(1, min(Int(fallbackChannels > 0 ? fallbackChannels : Int32(parsed?.channels ?? 2)), 8)))
        guard rate >= 8000, let compressed = AVAudioFormat(settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
        ]) else { return }
        guard let playback = installPlayback(compressed: compressed, sourceRate: rate, sourceChannels: channels) else { return }
        audioConverter = playback.converter
        compressedFormat = compressed
        audioFormat = playback.format
        audioReady = false
        audioStartFailed = false
        playerNode.volume = isMuted ? 0 : 1
        NSLog("MediaFlowRX: audio pronto %.0f Hz %u canali", playback.format.sampleRate, playback.format.channelCount)
    }

    /// Connects the player to the mixer. The format is non-interleaved float32, the only one the mixer accepts.
    /// `connect` and `play`, available since macOS 14, throw NSException when the format is rejected.
    /// Swift does not catch it: the bridge in mfrx_audio.m turns it into a string.
    private func installPlayback(compressed: AVAudioFormat, sourceRate: Double, sourceChannels: AVAudioChannelCount) -> (converter: AVAudioConverter, format: AVAudioFormat)? {
        var candidates: [AVAudioFormat] = []
        let hardware = audioEngine.outputNode.outputFormat(forBus: 0)
        if hardware.sampleRate > 0, hardware.channelCount > 0,
           let device = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate, channels: hardware.channelCount) {
            candidates.append(device)
        }
        if let source = AVAudioFormat(standardFormatWithSampleRate: sourceRate, channels: sourceChannels),
           !candidates.contains(where: { $0.sampleRate == source.sampleRate && $0.channelCount == source.channelCount }) {
            candidates.append(source)
        }
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        for format in candidates {
            guard let converter = AVAudioConverter(from: compressed, to: format) else { continue }
            audioEngine.disconnectNodeOutput(playerNode)
            if let message = mfrx_audio_connect(audioEngine, playerNode, format) {
                NSLog("%@", "MediaFlowRX: audio non collegato a \(format.sampleRate) Hz (\(message))" as NSString)
                continue
            }
            return (converter, format)
        }
        return nil
    }

    private func decodeAAC(_ packet: Data) -> AVAudioPCMBuffer? {
        guard let audioConverter, let audioFormat, let compressedFormat else { return nil }
        let compressed = AVAudioCompressedBuffer(format: compressedFormat, packetCapacity: 1, maximumPacketSize: packet.count)
        packet.withUnsafeBytes { raw in
            compressed.data.copyMemory(from: raw.baseAddress!, byteCount: packet.count)
        }
        compressed.byteLength = UInt32(packet.count)
        compressed.packetCount = 1
        compressed.packetDescriptions?[0] = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: 0,
            mDataByteSize: UInt32(packet.count)
        )
        guard let output = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: 4096) else { return nil }
        var supplied = false
        var error: NSError?
        let status = audioConverter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return compressed
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }

    private func schedule(_ buffer: AVAudioPCMBuffer) {
        if !audioReady {
            if audioStartFailed { return }
            if let message = mfrx_audio_start(audioEngine, playerNode) {
                audioStartFailed = true
                NSLog("%@", "MediaFlowRX: riproduzione audio non avviata (\(message))" as NSString)
                return
            }
            audioReady = true
            NSLog("MediaFlowRX: riproduzione audio avviata")
        }
        playerNode.scheduleBuffer(buffer)
    }

    private func stripADTS(_ data: Data) -> Data {
        guard data.count > 7, data[0] == 0xFF, (data[1] & 0xF0) == 0xF0 else { return data }
        let header = (data[1] & 0x01) == 1 ? 7 : 9
        guard data.count > header else { return Data() }
        return data.subdata(in: header..<data.count)
    }

    private static func audioSpecificConfig(sampleRate: Int32, channels: Int32) -> Data? {
        let rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
        guard let index = rates.firstIndex(of: Int(sampleRate)), (1...7).contains(channels) else { return nil }
        let objectTypeAACLC: UInt8 = 2
        let first = (objectTypeAACLC << 3) | UInt8(index >> 1)
        let second = (UInt8(index & 1) << 7) | (UInt8(channels) << 3)
        return Data([first, second])
    }

    private func parseASC(_ data: Data) -> (rate: Double, channels: UInt32)? {
        guard data.count >= 2 else { return nil }
        let rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
        let freqIndex = Int(((data[0] & 0x07) << 1) | (data[1] >> 7))
        var channels = UInt32((data[1] >> 3) & 0x0F)
        guard freqIndex < rates.count else { return nil }
        if channels == 0 { channels = 2 }
        return (Double(rates[freqIndex]), channels)
    }
}

final class VideoHostView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        displayLayer.frame = bounds
    }
}

struct VideoCanvas: NSViewRepresentable {
    var player: PreviewPlayer

    func makeNSView(context: Context) -> VideoHostView {
        let view = VideoHostView()
        player.attach(view.displayLayer)
        return view
    }

    func updateNSView(_ nsView: VideoHostView, context: Context) {
        player.attach(nsView.displayLayer)
    }
}
