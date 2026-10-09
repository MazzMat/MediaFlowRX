import AppKit

/// `system` follows the Mac language. Any other choice stays put if the Mac language
/// changes, and menus and strings pick it up on the next launch.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case italian = "it"
    case english = "en"

    var id: String { rawValue }

    static var stored: AppLanguage {
        guard let codes = UserDefaults.standard.stringArray(forKey: key),
              let first = codes.first else { return .system }
        if first.hasPrefix("it") { return .italian }
        if first.hasPrefix("en") { return .english }
        return .system
    }

    /// Language code this process launched with. It does not change until relaunch.
    private static let running = String((Bundle.main.preferredLocalizations.first ?? "en").prefix(2)).lowercased()

    var needsRelaunch: Bool {
        effectiveCode != Self.running
    }

    func save() {
        switch self {
        case .system:
            UserDefaults.standard.removeObject(forKey: Self.key)
        case .italian:
            UserDefaults.standard.set(["it"], forKey: Self.key)
        case .english:
            UserDefaults.standard.set(["en"], forKey: Self.key)
        }
    }

    func relaunch() {
        save()
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            guard error == nil else { return }
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }

    private var effectiveCode: String {
        switch self {
        case .italian: "it"
        case .english: "en"
        case .system: Self.systemCode
        }
    }

    private static var systemCode: String {
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        let first = (global?["AppleLanguages"] as? [String])?.first ?? Locale.current.identifier
        return String(first.prefix(2)).lowercased()
    }

    private static let key = "AppleLanguages"
}
