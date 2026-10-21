import SwiftUI

@main
struct KeepSignedApp: App {
    @State private var service = ResignService()
    private let updater = AppUpdater()

    var body: some Scene {
        MenuBarExtra {
            MenuView(service: service, updater: updater)
        } label: {
            // Wax seal template images (design/menubar.py); "!" when something needs attention.
            Image(service.hasWarning ? "MenuBarSealWarning" : "MenuBarSeal")
        }
        .menuBarExtraStyle(.window)

        Window("設定精靈", id: "onboarding") {
            OnboardingView(service: service)
        }
        .windowResizability(.contentSize)
        // Opens by itself until the wizard has been completed once.
        .defaultLaunchBehavior(service.settings.onboardingDone ? .suppressed : .presented)

        Settings {
            SettingsView(service: service)
        }
    }
}
