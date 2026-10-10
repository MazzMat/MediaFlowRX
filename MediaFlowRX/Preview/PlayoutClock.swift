import Foundation

/// Maps stream timestamps (ms) to the host time, in seconds, at which the preview shows each frame.
/// Frames are shown `delay` after they arrive. The timeline follows the stream timestamps,
/// re-anchors when a frame would be late or the timestamps jump, and slowly pulls back
/// latency that built up, so it never grows for good.
nonisolated struct PlayoutClock {
    /// A small fixed buffer keeps a late or bursty packet from showing up as a jump.
    static let delay = 0.12
    /// Past this lead over the delay, the timeline catches up a little on every frame,
    /// until the lead is back under `settledLead`. The gap leaves room for B-frame reordering.
    static let catchUpLead = 0.25
    static let settledLead = 0.03
    /// Past this lead, or this far backwards, the timestamps jumped: the timeline restarts from now.
    static let jumpLead = 1.0
    /// Smaller than any frame interval, so frames keep their order while catching up.
    static let catchUpStep = 0.004
    static let lateTolerance = 0.02

    private(set) var isReady = false
    private var anchorHost = 0.0
    private var anchorPTS: UInt64 = 0
    private var catchingUp = false

    mutating func reset() {
        isReady = false
        catchingUp = false
    }

    mutating func presentationTime(for pts: UInt64, hostNow: Double) -> Double {
        guard isReady else {
            isReady = true
            return reanchor(pts: pts, hostNow: hostNow)
        }
        let deltaMs = Int64(bitPattern: pts) - Int64(bitPattern: anchorPTS)
        // Small negative deltas are B-frames shown before the frame the timeline was anchored on.
        if Double(deltaMs) / 1000 < -Self.jumpLead {
            return reanchor(pts: pts, hostNow: hostNow)
        }
        let offset = Double(deltaMs) / 1000
        var when = anchorHost + offset
        let ahead = when - hostNow
        if ahead < -Self.lateTolerance {
            // The frame arrived after its time. Re-anchor the timeline on now plus the buffer.
            anchorHost = hostNow + Self.delay - offset
            return hostNow + Self.delay
        }
        let lead = ahead - Self.delay
        if lead > Self.jumpLead {
            // Timestamps jumped forward: waiting for them would freeze the picture.
            return reanchor(pts: pts, hostNow: hostNow)
        }
        if lead > Self.catchUpLead {
            catchingUp = true
        } else if lead <= Self.settledLead {
            catchingUp = false
        }
        if catchingUp {
            anchorHost -= Self.catchUpStep
            when -= Self.catchUpStep
        }
        return when
    }

    private mutating func reanchor(pts: UInt64, hostNow: Double) -> Double {
        anchorHost = hostNow + Self.delay
        anchorPTS = pts
        catchingUp = false
        return anchorHost
    }
}

/// Keeps the audio queued in the player close to the video delay. After a gap the queue is
/// primed with silence up to the delay; when it grows past the limit (a burst, or an encoder
/// clock faster than the sound card) buffers are dropped until it is back at the delay.
nonisolated struct AudioLatencyGate {
    enum Decision: Equatable {
        case play
        case primeThenPlay(silence: Double)
        case drop
    }

    static let maxLead = 0.35

    private var draining = false

    mutating func reset() {
        draining = false
    }

    mutating func decide(queued: Double) -> Decision {
        if queued > Self.maxLead {
            draining = true
        }
        if draining {
            if queued > PlayoutClock.delay { return .drop }
            draining = false
        }
        return queued <= 0 ? .primeThenPlay(silence: PlayoutClock.delay) : .play
    }
}
