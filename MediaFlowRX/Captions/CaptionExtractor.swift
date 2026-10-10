import Foundation

/// One cc_data entry: cc_type 0 and 1 are CEA-608 field 1 and field 2, 2 and 3 are CEA-708 (DTVCC).
nonisolated struct CaptionTriplet: Equatable, Sendable {
    var type: UInt8
    var byte1: UInt8
    var byte2: UInt8
}

/// Reads the closed caption data that encoders put in the video: an ATSC A/53 `GA94` block
/// inside a user_data_registered_itu_t_t35 SEI message, the same in H.264 and HEVC.
nonisolated enum CaptionExtractor {
    enum NALKind {
        case sei
        case picture
        case other
    }

    /// Kind of the first NAL unit in the packet. The engine splits access units, so a SEI
    /// arrives on its own or ahead of the slices, never after them.
    static func firstNAL(of data: Data, prefixSize: Int, codec: Int32) -> NALKind {
        guard let header = headerOffset(data, prefixSize: prefixSize), header < data.count else { return .other }
        return kind(data[data.startIndex + header], codec: codec)
    }

    /// Valid cc_data of every caption SEI in the packet, in stream order.
    static func triplets(in data: Data, prefixSize: Int, codec: Int32) -> [CaptionTriplet] {
        guard firstNAL(of: data, prefixSize: prefixSize, codec: codec) == .sei else { return [] }
        let headerLength = codec == MFRX_CODEC_H265 ? 2 : 1
        var result: [CaptionTriplet] = []
        for nal in nalUnits([UInt8](data)) where nal.count > headerLength && kind(nal[0], codec: codec) == .sei {
            let rbsp = removingEmulationPrevention(nal[headerLength...])
            readMessages(rbsp, into: &result)
        }
        return result
    }

    private static func kind(_ header: UInt8, codec: Int32) -> NALKind {
        if codec == MFRX_CODEC_H264 {
            let type = header & 0x1F
            if type == 6 { return .sei }
            return (1...5).contains(type) ? .picture : .other
        }
        if codec == MFRX_CODEC_H265 {
            let type = (header & 0x7E) >> 1
            if type == 39 || type == 40 { return .sei }
            return type <= 31 ? .picture : .other
        }
        return .other
    }

    private static func headerOffset(_ data: Data, prefixSize: Int) -> Int? {
        if prefixSize > 0 { return prefixSize }
        let start = data.startIndex
        if data.count > 3, data[start] == 0, data[start + 1] == 0, data[start + 2] == 1 { return 3 }
        if data.count > 4, data[start] == 0, data[start + 1] == 0, data[start + 2] == 0, data[start + 3] == 1 { return 4 }
        return data.isEmpty ? nil : 0
    }

    /// sei_message() loop of ITU-T H.264 7.3.2.3.1 and H.265 7.3.5.
    private static func readMessages(_ rbsp: [UInt8], into result: inout [CaptionTriplet]) {
        var index = 0
        while index < rbsp.count {
            if rbsp[index] == 0x80, index == rbsp.count - 1 { return }
            var type = 0
            while index < rbsp.count, rbsp[index] == 0xFF {
                type += 255
                index += 1
            }
            guard index < rbsp.count else { return }
            type += Int(rbsp[index])
            index += 1
            var size = 0
            while index < rbsp.count, rbsp[index] == 0xFF {
                size += 255
                index += 1
            }
            guard index < rbsp.count else { return }
            size += Int(rbsp[index])
            index += 1
            guard index + size <= rbsp.count else { return }
            if type == 4 {
                readA53(rbsp[index..<(index + size)], into: &result)
            }
            index += size
        }
    }

    /// ATSC A/53 Part 4 6.2.3: country 0xB5, provider 0x0031, `GA94`, type 0x03, then cc_data().
    private static func readA53(_ payload: ArraySlice<UInt8>, into result: inout [CaptionTriplet]) {
        let bytes = Array(payload)
        guard bytes.count >= 10,
              bytes[0] == 0xB5, bytes[1] == 0x00, bytes[2] == 0x31,
              bytes[3] == 0x47, bytes[4] == 0x41, bytes[5] == 0x39, bytes[6] == 0x34,
              bytes[7] == 0x03 else { return }
        let flags = bytes[8]
        guard flags & 0x40 != 0 else { return }
        let count = Int(flags & 0x1F)
        var offset = 10
        for _ in 0..<count {
            guard offset + 3 <= bytes.count else { return }
            let marker = bytes[offset]
            if marker & 0x04 != 0 {
                result.append(CaptionTriplet(type: marker & 0x03, byte1: bytes[offset + 1], byte2: bytes[offset + 2]))
            }
            offset += 3
        }
    }

    private static func removingEmulationPrevention(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
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

    private static func nalUnits(_ bytes: [UInt8]) -> [[UInt8]] {
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

/// Which caption services carry real data. Encoders fill cc_data with padding even without
/// text, so a service counts only once it sends something other than padding.
nonisolated struct CaptionPresence: Equatable, Sendable {
    /// CEA-608 channels: 1 and 2 on field 1, 3 and 4 on field 2.
    var channels608: [Int] = []
    var has708 = false

    var isEmpty: Bool { channels608.isEmpty && !has708 }
}

/// Tracks the CEA-608 data channel of each field and when each service was last seen.
nonisolated struct CaptionPresenceTracker {
    /// Captions pause for long stretches: a service is dropped only after this much silence.
    static let timeout: TimeInterval = 30

    private var channel = [1, 1]
    private var inXDS = false
    private var lastSeen608: [Int: TimeInterval] = [:]
    private var lastSeen708: TimeInterval?

    mutating func reset() {
        channel = [1, 1]
        inXDS = false
        lastSeen608.removeAll()
        lastSeen708 = nil
    }

    /// Notes one triplet. Returns the 608 data channel (1 or 2) when the pair belongs to a caption channel.
    @discardableResult
    mutating func note(_ triplet: CaptionTriplet, at now: TimeInterval) -> Int? {
        let first = triplet.byte1 & 0x7F
        let second = triplet.byte2 & 0x7F
        switch triplet.type {
        case 0, 1:
            let field = Int(triplet.type)
            if first == 0, second == 0 { return nil }
            if (0x10...0x1F).contains(first) {
                channel[field] = first & 0x08 != 0 ? 2 : 1
                if field == 1 { inXDS = false }
            } else if first < 0x10 {
                // XDS only travels on field 2. 0x0F closes the packet.
                if field == 1 { inXDS = first != 0x0F }
                return nil
            } else if field == 1, inXDS {
                return nil
            }
            lastSeen608[field * 2 + channel[field]] = now
            return channel[field]
        default:
            if triplet.type == 3 || first != 0 || second != 0 {
                lastSeen708 = now
            }
            return nil
        }
    }

    func presence(at now: TimeInterval) -> CaptionPresence {
        let channels = lastSeen608.filter { now - $0.value < Self.timeout }.keys.sorted()
        let has708 = lastSeen708.map { now - $0 < Self.timeout } ?? false
        return CaptionPresence(channels608: channels, has708: has708)
    }
}
