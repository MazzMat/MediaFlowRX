import Foundation

/// The CEA-608 display: up to 15 rows of 32 columns.
nonisolated struct CaptionScreen: Equatable, Sendable {
    static let rows = Int(MFRX_CAPTION_ROWS)
    static let columns = Int(MFRX_CAPTION_COLS)

    enum Color: Int, Sendable {
        case white, green, blue, cyan, red, yellow, magenta
    }

    struct Run: Equatable, Sendable {
        var text: String
        var color: Color
        var italic: Bool
        var underline: Bool
    }

    /// A row from its first to its last character. Empty cells inside it are spaces.
    struct Row: Equatable, Sendable, Identifiable {
        var row: Int
        var column: Int
        var runs: [Run]

        var id: Int { row }
        var text: String { runs.map(\.text).joined() }
        var length: Int { runs.reduce(0) { $0 + $1.text.count } }
    }

    var rows: [Row] = []
    var rollUp = false

    var isEmpty: Bool { rows.isEmpty }

    /// Text for a subtitle cue. In roll-up only the line being written: the rows above it
    /// were already part of the previous cues.
    var cueText: (plain: String, tagged: String) {
        let lines = rollUp ? Array(rows.suffix(1)) : rows
        let plain = lines.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
        let tagged = lines.map { line -> String in
            var out = ""
            for run in line.runs {
                out += run.italic ? "<i>\(run.text)</i>" : run.text
            }
            return out.trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
        return (plain, tagged.replacingOccurrences(of: "</i><i>", with: ""))
    }

    /// Reads the displayed memory of the decoder.
    init(decoder: OpaquePointer) {
        rollUp = mfrx_captions_rollup(decoder) > 0
        var buffer = [CChar](repeating: 0, count: 8)
        for row in 0..<Self.rows {
            var cells: [(column: Int, text: String, style: Int32, underline: Bool)] = []
            for column in 0..<Self.columns {
                var style: Int32 = 0
                var underline: Int32 = 0
                let length = mfrx_captions_cell(decoder, Int32(row), Int32(column), &buffer, &style, &underline)
                guard length > 0 else { continue }
                cells.append((column, String(cString: buffer), style, underline != 0))
            }
            let visible = cells.filter { !$0.text.allSatisfy(\.isWhitespace) }
            guard let first = visible.first, let last = visible.last else { continue }
            var runs: [Run] = []
            var index = cells.firstIndex { $0.column == first.column } ?? 0
            var column = first.column
            while column <= last.column {
                let run: Run
                if index < cells.count, cells[index].column == column {
                    let cell = cells[index]
                    let italic = cell.style == MFRX_CAPTION_STYLE_ITALICS
                    run = Run(
                        text: cell.text,
                        color: italic ? .white : Color(rawValue: Int(cell.style)) ?? .white,
                        italic: italic,
                        underline: cell.underline
                    )
                    index += 1
                } else {
                    run = Run(text: " ", color: runs.last?.color ?? .white, italic: runs.last?.italic ?? false, underline: false)
                }
                if var previous = runs.last, previous.color == run.color, previous.italic == run.italic, previous.underline == run.underline {
                    previous.text += run.text
                    runs[runs.count - 1] = previous
                } else {
                    runs.append(run)
                }
                column += 1
            }
            rows.append(Row(row: row, column: first.column, runs: runs))
        }
    }

    init() {}
}

/// Writes cues to an SRT file while the recording runs. Each cue lands on disk as soon as it
/// closes, so a crash keeps everything up to the last caption.
nonisolated final class SRTWriter {
    let url: URL
    private(set) var cueCount = 0
    private var handle: FileHandle?
    private var pending: (start: Double, plain: String, tagged: String)?
    private var lastTime = 0.0
    private var cues: [(start: Double, end: Double, text: String)] = []

    init?(url: URL) {
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else { return nil }
        self.url = url
        self.handle = handle
    }

    /// The text on screen changed at `time`, in seconds of the recording.
    /// A cue that only grows (paint-on, or roll-up typing) keeps its start.
    func update(plain: String, tagged: String, at time: Double) {
        let time = max(time, lastTime)
        lastTime = time
        guard let current = pending else {
            if !plain.isEmpty { pending = (time, plain, tagged) }
            return
        }
        if plain == current.plain { return }
        if !plain.isEmpty, plain.hasPrefix(current.plain) {
            pending = (current.start, plain, tagged)
            return
        }
        write(start: current.start, end: time, text: current.tagged)
        pending = plain.isEmpty ? nil : (time, plain, tagged)
    }

    /// Closes the cue still on screen at `time` and the file.
    func finish(at time: Double) {
        if let current = pending {
            write(start: current.start, end: max(time, current.start + 1), text: current.tagged)
            pending = nil
        }
        try? handle?.close()
        handle = nil
    }

    /// Moves every cue of the finished file by `offset` seconds, dropping those that end before 0.
    func shift(by offset: Double) {
        guard handle == nil, !cues.isEmpty else { return }
        let moved = cues.compactMap { cue -> (start: Double, end: Double, text: String)? in
            let end = cue.end + offset
            return end > 0 ? (max(0, cue.start + offset), end, cue.text) : nil
        }
        cues = moved
        cueCount = moved.count
        let text = moved.enumerated().map { Self.block($0.offset + 1, $0.element.start, $0.element.end, $0.element.text) }.joined()
        try? Data(text.utf8).write(to: url)
    }

    private func write(start: Double, end: Double, text: String) {
        guard end > start, !text.isEmpty, let handle else { return }
        cues.append((start, end, text))
        cueCount += 1
        try? handle.write(contentsOf: Data(Self.block(cueCount, start, end, text).utf8))
    }

    private static func block(_ number: Int, _ start: Double, _ end: Double, _ text: String) -> String {
        "\(number)\n\(timestamp(start)) --> \(timestamp(end))\n\(text)\n\n"
    }

    static func timestamp(_ seconds: Double) -> String {
        let total = Int((max(0, seconds) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", total / 3_600_000, (total / 60_000) % 60, (total / 1000) % 60, total % 1000)
    }
}

/// The MP4 timeline of a recording, rebuilt from the video timestamps the way ZLMediaKit's
/// muxer does: it starts at 0 on the first keyframe, follows the DTS, and on a jump of more
/// than 300 ms, or backwards (an encoder that reset its clock), it advances by one frame only.
nonisolated struct RecordingTimeline {
    private static let maxDelta: Int64 = 300
    private static let maxCTS: Int64 = 500

    private(set) var started = false
    private var lastDTS: Int64 = 0
    private var relative: Int64 = 0
    private var lastDelta: Int64 = 1
    private var recent: [(dts: UInt64, relative: Int64)] = []
    private var lastKey: (dts: UInt64, relative: Int64)?

    /// Last time reached, in seconds of the recording.
    var now: Double { Double(relative) / 1000 }
    /// Time of the last keyframe, where the engine switches to the next file.
    var lastKeyTime: Double? { lastKey.map { Double($0.relative) / 1000 } }

    mutating func reset() {
        self = RecordingTimeline()
    }

    /// The next file of the same recording, which starts on the last keyframe seen here.
    func continued() -> RecordingTimeline {
        guard let key = lastKey else { return RecordingTimeline() }
        var next = self
        next.relative -= key.relative
        next.recent = recent.filter { $0.dts >= key.dts }.map { ($0.dts, $0.relative - key.relative) }
        next.lastKey = (key.dts, 0)
        return next
    }

    /// False when the decode time jumps, as when the encoder resets its clock.
    func continues(dts: UInt64) -> Bool {
        guard started else { return true }
        let delta = Int64(bitPattern: dts) - lastDTS
        return delta >= 0 && delta <= Self.maxDelta
    }

    mutating func notePicture(dts: UInt64, isKey: Bool) {
        let value = Int64(bitPattern: dts)
        if !started {
            guard isKey else { return }
            started = true
            lastDTS = value
            relative = 0
        } else if value != lastDTS {
            let delta = value - lastDTS
            if delta > 0, delta <= Self.maxDelta {
                relative += delta
                lastDelta = delta
            } else {
                relative += lastDelta
            }
            lastDTS = value
        }
        if isKey { lastKey = (dts, relative) }
        if recent.last?.dts != dts {
            recent.append((dts, relative))
            if recent.count > 256 { recent.removeFirst(recent.count - 256) }
        }
    }

    /// Recording time at which the frame with these timestamps is shown, nil before the file starts.
    /// The decode time of caption data need not match a picture's (RTSP gives it the presentation time),
    /// so it is placed after the closest picture decoded before it.
    func time(pts: UInt64, dts: UInt64) -> Double? {
        guard started, let entry = recent.last(where: { $0.dts <= dts }) else { return nil }
        let gap = Int64(bitPattern: dts) - Int64(bitPattern: entry.dts)
        guard gap <= Self.maxDelta else { return nil }
        var cts = Int64(bitPattern: pts) - Int64(bitPattern: dts)
        if abs(cts) > Self.maxCTS { cts = 0 }
        return Double(max(0, entry.relative + gap + cts)) / 1000
    }
}
