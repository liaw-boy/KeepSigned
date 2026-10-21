import Foundation

/// Targets live in ~/Library/Application Support/KeepSigned/targets.json.
/// No Apple ID or password is stored: signing uses the account already signed in to Xcode.
enum ConfigStore {
    static var directory: URL {
        let dir: URL
        // KEEPSIGNED_HOME lets tests and "fresh user" checks run without touching the real config.
        if let home = ProcessInfo.processInfo.environment["KEEPSIGNED_HOME"], home.hasPrefix("/") {
            dir = URL(fileURLWithPath: home, isDirectory: true).standardizedFileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            dir = base.appendingPathComponent("KeepSigned", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir
    }

    static var fileURL: URL { directory.appendingPathComponent("targets.json") }
    static var settingsURL: URL { directory.appendingPathComponent("settings.json") }
    static var logURL: URL { directory.appendingPathComponent("resign.log") }

    static func derivedData(for id: UUID) -> URL {
        directory.appendingPathComponent("DerivedData/\(id.uuidString)", isDirectory: true)
    }

    static func load() -> [ResignTarget] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ResignTarget].self, from: data)) ?? []
    }

    static func save(_ targets: [ResignTarget]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(targets) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    static func loadSettings() -> AppSettings {
        guard let data = try? Data(contentsOf: settingsURL),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }

    static func saveSettings(_ s: AppSettings) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(s) else { return }
        try? data.write(to: settingsURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
    }
}

/// Per-user values, detected or chosen in the setup wizard. Stored only on this Mac.
struct AppSettings: Codable, Equatable {
    var teamID: String?
    /// e.g. "dev.example"; apps that use $(BUNDLE_ID_PREFIX) get "<prefix>.<app>".
    var bundlePrefix: String?
    var onboardingDone = false
}
