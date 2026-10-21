import AppKit
import Foundation
import Observation
import ServiceManagement
import UserNotifications

@MainActor
@Observable
final class ResignService {
    private(set) var targets: [ResignTarget] = ConfigStore.load()
    /// Target currently being re-signed; one at a time.
    private(set) var runningID: UUID?
    private(set) var runningStep = ""
    private(set) var settings: AppSettings = ConfigStore.loadSettings()

    private var timer: Timer?
    private let profileCache: ProfileCache

    init(profileCache: ProfileCache = .live) {
        self.profileCache = profileCache
        // Hourly check, plus one after the Mac wakes up.
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.renewDue() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.renewDue() }
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        Task { await renewDue() }
    }

    // MARK: Targets

    func upsert(_ target: ResignTarget) throws {
        try Validator.validate(target)
        if let i = targets.firstIndex(where: { $0.id == target.id }) {
            targets[i] = target
        } else {
            targets.append(target)
        }
        ConfigStore.save(targets)
    }

    func remove(_ id: UUID) {
        targets.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: ConfigStore.derivedData(for: id))
        ConfigStore.save(targets)
    }

    func updateSettings(_ change: (inout AppSettings) -> Void) {
        var s = settings
        change(&s)
        if let t = s.teamID, !Validator.isValidTeamID(t) { s.teamID = nil }
        if let p = s.bundlePrefix, !Validator.isValidBundlePrefix(p) { s.bundlePrefix = nil }
        settings = s
        ConfigStore.saveSettings(s)
    }

    // MARK: Re-signing

    func renewDue() async {
        for t in targets where t.needsRenewal() {
            await resign(t.id)
        }
    }

    func resign(_ id: UUID) async {
        guard runningID == nil, let target = targets.first(where: { $0.id == id }) else { return }
        runningID = id
        defer { runningID = nil; runningStep = "" }

        do {
            try Validator.validate(target)
            let (expiry, bundleID) = try await build(target)
            update(id) {
                $0.expiresAt = expiry
                $0.bundleID = bundleID ?? $0.bundleID
                $0.lastSucceeded = true
                $0.lastMessage = "已續簽並安裝"
            }
        } catch {
            let msg = error.localizedDescription
            update(id) {
                $0.lastSucceeded = false
                $0.lastMessage = msg
            }
            notify(title: "\(target.name) 續簽失敗", body: msg)
        }
    }

    /// Build (which re-signs) and install; returns the new profile's expiry and the app's bundle ID.
    private func build(_ t: ResignTarget) async throws -> (Date, String?) {
        let dd = ConfigStore.derivedData(for: t.id)
        log("== \(t.name) \(Date()) ==")

        // Without this Xcode reuses the unexpired profile and the expiry doesn't move.
        var moved: [ProfileCache.Move] = []
        if let bundleID = t.bundleID {
            runningStep = "準備新的描述檔…"
            moved = try await profileCache.moveAside(bundleID: bundleID)
            log("moved \(moved.count) cached profile(s) aside")
        }

        runningStep = "編譯並簽名中…"
        let build = try await CommandRunner.run("/usr/bin/xcrun",
            Self.buildArguments(t, settings: settings, derivedData: dd),
            timeout: 20 * 60, logTo: ConfigStore.logURL)
        guard build.status == 0 else {
            profileCache.restore(moved)
            throw RunnerError.message(Self.buildFailureReason(build.text))
        }

        let products = dd.appendingPathComponent("Build/Products/Debug-iphoneos")
        let apps = (try? FileManager.default.contentsOfDirectory(at: products, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "app" } ?? []
        guard apps.count == 1, let app = apps.first else {
            throw RunnerError.message("找不到唯一的 .app 產物")
        }
        let expiry = try await ProvisioningProfile.expiration(ofApp: app)
        let bundleID = Bundle(url: app)?.bundleIdentifier.flatMap { ProfileCache.isValidBundleID($0) ? $0 : nil }

        runningStep = "安裝到裝置中…"
        let install = try await CommandRunner.run("/usr/bin/xcrun", [
            "devicectl", "device", "install", "app", "--device", t.deviceID, app.path,
        ], timeout: 10 * 60, logTo: ConfigStore.logURL)
        guard install.status == 0 else {
            throw RunnerError.message("安裝失敗：請確認 iPhone 已解鎖且與 Mac 在同一個網路")
        }
        return (expiry, bundleID)
    }

    /// Team and prefix go in as build-setting overrides, so the app's project
    /// needs no per-user edits. Only validated values are passed.
    nonisolated static func buildArguments(_ t: ResignTarget, settings: AppSettings, derivedData: URL) -> [String] {
        let projFlag = t.projectPath.hasSuffix(".xcworkspace") ? "-workspace" : "-project"
        var args = [
            "xcodebuild", projFlag, t.projectPath,
            "-scheme", t.scheme,
            "-configuration", "Debug",
            "-destination", "id=\(t.deviceID)",
            "-derivedDataPath", derivedData.path,
            "-allowProvisioningUpdates",
        ]
        if let team = settings.teamID, Validator.isValidTeamID(team) {
            args.append("DEVELOPMENT_TEAM=\(team)")
        }
        if let prefix = settings.bundlePrefix, Validator.isValidBundlePrefix(prefix) {
            args.append("BUNDLE_ID_PREFIX=\(prefix)")
        }
        args.append("build")
        return args
    }

    /// Short, user-facing reason; full output is in the log file.
    nonisolated static func buildFailureReason(_ output: String) -> String {
        if output.contains("No Accounts") || output.contains("No account for team") {
            return "Xcode 尚未登入 Apple ID（Xcode → Settings → Accounts）"
        }
        if output.contains("Unable to find a destination") {
            return "找不到裝置：請確認 iPhone 已連線（同網路或傳輸線）"
        }
        if output.contains("maximum number of") || output.contains("App ID limit") {
            return "免費帳號 App ID 數量已達上限，請過幾天再試"
        }
        if output.contains("requires a development team") {
            return "專案尚未設定 Team（Signing & Capabilities）"
        }
        return "編譯失敗，詳見紀錄檔"
    }

    private func update(_ id: UUID, _ change: (inout ResignTarget) -> Void) {
        guard let i = targets.firstIndex(where: { $0.id == id }) else { return }
        change(&targets[i])
        targets[i].lastRunAt = Date()
        ConfigStore.save(targets)
    }

    private func log(_ line: String) {
        Log.appendRaw(Data((line + "\n").utf8), to: ConfigStore.logURL)
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: Launch at login

    enum LoginItemState { case enabled, disabled, needsApproval }

    /// Stored (not computed) so SwiftUI redraws; refreshed from the system after every change.
    private(set) var loginItem: LoginItemState = ResignService.currentLoginItemState()

    nonisolated static func currentLoginItemState() -> LoginItemState {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .needsApproval
        default: return .disabled
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            notify(title: "無法設定登入時啟動", body: error.localizedDescription)
        }
        refreshLoginItem()
    }

    func refreshLoginItem() { loginItem = Self.currentLoginItemState() }

    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }

    var hasWarning: Bool {
        targets.contains { $0.lastSucceeded == false || ($0.remaining() ?? .infinity) < 24 * 3600 }
    }
}
