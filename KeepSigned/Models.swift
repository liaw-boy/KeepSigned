import Foundation

/// One iOS app that KeepSigned keeps re-signed on one device.
struct ResignTarget: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// Absolute path to a .xcodeproj or .xcworkspace.
    var projectPath: String
    var scheme: String
    /// Device UDID as shown by `xcrun devicectl list devices`.
    var deviceID: String
    /// Re-sign automatically once less than this many hours remain.
    var thresholdHours: Int = 48
    var autoRenew: Bool = true
    /// Learned from the first successful build; used to find the cached profile.
    var bundleID: String?

    // State from the last run.
    var expiresAt: Date?
    var lastRunAt: Date?
    var lastSucceeded: Bool?
    var lastMessage: String?
}

enum ValidationError: LocalizedError, Equatable {
    case name, projectPath, scheme, deviceID, threshold

    var errorDescription: String? {
        switch self {
        case .name: return "名稱需為 1–60 字"
        case .projectPath: return "專案路徑需為存在的 .xcodeproj 或 .xcworkspace"
        case .scheme: return "Scheme 只能含英數、空白、底線、點、連字號，且需以英數開頭"
        case .deviceID: return "裝置 ID 格式不正確"
        case .threshold: return "提前續簽時數需介於 1–144"
        }
    }
}

/// Every value here ends up as an argument to xcodebuild/devicectl, so it is
/// checked before use. Leading "-" is rejected to rule out option injection.
enum Validator {
    private static let schemePattern = #"^[A-Za-z0-9][A-Za-z0-9 _.\-]{0,99}$"#
    private static let devicePattern = #"^[A-Za-z0-9][A-Za-z0-9\-]{7,63}$"#

    static func validate(_ t: ResignTarget, fileManager: FileManager = .default) throws {
        let name = t.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.count <= 60 else { throw ValidationError.name }
        guard isValidProjectPath(t.projectPath, fileManager: fileManager) else { throw ValidationError.projectPath }
        guard matches(t.scheme, schemePattern) else { throw ValidationError.scheme }
        guard matches(t.deviceID, devicePattern) else { throw ValidationError.deviceID }
        guard (1...144).contains(t.thresholdHours) else { throw ValidationError.threshold }
    }

    static func isValidProjectPath(_ path: String, fileManager: FileManager = .default) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        // Reject paths that change meaning once normalised (e.g. "..").
        guard url.path == path || url.path + "/" == path else { return false }
        guard ["xcodeproj", "xcworkspace"].contains(url.pathExtension) else { return false }
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    static func isValidTeamID(_ s: String) -> Bool { matches(s, #"^[A-Z0-9]{10}$"#) }

    /// Two or more dot-separated labels, e.g. "dev.example".
    static func isValidBundlePrefix(_ s: String) -> Bool {
        matches(s, #"^[a-z][a-z0-9-]{0,30}(\.[a-z][a-z0-9-]{0,30}){1,3}$"#)
    }

    static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }
}

extension ResignTarget {
    func remaining(now: Date = Date()) -> TimeInterval? {
        expiresAt.map { $0.timeIntervalSince(now) }
    }

    /// True when auto-renew should run now. Unknown expiry never triggers it:
    /// the first sign has to be started by hand.
    func needsRenewal(now: Date = Date()) -> Bool {
        guard autoRenew, let left = remaining(now: now) else { return false }
        return left < TimeInterval(thresholdHours) * 3600
    }
}
