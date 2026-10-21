import Foundation

/// Xcode reuses a cached profile until it expires, so rebuilding early does not
/// extend the app's life. Moving the app's cached profile aside before the build
/// makes Xcode fetch a fresh 7-day one. Files are moved, never deleted, and put
/// back if the build fails.
struct ProfileCache {
    struct Move { let original: URL; let backup: URL }

    var profileDirs: [URL]
    var backupRoot: URL
    /// Returns the profile's plist. Injected so tests can skip `security cms`.
    var decode: (URL) async throws -> Data

    static let live = ProfileCache(
        profileDirs: [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Developer/Xcode/UserData/Provisioning Profiles"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/MobileDevice/Provisioning Profiles"),
        ],
        backupRoot: ConfigStore.directory.appendingPathComponent("ProfileBackup"),
        decode: { url in
            let r = try await CommandRunner.run("/usr/bin/security", ["cms", "-D", "-i", url.path], timeout: 30)
            guard r.status == 0 else { throw RunnerError.message("無法解析描述檔") }
            return r.output
        })

    static func isValidBundleID(_ id: String) -> Bool {
        Validator.matches(id, #"^[A-Za-z0-9][A-Za-z0-9.\-]{0,154}$"#) && !id.contains("..")
    }

    /// "TEAMID.dev.example.app" belongs to "dev.example.app"; wildcard profiles never match.
    static func appIdentifier(_ appID: String, matches bundleID: String) -> Bool {
        guard let dot = appID.firstIndex(of: ".") else { return false }
        return appID[appID.index(after: dot)...] == bundleID
    }

    /// Moves every cached profile for `bundleID` into its backup folder,
    /// replacing the previous backup. Returns what was moved so it can be restored.
    func moveAside(bundleID: String) async throws -> [Move] {
        guard Self.isValidBundleID(bundleID) else { throw RunnerError.message("Bundle ID 格式不正確") }
        let fm = FileManager.default
        var matches: [URL] = []
        for dir in profileDirs {
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for f in files where ["mobileprovision", "provisionprofile"].contains(f.pathExtension) {
                guard let data = try? await decode(f),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let ent = plist["Entitlements"] as? [String: Any],
                      let appID = ent["application-identifier"] as? String,
                      Self.appIdentifier(appID, matches: bundleID) else { continue }
                matches.append(f)
            }
        }
        guard !matches.isEmpty else { return [] }

        let dest = backupRoot.appendingPathComponent(bundleID, isDirectory: true)
        try? fm.removeItem(at: dest)  // keep only the latest backup per app
        try fm.createDirectory(at: dest, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        var moves: [Move] = []
        for (i, f) in matches.enumerated() {
            let backup = dest.appendingPathComponent("\(i)-\(f.lastPathComponent)")
            try fm.moveItem(at: f, to: backup)
            moves.append(Move(original: f, backup: backup))
        }
        return moves
    }

    /// Puts moved profiles back, unless Xcode already wrote a file with the same name.
    func restore(_ moves: [Move]) {
        let fm = FileManager.default
        for m in moves where !fm.fileExists(atPath: m.original.path) {
            try? fm.moveItem(at: m.backup, to: m.original)
        }
    }
}
