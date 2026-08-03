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
        NotificationManager.shared.registerNotificationCategories()
        BackgroundRefreshManager.shared.register()
        BackgroundRefreshManager.shared.schedule()
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        LocalDB.shared.flushPendingWrites()
        BackgroundRefreshManager.shared.schedule()
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        BackgroundRefreshManager.shared.schedule()
    }

    // Present locally scheduled new-item alerts as a banner with sound while
    // the app is active; background refresh may also schedule these alerts.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound, .badge])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            let userInfo = response.notification.request.content.userInfo
            switch response.actionIdentifier {
            case NotificationManager.saveActionIdentifier:
                NotificationNavigationManager.shared.save(userInfo: userInfo)
            case NotificationManager.openActionIdentifier, UNNotificationDefaultActionIdentifier:
                NotificationNavigationManager.shared.open(userInfo: userInfo)
            default:
                break
            }
            completionHandler()
        }
    }
}
