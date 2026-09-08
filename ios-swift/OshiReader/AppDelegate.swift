import UIKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Local alerts remain the free/default path; the optional paid hosted
        // lane is initialized separately below when a catalog is configured.
        UNUserNotificationCenter.current().delegate = self
        NotificationManager.shared.registerNotificationCategories()
        application.setMinimumBackgroundFetchInterval(BackgroundRefreshManager.minimumInterval)
        BackgroundRefreshManager.shared.register()
        // Queue an initial opportunity immediately. The scene-background hook
        // submits again at the lifecycle boundary where iOS can run the work.
        BackgroundRefreshManager.shared.schedule()
        // Eagerly instantiate so its Combine subscription to LocalDB's
        // dataRevision starts this launch — otherwise a session that never
        // opens Settings (the only other place this singleton is touched)
        // would never auto-push local changes to iCloud.
        _ = CloudSyncManager.shared
        if PlusStore.shouldSyncBackend {
            _ = PlusStore.shared
            PushTermRegistry.shared.bootstrapFromProfiles()
            Task {
                await PushSyncCoordinator.shared.reconcile()
                await PaidBackendFeedCoordinator.shared.synchronizeTerms()
            }
        }
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task {
            await NotificationManager.shared.handleRegisteredDeviceToken(deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        NotificationManager.shared.handleRemoteNotificationRegistrationFailed(error)
        AppLogger.network.warning("System APNs registration failed: \(error.localizedDescription)")
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // Pending requests disappear from the system queue as they deliver.
        // Re-check capacity whenever the app becomes active so persisted
        // overflow cannot remain stranded after those slots have opened.
        Task {
            await NotificationManager.shared.refreshAuthorizationStatus()
            await NotificationManager.shared.drainQueuedIndividualNotifications()
        }
        if PlusStore.shouldSyncBackend {
            if PlusStore.shared.hasActiveEntitlement {
                NotificationManager.shared.registerForRemoteNotificationsForDeviceAuthentication()
            }
            Task {
                await PushSyncCoordinator.shared.reconcile()
                await PaidBackendFeedCoordinator.shared.synchronizeTerms()
            }
        }
    }

    // Backgrounding work (flush pending writes, queue the next refresh) is
    // driven from `OshiReaderApp`'s `scenePhase` observer — the single path,
    // since scene-based SwiftUI apps do not reliably deliver
    // `applicationDidEnterBackground` here.

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

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard PlusStore.shouldSyncBackend else {
            completionHandler(.noData)
            return
        }
        AppLogger.network.notice("Paid silent push requested a background refresh")
        Task { @MainActor in
            let hasPreview = userInfo["preview_item"] != nil || userInfo["item_id"] != nil
            let mergedPreview = hasPreview && NotificationNavigationManager.shared.mergeNotificationItem(userInfo: userInfo)
            let outcome = await BackgroundRefreshManager.shared.refreshNow()
            LocalDB.shared.flushPendingWrites()
            switch outcome {
            case .newData:
                completionHandler(.newData)
            case .noData:
                completionHandler(mergedPreview ? .newData : .noData)
            case .failed:
                completionHandler(mergedPreview ? .newData : .failed)
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
        // While the app stays in the foreground, each delivered notification
        // frees a pending slot without another lifecycle transition. Replenish
        // the system queue as those slots open.
        Task { @MainActor in
            await NotificationManager.shared.drainQueuedIndividualNotifications()
        }
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
            // Tell the system the interaction is handled before queue draining,
            // which may suspend while preparing notification attachments.
            completionHandler()
            await NotificationManager.shared.drainQueuedIndividualNotifications()
        }
    }
}
