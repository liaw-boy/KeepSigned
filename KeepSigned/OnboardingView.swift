import SwiftUI
import UniformTypeIdentifiers

/// First-run wizard: walks a non-developer from "nothing installed" to
/// "app installed on the iPhone and renewing itself". Every step re-checks the
/// real state instead of trusting a checkbox.
struct OnboardingView: View {
    let service: ResignService
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var model = OnboardingModel()
    @State private var step: OnboardingModel.Step = .xcode

    var body: some View {
        HStack(spacing: 0) {
            List(OnboardingModel.Step.allCases, selection: $step) { s in
                Label {
                    Text(s.title)
                } icon: {
                    Image(systemName: model.done(s, service: service) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(model.done(s, service: service) ? .green : .secondary)
                }
                .tag(s)
            }
            .listStyle(.sidebar)
            .frame(width: 210)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                Text("步驟 \(step.rawValue + 1)／\(OnboardingModel.Step.allCases.count)　\(step.title)")
                    .font(.title2).bold()
                ScrollView {
                    StepDetail(step: step, model: model, service: service)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 0)
                HStack {
                    Button("重新檢查") { Task { await model.refresh(service: service) } }
                        .disabled(model.checking)
                    if model.checking { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("上一步") { move(-1) }.disabled(step == .xcode)
                    if step == .finish {
                        Button("完成") {
                            service.updateSettings { $0.onboardingDone = true }
                            dismissWindow(id: "onboarding")
                        }
                        .keyboardShortcut(.defaultAction)
                    } else {
                        Button("下一步") { move(1) }.keyboardShortcut(.defaultAction)
                    }
                }
            }
            .padding(20)
        }
        .frame(width: 780, height: 520)
        .task { await model.refresh(service: service) }
    }

    private func move(_ d: Int) {
        if let s = OnboardingModel.Step(rawValue: step.rawValue + d) { step = s }
        Task { await model.refresh(service: service) }
    }
}

@MainActor
@Observable
final class OnboardingModel {
    enum Step: Int, CaseIterable, Identifiable {
        case xcode, firstLaunch, account, prefix, iphone, developerMode, project, install, wireless, finish
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .xcode: return "安裝 Xcode"
            case .firstLaunch: return "第一次打開 Xcode"
            case .account: return "登入 Apple ID"
            case .prefix: return "取一個前綴"
            case .iphone: return "連接 iPhone"
            case .developerMode: return "開啟開發者模式"
            case .project: return "選擇要安裝的 App"
            case .install: return "第一次安裝"
            case .wireless: return "無線連線（建議）"
            case .finish: return "完成"
            }
        }
    }

    var checking = false
    var xcodeOK = false
    var firstLaunchOK = false
    var signedIn = false
    var devices: [Device] = []
    var selectedDevice: String = ""
    var deviceStatus: EnvironmentCheck.DeviceStatus?
    var prefixDraft = ""
    var teamDraft = ""
    var projectPath = ""
    var scheme = ""
    var message: String?

    var selectedLink: Device.Link { devices.first { $0.udid == selectedDevice }?.link ?? .offline }

    func done(_ s: Step, service: ResignService) -> Bool {
        switch s {
        case .xcode: return xcodeOK
        case .firstLaunch: return firstLaunchOK
        case .account: return signedIn && service.settings.teamID != nil
        case .prefix: return service.settings.bundlePrefix != nil
        case .iphone: return deviceStatus?.paired == true && selectedLink != .offline
        case .developerMode: return deviceStatus?.developerMode == true
        case .project: return !service.targets.isEmpty
        case .install: return service.targets.contains { $0.lastSucceeded == true }
        case .wireless: return deviceStatus?.wireless == true
        case .finish: return service.loginItem != .disabled
        }
    }

    func refresh(service: ResignService) async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        xcodeOK = await EnvironmentCheck.xcodeInstalled()
        guard xcodeOK else { return }
        firstLaunchOK = await EnvironmentCheck.xcodeFirstLaunchDone()
        signedIn = await EnvironmentCheck.appleIDSignedIn()
        if service.settings.teamID == nil, let team = await EnvironmentCheck.detectTeamID() {
            service.updateSettings { $0.teamID = team }
        }
        if teamDraft.isEmpty { teamDraft = service.settings.teamID ?? "" }
        if prefixDraft.isEmpty { prefixDraft = service.settings.bundlePrefix ?? EnvironmentCheck.suggestPrefix() }
        devices = (try? await Devices.list()) ?? []
        if selectedDevice.isEmpty || !devices.contains(where: { $0.udid == selectedDevice }) {
            selectedDevice = devices.first?.udid ?? ""
        }
        deviceStatus = selectedDevice.isEmpty ? nil : await EnvironmentCheck.device(selectedDevice)
        service.refreshLoginItem()
    }

    /// Adds the chosen project as a target (or updates the existing one for that project).
    func saveTarget(service: ResignService) {
        message = nil
        guard !selectedDevice.isEmpty else { message = "請先完成「連接 iPhone」"; return }
        var t = service.targets.first { $0.projectPath == projectPath }
            ?? ResignTarget(name: scheme, projectPath: projectPath, scheme: scheme, deviceID: selectedDevice)
        t.name = scheme
        t.scheme = scheme
        t.deviceID = selectedDevice
        do { try service.upsert(t) } catch { message = error.localizedDescription }
    }
}

private struct StepDetail: View {
    let step: OnboardingModel.Step
    @Bindable var model: OnboardingModel
    let service: ResignService

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch step {
            case .xcode:
                Steps([
                    "KeepSigned 透過 Apple 免費的 Xcode 幫 App 簽名，所以需要先安裝 Xcode。",
                    "點下方按鈕打開 App Store，安裝 Xcode（檔案很大，請預留 40 GB 以上空間與時間）。",
                    "安裝完成後回到這裡按「重新檢查」。",
                ])
                Button("在 App Store 打開 Xcode") {
                    NSWorkspace.shared.open(URL(string: "macappstore://apps.apple.com/app/id497799835")!)
                }
                Status(ok: model.xcodeOK, yes: "已安裝 Xcode", no: "尚未偵測到 Xcode")

            case .firstLaunch:
                Steps([
                    "打開 Xcode 一次，同意授權條款。",
                    "若跳出「安裝額外元件」或要選平台，請勾選 iOS 並安裝。",
                    "看到 Xcode 歡迎畫面後即可關閉，回到這裡按「重新檢查」。",
                ])
                Button("打開 Xcode") { openXcode() }
                Status(ok: model.firstLaunchOK, yes: "Xcode 已就緒", no: "Xcode 尚未完成第一次啟動")

            case .account:
                Steps([
                    "在 Xcode 選單點 Xcode → Settings…（設定），切到 Accounts。",
                    "按左下角「+」→ Apple ID，登入你自己的 Apple 帳號（免費帳號即可）。",
                    "KeepSigned 不會讀取或儲存你的帳號密碼，只會讀取 Team ID 用來簽名。",
                ])
                Button("打開 Xcode") { openXcode() }
                Status(ok: model.signedIn, yes: "已登入 Apple ID", no: "Xcode 尚未登入 Apple ID")
                HStack {
                    TextField("Team ID（10 碼英數）", text: $model.teamDraft).frame(width: 200)
                    Button("儲存") {
                        let v = model.teamDraft.trimmingCharacters(in: .whitespaces).uppercased()
                        if Validator.isValidTeamID(v) { service.updateSettings { $0.teamID = v }; model.message = nil }
                        else { model.message = "Team ID 應為 10 碼大寫英數" }
                    }
                }
                Text("通常會自動偵測。若空白，請在 Xcode 隨便開一個專案，在 Signing & Capabilities 的 Team 選一次自己的名字，再按「重新檢查」。")
                    .font(.caption).foregroundStyle(.secondary)
                Message(model.message)

            case .prefix:
                Steps([
                    "每個 App 都需要一個全世界唯一的識別碼（Bundle ID），格式像 dev.bluefox.sampleapp。",
                    "前面的 dev.bluefox 是你的「前綴」，你的所有 App 共用，取一次就好。",
                    "請取一個跟真名、帳號無關的英文代號，只能用小寫英文、數字、連字號，用「.」分段。",
                    "定了之後不要再改，改了 iPhone 會把 App 當成新的，舊資料不會帶過去。",
                ])
                HStack {
                    TextField("例如 dev.bluefox", text: $model.prefixDraft).frame(width: 240)
                    Button("換一個") { model.prefixDraft = EnvironmentCheck.suggestPrefix() }
                    Button("使用這個") {
                        let v = model.prefixDraft.trimmingCharacters(in: .whitespaces).lowercased()
                        if Validator.isValidBundlePrefix(v) { service.updateSettings { $0.bundlePrefix = v }; model.message = nil }
                        else { model.message = "格式不正確，例：dev.bluefox" }
                    }
                }
                Message(model.message)
                if let p = service.settings.bundlePrefix {
                    Status(ok: true, yes: "目前前綴：\(p)", no: "")
                }

            case .iphone:
                Steps([
                    "用傳輸線把 iPhone 接到這台 Mac，並解鎖 iPhone。",
                    "iPhone 跳出「要信任這部電腦嗎？」時點「信任」，輸入手機密碼。",
                    "第一次連接時 Xcode 會在背景準備手機，可能需要幾分鐘。",
                ])
                DevicePicker(model: model)
                Status(ok: model.deviceStatus?.paired == true && model.selectedLink != .offline,
                       yes: "已連接：\(model.deviceStatus?.name ?? "")", no: "尚未偵測到已信任的 iPhone")
                Text("有多台裝置時，請在上方選單選擇要安裝的那一台。").font(.caption).foregroundStyle(.secondary)

            case .developerMode:
                Steps([
                    "在 iPhone 打開「設定 → 隱私權與安全性」，滑到最下面。",
                    "點「開發者模式」並打開，手機會要求重新開機。",
                    "重開機解鎖後，跳出確認視窗時點「開啟」並輸入密碼。",
                    "看不到這個選項？請先完成上一步（接上 Mac），等一兩分鐘後再看。",
                    "開發者模式只是允許安裝自己簽名的 App，隨時可以關閉；請勿安裝來路不明的 App。",
                ])
                if model.deviceStatus != nil && model.deviceStatus?.developerMode == nil {
                    Label("無法確認：請解鎖 iPhone 後按「重新檢查」", systemImage: "questionmark.circle")
                        .foregroundStyle(.orange)
                } else {
                    Status(ok: model.deviceStatus?.developerMode == true, yes: "開發者模式已開啟", no: "開發者模式尚未開啟")
                }

            case .project:
                Steps([
                    "選擇要安裝的 App 專案（作者提供的資料夾中，副檔名為 .xcodeproj 的檔案）。",
                    "KeepSigned 會用你的前綴與 Apple ID 幫它簽名，不需要改任何程式碼。",
                ])
                HStack {
                    Text(model.projectPath.isEmpty ? "尚未選擇" : model.projectPath)
                        .lineLimit(1).truncationMode(.middle)
                    Button("選擇…") { chooseProject() }
                }
                if !model.projectPath.isEmpty {
                    HStack {
                        TextField("Scheme", text: $model.scheme).frame(width: 200)
                        Button("加入") { model.saveTarget(service: service) }
                    }
                }
                Message(model.message)
                ForEach(service.targets) { t in
                    Status(ok: true, yes: "已加入：\(t.name)", no: "")
                }

            case .install:
                Steps([
                    "保持 iPhone 解鎖並接著傳輸線，按下「安裝到 iPhone」，約需 1–3 分鐘。",
                    "完成後，在 iPhone 打開「設定 → 一般 → VPN 與裝置管理」。",
                    "在「開發者 App」下點你的 Apple ID，再點「信任」。",
                    "回到主畫面打開 App 即可使用。之後每次續簽都不用再信任。",
                ])
                ForEach(service.targets) { t in
                    HStack {
                        Text(t.name).bold()
                        Spacer()
                        if service.runningID == t.id {
                            ProgressView().controlSize(.small)
                            Text(service.runningStep).font(.caption)
                        } else {
                            Button("安裝到 iPhone") { Task { await service.resign(t.id) } }
                                .disabled(service.runningID != nil)
                        }
                    }
                    if let msg = t.lastMessage {
                        Text(msg).font(.caption).foregroundStyle(t.lastSucceeded == false ? .red : .green)
                    }
                }
                if service.targets.isEmpty { Text("請先完成上一步").foregroundStyle(.secondary) }

            case .wireless:
                Steps([
                    "設定後，iPhone 和 Mac 在同一個 Wi-Fi 就能自動續簽，不用接線。",
                    "保持 iPhone 接著傳輸線，在 Xcode 選單點 Window → Devices and Simulators。",
                    "左邊選你的 iPhone，勾選「Connect via network」。",
                    "拔掉傳輸線，等約 30 秒後按「重新檢查」。",
                    "這一步可以略過，但之後每次續簽都要接線。",
                ])
                Button("打開 Xcode") { openXcode() }
                Status(ok: model.deviceStatus?.wireless == true, yes: "已透過無線網路連線",
                       no: "目前是有線連線或未連線")

            case .finish:
                Steps([
                    "打開「登入時自動啟動」，Mac 開機後 KeepSigned 會在背景執行。",
                    "KeepSigned 每小時檢查一次，到期前 2 天自動續簽並安裝；失敗會跳通知。",
                    "續簽時 Mac 需開著，iPhone 需與 Mac 在同一個 Wi-Fi（或接線）。",
                    "免費 Apple ID 的限制：同一台 iPhone 最多 3 個自簽 App，每 7 天最多 10 個新 App ID。",
                    "之後可從選單列的圖示查看剩餘天數或手動續簽。",
                ])
                LoginItemRow(service: service)
            }
        }
    }

    private func openXcode() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Xcode.app"))
    }

    private func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["xcodeproj", "xcworkspace"].compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK, let url = panel.url {
            model.projectPath = url.standardizedFileURL.path
            model.scheme = url.deletingPathExtension().lastPathComponent
        }
    }
}

private struct DevicePicker: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        if model.devices.isEmpty {
            Text("找不到 iPhone，接上後按「重新檢查」").foregroundStyle(.secondary)
        } else {
            Picker("裝置", selection: $model.selectedDevice) {
                ForEach(model.devices) { d in Text("\(d.name)（\(d.link.label)）").tag(d.udid) }
            }
            .frame(width: 320)
        }
    }
}

private struct Steps: View {
    let lines: [String]
    init(_ lines: [String]) { self.lines = lines }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(i + 1).").monospacedDigit().foregroundStyle(.secondary)
                    Text(line).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct Status: View {
    let ok: Bool
    let yes: String
    let no: String

    var body: some View {
        Label(ok ? yes : no, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
            .foregroundStyle(ok ? .green : .orange)
    }
}

private struct Message: View {
    let text: String?
    init(_ text: String?) { self.text = text }
    var body: some View {
        if let text { Text(text).foregroundStyle(.red).font(.caption) }
    }
}
