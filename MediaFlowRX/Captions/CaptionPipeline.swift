import Foundation

/// Decodes CEA-608 CC1 from the video, on its own serial queue fed straight from the engine thread.
/// It drives the overlay and writes the SRT next to each recording. Every stored property is
/// touched only on `queue`.
nonisolated final class CaptionPipeline: @unchecked Sendable {
    struct Configuration: Sendable {
        var saveSRT = true
        var folder: URL?
        var slug = ""
    }

    /// The screen to show, with the host time (seconds) at which its frame appears. Called on `queue`.
    var onScreen: (@Sendable (CaptionScreen, Double?) -> Void)?
    var onPresence: (@Sendable (CaptionPresence) -> Void)?
    /// Cues written to the SRT of the recording in progress, nil when none is being written.
    var onCueCount: (@Sendable (Int?) -> Void)?

    private let queue = DispatchQueue(label: "MediaFlowRX.captions", qos: .userInitiated)
    private let decoder: OpaquePointer?
    private var configuration = Configuration()
    private var displayTime: (@Sendable (UInt64) -> Double?)?

    private struct Pending {
        var pts: UInt64
        var dts: UInt64
        var epoch: UInt32
        var triplets: [CaptionTriplet]
    }
    /// Caption data arrives in decode order. It is released in presentation order, once a
    /// picture with a later decode time proves no earlier frame is still to come.
    private var pending: [Pending] = []
    private static let maxPending = 32

    private var presence = CaptionPresenceTracker()
    private var publishedPresence = CaptionPresence()
    private var screen = CaptionScreen()

    private struct Session {
        let epoch: UInt32
        let slice: Int
        var timeline = RecordingTimeline()
        var writer: SRTWriter?
        /// Where the MP4 really starts on `timeline`, once its length is known.
        var fileStart = 0.0
    }
    /// Below this the gap between the SRT and the MP4 is the audio tail, not a different first keyframe.
    private static let startTolerance = 0.2
    private var active: Session?
    /// Follows the pictures while nothing records. The engine starts an MP4 with the GOP it has
    /// cached, so a recording begins on the last keyframe before its first frame, not the next one.
    private var idle = RecordingTimeline()
    /// Finished SRTs waiting for their MP4 to reach its final name.
    private var closing: [Session] = []
    private static let maxClosing = 16
    private var lastEpoch: UInt32 = 0
    private var publishedCueCount: Int??

    init() {
        decoder = mfrx_captions_create()
    }

    deinit {
        mfrx_captions_free(decoder)
    }

    // MARK: - Interface, callable from any thread

    func configure(_ value: Configuration) {
        queue.async { self.configuration = value }
    }

    /// Where the preview shows a frame: lets the overlay change with the picture, not before it.
    func setDisplayTime(_ provider: @escaping @Sendable (UInt64) -> Double?) {
        queue.async { self.displayTime = provider }
    }

    func consume(_ packet: MediaPacket) {
        guard packet.isVideo, !packet.isConfig else { return }
        queue.async { self.consumeOnQueue(packet) }
    }

    /// The stream went away: the screen and the services start over. Recordings are untouched.
    func reset() {
        queue.async { self.resetOnQueue() }
    }

    /// The app stopped recording. The SRT waits for its MP4 to close, to take the same name.
    func recordingStopped() {
        queue.async { self.finishActive() }
    }

    /// The engine closed an MP4 that lasts `duration` seconds. `continuing` when the recording goes on in the next slice.
    func sliceClosed(epoch: UInt32, slice: Int, continuing: Bool, duration: Double) {
        queue.async { self.sliceClosedOnQueue(epoch: epoch, slice: slice, continuing: continuing, duration: duration) }
    }

    /// The MP4 reached its final name, possibly much later when copied to another volume.
    func fileStored(_ path: String, epoch: UInt32, slice: Int) {
        queue.async { self.fileStoredOnQueue(URL(fileURLWithPath: path), epoch: epoch, slice: slice) }
    }

    // MARK: - Queue side

    private func consumeOnQueue(_ packet: MediaPacket) {
        trackRecording(packet)
        switch CaptionExtractor.firstNAL(of: packet.data, prefixSize: packet.prefixSize, codec: packet.codec) {
        case .sei:
            let triplets = CaptionExtractor.triplets(in: packet.data, prefixSize: packet.prefixSize, codec: packet.codec)
            guard !triplets.isEmpty else { return }
            if let index = pending.firstIndex(where: { $0.pts == packet.pts && $0.dts == packet.dts }) {
                pending[index].triplets += triplets
            } else {
                let entry = Pending(pts: packet.pts, dts: packet.dts, epoch: packet.recordEpoch, triplets: triplets)
                let index = pending.firstIndex { $0.pts > packet.pts } ?? pending.endIndex
                pending.insert(entry, at: index)
            }
            if pending.count > Self.maxPending {
                release(upTo: pending[0].pts)
            }
        case .picture:
            if let session = active {
                let wasStarted = session.timeline.started
                active?.timeline.notePicture(dts: packet.dts, isKey: packet.isKey)
                if !wasStarted, active?.timeline.started == true, let writer = session.writer {
                    // A caption already on screen when the file starts belongs to it from 0.
                    let text = screen.cueText
                    writer.update(plain: text.plain, tagged: text.tagged, at: 0)
                }
            } else {
                // The cached GOP never spans a timestamp jump.
                if !idle.continues(dts: packet.dts) { idle.reset() }
                idle.notePicture(dts: packet.dts, isKey: packet.isKey)
            }
            release(upTo: packet.dts)
        case .other:
            break
        }
    }

    private func release(upTo limit: UInt64) {
        let end = pending.firstIndex { $0.pts > limit } ?? pending.endIndex
        guard end > 0 else { return }
        let ready = pending[..<end]
        pending.removeFirst(end)
        let now = ProcessInfo.processInfo.systemUptime
        for entry in ready {
            decode(entry, now: now)
        }
        publishPresence(at: now)
    }

    private func decode(_ entry: Pending, now: TimeInterval) {
        var changed = false
        for triplet in entry.triplets {
            let channel = presence.note(triplet, at: now)
            guard triplet.type == 0, channel == 1 else { continue }
            if mfrx_captions_decode(decoder, triplet.byte1, triplet.byte2) != 0 {
                changed = true
            }
        }
        guard changed, let decoder else { return }
        let next = CaptionScreen(decoder: decoder)
        guard next != screen else { return }
        screen = next
        onScreen?(next, displayTime?(entry.pts))
        if let session = active, session.epoch == entry.epoch, let writer = session.writer,
           let time = session.timeline.time(pts: entry.pts, dts: entry.dts) {
            let text = next.cueText
            writer.update(plain: text.plain, tagged: text.tagged, at: time)
            publishCueCount()
        }
    }

    private func publishPresence(at now: TimeInterval) {
        let current = presence.presence(at: now)
        guard current != publishedPresence else { return }
        publishedPresence = current
        onPresence?(current)
    }

    private func resetOnQueue() {
        pending.removeAll()
        idle.reset()
        mfrx_captions_reset(decoder)
        presence.reset()
        publishedPresence = CaptionPresence()
        if !screen.isEmpty {
            screen = CaptionScreen()
            onScreen?(screen, nil)
            if let writer = active?.writer, let time = active?.timeline.now {
                writer.update(plain: "", tagged: "", at: time)
            }
        }
    }

    // MARK: - Recordings

    /// Frames carry the epoch of the recording they reach in the MP4. A new epoch opens a new SRT,
    /// whose timeline starts on the same keyframe the MP4 starts on.
    private func trackRecording(_ packet: MediaPacket) {
        let epoch = packet.recordEpoch
        if epoch == 0 {
            if active != nil { finishActive() }
            return
        }
        guard epoch != active?.epoch, epoch > lastEpoch else { return }
        finishActive()
        lastEpoch = epoch
        let session = Session(epoch: epoch, slice: 1, timeline: idle.continued(), writer: makeWriter(epoch: epoch, slice: 1))
        idle.reset()
        if session.timeline.started {
            let text = screen.cueText
            session.writer?.update(plain: text.plain, tagged: text.tagged, at: 0)
        }
        active = session
        publishCueCount()
    }

    private func makeWriter(epoch: UInt32, slice: Int) -> SRTWriter? {
        guard configuration.saveSRT, let folder = configuration.folder else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let name = ".\(configuration.slug)_\(formatter.string(from: Date()))~\(epoch)-\(slice).srt"
        return SRTWriter(url: folder.appending(path: name))
    }

    private func finishActive() {
        guard let session = active else { return }
        active = nil
        park(session)
        publishCueCount()
    }

    private func park(_ session: Session) {
        session.writer?.finish(at: session.timeline.now)
        closing.append(session)
        if closing.count > Self.maxClosing {
            // A file the engine never reported, most likely dropped for being too short.
            discard(closing.removeFirst())
        }
    }

    private func sliceClosedOnQueue(epoch: UInt32, slice: Int, continuing: Bool, duration: Double) {
        guard let session = active, session.epoch == epoch, session.slice == slice else {
            // Already finished: the recording stopped before the engine closed the file.
            if let index = closing.firstIndex(where: { $0.epoch == epoch && $0.slice == slice }) {
                closing[index].fileStart = Self.fileStart(of: closing[index].timeline, end: closing[index].timeline.now, duration: duration)
            }
            return
        }
        var finished = session
        let end = continuing ? (session.timeline.lastKeyTime ?? session.timeline.now) : session.timeline.now
        finished.fileStart = Self.fileStart(of: session.timeline, end: end, duration: duration)
        active = nil
        park(finished)
        if continuing {
            // The engine switches file on a keyframe, and closes the old one just after it.
            let text = screen.cueText
            let next = Session(
                epoch: epoch,
                slice: slice + 1,
                timeline: session.timeline.continued(),
                writer: makeWriter(epoch: epoch, slice: slice + 1)
            )
            if next.timeline.started {
                next.writer?.update(plain: text.plain, tagged: text.tagged, at: 0)
            }
            active = next
        } else {
            active = nil
        }
        publishCueCount()
    }

    /// The engine may start the file one GOP away from where the timeline guessed, when the stream
    /// had just connected. Its length tells where it really started.
    private static func fileStart(of timeline: RecordingTimeline, end: Double, duration: Double) -> Double {
        guard timeline.started, duration > 0 else { return 0 }
        let start = end - duration
        return abs(start) > startTolerance ? start : 0
    }

    private func fileStoredOnQueue(_ mp4: URL, epoch: UInt32, slice: Int) {
        guard let index = closing.firstIndex(where: { $0.epoch == epoch && $0.slice == slice }) else { return }
        let session = closing.remove(at: index)
        deliver(session, next: mp4)
    }

    private func deliver(_ session: Session, next mp4: URL) {
        guard let writer = session.writer else { return }
        if session.fileStart != 0 {
            writer.shift(by: -session.fileStart)
        }
        guard writer.cueCount > 0 else {
            discard(session)
            return
        }
        let manager = FileManager.default
        var destination = mp4.deletingPathExtension().appendingPathExtension("srt")
        var number = 2
        while manager.fileExists(atPath: destination.path) {
            destination = mp4.deletingPathExtension().appendingPathExtension("\(number).srt")
            number += 1
        }
        if (try? manager.moveItem(at: writer.url, to: destination)) == nil {
            NSLog("%@", "MediaFlowRX: SRT non spostato in \(destination.path)" as NSString)
        }
    }

    private func discard(_ session: Session) {
        guard let writer = session.writer else { return }
        writer.finish(at: session.timeline.now)
        try? FileManager.default.removeItem(at: writer.url)
    }

    private func publishCueCount() {
        let count: Int? = active?.writer?.cueCount
        guard publishedCueCount != .some(count) else { return }
        publishedCueCount = .some(count)
        onCueCount?(count)
    }
}
