import AppKit
import AVFoundation
import CoreMedia
import os
import SwiftUI
import VideoToolbox

nonisolated struct MediaPacket: Sendable {
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
    /// Nonzero when the frame reaches the MP4 of that recording.
    var recordEpoch: UInt32 = 0
}

nonisolated struct AudioLevel: Equatable, Sendable {
    static let floor: Float = -60
    var peak: Float = AudioLevel.floor
    var rms: Float = AudioLevel.floor
}

/// Decodes and plays the preview on its own serial queue, so a busy UI never delays frames
/// and decoding never slows the UI. Every stored property is touched only on `queue`,
/// except the meter, which has its own lock because the view reads it from the main thread.
nonisolated final class PreviewPlayer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MediaFlowRX.preview", qos: .userInteractive)

    /// The layer itself belongs to the main thread. Its renderer is the part meant to be fed from a queue.
    private var renderer: AVSampleBufferVideoRenderer?
    private var formatDescription: CMVideoFormatDescription?
    private var h264SPS: Data?
    private var h264PPS: Data?
    private var hevcVPS: Data?
    private var hevcSPS: Data?
    private var hevcPPS: Data?
    private var pendingPTS: UInt64?
    private var pendingKey = false
    private var pendingNALs: [Data] = []
    private var formatTokenSPS: Data?
    private var formatTokenPPS: Data?
    private var formatTokenVPS: Data?
    private let timebase: CMTimebase?
    private var clock = PlayoutClock()
    private var lastVideoPTS: UInt64?
    private var needsKeyframe = true
    /// The encoder splits frames into slices (x264 zerolatency, for example).
    /// Slices are then joined, and the frame is sent only when the next one arrives.
    private var multiSlice = false

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var audioConverter: AVAudioConverter?
    private var compressedFormat: AVAudioFormat?
    private var audioFormat: AVAudioFormat?
    private var audioSpecificConfig = Data()
    /// The last configuration seen, kept to rebuild the chain after an output device change.
    private var knownASC: Data?
    private var usingCookie = false
    private var audioReady = false
    private var audioStartFailed = false
    /// Frames handed to the player and not played yet. This is the audio delay we control.
    private var queuedFrames: AVAudioFramePosition = 0
    /// Bumped on every reset, so completions of buffers from before it are ignored.
    private var audioGeneration = 0
    private var audioGate = AudioLatencyGate()
    private var muted = false
    private var configurationObserver: NSObjectProtocol?

    private struct MeterState {
        var peak = AudioLevel.floor
        var rms = AudioLevel.floor
        var time: TimeInterval = 0
    }
    private let meterState = OSAllocatedUnfairLock(initialState: MeterState())
    /// The last frame handed to the renderer and the host time it is shown at. Read by the captions.
    private let shownState = OSAllocatedUnfairLock<(pts: UInt64, host: Double)?>(initialState: nil)

    init() {
        var created: CMTimebase?
        CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &created
        )
        timebase = created
        audioEngine.attach(playerNode)
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.audioConfigurationChanged() }
        }
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    // MARK: - Interface, callable from any thread

    @MainActor
    func attach(_ layer: AVSampleBufferDisplayLayer) {
        if layer.controlTimebase !== timebase {
            layer.controlTimebase = timebase
        }
        // Not annotated Sendable, but the renderer is the API meant to be fed from a background queue.
        nonisolated(unsafe) let renderer = layer.sampleBufferRenderer
        queue.async { self.attachOnQueue(renderer) }
    }

    func reset() {
        queue.async { self.resetOnQueue() }
    }

    func consume(_ packet: MediaPacket) {
        queue.async { self.consumeOnQueue(packet) }
    }

    func setMuted(_ value: Bool) {
        queue.async {
            self.muted = value
            self.playerNode.volume = value ? 0 : 1
        }
    }

    /// Level to show now. Not observed: the view reads it on a timer.
    /// Measured on decoded samples, so it stays live while the audio is muted.
    func audioLevel(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> AudioLevel {
        meterState.withLock { Self.level(of: $0, at: now) }
    }

    /// Host time, in seconds, at which the frame with this timestamp is shown. Nil without a picture.
    func displayTime(forPTS pts: UInt64) -> Double? {
        guard let shown = shownState.withLock({ $0 }) else { return nil }
        let offset = Double(Int64(bitPattern: pts) - Int64(bitPattern: shown.pts)) / 1000
        guard abs(offset) < PlayoutClock.jumpLead else { return nil }
        return shown.host + offset
    }

    // MARK: - Queue side

    private func attachOnQueue(_ renderer: AVSampleBufferVideoRenderer) {
        guard self.renderer !== renderer else { return }
        self.renderer = renderer
        clock.reset()
        needsKeyframe = true
    }

    private func resetOnQueue() {
        pendingPTS = nil
        pendingKey = false
        pendingNALs.removeAll()
        clock.reset()
        lastVideoPTS = nil
        needsKeyframe = true
        multiSlice = false
        renderer?.flush(removingDisplayedImage: true, completionHandler: nil)
        stopAudio()
        audioConverter = nil
        compressedFormat = nil
        audioFormat = nil
        audioSpecificConfig = Data()
        knownASC = nil
        meterState.withLock { $0 = MeterState() }
        shownState.withLock { $0 = nil }
    }

    private func consumeOnQueue(_ packet: MediaPacket) {
        if packet.isVideo {
            consumeVideo(packet)
        } else if packet.codec == MFRX_CODEC_AAC {
            consumeAudio(packet)
        }
    }

    // MARK: - Meter

    /// Fall in dB per second. The peak drops slowly so it stays readable; the average drops faster.
    private static let peakRelease: Float = 20
    private static let rmsRelease: Float = 30

    private static func level(of state: MeterState, at now: TimeInterval) -> AudioLevel {
        let elapsed = Float(max(0, now - state.time))
        return AudioLevel(
            peak: max(AudioLevel.floor, state.peak - elapsed * peakRelease),
            rms: max(AudioLevel.floor, state.rms - elapsed * rmsRelease)
        )
    }

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
        let peakDB = Self.decibels(peak)
        let rmsDB = Self.decibels((sum / count).squareRoot())
        meterState.withLock { state in
            let current = Self.level(of: state, at: now)
            state = MeterState(peak: max(current.peak, peakDB), rms: max(current.rms, rmsDB), time: now)
        }
    }

    private static func decibels(_ amplitude: Float) -> Float {
        guard amplitude > 0 else { return AudioLevel.floor }
        return max(AudioLevel.floor, 20 * log10(amplitude))
    }

    // MARK: - Video

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
            pendingKey = packet.isKey
        }
        pendingNALs.append(contentsOf: picture)
        if !multiSlice {
            enqueuePending()
            clearPending()
        }
    }

    private func clearPending() {
        pendingPTS = nil
        pendingNALs.removeAll()
    }

    private func enqueuePending() {
        guard let renderer, let formatDescription, !pendingNALs.isEmpty else { return }
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            renderer.flush()
            clock.reset()
            needsKeyframe = true
        }
        if needsKeyframe && !pendingKey {
            return
        }
        let pts = pendingPTS ?? 0
        let shownAt = presentationTime(for: pts)
        // No decode time: the layer decodes in enqueue order, which is decode order,
        // and a decode time derived from the presentation clock breaks with B-frames.
        guard let sample = makeSampleBuffer(
            nals: pendingNALs,
            format: formatDescription,
            pts: shownAt,
            duration: frameDuration(endingAt: pts)
        ) else { return }
        shownState.withLock { $0 = (pts, CMTimeGetSeconds(shownAt)) }
        needsKeyframe = false
        lastVideoPTS = pts
        renderer.enqueue(sample)
    }

    private func presentationTime(for pts: UInt64) -> CMTime {
        let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
        if !clock.isReady, let timebase {
            CMTimebaseSetTime(timebase, time: hostNow)
            CMTimebaseSetRate(timebase, rate: 1)
        }
        let when = clock.presentationTime(for: pts, hostNow: CMTimeGetSeconds(hostNow))
        return CMTime(seconds: when, preferredTimescale: 1_000_000_000)
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
        data.withUnsafeBytes { raw -> [Data] in
            let bytes = raw.bindMemory(to: UInt8.self)
            let count = bytes.count
            var headers: [(payload: Int, code: Int)] = []
            var index = 0
            while index + 3 < count {
                if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                    headers.append((index + 3, index))
                    index += 3
                    continue
                }
                if index + 4 < count, bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 0, bytes[index + 3] == 1 {
                    headers.append((index + 4, index))
                    index += 4
                    continue
                }
                index += 1
            }
            if headers.isEmpty {
                return count == 0 ? [] : [data]
            }
            var units: [Data] = []
            for offset in headers.indices {
                let begin = headers[offset].payload
                let end = offset + 1 < headers.count ? headers[offset + 1].code : count
                if begin < end {
                    units.append(Data(UnsafeRawBufferPointer(rebasing: raw[begin..<end])))
                }
            }
            return units
        }
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

    private func makeSampleBuffer(nals: [Data], format: CMVideoFormatDescription, pts: CMTime, duration: CMTime) -> CMSampleBuffer? {
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
            decodeTimeStamp: .invalid
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

    // MARK: - Audio

    private func consumeAudio(_ packet: MediaPacket) {
        if packet.isConfig {
            configureAudio(asc: packet.data, fallbackRate: packet.sampleRate, fallbackChannels: packet.channels)
            return
        }
        if audioConverter == nil {
            // Some encoders, OBS included, never send the AAC sequence header to a
            // track that is already attached. Without it the audio was dropped silently.
            // Rebuild an AAC-LC AudioSpecificConfig from the frame's rate and channel count.
            guard let asc = knownASC ?? Self.audioSpecificConfig(sampleRate: packet.sampleRate, channels: packet.channels) else { return }
            configureAudio(asc: asc, fallbackRate: packet.sampleRate, fallbackChannels: packet.channels)
            if audioConverter == nil { return }
        }
        let raw = Self.payload(of: packet)
        guard !raw.isEmpty, let buffer = decodeAAC(raw) else { return }
        meter(buffer)
        schedule(buffer)
    }

    private func configureAudio(asc: Data, fallbackRate: Int32, fallbackChannels: Int32) {
        guard asc != audioSpecificConfig else { return }
        // Marked immediately. A failed connection must not be retried on every packet.
        audioSpecificConfig = asc
        knownASC = asc
        let parsed = Self.parseASC(asc)
        let rate = parsed?.sampleRate ?? Double(fallbackRate > 0 ? fallbackRate : 48000)
        let channels = AVAudioChannelCount(max(1, min(parsed?.channels ?? Int(fallbackChannels > 0 ? fallbackChannels : 2), 8)))
        guard rate >= 8000, let compressed = AVAudioFormat(settings: [
            AVFormatIDKey: parsed?.formatID ?? kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
        ]) else { return }
        stopAudio()
        guard let playback = installPlayback(compressed: compressed, sourceRate: rate, sourceChannels: channels) else { return }
        audioConverter = playback.converter
        compressedFormat = compressed
        audioFormat = playback.format
        applyCookie(to: playback.converter, asc: asc)
        playerNode.volume = muted ? 0 : 1
        NSLog("MediaFlowRX: audio pronto %.0f Hz %u canali", playback.format.sampleRate, playback.format.channelCount)
    }

    /// The decoder reads profile, SBR and PS from the cookie. Without it HE-AAC plays at the wrong rate.
    private func applyCookie(to converter: AVAudioConverter, asc: Data) {
        converter.magicCookie = Self.esds(for: asc)
        usingCookie = converter.magicCookie != nil
    }

    /// The output device changed (headphones, AirPlay, sample rate). The engine has stopped on its own:
    /// the chain is rebuilt on the next packet, from the same configuration.
    private func audioConfigurationChanged() {
        stopAudio()
        audioConverter = nil
        compressedFormat = nil
        audioFormat = nil
        audioSpecificConfig = Data()
        NSLog("MediaFlowRX: uscita audio cambiata, riconfiguro")
    }

    private func stopAudio() {
        playerNode.stop()
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioReady = false
        audioStartFailed = false
        queuedFrames = 0
        audioGeneration += 1
        audioGate.reset()
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
        if let buffer = convert(packet) {
            return buffer
        }
        // A decoder that refuses the cookie gets one more chance without it, as before.
        guard usingCookie, let compressedFormat, let audioFormat,
              let plain = AVAudioConverter(from: compressedFormat, to: audioFormat) else { return nil }
        audioConverter = plain
        usingCookie = false
        NSLog("MediaFlowRX: magic cookie AAC rifiutato, decodifico senza")
        return convert(packet)
    }

    private func convert(_ packet: Data) -> AVAudioPCMBuffer? {
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
        switch audioGate.decide(queued: Double(queuedFrames) / buffer.format.sampleRate) {
        case .drop:
            return
        case .primeThenPlay(let seconds):
            if let silence = Self.silence(format: buffer.format, seconds: seconds) {
                enqueueAudio(silence)
            }
        case .play:
            break
        }
        enqueueAudio(buffer)
    }

    private func enqueueAudio(_ buffer: AVAudioPCMBuffer) {
        let frames = AVAudioFramePosition(buffer.frameLength)
        let generation = audioGeneration
        queuedFrames += frames
        playerNode.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.queue.async {
                guard self.audioGeneration == generation else { return }
                self.queuedFrames = max(0, self.queuedFrames - frames)
            }
        }
    }

    private static func silence(format: AVAudioFormat, seconds: Double) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(format.sampleRate * seconds)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = frames
        for channel in 0..<Int(format.channelCount) {
            channels[channel].update(repeating: 0, count: Int(frames))
        }
        return buffer
    }

    /// The engine marks the ADTS header with prefix_size. A header with CRC is two bytes longer.
    private static func payload(of packet: MediaPacket) -> Data {
        let data = packet.data
        var header = max(0, packet.prefixSize)
        if header == 7, data.count > 1, data[data.startIndex] == 0xFF, (data[data.startIndex + 1] & 0x01) == 0 {
            header = 9
        }
        guard data.count > header else { return header == 0 ? data : Data() }
        return header == 0 ? data : data.subdata(in: (data.startIndex + header)..<data.endIndex)
    }

    private static let aacRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    private static func audioSpecificConfig(sampleRate: Int32, channels: Int32) -> Data? {
        guard let index = aacRates.firstIndex(of: Int(sampleRate)), (1...7).contains(channels) else { return nil }
        let objectTypeAACLC: UInt8 = 2
        let first = (objectTypeAACLC << 3) | UInt8(index >> 1)
        let second = (UInt8(index & 1) << 7) | (UInt8(channels) << 3)
        return Data([first, second])
    }

    private struct AudioConfig {
        var formatID: AudioFormatID
        var sampleRate: Double
        var channels: Int
    }

    /// AudioSpecificConfig (ISO 14496-3 1.6.2.1): object type, rate and channels,
    /// plus the SBR rate for HE-AAC, which the decoder outputs instead of the core rate.
    private static func parseASC(_ data: Data) -> AudioConfig? {
        var reader = BitReader(data)
        func objectType() -> Int? {
            guard let type = reader.read(5) else { return nil }
            guard type == 31 else { return type }
            return reader.read(6).map { 32 + $0 }
        }
        func frequency() -> Double? {
            guard let index = reader.read(4) else { return nil }
            if index == 15 { return reader.read(24).map(Double.init) }
            return index < aacRates.count ? Double(aacRates[index]) : nil
        }
        guard let type = objectType(), let coreRate = frequency(), let config = reader.read(4) else { return nil }
        var channels = config == 0 ? 2 : (config == 7 ? 8 : config)
        var rate = coreRate
        var formatID = kAudioFormatMPEG4AAC
        if type == 5 || type == 29 {
            if let extended = frequency() { rate = extended }
            formatID = type == 29 ? kAudioFormatMPEG4AAC_HE_V2 : kAudioFormatMPEG4AAC_HE
            if type == 29 { channels = 2 }
        }
        return AudioConfig(formatID: formatID, sampleRate: rate, channels: channels)
    }

    /// The MPEG-4 ES descriptor that wraps the AudioSpecificConfig: the cookie Core Audio expects for AAC.
    private static func esds(for asc: Data) -> Data? {
        guard !asc.isEmpty, asc.count < 100 else { return nil }
        let specific = [UInt8(0x05), UInt8(asc.count)] + [UInt8](asc)
        let decoderConfig: [UInt8] = [0x04, UInt8(13 + specific.count), 0x40, 0x15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] + specific
        let slConfig: [UInt8] = [0x06, 0x01, 0x02]
        let body: [UInt8] = [0, 0, 0] + decoderConfig + slConfig
        return Data([0x03, UInt8(body.count)] + body)
    }
}

nonisolated private struct BitReader {
    private let bytes: [UInt8]
    private var position = 0

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    mutating func read(_ count: Int) -> Int? {
        guard position + count <= bytes.count * 8 else { return nil }
        var value = 0
        for _ in 0..<count {
            let bit = (bytes[position / 8] >> (7 - UInt8(position % 8))) & 1
            value = (value << 1) | Int(bit)
            position += 1
        }
        return value
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
