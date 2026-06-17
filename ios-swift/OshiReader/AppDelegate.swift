import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Fully local app — notifications are delivered locally, so there is no
        // remote/APNs registration here. We do need to be the notification
        // center delegate so new-item alerts can show while the app is open.
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    // The app only fetches new items while it is in the foreground, so without
    // this the system would silently suppress every new-item banner. Present
    // them as a banner with sound instead.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound, .badge])
    }
}
