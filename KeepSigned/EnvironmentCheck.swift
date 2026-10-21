import Foundation

/// Read-only checks for the setup wizard. Nothing here reads or stores the
/// Apple ID itself or the name on the signing certificate.
enum EnvironmentCheck {
    struct DeviceStatus: Equatable {
        var udid: String
        var name: String
        var paired: Bool
        /// nil when the device is paired but not reachable (locked / no tunnel), so the status can't be read.
        var developerMode: Bool?
        /// "wired", "localNetwork", ...
        var transport: String?
        var wireless: Bool { transport != nil && transport != "wired" }
    }

    static func xcodeInstalled() async -> Bool {
        guard let r = try? await CommandRunner.run("/usr/bin/xcrun", ["xcodebuild", "-version"], timeout: 60) else { return false }
        return r.status == 0
    }

    /// False until Xcode has been opened once and its extra components installed.
    static func xcodeFirstLaunchDone() async -> Bool {
        guard let r = try? await CommandRunner.run("/usr/bin/xcrun", ["xcodebuild", "-checkFirstLaunchStatus"], timeout: 60) else { return false }
        return r.status == 0
    }

    private static func xcodeDefaults() async -> [String: Any]? {
        guard let r = try? await CommandRunner.run("/usr/bin/defaults", ["export", "com.apple.dt.Xcode", "-"], timeout: 30),
              r.status == 0 else { return nil }
        return try? PropertyListSerialization.propertyList(from: r.output, format: nil) as? [String: Any]
    }

    /// Whether any account is signed in to Xcode; only the count is looked at.
    static func appleIDSignedIn() async -> Bool {
        guard let d = await xcodeDefaults() else { return false }
        return signedIn(defaults: d)
    }

    static func signedIn(defaults d: [String: Any]) -> Bool {
        guard let lists = d["DVTDeveloperAccountManagerAppleIDLists"] as? [String: Any] else { return false }
        return lists.values.contains { ($0 as? [Any])?.isEmpty == false }
    }

    static func detectTeamID() async -> String? {
        guard let d = await xcodeDefaults() else { return nil }
        return teamID(defaults: d)
    }

    static func teamID(defaults d: [String: Any]) -> String? {
        guard let id = d["IDEProvisioningTeamManagerLastSelectedTeamID"] as? String,
              Validator.isValidTeamID(id) else { return nil }
        return id
    }

    static func device(_ udid: String) async -> DeviceStatus? {
        guard Validator.matches(udid, #"^[A-Za-z0-9][A-Za-z0-9\-]{7,63}$"#) else { return nil }
        let json = FileManager.default.temporaryDirectory
            .appendingPathComponent("keepsigned-info-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: json) }
        guard let r = try? await CommandRunner.run("/usr/bin/xcrun",
                ["devicectl", "device", "info", "details", "--device", udid, "--json-output", json.path], timeout: 60),
              r.status == 0, let data = try? Data(contentsOf: json) else { return nil }
        return parseDetails(data, udid: udid)
    }

    static func parseDetails(_ data: Data, udid: String) -> DeviceStatus? {
        struct Root: Decodable { var result: R }
        struct R: Decodable { var deviceProperties: DP; var connectionProperties: CP }
        struct DP: Decodable { var name: String?; var developerModeStatus: String? }
        struct CP: Decodable { var pairingState: String?; var transportType: String? }
        guard let r = try? JSONDecoder().decode(Root.self, from: data).result else { return nil }
        return DeviceStatus(udid: udid,
                            name: r.deviceProperties.name ?? udid,
                            paired: r.connectionProperties.pairingState == "paired",
                            developerMode: r.deviceProperties.developerModeStatus.map { $0 == "enabled" },
                            transport: r.connectionProperties.transportType)
    }

    /// Suggestion for the prefix field: two random words, never anything personal.
    static func suggestPrefix() -> String {
        let a = ["blue", "mint", "tofu", "pixel", "moon", "cloud", "quiet", "lantern", "maple", "cocoa"]
        let b = ["fox", "kite", "koi", "forge", "owl", "mochi", "bit", "works", "lab", "cat"]
        return "dev.\(a.randomElement()!)\(b.randomElement()!)"
    }
}
