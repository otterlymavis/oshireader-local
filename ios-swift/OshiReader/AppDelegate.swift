import UIKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Fully local app: the notification center delegate lets new-item
        // alerts show while the app is open.
        UNUserNotificationCenter.current().delegate = self
        NotificationManager.shared.registerNotificationCategories()
        application.setMinimumBackgroundFetchInterval(BackgroundRefreshManager.minimumInterval)
        BackgroundRefreshManager.shared.register()
        // Eagerly instantiate so its Combine subscription to LocalDB's
        // dataRevision starts this launch — otherwise a session that never
        // opens Settings (the only other place this singleton is touched)
        // would never auto-push local changes to iCloud.
        _ = CloudSyncManager.shared
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        LocalDB.shared.flushPendingWrites()
        BackgroundRefreshManager.shared.schedule()
    }

    func application(
        _ application: UIApplication,
        performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        AppLogger.network.notice("Legacy background fetch started")
        Task { @MainActor in
            let outcome = await BackgroundRefreshManager.shared.refreshNow()
            AppLogger.network.notice("Legacy background fetch completed outcome=\(String(describing: outcome))")
            switch outcome {
            case .newData: completionHandler(.newData)
            case .noData: completionHandler(.noData)
            case .failed: completionHandler(.failed)
            }
        }
    }

    // Present locally scheduled new-item alerts as a banner with sound while
    // the app is active; background refresh may also schedule these alerts.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound, .badge])
    }

    nonisolated func userNotificationCenter(
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
