import Foundation

enum ProvisioningProfile {
    /// Expiration date of the profile embedded in a built .app.
    static func expiration(ofApp appURL: URL) async throws -> Date {
        let profile = appURL.appendingPathComponent("embedded.mobileprovision")
        guard FileManager.default.fileExists(atPath: profile.path) else {
            throw RunnerError.message("找不到 embedded.mobileprovision（是否沒有簽名？）")
        }
        // The profile is a CMS envelope; `security cms -D` unwraps it to a plist.
        let result = try await CommandRunner.run("/usr/bin/security", ["cms", "-D", "-i", profile.path], timeout: 30)
        guard result.status == 0 else { throw RunnerError.message("無法解析描述檔") }
        return try expiration(fromPlist: result.output)
    }

    static func expiration(fromPlist data: Data) throws -> Date {
        let obj = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dict = obj as? [String: Any], let date = dict["ExpirationDate"] as? Date else {
            throw RunnerError.message("描述檔缺少 ExpirationDate")
        }
        return date
    }
}
