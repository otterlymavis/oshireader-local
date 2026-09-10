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

private struct QueuedIndividualNotification: Codable, Equatable {
    let identifier: String
    let termID: String
    let item: FeedItem
    let includeAttachments: Bool
    let notBefore: Date
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
    private var isDrainingIndividualNotifications = false
    private var lastIndividualDeliveryDate: Date?
    private var individualNotificationDrainWaiters: [CheckedContinuation<Void, Never>] = []

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
        self.lastIndividualDeliveryDate = Self.loadLastIndividualDeliveryDate(
            defaults: notificationQueueDefaults,
            profileID: initialQueueProfileID
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
        lastIndividualDeliveryDate = nil
        persistQueuedIndividualNotifications()
        persistLastIndividualDeliveryDate()
        QuietHoursDigestState.clear(defaults: notificationQueueDefaults)
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    func clearNotification(forTermID termID: String) async {
        localNotificationGeneration &+= 1
        loadNotificationQueueForCurrentProfileIfNeeded()
        queuedIndividualNotifications.removeAll { $0.termID == termID }
        persistQueuedIndividualNotifications()
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
        let quietHours = QuietHoursSettings.current()
        let now = nowProvider()
        let notBefore = quietHours.contains(now) ? quietHours.nextEndDate(after: now) : now

        // Migrate away from the former single Quiet Hours/overflow digest.
        center.removePendingNotificationRequests(withIdentifiers: [Self.quietHoursDigestIdentifier])
        QuietHoursDigestState.clear(defaults: notificationQueueDefaults)

        loadNotificationQueueForCurrentProfileIfNeeded()
        let pendingIDs = Set(await center.pendingNotificationRequests().map(\.identifier))
        guard !Task.isCancelled, generation == localNotificationGeneration else { return }

        // Keep every match as an individual queued alert. Existing queued entries
        // are replaced in place so a newer activity update keeps its position.
        // A request already owned by Notification Center is left alone: removing
        // and re-enqueuing it would move a duplicate behind genuinely new items
        // and could consume the only newly available pending-request slot.
        let deliveryItems = matchingItems.sorted(by: feedItemSortPrecedes).reversed()
        for item in deliveryItems {
            guard let term = notifiedTermsByKeyword[item.watch_term_keyword] else { continue }
            let notificationIdentifier = Self.notificationIdentifier(forTermID: term.id, itemID: item.id)
            guard !pendingIDs.contains(notificationIdentifier) else { continue }
            let queued = QueuedIndividualNotification(
                identifier: notificationIdentifier,
                termID: term.id,
                item: item,
                includeAttachments: includeAttachments,
                notBefore: notBefore
            )
            if let existingIndex = queuedIndividualNotifications.firstIndex(where: { $0.identifier == notificationIdentifier }) {
                queuedIndividualNotifications[existingIndex] = queued
            } else {
                queuedIndividualNotifications.append(queued)
            }
        }
        persistQueuedIndividualNotifications()
        await drainQueuedIndividualNotifications(generation: generation)
    }

    private static let quietHoursDigestIdentifier = "oshireader-quiet-hours-digest"

    private static let alertSubtitleLimit = 50
    private static let alertBodyLimit = 100
    /// The first few ready items in a drain fire with no artificial delay so
    /// alerts track real time; every item after that is spaced this far apart
    /// so a large burst still arrives gradually instead of all at once.
    private static let individualDeliverySpacing: TimeInterval = 4
    private static let immediateDeliveryBurst = 3
    private static let individualNotificationQueueKey = "individual_notification_queue"
    private static let individualNotificationIdentifierPrefix = "oshireader-new-term-"
    private static let scheduledDeliveryAtUserInfoKey = "oshireader_local_scheduled_delivery_at"
    private static let profileIDUserInfoKey = "oshireader_local_profile_id"

    var queuedIndividualNotificationCount: Int {
        loadNotificationQueueForCurrentProfileIfNeeded()
        return queuedIndividualNotifications.count
    }

    func drainQueuedIndividualNotifications(generation requestedGeneration: Int? = nil) async {
        loadNotificationQueueForCurrentProfileIfNeeded()
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
        queuedIndividualNotifications.removeAll { pendingIDs.contains($0.identifier) }
        persistQueuedIndividualNotifications()

        var availableSlots = max(0, maximumPendingNotificationRequests - pending.count)
        guard availableSlots > 0 else { return }

        let now = nowProvider()
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
            // The previous burst has fully landed, but only just. Taper the
            // allowance back one slot per `individualDeliverySpacing`, so two
            // refreshes moments apart can't each fire a fresh burst while one
            // well afterwards still gets all three.
            immediateBudget = Int(
                now.timeIntervalSince(lastIndividualDeliveryDate) / Self.individualDeliverySpacing
            )
        } else {
            immediateBudget = Self.immediateDeliveryBurst
        }

        while availableSlots > 0, let queued = queuedIndividualNotifications.first {
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
            let earliestDelivery = max(queued.notBefore, max(spacingFloor, schedulingNow))
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
                center.removePendingNotificationRequests(withIdentifiers: [queued.identifier])
                try await center.add(request)
                guard !Task.isCancelled, generation == localNotificationGeneration else {
                    center.removePendingNotificationRequests(withIdentifiers: [queued.identifier])
                    center.removeDeliveredNotifications(withIdentifiers: [queued.identifier])
                    return
                }
                if queuedIndividualNotifications.first == queued {
                    queuedIndividualNotifications.removeFirst()
                    persistQueuedIndividualNotifications()
                }
                pending.append(request)
                availableSlots -= 1
                deliveryCursor = deliveryDate
                lastIndividualDeliveryDate = deliveryDate
                persistLastIndividualDeliveryDate()
                if usesImmediateBurst { immediateBudget -= 1 }
            } catch {
                AppLogger.notifications.error("Notification scheduling failed for \(queued.item.watch_term_keyword): \(error.localizedDescription)")
                return
            }
        }
    }

    private func notificationContent(for queued: QueuedIndividualNotification) async -> UNMutableNotificationContent {
        let item = queued.item
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
        if queued.includeAttachments,
           let attachment = await notificationAttachment(for: item) {
            content.attachments = [attachment]
        }
        content.userInfo = notificationUserInfo(for: item)
        // Tag the owning profile so a later drain on a different profile (after
        // deleting the active one) doesn't count this request as its own.
        content.userInfo[Self.profileIDUserInfoKey] = notificationQueueProfileID.uuidString
        content.threadIdentifier = queued.identifier
        content.targetContentIdentifier = item.id
        return content
    }

    private func loadNotificationQueueForCurrentProfileIfNeeded() {
        let currentProfileID = notificationQueueProfileIDProvider()
        guard currentProfileID != notificationQueueProfileID else { return }
        notificationQueueProfileID = currentProfileID
        queuedIndividualNotifications = Self.loadQueuedIndividualNotifications(
            defaults: notificationQueueDefaults,
            profileID: currentProfileID
        )
        lastIndividualDeliveryDate = Self.loadLastIndividualDeliveryDate(
            defaults: notificationQueueDefaults,
            profileID: currentProfileID
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
