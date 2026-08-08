import SwiftUI

@main
struct OshiReaderApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

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
    }

    private static var isUnitTesting: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
            NSClassFromString("XCTestCase") != nil
    }
}
