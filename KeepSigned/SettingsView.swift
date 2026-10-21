import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    let service: ResignService
    @State private var editing: ResignTarget?

    var body: some View {
        VStack(alignment: .leading) {
            List {
                ForEach(service.targets) { t in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(t.name).bold()
                            Text(t.projectPath).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button("編輯") { editing = t }
                        Button("刪除", role: .destructive) { service.remove(t.id) }
                    }
                }
            }
            HStack {
                Button("新增 App…") {
                    editing = ResignTarget(name: "", projectPath: "", scheme: "", deviceID: "")
                }
                Spacer()
                Text("簽名使用 Xcode 已登入的 Apple ID，本工具不儲存帳密。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(minWidth: 560, minHeight: 320)
        .sheet(item: $editing) { t in
            TargetEditor(target: t, service: service) { editing = nil }
        }
    }
}

private struct TargetEditor: View {
    @State var target: ResignTarget
    let service: ResignService
    let done: () -> Void

    @State private var devices: [Device] = []
    @State private var error: String?
    @State private var loadingDevices = false

    var body: some View {
        Form {
            TextField("名稱", text: $target.name)
            HStack {
                TextField("專案路徑", text: $target.projectPath)
                Button("選擇…", action: chooseProject)
            }
            TextField("Scheme", text: $target.scheme)
            HStack {
                Picker("裝置", selection: $target.deviceID) {
                    if !devices.contains(where: { $0.udid == target.deviceID }) {
                        Text(target.deviceID.isEmpty ? "請選擇" : target.deviceID).tag(target.deviceID)
                    }
                    ForEach(devices) { d in
                        Text("\(d.name)（\(d.link.label)）").tag(d.udid)
                    }
                }
                Button(loadingDevices ? "讀取中…" : "重新整理") { Task { await loadDevices() } }
                    .disabled(loadingDevices)
            }
            Stepper("剩不到 \(target.thresholdHours) 小時就自動續簽",
                    value: $target.thresholdHours, in: 1...144, step: 12)
            Toggle("自動續簽", isOn: $target.autoRenew)

            if let error {
                Text(error).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消", action: done)
                Button("儲存") {
                    do { try service.upsert(target); done() }
                    catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 520)
        .task { await loadDevices() }
    }

    private func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = ["xcodeproj", "xcworkspace"]
            .compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK, let url = panel.url {
            target.projectPath = url.standardizedFileURL.path
            if target.scheme.isEmpty { target.scheme = url.deletingPathExtension().lastPathComponent }
            if target.name.isEmpty { target.name = target.scheme }
        }
    }

    private func loadDevices() async {
        loadingDevices = true
        defer { loadingDevices = false }
        do { devices = try await Devices.list() }
        catch { self.error = error.localizedDescription }
    }
}
