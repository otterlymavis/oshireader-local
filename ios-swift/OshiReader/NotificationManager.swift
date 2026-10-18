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
    func deliveredNotificationRequests() async -> [UNNotificationRequest]
}

extension NotificationCenterClient {
    func deliveredNotificationRequests() async -> [UNNotificationRequest] {
        await deliveredNotificationIdentifiers().map {
            UNNotificationRequest(identifier: $0, content: UNMutableNotificationContent(), trigger: nil)
        }
    }
}

extension UNUserNotificationCenter: NotificationCenterClient {
    func authorizationStatus() async -> UNAuthorizationStatus {
        await notificationSettings().authorizationStatus
    }

    func deliveredNotificationIdentifiers() async -> [String] {
        await deliveredNotifications().map { $0.request.identifier }
    }

    func deliveredNotificationRequests() async -> [UNNotificationRequest] {
        await deliveredNotifications().map(\.request)
    }
}

private struct QueuedIndividualNotification: Codable, Equatable {
    let identifier: String
    let termID: String
    // Always at least one item, sorted newest-first. Individual delivery
    // (`NotificationDeliverySettings.groupedByKeyword == false`) always queues
    // exactly one; grouped delivery bundles every new match for the keyword
    // into a single queued entry so it delivers as one banner.
    let items: [FeedItem]
    let includeAttachments: Bool
    let notBefore: Date
    // Optional so queues saved by earlier app versions remain readable.
    let enqueuedAt: Date?
    var silent: Bool? = nil

    func replacingItems(_ items: [FeedItem]) -> Self {
        Self(identifier: identifier, termID: termID, items: items, includeAttachments: includeAttachments,
             notBefore: notBefore, enqueuedAt: enqueuedAt, silent: silent)
    }

    func withoutAttachments() -> Self {
        Self(identifier: identifier, termID: termID, items: items, includeAttachments: false,
             notBefore: notBefore, enqueuedAt: enqueuedAt, silent: silent)
    }

    func silenced() -> Self {
        Self(identifier: identifier, termID: termID, items: items, includeAttachments: includeAttachments,
             notBefore: notBefore, enqueuedAt: enqueuedAt, silent: true)
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
    @Published private(set) var catchUpItemCount = 0

    private let center: NotificationCenterClient
    private let remoteRegistration: @MainActor () -> Void
    private let registerDeviceToken: @MainActor (String) async throws -> Void
    private let registeredTokenProvider: () -> String?
    private let retrySleeper: (UInt64) async throws -> Void
    private let registrationRetryDelays: [UInt64]
    private let notificationQueueDefaults: UserDefaults
    private let notificationQueueProfileIDProvider: () -> UUID
    private let nowProvider: () -> Date
    private let maximumPendingNotificationRequests: Int
    private let maximumAttachmentBytes: Int64 = 10 * 1024 * 1024
    private var localNotificationGeneration = 0
    private var authorizationRequestTask: Task<(granted: Bool, status: UNAuthorizationStatus), Never>?
    private var lastRegisteredDeviceToken: String?
    private var lastAttemptedDeviceToken: String?
    private var registrationRetryTask: Task<Void, Never>?
    private var registrationRetryAttempt = 0
    private var tokenRegistrationWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var notificationQueueProfileID: UUID
    private var queuedIndividualNotifications: [QueuedIndividualNotification]
    // Keep the unread membership after delivery: a later refresh replaces the
    // same summary, and reviewing one post only subtracts that post.
    private var rollingSummaries: [String: QueuedIndividualNotification]
    private var isDrainingIndividualNotifications = false
    private var isReviewingNotifications = false
    private var notificationReviewWaiters: [CheckedContinuation<Void, Never>] = []
    private var lastIndividualDeliveryDate: Date?
    private var individualNotificationDrainWaiters: [CheckedContinuation<Void, Never>] = []
    // Records every item id actually handed to `center.add(_:)`, keyed by its
    // per-term notification identifier, so a later refresh can tell "already
    // notified" apart from "new" independent of the OS's own pending/delivered
    // state. Grouped banners register one stable summary identifier, so the
    // bundled items would look unseen again if they ever resurface (e.g.
    // evicted by the feed cap, then re-ingested). Pruned to the
    // same window LocalDB stops treating a resurfaced item as notifiable at all.
    private var notifiedItemLedger: [String: Date] = [:]
    private var isAppForeground = false
    private var foregroundCountedIdentifiers = Set<String>()

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
        },
        notificationQueueDefaults: UserDefaults = .standard,
        notificationQueueProfileIDProvider: @escaping () -> UUID = {
            LocalProfileStore.shared.currentProfileIDThreadSafe
        },
        nowProvider: @escaping () -> Date = Date.init,
        maximumPendingNotificationRequests: Int = 60
    ) {
        let initialQueueProfileID = notificationQueueProfileIDProvider()
        self.center = center
        self.remoteRegistration = remoteRegistration
        self.registerDeviceToken = registerDeviceToken
        self.registeredTokenProvider = registeredTokenProvider
        self.registrationRetryDelays = registrationRetryDelays
        self.retrySleeper = retrySleeper
        self.notificationQueueDefaults = notificationQueueDefaults
        self.notificationQueueProfileIDProvider = notificationQueueProfileIDProvider
        self.nowProvider = nowProvider
        self.maximumPendingNotificationRequests = maximumPendingNotificationRequests
        self.notificationQueueProfileID = initialQueueProfileID
        self.queuedIndividualNotifications = Self.loadQueuedIndividualNotifications(
            defaults: notificationQueueDefaults,
            profileID: initialQueueProfileID
        )
        self.rollingSummaries = Self.loadRollingSummaries(defaults: notificationQueueDefaults, profileID: initialQueueProfileID)
        self.lastIndividualDeliveryDate = Self.loadLastIndividualDeliveryDate(
            defaults: notificationQueueDefaults,
            profileID: initialQueueProfileID
        )
        self.notifiedItemLedger = Self.loadNotifiedItemLedger(
            defaults: notificationQueueDefaults,
            profileID: initialQueueProfileID,
            now: nowProvider()
        )
        self.lastRegisteredDeviceToken = initialRegisteredDeviceToken ?? registeredTokenProvider()

        // Migration cleanup does not require notification authorization. Run it
        // synchronously so a legacy digest cannot survive an upgrade performed
        // while alerts are denied and fire later if permission is restored.
        center.removePendingNotificationRequests(withIdentifiers: [Self.quietHoursDigestIdentifier])
        QuietHoursDigestState.clear(defaults: notificationQueueDefaults)
        Task {
            await refreshAuthorizationStatus()
            guard canScheduleNotifications else { return }
            await drainQueuedIndividualNotifications()
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
        loadNotificationQueueForCurrentProfileIfNeeded()
        queuedIndividualNotifications.removeAll()
        rollingSummaries.removeAll()
        lastIndividualDeliveryDate = nil
        notifiedItemLedger.removeAll()
        catchUpItemCount = 0
        foregroundCountedIdentifiers.removeAll()
        persistQueuedIndividualNotifications()
        persistRollingSummaries()
        persistLastIndividualDeliveryDate()
        persistNotifiedItemLedger()
        QuietHoursDigestState.clear(defaults: notificationQueueDefaults)
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    func clearNotification(forTermID termID: String) async {
        localNotificationGeneration &+= 1
        loadNotificationQueueForCurrentProfileIfNeeded()
        queuedIndividualNotifications.removeAll { $0.termID == termID }
        rollingSummaries = rollingSummaries.filter { $0.value.termID != termID }
        persistQueuedIndividualNotifications()
        persistRollingSummaries()
        let prefix = Self.notificationIdentifierPrefix(forTermID: termID)
        notifiedItemLedger = notifiedItemLedger.filter { !$0.key.hasPrefix(prefix) }
        persistNotifiedItemLedger()
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

    /// Acknowledges only this post, never every unread post in its keyword.
    /// Notification identifiers and profile tags keep hosted alerts and other
    /// profiles outside this local-reader operation.
    func markReviewed(itemID: String) async {
        let requestedProfileID = notificationQueueProfileIDProvider()
        while isReviewingNotifications {
            await withCheckedContinuation { notificationReviewWaiters.append($0) }
        }
        guard notificationQueueProfileIDProvider() == requestedProfileID else { return }
        isReviewingNotifications = true
        var ownsReviewLock = true
        defer { if ownsReviewLock { finishReviewingNotifications() } }
        loadNotificationQueueForCurrentProfileIfNeeded()
        let profileID = notificationQueueProfileID
        localNotificationGeneration &+= 1
        notifiedItemLedger[Self.reviewedItemKey(itemID)] = nowProvider()
        var affectedSummaryIDs = Set<String>()
        for (identifier, summary) in rollingSummaries where summary.items.contains(where: { $0.id == itemID }) {
            affectedSummaryIDs.insert(identifier)
            let remaining = summary.items.filter { $0.id != itemID }
            rollingSummaries[identifier] = remaining.isEmpty ? nil : summary.replacingItems(remaining).silenced()
        }
        queuedIndividualNotifications = queuedIndividualNotifications.compactMap { entry in
            guard entry.items.contains(where: { $0.id == itemID }) else { return entry }
            let remaining = entry.items.filter { $0.id != itemID }
            return remaining.isEmpty ? nil : entry.replacingItems(remaining).silenced()
        }
        persistQueuedIndividualNotifications()
        persistRollingSummaries()
        persistNotifiedItemLedger()

        // An add already in flight must finish its generation-cancellation
        // cleanup before a reviewed summary is rewritten under that same ID.
        if isDrainingIndividualNotifications {
            await withCheckedContinuation { individualNotificationDrainWaiters.append($0) }
        }
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotificationRequests()
        guard notificationQueueProfileIDProvider() == profileID else { return }
        func owns(_ request: UNNotificationRequest) -> Bool {
            Self.isLocalRequest(request, profileID: profileID)
        }
        func matchesReviewedPost(_ request: UNNotificationRequest) -> Bool {
            guard owns(request) else { return false }
            return request.content.userInfo["feed_item_id"] as? String == itemID
                || request.identifier.hasSuffix("-\(itemID)")
        }
        let pendingToRemove = pending.filter { matchesReviewedPost($0) && !affectedSummaryIDs.contains($0.identifier) }.map(\.identifier)
        let deliveredToRemove = delivered.filter { matchesReviewedPost($0) && !affectedSummaryIDs.contains($0.identifier) }.map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: pendingToRemove)
        center.removeDeliveredNotifications(withIdentifiers: deliveredToRemove)

        for identifier in affectedSummaryIDs {
            guard notificationQueueProfileIDProvider() == profileID else { return }
            guard let summary = rollingSummaries[identifier] else {
                center.removePendingNotificationRequests(withIdentifiers: [identifier])
                center.removeDeliveredNotifications(withIdentifiers: [identifier])
                continue
            }
            let pendingRequest = pending.first { $0.identifier == identifier }
            guard pendingRequest != nil || delivered.contains(where: { $0.identifier == identifier }) else { continue }
            let revision = localNotificationGeneration
            let content = await notificationContent(for: summary.withoutAttachments())
            guard notificationQueueProfileIDProvider() == profileID,
                  revision == localNotificationGeneration else { continue }
            // A review refreshes the visible count without a new interruption.
            content.sound = nil
            content.interruptionLevel = .passive
            content.userInfo[Self.reviewUpdateUserInfoKey] = true
            let scheduledAt = pendingRequest?.content.userInfo[Self.scheduledDeliveryAtUserInfoKey] as? TimeInterval
            let delay = scheduledAt.map { $0 - nowProvider().timeIntervalSince1970 } ?? 0
            let trigger = delay > 0 ? UNTimeIntervalNotificationTrigger(timeInterval: max(1, delay), repeats: false) : nil
            content.userInfo[Self.scheduledDeliveryAtUserInfoKey] = scheduledAt
            do {
                try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
                guard notificationQueueProfileIDProvider() == profileID,
                      revision == localNotificationGeneration else {
                    center.removePendingNotificationRequests(withIdentifiers: [identifier])
                    center.removeDeliveredNotifications(withIdentifiers: [identifier])
                    if notificationQueueProfileIDProvider() == profileID,
                       let current = rollingSummaries[identifier] {
                        queuedIndividualNotifications.removeAll { $0.identifier == identifier }
                        queuedIndividualNotifications.append(current.silenced())
                        persistQueuedIndividualNotifications()
                    }
                    continue
                }
            } catch {
                AppLogger.notifications.error("Reviewed summary update failed: \(error.localizedDescription)")
            }
        }
        ownsReviewLock = false
        finishReviewingNotifications()
        if !isAppForeground { await drainQueuedIndividualNotifications() }
    }

    private func finishReviewingNotifications() {
        isReviewingNotifications = false
        let waiters = notificationReviewWaiters
        notificationReviewWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
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
        loadNotificationQueueForCurrentProfileIfNeeded()
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
        let quietHours = QuietHoursSettings.current()
        let now = nowProvider()
        let notBefore = quietHours.contains(now) ? quietHours.nextEndDate(after: now) : now

        // Migrate away from the former single Quiet Hours/overflow digest.
        center.removePendingNotificationRequests(withIdentifiers: [Self.quietHoursDigestIdentifier])
        QuietHoursDigestState.clear(defaults: notificationQueueDefaults)

        loadNotificationQueueForCurrentProfileIfNeeded()
        pruneStaleQueuedNotifications(at: now)
        let pendingIDs = Set(await center.pendingNotificationRequests().map(\.identifier))
        // An item that fell out of the feed cap (or reappears after a watch
        // term/platform is re-added) looks brand new to the merge even though
        // its deterministic term+item identifier already fired once. Pending
        // requests alone don't catch that — once delivered, a request leaves
        // `pendingNotificationRequests()` — so also skip anything still sitting
        // in Notification Center as delivered. 5ch activity updates are the one
        // case that legitimately reuses an already-delivered identifier (a
        // fresh reply bump on the same thread), so they're exempt below.
        let deliveredIDs = Set(await center.deliveredNotificationIdentifiers())
        guard !Task.isCancelled, generation == localNotificationGeneration else { return }

        // A request already owned by Notification Center is left alone here:
        // removing and re-enqueuing it would move a duplicate behind genuinely
        // new items and could consume the only newly available pending-request
        // slot. 5ch activity updates are the one case that legitimately reuses
        // an already-fired identifier (a fresh reply bump on the same thread),
        // so they're exempt from every dedup check below.
        func alreadyNotified(_ item: FeedItem, identifier: String) -> Bool {
            if let reviewedAt = notifiedItemLedger[Self.reviewedItemKey(item.id)] {
                // A later verified reply is a new event on the same 5ch post.
                let hasNewActivity = item.source == IngestionService.fiveChVerifiedActivitySource
                    && (parseISO8601Date(item.published_at) ?? .distantPast) > reviewedAt
                if !hasNewActivity { return true }
            }
            guard item.source != IngestionService.fiveChVerifiedActivitySource else { return false }
            return pendingIDs.contains(identifier)
                || deliveredIDs.contains(identifier)
                || notifiedItemLedger[identifier] != nil
        }

        let deliveryItems = matchingItems.sorted(by: feedItemSortPrecedes).reversed()
        let groupingEnabled = NotificationDeliverySettings.current(defaults: notificationQueueDefaults).groupedByKeyword
        // Foreground matches are already visible in the feed, in either
        // delivery mode. Count them for the in-app notice only; folding them
        // into a rolling summary would post a banner as soon as the app leaves.
        if isAppForeground {
            var newCount = 0
            for item in deliveryItems {
                guard let term = notifiedTermsByKeyword[item.watch_term_keyword] else { continue }
                let identifier = Self.notificationIdentifier(forTermID: term.id, itemID: item.id)
                guard !alreadyNotified(item, identifier: identifier),
                      foregroundCountedIdentifiers.insert(identifier).inserted else { continue }
                notifiedItemLedger[identifier] = now
                newCount += 1
            }
            if newCount > 0 {
                persistNotifiedItemLedger()
                catchUpItemCount += newCount
            }
            return
        }

        func enqueue(_ queued: QueuedIndividualNotification) {
            if let existingIndex = queuedIndividualNotifications.firstIndex(where: { $0.identifier == queued.identifier }) {
                queuedIndividualNotifications[existingIndex] = queued
            } else {
                queuedIndividualNotifications.append(queued)
            }
        }

        if groupingEnabled {
            // Stable profile/term identity keeps one summary across refreshes,
            // including batches that have already reached Notification Centre.
            var itemsByKeyword: [String: [FeedItem]] = [:]
            var keywordOrder: [String] = []
            for item in deliveryItems {
                guard notifiedTermsByKeyword[item.watch_term_keyword] != nil else { continue }
                let term = notifiedTermsByKeyword[item.watch_term_keyword]!
                let notificationIdentifier = Self.notificationIdentifier(forTermID: term.id, itemID: item.id)
                guard !alreadyNotified(item, identifier: notificationIdentifier) else { continue }
                if itemsByKeyword[item.watch_term_keyword] == nil {
                    keywordOrder.append(item.watch_term_keyword)
                }
                itemsByKeyword[item.watch_term_keyword, default: []].append(item)
            }
            for keyword in keywordOrder {
                guard let term = notifiedTermsByKeyword[keyword],
                      let newItems = itemsByKeyword[keyword], !newItems.isEmpty else { continue }
                let notificationIdentifier = rollingSummaryIdentifier(forTermID: term.id)
                let queuedItems = queuedIndividualNotifications.filter { $0.termID == term.id }.flatMap(\.items)
                let existingItems = (rollingSummaries[notificationIdentifier]?.items ?? []) + queuedItems
                var combinedByID: [String: FeedItem] = [:]
                for item in existingItems + newItems { combinedByID[item.id] = item }
                let combined = Self.boundedSummaryItems(combinedByID.values.filter {
                    guard let reviewedAt = notifiedItemLedger[Self.reviewedItemKey($0.id)] else { return true }
                    return $0.source == IngestionService.fiveChVerifiedActivitySource
                        && (parseISO8601Date($0.published_at) ?? .distantPast) > reviewedAt
                }, now: now)
                guard !combined.isEmpty else { continue }
                let summary = QueuedIndividualNotification(
                    identifier: notificationIdentifier,
                    termID: term.id,
                    items: combined,
                    includeAttachments: includeAttachments,
                    notBefore: notBefore,
                    enqueuedAt: now
                )
                rollingSummaries[notificationIdentifier] = summary
                queuedIndividualNotifications.removeAll { $0.termID == term.id }
                enqueue(summary)
            }
            persistRollingSummaries()
            persistNotifiedItemLedger()
        } else {
            for item in deliveryItems {
                guard let term = notifiedTermsByKeyword[item.watch_term_keyword] else { continue }
                let notificationIdentifier = Self.notificationIdentifier(forTermID: term.id, itemID: item.id)
                guard !alreadyNotified(item, identifier: notificationIdentifier) else { continue }
                enqueue(QueuedIndividualNotification(
                    identifier: notificationIdentifier,
                    termID: term.id,
                    items: [item],
                    includeAttachments: includeAttachments,
                    notBefore: notBefore,
                    enqueuedAt: now
                ))
            }
        }
        persistQueuedIndividualNotifications()
        await drainQueuedIndividualNotifications(generation: generation)
    }

    private static let quietHoursDigestIdentifier = "oshireader-quiet-hours-digest"

    private static let alertSubtitleLimit = 50
    private static let alertBodyLimit = 100
    /// The very first ready item in a drain fires with no artificial delay so
    /// an alert tracks real time; every item after that is spaced this far
    /// apart so a pile of new items visibly trickles in instead of landing as
    /// one clump. A single instant item plus a wide gap reads as staggered;
    /// three quick ones 4s apart did not.
    private static let individualDeliverySpacing: TimeInterval = 15
    private static let maximumQueuedAlertAge: TimeInterval = 24 * 60 * 60
    private static let immediateDeliveryBurst = 1
    private static let individualNotificationQueueKey = "individual_notification_queue"
    private static let individualNotificationIdentifierPrefix = "oshireader-new-term-"
    private static let scheduledDeliveryAtUserInfoKey = "oshireader_local_scheduled_delivery_at"
    private static let profileIDUserInfoKey = "oshireader_local_profile_id"

    private static func reviewedItemKey(_ itemID: String) -> String { "reviewed:\(itemID)" }

    private nonisolated static let reviewUpdateUserInfoKey = "oshireader_local_review_update"

    /// A summary re-posted by `markReviewed` only lowers an existing count. It
    /// is not a new arrival, so it must not raise the catch-up notice, and it
    /// stays in Notification Centre rather than vanishing in the foreground.
    nonisolated static func isReviewUpdate(_ request: UNNotificationRequest) -> Bool {
        request.content.userInfo[reviewUpdateUserInfoKey] as? Bool == true
    }

    private func rollingSummaryIdentifier(forTermID termID: String) -> String {
        Self.notificationIdentifierPrefix(forTermID: termID) + "summary-\(notificationQueueProfileID.uuidString)"
    }

    private func isRollingSummary(_ identifier: String) -> Bool {
        identifier.hasSuffix("-summary-\(notificationQueueProfileID.uuidString)")
    }

    private static func isLocalRequest(_ request: UNNotificationRequest, profileID: UUID) -> Bool {
        guard request.identifier.hasPrefix(individualNotificationIdentifierPrefix) else { return false }
        if let tagged = request.content.userInfo[profileIDUserInfoKey] as? String {
            return tagged == profileID.uuidString
        }
        // Untagged individual alerts predate profile tags. New summaries also
        // encode ownership in the ID, including when only that ID is available.
        return !request.identifier.contains("-summary-") || request.identifier.hasSuffix("-summary-\(profileID.uuidString)")
    }

    var queuedIndividualNotificationCount: Int {
        loadNotificationQueueForCurrentProfileIfNeeded()
        return queuedIndividualNotifications.count
    }

    /// Show a catch-up count on return. Rolling summaries remain unread until
    /// their posts are reviewed; merely opening the feed cannot dismiss them.
    func handleAppBecameActive() async {
        loadNotificationQueueForCurrentProfileIfNeeded()
        isAppForeground = true
        localNotificationGeneration &+= 1
        let generation = localNotificationGeneration
        let now = nowProvider()
        let pending = await center.pendingNotificationRequests()
        guard isAppForeground, generation == localNotificationGeneration else { return }
        let localPending = pending.filter { Self.isLocalRequest($0, profileID: notificationQueueProfileID) }
        let queued = queuedIndividualNotifications
        // The catch-up notice below covers a queued summary, so its later
        // post (once the app leaves) refreshes the count without interrupting.
        queuedIndividualNotifications = queued.compactMap { isRollingSummary($0.identifier) ? $0.silenced() : nil }
        persistQueuedIndividualNotifications()
        lastIndividualDeliveryDate = nil
        persistLastIndividualDeliveryDate()

        var countsByIdentifier: [String: Int] = [:]
        for request in localPending where !Self.isStaleNotification(userInfo: request.content.userInfo, now: now) {
            countsByIdentifier[request.identifier] = max(1, request.content.userInfo["new_count"] as? Int ?? 1)
        }
        for entry in queued {
            for item in entry.items {
                notifiedItemLedger[Self.notificationIdentifier(forTermID: entry.termID, itemID: item.id)] = now
            }
            guard !isStale(entry, at: now) else { continue }
            countsByIdentifier[entry.identifier] = max(countsByIdentifier[entry.identifier] ?? 0, entry.items.count)
        }
        persistNotifiedItemLedger()
        center.removePendingNotificationRequests(withIdentifiers: localPending.filter { !isRollingSummary($0.identifier) }.map(\.identifier))
        let count = countsByIdentifier.reduce(into: 0) { total, entry in
            if foregroundCountedIdentifiers.insert(entry.key).inserted { total += entry.value }
        }
        if count > 0 { catchUpItemCount += count }
    }

    func handleAppEnteredBackground() {
        isAppForeground = false
        localNotificationGeneration &+= 1
        foregroundCountedIdentifiers.removeAll()
        catchUpItemCount = 0
        Task { await drainQueuedIndividualNotifications() }
    }

    func dismissCatchUp() {
        catchUpItemCount = 0
    }


    func handleForegroundLocalDelivery(_ request: UNNotificationRequest) {
        guard request.identifier.hasPrefix(Self.individualNotificationIdentifierPrefix),
              !Self.isReviewUpdate(request),
              foregroundCountedIdentifiers.insert(request.identifier).inserted,
              !Self.isStaleNotification(userInfo: request.content.userInfo, now: nowProvider()) else { return }
        catchUpItemCount += max(1, request.content.userInfo["new_count"] as? Int ?? 1)
    }

    private func isStale(_ entry: QueuedIndividualNotification, at now: Date) -> Bool {
        let queuedAt = entry.enqueuedAt
            ?? entry.items.first.flatMap { parseISO8601Date($0.fetched_at) }
            ?? entry.notBefore
        return now.timeIntervalSince(queuedAt) > Self.maximumQueuedAlertAge
    }

    private static func isStaleNotification(userInfo: [AnyHashable: Any], now: Date) -> Bool {
        let queuedAt = (userInfo["oshireader_local_enqueued_at"] as? TimeInterval)
            .map { Date(timeIntervalSince1970: $0) }
            ?? (userInfo["fetched_at"] as? String).flatMap(parseISO8601Date)
        return queuedAt.map { now.timeIntervalSince($0) > maximumQueuedAlertAge } ?? false
    }

    private static let maximumRollingSummaryItems = 100

    /// Newest-first summary members the merge could still notify. Posts that
    /// are never opened (or fall out of the feed cap) would otherwise stay in
    /// a summary forever, inflating its count and its persisted size.
    private static func boundedSummaryItems(_ items: [FeedItem], now: Date) -> [FeedItem] {
        let recent = items.filter { item in
            guard let published = parseISO8601Date(item.published_at) ?? parseISO8601Date(item.fetched_at) else {
                return true
            }
            return now.timeIntervalSince(published) <= notifiedItemLedgerRetention
        }
        return Array(recent.sorted(by: feedItemSortPrecedes).prefix(maximumRollingSummaryItems))
    }

    private func pruneRollingSummaries(at now: Date) {
        var emptiedIDs: [String] = []
        var changed = false
        for (identifier, summary) in rollingSummaries {
            let bounded = Self.boundedSummaryItems(summary.items, now: now)
            guard bounded.count != summary.items.count else { continue }
            changed = true
            if bounded.isEmpty {
                rollingSummaries[identifier] = nil
                queuedIndividualNotifications.removeAll { $0.identifier == identifier }
                emptiedIDs.append(identifier)
            } else {
                rollingSummaries[identifier] = summary.replacingItems(bounded)
                if let index = queuedIndividualNotifications.firstIndex(where: { $0.identifier == identifier }) {
                    queuedIndividualNotifications[index] = queuedIndividualNotifications[index].replacingItems(bounded)
                }
            }
        }
        guard changed else { return }
        if !emptiedIDs.isEmpty {
            // Every member has aged out, so the visible summary is stale too.
            center.removePendingNotificationRequests(withIdentifiers: emptiedIDs)
            center.removeDeliveredNotifications(withIdentifiers: emptiedIDs)
        }
        persistRollingSummaries()
        persistQueuedIndividualNotifications()
    }

    private func pruneStaleQueuedNotifications(at now: Date) {
        pruneRollingSummaries(at: now)
        let stale = queuedIndividualNotifications.filter { isStale($0, at: now) }
        guard !stale.isEmpty else { return }
        for entry in stale {
            for item in entry.items {
                notifiedItemLedger[Self.notificationIdentifier(forTermID: entry.termID, itemID: item.id)] = now
            }
        }
        let staleIDs = Set(stale.map(\.identifier))
        queuedIndividualNotifications.removeAll { staleIDs.contains($0.identifier) }
        persistQueuedIndividualNotifications()
        persistNotifiedItemLedger()
    }

    func drainQueuedIndividualNotifications(generation requestedGeneration: Int? = nil) async {
        loadNotificationQueueForCurrentProfileIfNeeded()
        let now = nowProvider()
        pruneStaleQueuedNotifications(at: now)
        guard !isAppForeground, !isReviewingNotifications else { return }
        if isDrainingIndividualNotifications {
            await withCheckedContinuation { continuation in
                individualNotificationDrainWaiters.append(continuation)
            }
            if !queuedIndividualNotifications.isEmpty {
                await drainQueuedIndividualNotifications(generation: requestedGeneration)
            }
            return
        }
        guard canScheduleNotifications else { return }
        isDrainingIndividualNotifications = true
        defer {
            isDrainingIndividualNotifications = false
            let waiters = individualNotificationDrainWaiters
            individualNotificationDrainWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }

        let generation = requestedGeneration ?? localNotificationGeneration
        var pending = await center.pendingNotificationRequests()
        guard !Task.isCancelled, generation == localNotificationGeneration else { return }

        let pendingIDs = Set(pending.map(\.identifier))
        queuedIndividualNotifications.removeAll { pendingIDs.contains($0.identifier) && !isRollingSummary($0.identifier) }
        persistQueuedIndividualNotifications()

        var availableSlots = max(0, maximumPendingNotificationRequests - pending.count)

        let managedPending = pending.filter { request in
            guard request.identifier.hasPrefix(Self.individualNotificationIdentifierPrefix) else { return false }
            // A request tagged for another profile — possible after deleting the
            // active profile, which swaps the active id without a full switch —
            // must not seed this profile's spacing cursor or draw down its burst
            // budget. Untagged requests predate the tag and belong to whatever
            // profile was active when they were scheduled, i.e. this one.
            if let taggedProfile = request.content.userInfo[Self.profileIDUserInfoKey] as? String {
                return taggedProfile == notificationQueueProfileID.uuidString
            }
            return true
        }
        // `UNTimeIntervalNotificationTrigger.nextTriggerDate()` is relative to
        // the time it is queried, not the time the request was originally
        // submitted. Persist the absolute scheduled date in the request instead
        // so every later drain continues from the real end of the pending batch.
        let latestRecordedDelivery = managedPending.compactMap { request -> Date? in
            if let timestamp = request.content.userInfo[Self.scheduledDeliveryAtUserInfoKey] as? TimeInterval {
                return Date(timeIntervalSince1970: timestamp)
            }
            // A legacy immediate request has already reached its delivery point.
            // Legacy interval requests have no trustworthy absolute anchor, so
            // ignore their moving `nextTriggerDate()` during the one-time migration.
            return request.trigger == nil ? now : nil
        }.max()
        // A delivered request disappears from `pending`. Keep its scheduled
        // time across drains so a second refresh cannot immediately alert again.
        // Future requests may have been cancelled (for example, unfollowing
        // a term). Only the current pending queue can reserve future slots.
        let recentDelivery = lastIndividualDeliveryDate.map { min($0, now) }
        var deliveryCursor = [latestRecordedDelivery, recentDelivery]
            .compactMap { $0 }.max() ?? now.addingTimeInterval(-Self.individualDeliverySpacing)

        // How many of this drain's alerts may skip the inter-item spacing and
        // fire right away.
        var immediateBudget: Int
        let staggeredTailPending = managedPending.contains { request in
            guard let timestamp = request.content.userInfo[Self.scheduledDeliveryAtUserInfoKey] as? TimeInterval
            else { return false }
            return Date(timeIntervalSince1970: timestamp) > now
        }
        if staggeredTailPending {
            // A staggered batch is still being delivered — new items join its
            // tail instead of jumping the line with an instant banner.
            immediateBudget = 0
        } else if let lastIndividualDeliveryDate, lastIndividualDeliveryDate <= now,
                  now.timeIntervalSince(lastIndividualDeliveryDate)
                    < Double(Self.immediateDeliveryBurst) * Self.individualDeliverySpacing {
            // The previous instant delivery has fully landed, but only just.
            // Taper the allowance back in per `individualDeliverySpacing`, so
            // two refreshes moments apart can't each fire a fresh instant
            // item while one well afterwards still gets it.
            immediateBudget = Int(
                now.timeIntervalSince(lastIndividualDeliveryDate) / Self.individualDeliverySpacing
            )
        } else {
            immediateBudget = Self.immediateDeliveryBurst
        }

        while !queuedIndividualNotifications.isEmpty {
            let candidate = availableSlots > 0 ? queuedIndividualNotifications.first : queuedIndividualNotifications.first { entry in
                pending.contains { $0.identifier == entry.identifier }
            }
            guard let queued = candidate else { return }
            let replacesPending = pending.contains { $0.identifier == queued.identifier }
            guard availableSlots > 0 || replacesPending else { return }
            guard !Task.isCancelled, generation == localNotificationGeneration else { return }
            let content = await notificationContent(for: queued)
            guard !Task.isCancelled, generation == localNotificationGeneration else { return }

            // Attachment preparation can suspend for several seconds. Base the
            // trigger on the actual submission time so a slow first attachment
            // cannot turn the rest of the batch into immediate notifications.
            let schedulingNow = nowProvider()
            // The burst shortcut only applies to items ready to fire now.
            // Anything held for a future `notBefore` (quiet hours) still
            // staggers off `deliveryCursor` so a held-back batch is released
            // gradually, not as one clump when the window opens.
            let usesImmediateBurst = immediateBudget > 0 && queued.notBefore <= schedulingNow
            let spacingFloor = usesImmediateBurst
                ? schedulingNow
                : deliveryCursor.addingTimeInterval(Self.individualDeliverySpacing)
            let existingDelivery = isRollingSummary(queued.identifier)
                ? pending.first(where: { $0.identifier == queued.identifier })?.content.userInfo[Self.scheduledDeliveryAtUserInfoKey] as? TimeInterval
                : nil
            // Extending a pending summary must not push its existing delivery
            // opportunity later on every refresh, especially at Quiet Hours end.
            let earliestDelivery: Date
            if let existingDelivery, existingDelivery > schedulingNow.timeIntervalSince1970 {
                earliestDelivery = max(queued.notBefore, Date(timeIntervalSince1970: existingDelivery))
            } else {
                earliestDelivery = max(queued.notBefore, max(spacingFloor, schedulingNow))
            }
            let requestedDelay = earliestDelivery.timeIntervalSince(schedulingNow)
            let deliveryDate: Date
            let trigger: UNNotificationTrigger?
            if requestedDelay <= 0 {
                deliveryDate = schedulingNow
                trigger = nil
            } else {
                let delay = max(1, requestedDelay)
                deliveryDate = schedulingNow.addingTimeInterval(delay)
                trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
            }
            content.userInfo[Self.scheduledDeliveryAtUserInfoKey] = deliveryDate.timeIntervalSince1970
            let request = UNNotificationRequest(
                identifier: queued.identifier,
                content: content,
                trigger: trigger
            )
            do {
                try await center.add(request)
                guard !Task.isCancelled, generation == localNotificationGeneration else {
                    center.removePendingNotificationRequests(withIdentifiers: [queued.identifier])
                    center.removeDeliveredNotifications(withIdentifiers: [queued.identifier])
                    return
                }
                // A newer batch may extend this stable summary while add is
                // suspended. Keep that revision queued so its count is posted
                // next, rather than ledgering items absent from this request.
                if let dequeuedIndex = queuedIndividualNotifications.firstIndex(of: queued) {
                    queuedIndividualNotifications.remove(at: dequeuedIndex)
                    persistQueuedIndividualNotifications()
                }
                pending.removeAll { $0.identifier == request.identifier }
                pending.append(request)
                if !replacesPending { availableSlots -= 1 }
                deliveryCursor = max(deliveryCursor, deliveryDate)
                lastIndividualDeliveryDate = deliveryCursor
                persistLastIndividualDeliveryDate()
                if usesImmediateBurst { immediateBudget -= 1 }
                for item in queued.items {
                    notifiedItemLedger[Self.notificationIdentifier(forTermID: queued.termID, itemID: item.id)] = schedulingNow
                }
                persistNotifiedItemLedger()
            } catch {
                let keyword = queued.items.first?.watch_term_keyword ?? queued.termID
                AppLogger.notifications.error("Notification scheduling failed for \(keyword): \(error.localizedDescription)")
                return
            }
        }
    }

    private func notificationContent(for queued: QueuedIndividualNotification) async -> UNMutableNotificationContent {
        // The anchor — always the newest item (`queued.items` is newest-first,
        // enforced where each `QueuedIndividualNotification` is built). A
        // grouped entry (`items.count > 1`) still names and links through this
        // one item; the body just adds the count instead of repeating its text.
        let item = queued.items[0]
        let content = UNMutableNotificationContent()
        content.title = item.watch_term_keyword
        let itemTitle = cleanDisplayText(item.title)
        let itemBody = cleanDisplayText(item.content_text)
        if let itemTitle, !itemTitle.isEmpty {
            content.subtitle = Self.limitedAlertText(itemTitle, limit: Self.alertSubtitleLimit)
        }
        if queued.items.count > 1 {
            content.body = I18nManager.shared.tFormat("notificationGroupedCountFmt", queued.items.count)
        } else if let itemBody, !itemBody.isEmpty, itemBody != itemTitle {
            content.body = Self.limitedAlertText(itemBody, limit: Self.alertBodyLimit)
        } else if content.subtitle.isEmpty {
            let fallback = item.url.isEmpty ? "1 new item found." : item.url
            content.body = Self.limitedAlertText(fallback, limit: Self.alertBodyLimit)
        }
        content.sound = .default
        if queued.silent == true {
            content.sound = nil
            content.interruptionLevel = .passive
        }
        content.categoryIdentifier = Self.categoryIdentifier
        if queued.items.count == 1, queued.includeAttachments,
           let attachment = await notificationAttachment(for: item) {
            content.attachments = [attachment]
        }
        content.userInfo = notificationUserInfo(for: item)
        content.userInfo["new_count"] = queued.items.count
        content.userInfo["oshireader_local_item_ids"] = queued.items.map(\.id)
        // Tag the owning profile so a later drain on a different profile (after
        // deleting the active one) doesn't count this request as its own.
        content.userInfo[Self.profileIDUserInfoKey] = notificationQueueProfileID.uuidString
        content.userInfo["oshireader_local_enqueued_at"] = queued.enqueuedAt?.timeIntervalSince1970
        content.threadIdentifier = queued.identifier
        content.targetContentIdentifier = item.id
        return content
    }

    private func loadNotificationQueueForCurrentProfileIfNeeded() {
        let currentProfileID = notificationQueueProfileIDProvider()
        guard currentProfileID != notificationQueueProfileID else { return }
        localNotificationGeneration &+= 1
        notificationQueueProfileID = currentProfileID
        catchUpItemCount = 0
        foregroundCountedIdentifiers.removeAll()
        queuedIndividualNotifications = Self.loadQueuedIndividualNotifications(
            defaults: notificationQueueDefaults,
            profileID: currentProfileID
        )
        rollingSummaries = Self.loadRollingSummaries(defaults: notificationQueueDefaults, profileID: currentProfileID)
        lastIndividualDeliveryDate = Self.loadLastIndividualDeliveryDate(
            defaults: notificationQueueDefaults,
            profileID: currentProfileID
        )
        notifiedItemLedger = Self.loadNotifiedItemLedger(
            defaults: notificationQueueDefaults,
            profileID: currentProfileID,
            now: nowProvider()
        )
    }

    private func persistQueuedIndividualNotifications() {
        let key = Self.notificationQueueStorageKey(profileID: notificationQueueProfileID)
        guard !queuedIndividualNotifications.isEmpty else {
            notificationQueueDefaults.removeObject(forKey: key)
            return
        }
        do {
            notificationQueueDefaults.set(try JSONEncoder().encode(queuedIndividualNotifications), forKey: key)
        } catch {
            AppLogger.notifications.error("Notification queue persistence failed: \(error.localizedDescription)")
        }
    }

    private func persistRollingSummaries() {
        let key = LocalProfileStore.defaultsKey("rolling_notification_summaries", profileID: notificationQueueProfileID)
        if rollingSummaries.isEmpty {
            notificationQueueDefaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(rollingSummaries) {
            notificationQueueDefaults.set(data, forKey: key)
        }
    }

    private static func loadRollingSummaries(defaults: UserDefaults, profileID: UUID) -> [String: QueuedIndividualNotification] {
        let key = LocalProfileStore.defaultsKey("rolling_notification_summaries", profileID: profileID)
        guard let data = defaults.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: QueuedIndividualNotification].self, from: data)) ?? [:]
    }

    private static func loadQueuedIndividualNotifications(
        defaults: UserDefaults,
        profileID: UUID
    ) -> [QueuedIndividualNotification] {
        let key = notificationQueueStorageKey(profileID: profileID)
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([QueuedIndividualNotification].self, from: data)) ?? []
    }

    /// The spacing anchor is kept next to the queue so an app relaunch (or a
    /// background wake) inside the cooldown window can't hand out a second
    /// fresh immediate burst on top of one it already delivered.
    private func persistLastIndividualDeliveryDate() {
        let key = Self.lastIndividualDeliveryStorageKey(profileID: notificationQueueProfileID)
        if let lastIndividualDeliveryDate {
            notificationQueueDefaults.set(lastIndividualDeliveryDate.timeIntervalSince1970, forKey: key)
        } else {
            notificationQueueDefaults.removeObject(forKey: key)
        }
    }

    private static func loadLastIndividualDeliveryDate(
        defaults: UserDefaults,
        profileID: UUID
    ) -> Date? {
        let key = lastIndividualDeliveryStorageKey(profileID: profileID)
        guard defaults.object(forKey: key) != nil else { return nil }
        return Date(timeIntervalSince1970: defaults.double(forKey: key))
    }

    private static func notificationQueueStorageKey(profileID: UUID) -> String {
        LocalProfileStore.defaultsKey(individualNotificationQueueKey, profileID: profileID)
    }

    private static func lastIndividualDeliveryStorageKey(profileID: UUID) -> String {
        LocalProfileStore.defaultsKey("individual_notification_last_delivery", profileID: profileID)
    }

    // Mirrors `LocalDB.maxNotifiableItemAge`: past this age a resurfaced item
    // is never notifiable again anyway (the merge's own age guard drops it),
    // so the ledger doesn't need to remember it for longer than that.
    private static let notifiedItemLedgerRetention: TimeInterval = 3 * 24 * 60 * 60

    private func persistNotifiedItemLedger() {
        let key = Self.notifiedItemLedgerStorageKey(profileID: notificationQueueProfileID)
        guard !notifiedItemLedger.isEmpty else {
            notificationQueueDefaults.removeObject(forKey: key)
            return
        }
        let raw = notifiedItemLedger.mapValues { $0.timeIntervalSince1970 }
        notificationQueueDefaults.set(raw, forKey: key)
    }

    private static func loadNotifiedItemLedger(
        defaults: UserDefaults,
        profileID: UUID,
        now: Date
    ) -> [String: Date] {
        let key = notifiedItemLedgerStorageKey(profileID: profileID)
        guard let raw = defaults.dictionary(forKey: key) as? [String: TimeInterval] else { return [:] }
        return raw.compactMapValues { timestamp -> Date? in
            let notifiedAt = Date(timeIntervalSince1970: timestamp)
            return now.timeIntervalSince(notifiedAt) <= notifiedItemLedgerRetention ? notifiedAt : nil
        }
    }

    private static func notifiedItemLedgerStorageKey(profileID: UUID) -> String {
        LocalProfileStore.defaultsKey("notified_item_ledger", profileID: profileID)
    }

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
