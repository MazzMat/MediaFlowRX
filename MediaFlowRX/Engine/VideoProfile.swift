import Foundation

enum VideoProfile {
    static func describe(_ data: Data, codec: Int32) -> String? {
        for nal in nalUnits(data) {
            if codec == MFRX_CODEC_H264, let text = h264(nal) { return text }
            if codec == MFRX_CODEC_H265, let text = hevc(nal) { return text }
        }
        return nil
    }

    private static func h264(_ nal: [UInt8]) -> String? {
        guard nal.count >= 4, nal[0] & 0x1F == 7 else { return nil }
        let profile = Int(nal[1])
        let constraints = nal[2]
        let level = Int(nal[3])
        let name: String
        switch profile {
        case 66: name = constraints & 0x40 != 0 ? "Constrained Baseline" : "Baseline"
        case 77: name = "Main"
        case 88: name = "Extended"
        case 100: name = "High"
        case 110: name = "High 10"
        case 122: name = "High 4:2:2"
        case 244: name = "High 4:4:4"
        default: name = "Profile \(profile)"
        }
        // Level 1b is stored as level 11 with constraint_set3, and only for Baseline and Main.
        if level == 11, constraints & 0x10 != 0, profile == 66 || profile == 77 {
            return "\(name) 1b"
        }
        return "\(name) \(levelText(level, divisor: 10))"
    }

    private static func hevc(_ nal: [UInt8]) -> String? {
        guard nal.count >= 2, (nal[0] & 0x7E) >> 1 == 33 else { return nil }
        // Past the 2-byte header and one id/sub-layer byte, profile_tier_level is
        // the profile, 4 compatibility bytes, 6 constraint bytes, then the level.
        let payload = removingEmulationPrevention(Array(nal.dropFirst(2).prefix(24)))
        guard payload.count >= 13 else { return nil }
        let tierHigh = payload[1] & 0x20 != 0
        let profile = Int(payload[1] & 0x1F)
        let level = Int(payload[12])
        let name: String
        switch profile {
        case 1: name = "Main"
        case 2: name = "Main 10"
        case 3: name = "Main Still Picture"
        case 4: name = "Range Extensions"
        default: name = "Profile \(profile)"
        }
        let tier = tierHigh ? " High tier" : ""
        return "\(name) \(levelText(level, divisor: 30))\(tier)"
    }

    private static func levelText(_ value: Int, divisor: Int) -> String {
        let whole = value / divisor
        let tenth = (value % divisor) * 10 / divisor
        return tenth == 0 ? "\(whole)" : "\(whole).\(tenth)"
    }

    private static func removingEmulationPrevention(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var zeros = 0
        for byte in bytes {
            if zeros >= 2, byte == 0x03 {
                zeros = 0
                continue
            }
            out.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return out
    }

    private static func nalUnits(_ data: Data) -> [[UInt8]] {
        let bytes = [UInt8](data)
        var starts: [(payload: Int, code: Int)] = []
        var index = 0
        while index + 3 <= bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                let code = index > 0 && bytes[index - 1] == 0 ? index - 1 : index
                starts.append((index + 3, code))
                index += 3
            } else {
                index += 1
            }
        }
        guard !starts.isEmpty else { return bytes.isEmpty ? [] : [bytes] }
        return starts.indices.compactMap { offset in
            let begin = starts[offset].payload
            let end = offset + 1 < starts.count ? starts[offset + 1].code : bytes.count
            return begin < end ? Array(bytes[begin..<end]) : nil
        }
    }
}
