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
    private let maximumAttachmentBytes: Int64 = 10 * 1024 * 1024
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

    func notifyForNewItems(_ items: [FeedItem], terms: [WatchTerm], includeAttachments: Bool = true) async {
        guard !Task.isCancelled, !items.isEmpty else { return }
        let generation = localNotificationGeneration
        await refreshAuthorizationStatus()
        guard !Task.isCancelled, generation == localNotificationGeneration else { return }
        guard canScheduleNotifications else { return }

        let notifiedKeywords = Set(terms.filter(\.notify_on_new).map(\.keyword))
        guard !notifiedKeywords.isEmpty else { return }
        var notifiedTermsByKeyword: [String: WatchTerm] = [:]
        for term in terms where term.notify_on_new {
            // Preserve the existing one-digest-per-keyword behavior for
            // legacy data that may contain duplicate keywords.
            notifiedTermsByKeyword[term.keyword] = notifiedTermsByKeyword[term.keyword] ?? term
        }

        let matchingItems = items.filter {
            notifiedKeywords.contains($0.watch_term_keyword)
                && $0.source != IngestionService.twitterPublicIndexSource
        }
        let itemsByKeyword = Dictionary(grouping: matchingItems) {
            $0.watch_term_keyword
        }

        let quietHours = QuietHoursSettings.current()
        let now = Date()
        if quietHours.contains(now) {
            await scheduleQuietHoursDigest(itemsByKeyword: itemsByKeyword, settings: quietHours, now: now)
            return
        }

        for (keyword, keywordItems) in itemsByKeyword where !keywordItems.isEmpty {
            guard !Task.isCancelled, generation == localNotificationGeneration else { return }
            guard let term = notifiedTermsByKeyword[keyword] else { continue }
            let count = keywordItems.count
            let representative = keywordItems.sorted {
                (parseISO8601Date($0.published_at) ?? .distantPast) >
                (parseISO8601Date($1.published_at) ?? .distantPast)
            }.first
            let content = UNMutableNotificationContent()
            content.title = I18nManager.shared.tFormat("notificationNewItemsForFmt", keyword)
            content.body = notificationBody(for: representative, count: count)
            content.sound = .default
            content.categoryIdentifier = Self.categoryIdentifier
            if includeAttachments,
               let attachment = await notificationAttachment(for: representative) {
                content.attachments = [attachment]
            }
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
                if let source = representative.source { userInfo["source"] = source }
                content.userInfo = userInfo
            }

            let request = UNNotificationRequest(
                identifier: Self.notificationIdentifier(forTermID: term.id),
                content: content,
                trigger: nil
            )
            do {
                guard !Task.isCancelled, generation == localNotificationGeneration else { return }
                center.removePendingNotificationRequests(withIdentifiers: [request.identifier])
                try await center.add(request)
                guard !Task.isCancelled, generation == localNotificationGeneration else {
                    center.removePendingNotificationRequests(withIdentifiers: [request.identifier])
                    center.removeDeliveredNotifications(withIdentifiers: [request.identifier])
                    return
                }
            } catch {
                AppLogger.notifications.error("Notification scheduling failed for \(keyword): \(error.localizedDescription)")
            }
        }
    }

    private static let quietHoursDigestIdentifier = "oshireader-quiet-hours-digest"

    /// Accumulates this batch's per-keyword counts into today's running
    /// total and (re)schedules a single trailing digest for the window's
    /// end time — removing and re-adding the same pending request each call
    /// so repeated refreshes during quiet hours coalesce into one
    /// notification instead of stacking up.
    private func scheduleQuietHoursDigest(itemsByKeyword: [String: [FeedItem]], settings: QuietHoursSettings, now: Date) async {
        let newCounts = itemsByKeyword.mapValues(\.count)
        guard newCounts.values.reduce(0, +) > 0 else { return }
        let state = QuietHoursDigestState.accumulating(newCounts, now: now)
        state.save()

        let content = UNMutableNotificationContent()
        content.title = I18nManager.shared.t("notificationDigestTitle")
        content.body = I18nManager.shared.tFormat("notificationDigestBodyFmt", state.totalCount)
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier

        let triggerDate = settings.nextEndDate(after: now)
        let triggerComponents = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: triggerDate
        )
        let request = UNNotificationRequest(
            identifier: Self.quietHoursDigestIdentifier,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: triggerComponents, repeats: false)
        )
        center.removePendingNotificationRequests(withIdentifiers: [Self.quietHoursDigestIdentifier])
        do {
            try await center.add(request)
        } catch {
            AppLogger.notifications.error("Quiet-hours digest scheduling failed: \(error.localizedDescription)")
        }
    }

    private func notificationBody(for item: FeedItem?, count: Int) -> String {
        let preview = cleanDisplayText(item?.title)
            ?? cleanDisplayText(item?.content_text)
            ?? item?.url
            ?? "\(count) new item\(count == 1 ? "" : "s") found."
        let limitedPreview = preview.count > 140 ? "\(preview.prefix(137))..." : preview
        guard count > 1 else { return limitedPreview }
        return "\(limitedPreview)\n+\(count - 1) more"
    }

    private func notificationAttachment(for item: FeedItem?) async -> UNNotificationAttachment? {
        guard let rawURL = item?.thumbnail_url,
              let url = URL(string: rawURL),
              ["http", "https"].contains(url.scheme?.lowercased()) else {
            return nil
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            let (tempURL, response) = try await URLSession.shared.download(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  http.mimeType?.lowercased().hasPrefix("image/") == true,
                  http.expectedContentLength <= 0 || http.expectedContentLength <= maximumAttachmentBytes,
                  notificationFileSize(at: tempURL) <= maximumAttachmentBytes else {
                return nil
            }

            let extensionHint = notificationAttachmentExtension(for: http, url: url)
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("oshireader-notification-\(UUID().uuidString).\(extensionHint)")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tempURL, to: destination)
            return try UNNotificationAttachment(identifier: "preview", url: destination)
        } catch {
            AppLogger.notifications.warning("Notification preview attachment failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func notificationFileSize(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? Int.max)
    }

    private func notificationAttachmentExtension(for response: HTTPURLResponse, url: URL) -> String {
        switch response.mimeType?.lowercased() {
        case "image/png":
            return "png"
        case "image/gif":
            return "gif"
        case "image/webp":
            return "webp"
        case "image/heic", "image/heif":
            return "heic"
        default:
            let ext = url.pathExtension.lowercased()
            return ["jpg", "jpeg"].contains(ext) ? ext : "jpg"
        }
    }

    private static func notificationIdentifier(forTermID termID: String) -> String {
        "oshireader-new-term-\(termID)"
    }
}
