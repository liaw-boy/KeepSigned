import SwiftUI

@main
struct SampleApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 48))
            Text("SampleApp")
                .font(.title)
            Text("Build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")")
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
