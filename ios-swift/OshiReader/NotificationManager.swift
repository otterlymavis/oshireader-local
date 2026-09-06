import Foundation
import UIKit
import UserNotifications

protocol NotificationCenterClient {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>)
    func removeAllPendingNotificationRequests()
    func removeAllDeliveredNotifications()
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
    func pendingNotificationRequests() async -> [UNNotificationRequest]
    func deliveredNotificationIdentifiers() async -> [String]
}

extension UNUserNotificationCenter: NotificationCenterClient {
    func authorizationStatus() async -> UNAuthorizationStatus {
        await notificationSettings().authorizationStatus
    }

    func deliveredNotificationIdentifiers() async -> [String] {
        await deliveredNotifications().map { $0.request.identifier }
    }
}

@MainActor
final class NotificationManager: ObservableObject {
    static let shared = NotificationManager()
    // Must match the category emitted by the paid-push backend and the
    // notification content extension's UNNotificationExtensionCategory.
    static let categoryIdentifier = "OSHI_RESULT_PREVIEW"
    static let openActionIdentifier = "oshireader.notification.open"
    static let saveActionIdentifier = "oshireader.notification.save"

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var lastRemoteRegistrationError: String?

    private let center: NotificationCenterClient
    private let remoteRegistration: @MainActor () -> Void
    private let registerDeviceToken: @MainActor (String) async throws -> Void
    private let registeredTokenProvider: () -> String?
    private let retrySleeper: (UInt64) async throws -> Void
    private let registrationRetryDelays: [UInt64]
    private let maximumAttachmentBytes: Int64 = 10 * 1024 * 1024
    private var localNotificationGeneration = 0
    private var authorizationRequestTask: Task<(granted: Bool, status: UNAuthorizationStatus), Never>?
    private var lastRegisteredDeviceToken: String?
    private var lastAttemptedDeviceToken: String?
    private var registrationRetryTask: Task<Void, Never>?
    private var registrationRetryAttempt = 0
    private var tokenRegistrationWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    init(
        center: NotificationCenterClient = UNUserNotificationCenter.current(),
        initialRegisteredDeviceToken: String? = nil,
        registeredTokenProvider: @escaping () -> String? = {
            BackendClient.shared.hasRegisteredAPNSDeviceForCurrentEnvironment
                ? KeychainHelper.read(.apnsDeviceToken)
                : nil
        },
        remoteRegistration: @escaping @MainActor () -> Void = {
            UIApplication.shared.registerForRemoteNotifications()
        },
        registerDeviceToken: @escaping @MainActor (String) async throws -> Void = { token in
            try await BackendClient.shared.registerAPNSToken(token)
        },
        registrationRetryDelays: [UInt64] = [1, 5, 30, 120],
        retrySleeper: @escaping (UInt64) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
        }
    ) {
        self.center = center
        self.remoteRegistration = remoteRegistration
        self.registerDeviceToken = registerDeviceToken
        self.registeredTokenProvider = registeredTokenProvider
        self.registrationRetryDelays = registrationRetryDelays
        self.retrySleeper = retrySleeper
        self.lastRegisteredDeviceToken = initialRegisteredDeviceToken ?? registeredTokenProvider()
        Task {
            await refreshAuthorizationStatus()
        }
    }

    var statusText: String {
        let i18n = I18nManager.shared
        switch authorizationStatus {
        case .authorized:
            return i18n.t("notificationStatusEnabled")
        case .provisional:
            return i18n.t("notificationStatusQuiet")
        case .denied:
            return i18n.t("notificationStatusDisabled")
        case .ephemeral:
            return i18n.t("notificationStatusTemporary")
        case .notDetermined:
            return i18n.t("notificationStatusNotRequested")
        @unknown default:
            return i18n.t("notificationStatusUnknown")
        }
    }

    var canScheduleNotifications: Bool {
        authorizationStatus == .authorized || authorizationStatus == .provisional || authorizationStatus == .ephemeral
    }

    var hasRemoteDeviceToken: Bool {
        lastRegisteredDeviceToken != nil || registeredTokenProvider() != nil
    }

    func registerForRemoteNotificationsForDeviceAuthentication(
        resetRetryStateIfExhausted: Bool = true
    ) {
        if resetRetryStateIfExhausted,
           registrationRetryTask == nil,
           registrationRetryAttempt >= registrationRetryDelays.count {
            resetRegistrationRetryState()
        }
        remoteRegistration()
    }

    func ensureRemoteNotificationsRegistered(
        timeout: TimeInterval = 12,
        forceRefresh: Bool = true
    ) async -> Bool {
        if !forceRefresh, hasRemoteDeviceToken, lastRemoteRegistrationError == nil {
            return true
        }
        if forceRefresh {
            resetRegistrationRetryState()
            lastRemoteRegistrationError = nil
        }

        return await withCheckedContinuation { continuation in
            let waiterID = UUID()
            tokenRegistrationWaiters[waiterID] = continuation

            Task { @MainActor [weak self] in
                guard let self else { return }
                if forceRefresh, let cachedToken = self.registeredTokenProvider() {
                    await self.attemptDeviceRegistration(token: cachedToken)
                } else {
                    self.registerForRemoteNotificationsForDeviceAuthentication()
                }
            }

            Task { @MainActor [weak self] in
                let nanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard let self, let waiter = self.tokenRegistrationWaiters.removeValue(forKey: waiterID) else {
                    return
                }
                waiter.resume(returning: false)
            }
        }
    }

    nonisolated static func deviceTokenString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    func handleRegisteredDeviceToken(_ deviceToken: Data) async {
        await attemptDeviceRegistration(token: Self.deviceTokenString(deviceToken))
    }

    func handleRemoteNotificationRegistrationFailed(_ error: Error) {
        lastRemoteRegistrationError = error.localizedDescription
        scheduleRegistrationRetry()
    }

    /// Drops a server-rejected APNs registration without unregistering it
    /// remotely. The next app-active registration obtains and verifies a fresh
    /// credential, while notification routing immediately falls back to Local.
    func invalidateRemoteNotificationRegistration() {
        resetRegistrationRetryState()
        lastRegisteredDeviceToken = nil
        lastAttemptedDeviceToken = nil
        lastRemoteRegistrationError = nil
        _ = KeychainHelper.save(.apnsDeviceToken, nil)
        _ = KeychainHelper.save(.apnsDeviceEnvironment, nil)
        completeTokenRegistrationWaiters(success: false)
    }

    /// Clears a completed server-side deletion only when it still targets the
    /// registration currently persisted by this installation. APNs
    /// registration persistence is also main-actor isolated, so the comparison
    /// and clear cannot race a newly verified token within the process.
    @discardableResult
    func invalidateRemoteNotificationRegistration(
        ifTokenMatches token: String,
        environment: String?
    ) -> Bool {
        guard KeychainHelper.read(.apnsDeviceToken) == token,
              KeychainHelper.read(.apnsDeviceEnvironment) == environment
        else { return false }
        invalidateRemoteNotificationRegistration()
        return true
    }

    private func attemptDeviceRegistration(token: String) async {
        lastAttemptedDeviceToken = token
        do {
            try await registerDeviceToken(token)
            resetRegistrationRetryState()
            lastRegisteredDeviceToken = token
            lastRemoteRegistrationError = nil
            lastAttemptedDeviceToken = nil
            completeTokenRegistrationWaiters(success: true)
        } catch {
            lastRemoteRegistrationError = error.localizedDescription
            scheduleRegistrationRetry()
        }
    }

    private func scheduleRegistrationRetry() {
        guard registrationRetryTask == nil else { return }
        guard registrationRetryAttempt < registrationRetryDelays.count else {
            completeTokenRegistrationWaiters(success: false)
            return
        }
        let delay = registrationRetryDelays[registrationRetryAttempt]
        registrationRetryAttempt += 1
        registrationRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.retrySleeper(delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self.registrationRetryTask = nil
            if let token = self.lastAttemptedDeviceToken {
                await self.attemptDeviceRegistration(token: token)
            } else {
                self.remoteRegistration()
            }
        }
    }

    private func resetRegistrationRetryState() {
        registrationRetryTask?.cancel()
        registrationRetryTask = nil
        registrationRetryAttempt = 0
    }

    private func completeTokenRegistrationWaiters(success: Bool) {
        let waiters = tokenRegistrationWaiters.values
        tokenRegistrationWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: success) }
    }

    nonisolated static func shouldScheduleLocalNotification(
        for term: WatchTerm,
        pushDeliveryState: PushDeliveryState,
        hasRegisteredAPNSDevice: Bool
    ) -> Bool {
        guard term.notify_on_new else { return false }
        let serverOwnsDelivery = term.backendTermID != nil
            && pushDeliveryState == .active
            && hasRegisteredAPNSDevice
        return !serverOwnsDelivery
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
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.categoryIdentifier,
                actions: [open, save],
                intentIdentifiers: [],
                options: [.customDismissAction]
            )
        ])
    }

    func clearLocalNotifications() {
        localNotificationGeneration &+= 1
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    func clearNotification(forTermID termID: String) async {
        localNotificationGeneration &+= 1
        let prefix = Self.notificationIdentifierPrefix(forTermID: termID)
        let pendingIDs = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(prefix) }
        let deliveredIDs = await center.deliveredNotificationIdentifiers()
            .filter { $0.hasPrefix(prefix) }
        if !pendingIDs.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: pendingIDs)
        }
        if !deliveredIDs.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: deliveredIDs)
        }
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

        let pushDeliveryState = PlusStore.shared.pushDeliveryState
        let hasRegisteredAPNSDevice = BackendClient.shared.hasRegisteredAPNSDeviceForCurrentEnvironment
        let locallyNotifiedTerms = terms.filter {
            Self.shouldScheduleLocalNotification(
                for: $0,
                pushDeliveryState: pushDeliveryState,
                hasRegisteredAPNSDevice: hasRegisteredAPNSDevice
            )
        }
        let notifiedKeywords = Set(locallyNotifiedTerms.map(\.keyword))
        guard !notifiedKeywords.isEmpty else { return }
        var notifiedTermsByKeyword: [String: WatchTerm] = [:]
        for term in locallyNotifiedTerms {
            // Preserve the existing one-digest-per-keyword behavior for
            // legacy data that may contain duplicate keywords.
            notifiedTermsByKeyword[term.keyword] = notifiedTermsByKeyword[term.keyword] ?? term
        }

        let matchingItems = items.filter {
            notifiedKeywords.contains($0.watch_term_keyword)
                && $0.source != IngestionService.twitterPublicIndexSource
                && $0.source != IngestionService.unverifiedDateGoogleNewsSource
                && $0.source != IngestionService.fiveChThreadCreatedSource
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

        // One banner per new item, newest kept individual. A large first-time
        // burst (a term that just enabled "notify on new", a re-subscribed
        // platform) would otherwise schedule dozens of requests in one loop and
        // push past iOS's ~64-pending ceiling, silently dropping the rest — so
        // cap the individual banners and fold the older remainder into one
        // per-keyword summary.
        let newestFirst = matchingItems.sorted(by: feedItemSortPrecedes)
        let individualItems = Array(newestFirst.prefix(Self.maxIndividualNotificationsPerRefresh))
        let overflowItems = Array(newestFirst.dropFirst(Self.maxIndividualNotificationsPerRefresh))

        // Notification Center shows the most recently delivered request at the
        // top. Submit oldest-to-newest so the visible stack matches the feed's
        // newest-first order; ties stay deterministic via the shared comparator.
        let deliveryItems = Array(individualItems.sorted(by: feedItemSortPrecedes).reversed())
        // Slot 0 is reserved for the per-keyword overflow summary when there is
        // one, so the summary (oldest items) delivers first and sits below every
        // individual banner in Notification Center.
        let firstIndividualSlot = overflowItems.isEmpty ? 0 : 1
        let lastSlot = deliveryItems.count - 1 + firstIndividualSlot
        // Trickle the batch out so banners feel like a live feed instead of one
        // dump. Nominal gap is individualDeliverySpacing; for a large batch it
        // shrinks so the whole run still fits inside maxIndividualDeliverySpread
        // rather than piling the tail onto the ceiling.
        let deliverySpacing: TimeInterval = lastSlot > 0
            ? min(Self.individualDeliverySpacing,
                  Self.maxIndividualDeliverySpread / TimeInterval(lastSlot))
            : Self.individualDeliverySpacing

        // Identifiers added so far this call. Time-triggered banners stay
        // *pending* (not delivered) for minutes, so if a concurrent clear /
        // cancellation bumps the generation mid-loop, retract the whole batch —
        // not just the in-flight request — or stale banners fire later.
        var scheduledIdentifiers: [String] = []
        func retractScheduledBatch() {
            guard !scheduledIdentifiers.isEmpty else { return }
            center.removePendingNotificationRequests(withIdentifiers: scheduledIdentifiers)
            center.removeDeliveredNotifications(withIdentifiers: scheduledIdentifiers)
        }

        for (deliveryIndex, item) in deliveryItems.enumerated() {
            guard !Task.isCancelled, generation == localNotificationGeneration else {
                retractScheduledBatch()
                return
            }
            guard let term = notifiedTermsByKeyword[item.watch_term_keyword] else { continue }
            let notificationIdentifier = Self.notificationIdentifier(forTermID: term.id, itemID: item.id)
            let content = UNMutableNotificationContent()
            content.title = item.watch_term_keyword
            let itemTitle = cleanDisplayText(item.title)
            let itemBody = cleanDisplayText(item.content_text)
            if let itemTitle, !itemTitle.isEmpty {
                content.subtitle = Self.limitedAlertText(itemTitle, limit: Self.alertSubtitleLimit)
            }
            if let itemBody, !itemBody.isEmpty, itemBody != itemTitle {
                content.body = Self.limitedAlertText(itemBody, limit: Self.alertBodyLimit)
            } else if content.subtitle.isEmpty {
                let fallback = item.url.isEmpty ? "1 new item found." : item.url
                content.body = Self.limitedAlertText(fallback, limit: Self.alertBodyLimit)
            }
            content.sound = .default
            content.categoryIdentifier = Self.categoryIdentifier
            if includeAttachments,
               let attachment = await notificationAttachment(for: item) {
                content.attachments = [attachment]
            }
            content.userInfo = notificationUserInfo(for: item)
            // A unique thread prevents iOS from visually grouping separate
            // feed items into one per-keyword notification stack.
            content.threadIdentifier = notificationIdentifier
            content.targetContentIdentifier = item.id

            // deliveryItems is oldest-first, so the offset grows toward the
            // newest item — the stack still ends up newest-on-top, just spread
            // out. The earliest slot keeps a nil trigger for immediate delivery.
            let offset = Double(deliveryIndex + firstIndividualSlot) * deliverySpacing
            let trigger: UNNotificationTrigger? = offset > 0
                ? UNTimeIntervalNotificationTrigger(timeInterval: offset, repeats: false)
                : nil

            let request = UNNotificationRequest(
                identifier: notificationIdentifier,
                content: content,
                trigger: trigger
            )
            do {
                guard !Task.isCancelled, generation == localNotificationGeneration else {
                    retractScheduledBatch()
                    return
                }
                center.removePendingNotificationRequests(withIdentifiers: [request.identifier])
                try await center.add(request)
                scheduledIdentifiers.append(request.identifier)
                guard !Task.isCancelled, generation == localNotificationGeneration else {
                    retractScheduledBatch()
                    return
                }
            } catch {
                AppLogger.notifications.error("Notification scheduling failed for \(item.watch_term_keyword): \(error.localizedDescription)")
            }
        }

        guard !overflowItems.isEmpty else { return }
        let overflowByKeyword = Dictionary(grouping: overflowItems, by: \.watch_term_keyword)
        for keyword in overflowByKeyword.keys.sorted() {
            guard !Task.isCancelled, generation == localNotificationGeneration else {
                retractScheduledBatch()
                return
            }
            guard let term = notifiedTermsByKeyword[keyword],
                  let overflow = overflowByKeyword[keyword], !overflow.isEmpty else { continue }
            let newest = overflow.sorted(by: feedItemSortPrecedes).first
            let identifier = Self.notificationIdentifier(forTermID: term.id, itemID: "summary")
            let content = UNMutableNotificationContent()
            content.title = keyword
            content.body = I18nManager.shared.tFormat("notificationBurstOverflowBodyFmt", overflow.count)
            content.sound = .default
            content.categoryIdentifier = Self.categoryIdentifier
            content.threadIdentifier = identifier
            if let newest {
                content.userInfo = notificationUserInfo(for: newest)
                content.targetContentIdentifier = newest.id
            }
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            do {
                guard !Task.isCancelled, generation == localNotificationGeneration else {
                    retractScheduledBatch()
                    return
                }
                center.removePendingNotificationRequests(withIdentifiers: [identifier])
                try await center.add(request)
                scheduledIdentifiers.append(identifier)
            } catch {
                AppLogger.notifications.error("Notification summary scheduling failed for \(keyword): \(error.localizedDescription)")
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
        let state = QuietHoursDigestState.accumulating(newCounts, settings: settings, now: now)
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

    private static let alertSubtitleLimit = 50
    private static let alertBodyLimit = 100
    /// Cap on individual "new item" banners scheduled in one refresh. Beyond
    /// this the older remainder folds into one per-keyword summary, so a large
    /// first-time burst can't push past iOS's ~64-pending ceiling.
    private static let maxIndividualNotificationsPerRefresh = 24
    /// Gap between successive individual "new item" banners from one refresh, so
    /// a batch trickles in rather than arriving in a single burst.
    private static let individualDeliverySpacing: TimeInterval = 30
    /// Ceiling on how far out the last banner in a batch is scheduled. Kept
    /// under the shortest auto-refresh interval (5 min) so one batch finishes
    /// delivering before the next refresh schedules another — otherwise up to
    /// `maxIndividualNotificationsPerRefresh` pending requests per overlapping
    /// batch could approach iOS's ~64-pending ceiling.
    private static let maxIndividualDeliverySpread: TimeInterval = 3 * 60
    private static func limitedAlertText(_ value: String, limit: Int) -> String {
        value.count <= limit ? value : "\(value.prefix(limit - 3))..."
    }

    private func notificationUserInfo(for item: FeedItem) -> [AnyHashable: Any] {
        var userInfo: [AnyHashable: Any] = [
            "feed_item_id": item.id,
            "item_id": item.id,
            "watch_term_keyword": item.watch_term_keyword,
            "new_count": 1,
            "platform": item.platform,
            "item_platform": item.platform,
            "url": item.url,
            "item_url": item.url,
            "media_type": item.media_type,
            "item_media_type": item.media_type,
            "published_at": item.published_at,
            "item_published_at": item.published_at,
            "fetched_at": item.fetched_at,
        ]
        var previewItem: [String: Any] = [
            "id": item.id,
            "url": item.url,
            "platform": item.platform,
            "media_type": item.media_type,
            "published_at": item.published_at,
        ]
        if let title = cleanDisplayText(item.title) {
            userInfo["title"] = title
            userInfo["item_title"] = title
            previewItem["title"] = title
        }
        if let contentText = cleanDisplayText(item.content_text) {
            userInfo["content_text"] = contentText
            userInfo["item_content_text"] = contentText
            previewItem["content_text"] = contentText
        }
        if let author = cleanDisplayText(item.author) {
            userInfo["author"] = author
            userInfo["item_author"] = author
            previewItem["author"] = author
        }
        if let thumbnailURL = item.thumbnail_url {
            userInfo["thumbnail_url"] = thumbnailURL
            previewItem["thumbnail_url"] = thumbnailURL
        }
        if let source = item.source {
            userInfo["source"] = source
            userInfo["item_source"] = source
            previewItem["source"] = source
        }
        userInfo["preview_item"] = previewItem
        return userInfo
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
            let options = [UNNotificationAttachmentOptionsThumbnailHiddenKey: true]
            return try UNNotificationAttachment(identifier: "preview", url: destination, options: options)
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

    private static func notificationIdentifierPrefix(forTermID termID: String) -> String {
        "oshireader-new-term-\(termID)-"
    }

    private static func notificationIdentifier(forTermID termID: String, itemID: String) -> String {
        "\(notificationIdentifierPrefix(forTermID: termID))\(itemID)"
    }
}
