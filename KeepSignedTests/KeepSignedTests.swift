import XCTest
@testable import KeepSigned

final class ValidatorTests: XCTestCase {
    private var projectURL: URL!

    override func setUpWithError() throws {
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rb-\(UUID().uuidString)/Demo.xcodeproj").standardizedFileURL
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent())
    }

    private func target(scheme: String = "Demo", device: String = "00008101-000A1B2C3D4E001F",
                        path: String? = nil) -> ResignTarget {
        ResignTarget(name: "Demo", projectPath: path ?? projectURL.path, scheme: scheme, deviceID: device)
    }

    func testValidTargetPasses() throws {
        XCTAssertNoThrow(try Validator.validate(target()))
    }

    func testRejectsOptionInjectionInScheme() {
        XCTAssertThrowsError(try Validator.validate(target(scheme: "-exportArchive"))) {
            XCTAssertEqual($0 as? ValidationError, .scheme)
        }
        XCTAssertThrowsError(try Validator.validate(target(scheme: "Demo;rm -rf ~")))
    }

    func testRejectsBadDeviceID() {
        XCTAssertThrowsError(try Validator.validate(target(device: "--device")))
        XCTAssertThrowsError(try Validator.validate(target(device: "abc")))
        XCTAssertThrowsError(try Validator.validate(target(device: "0000 8101")))
    }

    func testRejectsBadProjectPaths() {
        XCTAssertThrowsError(try Validator.validate(target(path: "relative/Demo.xcodeproj")))
        XCTAssertThrowsError(try Validator.validate(target(path: "/nonexistent/Demo.xcodeproj")))
        let traversal = projectURL.deletingLastPathComponent().path + "/../x/../" + projectURL.lastPathComponent
        XCTAssertThrowsError(try Validator.validate(target(path: traversal)))
        let notProject = projectURL.deletingLastPathComponent().path
        XCTAssertThrowsError(try Validator.validate(target(path: notProject)))
    }

    func testNeedsRenewal() {
        let now = Date()
        var t = target()
        XCTAssertFalse(t.needsRenewal(now: now), "unknown expiry never auto-renews")
        t.expiresAt = now.addingTimeInterval(72 * 3600)
        XCTAssertFalse(t.needsRenewal(now: now))
        t.expiresAt = now.addingTimeInterval(47 * 3600)
        XCTAssertTrue(t.needsRenewal(now: now))
        t.autoRenew = false
        XCTAssertFalse(t.needsRenewal(now: now))
    }
}

final class ParsingTests: XCTestCase {
    func testProfileExpiration() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["ExpirationDate": date, "Name": "iOS Team Provisioning Profile"],
            format: .xml, options: 0)
        XCTAssertEqual(try ProvisioningProfile.expiration(fromPlist: plist), date)
    }

    func testProfileWithoutExpirationThrows() throws {
        let plist = try PropertyListSerialization.data(fromPropertyList: ["Name": "x"], format: .xml, options: 0)
        XCTAssertThrowsError(try ProvisioningProfile.expiration(fromPlist: plist))
    }

    func testDeviceListKeepsOnlyPhysicalIOS() throws {
        let json = """
        {"result":{"devices":[
          {"hardwareProperties":{"udid":"00008101-000A1B2C3D4E001F","platform":"iOS","productType":"iPhone14,2"},
           "deviceProperties":{"name":"Test Phone"}},
          {"hardwareProperties":{"udid":"00000000-0000-4000-8000-000000000001","platform":"iOS","reality":"simulated"},
           "deviceProperties":{"name":"Sim"}},
          {"hardwareProperties":{"udid":"0000-MAC-0001","platform":"macOS"},"deviceProperties":{"name":"Mac"}},
          {"hardwareProperties":{"udid":"--evil","platform":"iOS"},"deviceProperties":{"name":"Bad"}}
        ]}}
        """
        let devices = try Devices.parse(Data(json.utf8))
        XCTAssertEqual(devices.map(\.name), ["Test Phone"])
    }

    func testDeviceOrdering() throws {
        let json = """
        {"result":{"devices":[
          {"hardwareProperties":{"udid":"00008101-000000000000AAAA","platform":"iOS","deviceType":"iPad"},
           "deviceProperties":{"name":"Offline Tablet"},"connectionProperties":{"tunnelState":"unavailable"}},
          {"hardwareProperties":{"udid":"00008101-000000000000CCCC","platform":"iOS","deviceType":"iPad"},
           "deviceProperties":{"name":"Nearby Tablet"},"connectionProperties":{"tunnelState":"disconnected"}},
          {"hardwareProperties":{"udid":"00008110-000000000000BBBB","platform":"iOS","deviceType":"iPhone"},
           "deviceProperties":{"name":"Nearby Phone"},"connectionProperties":{"tunnelState":"disconnected"}},
          {"hardwareProperties":{"udid":"00008110-000000000000DDDD","platform":"iOS","deviceType":"iPad"},
           "deviceProperties":{"name":"Connected Tablet"},"connectionProperties":{"tunnelState":"connected"}}
        ]}}
        """
        let devices = try Devices.parse(Data(json.utf8))
        XCTAssertEqual(devices.map(\.name), ["Connected Tablet", "Nearby Phone", "Nearby Tablet", "Offline Tablet"])
        XCTAssertEqual(devices.map(\.link), [.connected, .nearby, .nearby, .offline])
    }

    func testRemainingFormat() {
        XCTAssertEqual(Format.remaining(nil), "未知")
        XCTAssertEqual(Format.remaining(-1), "已過期")
        XCTAssertEqual(Format.remaining(5 * 3600 + 10), "剩 5 時")
        XCTAssertEqual(Format.remaining(50 * 3600), "剩 2 天 2 時")
    }

    func testBuildFailureReasons() {
        XCTAssertTrue(ResignService.buildFailureReason("error: No Accounts").contains("Apple ID"))
        XCTAssertEqual(ResignService.buildFailureReason("random"), "編譯失敗，詳見紀錄檔")
    }
}

final class ProfileCacheTests: XCTestCase {
    private var root: URL!
    private var profiles: URL!
    private var cache: ProfileCache!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rb-pc-\(UUID().uuidString)")
        profiles = root.appendingPathComponent("Profiles")
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
        // Tests write plain plists, so "decoding" is just reading the file.
        cache = ProfileCache(profileDirs: [profiles], backupRoot: root.appendingPathComponent("Backup"),
                             decode: { try Data(contentsOf: $0) })
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func writeProfile(_ name: String, appID: String) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["Entitlements": ["application-identifier": appID]], format: .xml, options: 0)
        try data.write(to: profiles.appendingPathComponent(name))
    }

    private func remaining() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: profiles.path)) ?? []).sorted()
    }

    func testMovesOnlyMatchingProfiles() async throws {
        try writeProfile("a.mobileprovision", appID: "ABCDE12345.dev.example.sample")
        try writeProfile("b.mobileprovision", appID: "ABCDE12345.dev.example.sample.widget")
        try writeProfile("c.mobileprovision", appID: "ABCDE12345.*")
        try writeProfile("d.txt", appID: "ABCDE12345.dev.example.sample")

        let moves = try await cache.moveAside(bundleID: "dev.example.sample")
        XCTAssertEqual(moves.count, 1)
        XCTAssertEqual(remaining(), ["b.mobileprovision", "c.mobileprovision", "d.txt"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: moves[0].backup.path))
    }

    func testRestorePutsProfilesBack() async throws {
        try writeProfile("a.mobileprovision", appID: "ABCDE12345.dev.example.sample")
        let moves = try await cache.moveAside(bundleID: "dev.example.sample")
        cache.restore(moves)
        XCTAssertEqual(remaining(), ["a.mobileprovision"])
    }

    func testNoMatchMovesNothing() async throws {
        try writeProfile("a.mobileprovision", appID: "ABCDE12345.dev.other.app")
        let moves = try await cache.moveAside(bundleID: "dev.example.sample")
        XCTAssertTrue(moves.isEmpty)
        XCTAssertEqual(remaining(), ["a.mobileprovision"])
    }

    func testRejectsUnsafeBundleIDs() async {
        for bad in ["../evil", "dev/example", "-dev.example", ""] {
            do { _ = try await cache.moveAside(bundleID: bad); XCTFail("accepted \(bad)") } catch {}
        }
    }
}

final class SetupTests: XCTestCase {
    private let target = ResignTarget(name: "Demo", projectPath: "/tmp/Demo.xcodeproj",
                                      scheme: "Demo", deviceID: "00008101-000A1B2C3D4E001F")
    private let dd = URL(fileURLWithPath: "/tmp/dd")

    func testBuildArgumentsAddOverridesOnlyWhenValid() {
        var s = AppSettings()
        var args = ResignService.buildArguments(target, settings: s, derivedData: dd)
        XCTAssertFalse(args.contains { $0.hasPrefix("DEVELOPMENT_TEAM=") || $0.hasPrefix("BUNDLE_ID_PREFIX=") })
        XCTAssertEqual(args.last, "build")

        s.teamID = "ABCDE12345"
        s.bundlePrefix = "dev.example"
        args = ResignService.buildArguments(target, settings: s, derivedData: dd)
        XCTAssertTrue(args.contains("DEVELOPMENT_TEAM=ABCDE12345"))
        XCTAssertTrue(args.contains("BUNDLE_ID_PREFIX=dev.example"))
        XCTAssertEqual(args.last, "build")

        s.teamID = "bad team"
        s.bundlePrefix = "dev.example SOMETHING=1"
        args = ResignService.buildArguments(target, settings: s, derivedData: dd)
        XCTAssertFalse(args.contains { $0.hasPrefix("DEVELOPMENT_TEAM=") || $0.hasPrefix("BUNDLE_ID_PREFIX=") })
    }

    func testWorkspaceFlag() {
        var t = target
        t.projectPath = "/tmp/Demo.xcworkspace"
        XCTAssertEqual(ResignService.buildArguments(t, settings: AppSettings(), derivedData: dd)[1], "-workspace")
    }

    func testPrefixAndTeamValidation() {
        XCTAssertTrue(Validator.isValidBundlePrefix("dev.example"))
        XCTAssertTrue(Validator.isValidBundlePrefix("dev.blue-fox"))
        for bad in ["dev", "Dev.Example", "dev..x", ".dev.x", "dev.x.", "dev.ex ample", "dev.x/y", "-dev.x"] {
            XCTAssertFalse(Validator.isValidBundlePrefix(bad), bad)
        }
        XCTAssertTrue(Validator.isValidTeamID("ABCDE12345"))
        XCTAssertFalse(Validator.isValidTeamID("abcde12345"))
        XCTAssertFalse(Validator.isValidTeamID("ABCDE1234"))
    }

    func testSuggestedPrefixIsValid() {
        for _ in 0..<50 { XCTAssertTrue(Validator.isValidBundlePrefix(EnvironmentCheck.suggestPrefix())) }
    }

    func testXcodeDefaultsParsing() {
        let d: [String: Any] = [
            "DVTDeveloperAccountManagerAppleIDLists": ["IDE.Identifiers.Prod": [["identifier": "someone@example.com"]]],
            "IDEProvisioningTeamManagerLastSelectedTeamID": "ABCDE12345",
        ]
        XCTAssertTrue(EnvironmentCheck.signedIn(defaults: d))
        XCTAssertEqual(EnvironmentCheck.teamID(defaults: d), "ABCDE12345")
        XCTAssertFalse(EnvironmentCheck.signedIn(defaults: ["DVTDeveloperAccountManagerAppleIDLists": ["IDE.Identifiers.Prod": []]]))
        XCTAssertNil(EnvironmentCheck.teamID(defaults: ["IDEProvisioningTeamManagerLastSelectedTeamID": "x; rm"]))
    }

    func testDeviceDetailsParsing() {
        let json = """
        {"result":{"deviceProperties":{"name":"Test Phone","developerModeStatus":"enabled"},
                   "connectionProperties":{"pairingState":"paired","transportType":"localNetwork"}}}
        """
        let s = EnvironmentCheck.parseDetails(Data(json.utf8), udid: "00008101-000A1B2C3D4E001F")
        XCTAssertEqual(s?.paired, true)
        XCTAssertEqual(s?.developerMode, true)
        XCTAssertEqual(s?.wireless, true)
        XCTAssertNil(EnvironmentCheck.parseDetails(Data("{}".utf8), udid: "x"))

        // Paired but unreachable: developer mode is unknown, not "off".
        let locked = """
        {"result":{"deviceProperties":{"name":"Test Phone"},"connectionProperties":{"pairingState":"paired"}}}
        """
        let l = EnvironmentCheck.parseDetails(Data(locked.utf8), udid: "00008101-000A1B2C3D4E001F")
        XCTAssertEqual(l?.paired, true)
        XCTAssertNil(l?.developerMode)
        XCTAssertEqual(l?.wireless, false)
    }
}

final class UpdateConfigTests: XCTestCase {
    /// Tests run inside the app, so Bundle.main is KeepSigned.app.
    private func info(_ key: String) -> Any? { Bundle.main.object(forInfoDictionaryKey: key) }

    func testFeedIsHTTPSOnGitHubReleases() throws {
        let feed = try XCTUnwrap(info("SUFeedURL") as? String)
        let url = try XCTUnwrap(URL(string: feed))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "github.com")
        XCTAssertEqual(url.lastPathComponent, "appcast.xml")
    }

    /// Sparkle refuses updates without it; base64 of a 32-byte Ed25519 key.
    func testPublicKeyIsSet() throws {
        let key = try XCTUnwrap(info("SUPublicEDKey") as? String)
        XCTAssertEqual(Data(base64Encoded: key)?.count, 32, "run generate_keys and set SPARKLE_PUBLIC_KEY")
    }

    func testSignedFeedIsRequired() {
        XCTAssertEqual(info("SURequireSignedFeed") as? Bool, true)
        XCTAssertEqual(info("SUVerifyUpdateBeforeExtraction") as? Bool, true)
    }

    func testBuildNumberIsNumeric() throws {
        let build = try XCTUnwrap(info("CFBundleVersion") as? String)
        XCTAssertNotNil(Int(build))
    }
}
