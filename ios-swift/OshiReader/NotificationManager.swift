import Foundation
import UIKit
import UserNotifications

protocol NotificationCenterClient {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
    func removeAllPendingNotificationRequests()
    func removeAllDeliveredNotifications()
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
}

extension UNUserNotificationCenter: NotificationCenterClient {
    func authorizationStatus() async -> UNAuthorizationStatus {
        await notificationSettings().authorizationStatus
    }
}

@MainActor
final class NotificationManager: ObservableObject {
    static let shared = NotificationManager()
    static let categoryIdentifier = "oshireader.new-items"
    static let openActionIdentifier = "oshireader.notification.open"
    static let saveActionIdentifier = "oshireader.notification.save"

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    private let center: NotificationCenterClient
    private var localNotificationGeneration = 0
    private var authorizationRequestTask: Task<(granted: Bool, status: UNAuthorizationStatus), Never>?

    init(center: NotificationCenterClient = UNUserNotificationCenter.current()) {
        self.center = center
        Task {
            await refreshAuthorizationStatus()
        }
    }

    var statusText: String {
        switch authorizationStatus {
        case .authorized:
            return "Enabled"
        case .provisional:
            return "Quietly enabled"
        case .denied:
            return "Disabled in iOS Settings"
        case .ephemeral:
            return "Temporarily enabled"
        case .notDetermined:
            return "Not requested"
        @unknown default:
            return "Unknown"
        }
    }

    var canScheduleNotifications: Bool {
        authorizationStatus == .authorized || authorizationStatus == .provisional || authorizationStatus == .ephemeral
    }

    func refreshAuthorizationStatus() async {
        authorizationStatus = await center.authorizationStatus()
    }

    func registerNotificationCategories() {
        let open = UNNotificationAction(
            identifier: Self.openActionIdentifier,
            title: I18nManager.shared.t("openNotification"),
            options: [.foreground]
        )
        let save = UNNotificationAction(
            identifier: Self.saveActionIdentifier,
            title: I18nManager.shared.t("save"),
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.categoryIdentifier,
                actions: [open, save],
                intentIdentifiers: [],
                options: []
            )
        ])
    }

    func clearLocalNotifications() {
        localNotificationGeneration &+= 1
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    func clearNotification(forTermID termID: String) {
        localNotificationGeneration &+= 1
        let identifier = Self.notificationIdentifier(forTermID: termID)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        if let authorizationRequestTask {
            return (await authorizationRequestTask.value).granted
        }

        let task = Task { @MainActor [center] in
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
                return (granted: granted, status: await center.authorizationStatus())
            } catch {
                return (granted: false, status: await center.authorizationStatus())
            }
        }
        authorizationRequestTask = task
        let result = await task.value
        authorizationRequestTask = nil
        authorizationStatus = result.status
        return result.granted
    }

    func sendTestNotification() async throws {
        if !canScheduleNotifications {
            _ = await requestAuthorizationIfNeededForLocalAlerts()
        }
        guard canScheduleNotifications else { return }

        let content = UNMutableNotificationContent()
        content.title = "OshiReader"
        content.body = "Notifications are ready."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "oshireader-test-\(UUID().uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        try await center.add(request)
    }

    @discardableResult
    func requestAuthorizationIfNeededForLocalAlerts() async -> Bool {
        await refreshAuthorizationStatus()
        if authorizationStatus == .notDetermined {
            _ = await requestAuthorization()
        }
        return canScheduleNotifications
    }

    // Remote/APNs push has been removed — the app is fully local and delivers
    // new-item alerts via local notifications (see notifyForNewItems).
    nonisolated static func deviceTokenString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    func notifyForNewItems(_ items: [FeedItem], terms: [WatchTerm]) async {
        guard !items.isEmpty else { return }
        let generation = localNotificationGeneration
        await refreshAuthorizationStatus()
        guard generation == localNotificationGeneration else { return }
        guard canScheduleNotifications else { return }

        let notifiedKeywords = Set(terms.filter(\.notify_on_new).map(\.keyword))
        guard !notifiedKeywords.isEmpty else { return }
        var notifiedTermsByKeyword: [String: WatchTerm] = [:]
        for term in terms where term.notify_on_new {
            // Preserve the existing one-digest-per-keyword behavior for
            // legacy data that may contain duplicate keywords.
            notifiedTermsByKeyword[term.keyword] = notifiedTermsByKeyword[term.keyword] ?? term
        }

        let matchingItems = items.filter { notifiedKeywords.contains($0.watch_term_keyword) }
        let counts = Dictionary(grouping: matchingItems) {
            $0.watch_term_keyword
        }.mapValues(\.count)

        for (keyword, count) in counts where count > 0 {
            guard generation == localNotificationGeneration else { return }
            guard let term = notifiedTermsByKeyword[keyword] else { continue }
            let representative = matchingItems.first { $0.watch_term_keyword == keyword }
            let content = UNMutableNotificationContent()
            content.title = "New items for \(keyword)"
            content.body = "\(count) new item\(count == 1 ? "" : "s") found."
            content.sound = .default
            content.categoryIdentifier = Self.categoryIdentifier
            if let representative {
                var userInfo: [String: Any] = [
                    "feed_item_id": representative.id,
                    "watch_term_keyword": representative.watch_term_keyword,
                    "platform": representative.platform,
                    "url": representative.url,
                    "media_type": representative.media_type,
                    "published_at": representative.published_at,
                    "fetched_at": representative.fetched_at
                ]
                if let title = representative.title { userInfo["title"] = title }
                if let contentText = representative.content_text { userInfo["content_text"] = contentText }
                if let author = representative.author { userInfo["author"] = author }
                if let thumbnailURL = representative.thumbnail_url { userInfo["thumbnail_url"] = thumbnailURL }
                content.userInfo = userInfo
            }

            let request = UNNotificationRequest(
                identifier: Self.notificationIdentifier(forTermID: term.id),
                content: content,
                trigger: nil
            )
            do {
                guard generation == localNotificationGeneration else { return }
                center.removePendingNotificationRequests(withIdentifiers: [request.identifier])
                try await center.add(request)
                guard generation == localNotificationGeneration else {
                    center.removePendingNotificationRequests(withIdentifiers: [request.identifier])
                    center.removeDeliveredNotifications(withIdentifiers: [request.identifier])
                    return
                }
            } catch {
                #if DEBUG
                print("Notification scheduling failed for \(keyword): \(error)")
                #endif

            }
        }
    }

    private static func notificationIdentifier(forTermID termID: String) -> String {
        "oshireader-new-term-\(termID)"
    }
}
