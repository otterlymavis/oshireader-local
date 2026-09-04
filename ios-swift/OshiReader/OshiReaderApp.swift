import SwiftUI

@main
struct OshiReaderApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        LocalDB.shared.resetForUITesting()
    }

    var body: some Scene {
        WindowGroup {
            if Self.isUnitTesting {
                Color.clear
            } else {
                ContentView()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background, !Self.isUnitTesting else { return }
            // Scene-based SwiftUI apps do not reliably deliver the legacy
            // UIApplicationDelegate background callback. Queue the local feed
            // refresh from the scene lifecycle so new items can be discovered
            // while the app is not open and turned into local notifications.
            LocalDB.shared.flushPendingWrites()
            BackgroundRefreshManager.shared.schedule()
        }
    }

    private static var isUnitTesting: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
            NSClassFromString("XCTestCase") != nil
    }
}
