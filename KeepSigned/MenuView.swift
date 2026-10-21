import SwiftUI

struct MenuView: View {
    let service: ResignService
    let updater: AppUpdater
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("KeepSigned").font(.headline)
                Text("v\(AppInfo.version)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("檢查更新…") { updater.checkForUpdates() }
                    .controlSize(.small)
            }

            if service.targets.isEmpty {
                Text("尚未加入任何 App。請用設定精靈開始。")
                    .foregroundStyle(.secondary)
            }

            ForEach(service.targets) { t in
                TargetRow(target: t, service: service)
                Divider()
            }

            LoginItemRow(service: service)

            HStack {
                Button("設定精靈…") { openWindow(id: "onboarding"); NSApp.activate() }
                SettingsLink { Text("設定…") }
                    .simultaneousGesture(TapGesture().onEnded { NSApp.activate() })
                Button("開啟紀錄檔") { NSWorkspace.shared.open(ConfigStore.logURL) }
                Spacer()
                Button("結束") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}

struct LoginItemRow: View {
    let service: ResignService

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("登入時自動啟動", isOn: Binding(
                get: { service.loginItem != .disabled },
                set: { service.setLaunchAtLogin($0) }))
            if service.loginItem == .needsApproval {
                HStack {
                    Text("需要在系統設定中允許").font(.caption).foregroundStyle(.orange)
                    Button("打開登入項目設定") { service.openLoginItemsSettings() }
                        .controlSize(.small)
                }
            }
        }
        .onAppear { service.refreshLoginItem() }
    }
}

private struct TargetRow: View {
    let target: ResignTarget
    let service: ResignService

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(target.name).bold()
                Spacer()
                Text(Format.remaining(target.remaining()))
                    .foregroundStyle(color)
                    .monospacedDigit()
            }
            if let date = target.expiresAt {
                Text("到期：\(Format.dateTime(date))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if service.runningID == target.id {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(service.runningStep).font(.caption)
                }
            } else {
                HStack {
                    if let msg = target.lastMessage {
                        Text(msg).font(.caption)
                            .foregroundStyle(target.lastSucceeded == false ? .red : .secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    Button("立即續簽") { Task { await service.resign(target.id) } }
                        .disabled(service.runningID != nil)
                }
            }
        }
    }

    private var color: Color {
        guard let left = target.remaining() else { return .secondary }
        if left < 24 * 3600 { return .red }
        if left < 72 * 3600 { return .orange }
        return .green
    }
}

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
}

enum Format {
    static func remaining(_ t: TimeInterval?) -> String {
        guard let t else { return "未知" }
        if t <= 0 { return "已過期" }
        let hours = Int(t / 3600)
        return hours >= 24 ? "剩 \(hours / 24) 天 \(hours % 24) 時" : "剩 \(hours) 時"
    }

    /// 24-hour, zero-padded: 2026/10/06 15:04
    static func dateTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy/MM/dd HH:mm"
        return f.string(from: d)
    }
}
