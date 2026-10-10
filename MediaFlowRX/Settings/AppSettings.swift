import Foundation

enum IngestKind: Int, CaseIterable, Identifiable {
    case rtmp = 0
    case srt = 1
    case rtsp = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .rtmp: "RTMP"
        case .srt: "SRT"
        case .rtsp: "RTSP"
        }
    }

    var defaultPort: Int {
        switch self {
        case .rtmp: 1935
        case .srt: 9000
        case .rtsp: 8554
        }
    }
}

/// Everything that defines how the encoder reaches the app.
/// Changing it requires restarting the listener.
struct ConnectionConfig: Equatable {
    var kind: IngestKind = .rtmp
    var rtmpPort = 1935
    var srtPort = 9000
    var rtspPort = 8554
    var slug = "live"
    var streamKey = "stream"
    var username = ""
    var password = ""

    var activePort: Int {
        get {
            switch kind {
            case .rtmp: rtmpPort
            case .srt: srtPort
            case .rtsp: rtspPort
            }
        }
        set {
            switch kind {
            case .rtmp: rtmpPort = newValue
            case .srt: srtPort = newValue
            case .rtsp: rtspPort = newValue
            }
        }
    }

    func validationError() -> String? {
        if !(1...65535).contains(rtmpPort) || !(1...65535).contains(srtPort) || !(1...65535).contains(rtspPort) {
            return String(localized: "Ports must be between 1 and 65535")
        }
        if !Self.isToken(slug) || !Self.isToken(streamKey) {
            return String(localized: "Slug and key may only contain letters, numbers, dot, hyphen and underscore")
        }
        return nil
    }

    static func isPort(_ value: Int) -> Bool {
        (1...65535).contains(value)
    }

    static func isToken(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        return !value.isEmpty && value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

/// Editable copy of every setting, used by preferences.
/// Nothing reaches the app until Apply is pressed.
struct SettingsDraft: Equatable {
    var connection = ConnectionConfig()
    var autoRecord = true
    var folderPath = AppSettings.defaultFolder().path
    var showCaptions = true
    var saveCaptions = true
    var captionScale = 1.0
    var captionBackground = 0.8

    var normalized: SettingsDraft {
        var copy = self
        copy.captionBackground = min(max(captionBackground, 0), 1)
        copy.connection.slug = connection.slug.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.connection.streamKey = connection.streamKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return copy
    }

    var validationError: String? {
        connection.validationError()
    }
}

@Observable
final class AppSettings {
    var kind: IngestKind {
        didSet { defaults.set(kind.rawValue, forKey: Key.kind) }
    }
    var rtmpPort: Int {
        didSet { defaults.set(rtmpPort, forKey: Key.rtmpPort) }
    }
    var srtPort: Int {
        didSet { defaults.set(srtPort, forKey: Key.srtPort) }
    }
    var rtspPort: Int {
        didSet { defaults.set(rtspPort, forKey: Key.rtspPort) }
    }
    var slug: String {
        didSet { defaults.set(slug, forKey: Key.slug) }
    }
    var streamKey: String {
        didSet { defaults.set(streamKey, forKey: Key.streamKey) }
    }
    var username: String {
        didSet { defaults.set(username, forKey: Key.username) }
    }
    var password: String {
        didSet { defaults.set(password, forKey: Key.password) }
    }
    var autoRecord: Bool {
        didSet { defaults.set(autoRecord, forKey: Key.autoRecord) }
    }
    var recordingFolderPath: String {
        didSet { defaults.set(recordingFolderPath, forKey: Key.folder) }
    }
    /// Whether the main window shows closed captions when it opens. The CC button changes only the session.
    var showCaptions: Bool {
        didSet { defaults.set(showCaptions, forKey: Key.showCaptions) }
    }
    /// Whether each recording gets an SRT with its closed captions.
    var saveCaptions: Bool {
        didSet { defaults.set(saveCaptions, forKey: Key.saveCaptions) }
    }
    /// Caption text size relative to the television grid, one of `captionScales`.
    var captionScale: Double {
        didSet { defaults.set(captionScale, forKey: Key.captionScale) }
    }
    /// Opacity of the box behind the caption text, 0...1.
    var captionBackground: Double {
        didSet { defaults.set(captionBackground, forKey: Key.captionBackground) }
    }

    static let captionScales = [0.75, 1, 1.25, 1.5]

    var connection: ConnectionConfig {
        ConnectionConfig(
            kind: kind,
            rtmpPort: rtmpPort,
            srtPort: srtPort,
            rtspPort: rtspPort,
            slug: slug,
            streamKey: streamKey,
            username: username,
            password: password
        )
    }

    var draft: SettingsDraft {
        SettingsDraft(
            connection: connection,
            autoRecord: autoRecord,
            folderPath: recordingFolderPath,
            showCaptions: showCaptions,
            saveCaptions: saveCaptions,
            captionScale: captionScale,
            captionBackground: captionBackground
        )
    }

    var port: Int {
        get {
            switch kind {
            case .rtmp: rtmpPort
            case .srt: srtPort
            case .rtsp: rtspPort
            }
        }
        set {
            switch kind {
            case .rtmp: rtmpPort = newValue
            case .srt: srtPort = newValue
            case .rtsp: rtspPort = newValue
            }
        }
    }

    var recordingFolder: URL {
        URL(fileURLWithPath: recordingFolderPath, isDirectory: true)
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedKind = defaults.object(forKey: Key.kind) as? Int
        kind = IngestKind(rawValue: storedKind ?? IngestKind.rtmp.rawValue) ?? .rtmp
        rtmpPort = defaults.object(forKey: Key.rtmpPort) as? Int ?? 1935
        srtPort = defaults.object(forKey: Key.srtPort) as? Int ?? 9000
        rtspPort = defaults.object(forKey: Key.rtspPort) as? Int ?? 8554
        slug = defaults.string(forKey: Key.slug) ?? "live"
        streamKey = defaults.string(forKey: Key.streamKey) ?? "stream"
        username = defaults.string(forKey: Key.username) ?? ""
        password = defaults.string(forKey: Key.password) ?? ""
        autoRecord = defaults.object(forKey: Key.autoRecord) as? Bool ?? true
        recordingFolderPath = defaults.string(forKey: Key.folder) ?? Self.defaultFolder().path
        showCaptions = defaults.object(forKey: Key.showCaptions) == nil || defaults.bool(forKey: Key.showCaptions)
        saveCaptions = defaults.object(forKey: Key.saveCaptions) == nil || defaults.bool(forKey: Key.saveCaptions)
        let scale = defaults.double(forKey: Key.captionScale)
        captionScale = Self.captionScales.contains(scale) ? scale : 1
        captionBackground = defaults.object(forKey: Key.captionBackground) == nil
            ? 0.8 : min(max(defaults.double(forKey: Key.captionBackground), 0), 1)
        try? FileManager.default.createDirectory(at: recordingFolder, withIntermediateDirectories: true)
    }

    static func defaultFolder() -> URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies")
        return movies.appendingPathComponent("MediaFlowRX", isDirectory: true)
    }

    func apply(_ draft: SettingsDraft) {
        let value = draft.normalized
        kind = value.connection.kind
        rtmpPort = value.connection.rtmpPort
        srtPort = value.connection.srtPort
        rtspPort = value.connection.rtspPort
        slug = value.connection.slug
        streamKey = value.connection.streamKey
        username = value.connection.username
        password = value.connection.password
        autoRecord = value.autoRecord
        recordingFolderPath = value.folderPath
        showCaptions = value.showCaptions
        saveCaptions = value.saveCaptions
        captionScale = value.captionScale
        captionBackground = value.captionBackground
        try? FileManager.default.createDirectory(at: recordingFolder, withIntermediateDirectories: true)
    }

    func validationError() -> String? {
        connection.validationError()
    }

    private enum Key {
        static let kind = "ingest.kind"
        static let rtmpPort = "ingest.rtmpPort"
        static let srtPort = "ingest.srtPort"
        static let rtspPort = "ingest.rtspPort"
        static let slug = "ingest.slug"
        static let streamKey = "ingest.streamKey"
        static let username = "ingest.username"
        static let password = "ingest.password"
        static let autoRecord = "record.auto"
        static let folder = "record.folder"
        static let showCaptions = "captions.show"
        static let saveCaptions = "captions.srt"
        static let captionScale = "captions.scale"
        static let captionBackground = "captions.background"
    }
}
