import AppKit
import Foundation
import SwiftUI

struct PublishLine: Identifiable {
    var id: String { label + value }
    let label: String
    let value: String

    static func make(_ connection: ConnectionConfig, hosts: [String]) -> [PublishLine] {
        switch connection.kind {
        case .rtmp:
            let query = credentialQuery(connection)
            return hosts.map { host in
                PublishLine(
                    label: host == "127.0.0.1" ? String(localized: "Local") : String(localized: "Server"),
                    value: "rtmp://\(host):\(connection.rtmpPort)/\(connection.slug)\(query)"
                )
            } + [PublishLine(label: String(localized: "Stream key"), value: connection.streamKey)]
        case .srt:
            let streamID = "#!::r=\(connection.slug)/\(connection.streamKey),m=publish"
            return hosts.map { host in
                PublishLine(
                    label: host == "127.0.0.1" ? String(localized: "Local") : String(localized: "Server"),
                    value: "srt://\(host):\(connection.srtPort)"
                )
            } + [PublishLine(label: String(localized: "Stream ID"), value: streamID)]
        case .rtsp:
            let user = credentialPrefix(connection)
            return hosts.map { host in
                PublishLine(
                    label: host == "127.0.0.1" ? String(localized: "Local") : String(localized: "URL"),
                    value: "rtsp://\(user)\(host):\(connection.rtspPort)/\(connection.slug)/\(connection.streamKey)"
                )
            }
        }
    }

    /// IPv4 addresses to show: the LAN address first, when there is one, then localhost.
    static func localHosts() -> [String] {
        var hosts = ["127.0.0.1"]
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return hosts }
        defer { freeifaddrs(ifaddr) }
        var lan: [String] = []
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let interface = current.pointee
            pointer = interface.ifa_next
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            if name == "lo0" { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if result == 0 {
                let ip = String(cString: host)
                if !ip.isEmpty, ip != "127.0.0.1" {
                    lan.append(ip)
                }
            }
        }
        if let preferred = lan.first {
            hosts.insert(preferred, at: 0)
        }
        return hosts
    }

    private static func credentialQuery(_ connection: ConnectionConfig) -> String {
        guard !connection.username.isEmpty || !connection.password.isEmpty else { return "" }
        let user = connection.username.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let pass = connection.password.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return "?user=\(user)&pass=\(pass)"
    }

    private static func credentialPrefix(_ connection: ConnectionConfig) -> String {
        guard !connection.username.isEmpty || !connection.password.isEmpty else { return "" }
        let user = connection.username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? ""
        let pass = connection.password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? ""
        return "\(user):\(pass)@"
    }
}

struct CopyRow: View {
    let line: PublishLine
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        Button(action: copy) {
            HStack(spacing: 10) {
                Text(line.label)
                    .font(AppStyle.label)
                    .foregroundStyle(.secondary)
                    .frame(width: 84, alignment: .leading)
                Text(line.value)
                    .font(AppStyle.value)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    .foregroundStyle(copied ? Color.green : Color.secondary)
                    .opacity(copied || hovering ? 1 : 0.45)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: AppStyle.rowRadius, style: .continuous)
                    .fill(.primary.opacity(hovering ? 0.14 : 0.06))
            )
            .contentShape(RoundedRectangle(cornerRadius: AppStyle.rowRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Click to copy: \(line.value)")
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.15), value: copied)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(line.value, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            copied = false
        }
    }
}
