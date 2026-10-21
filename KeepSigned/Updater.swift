import AppKit
import Sparkle

/// Sparkle auto-update. Feed URL and public key come from Info.plist; every
/// update must carry a valid EdDSA signature from the matching private key.
@MainActor
final class AppUpdater {
    private let controller: SPUStandardUpdaterController

    init() {
        // Unit tests run inside the app; don't start update checks there.
        let underTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        controller = SPUStandardUpdaterController(startingUpdater: !underTest,
                                                  updaterDelegate: nil, userDriverDelegate: nil)
    }

    func checkForUpdates() {
        NSApp.activate()
        controller.checkForUpdates(nil)
    }
}
