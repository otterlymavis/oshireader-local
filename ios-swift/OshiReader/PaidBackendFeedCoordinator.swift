import Foundation

enum PaidHostedDiagnosticOperation: String, Equatable {
    case feedRefresh = "hosted_feed_refresh"
    case termSynchronization = "hosted_term_sync"
}

@MainActor
final class PaidHostedDiagnosticReporter {
    static let shared = PaidHostedDiagnosticReporter()
    static let consentKey = "paid_backend.diagnostics_opt_in"
    static let throttleInterval: TimeInterval = 6 * 60 * 60

    private let defaults: UserDefaults
    private let now: () -> Date
    private let paidBackendConfigured: () -> Bool
    private let activeEntitlement: () -> Bool
    private let diagnosticsEnabled: () -> Bool
    private let activeProfileID: () -> UUID
    private let environment: () -> String
    private let appMetadata: () -> (version: String?, build: String?)
    private let snapshot: () -> (activeTermsCount: Int, subscribedPlatforms: [String], cachedFeedCount: Int)
    private let submit: (ClientDiagnosticReport, TimeInterval) async throws -> Void
    private var profilesInFlight = Set<UUID>()

    init(
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        paidBackendConfigured: (() -> Bool)? = nil,
        activeEntitlement: (() -> Bool)? = nil,
        diagnosticsEnabled: (() -> Bool)? = nil,
        activeProfileID: (() -> UUID)? = nil,
        environment: (() -> String)? = nil,
        appMetadata: (() -> (version: String?, build: String?))? = nil,
        snapshot: (() -> (activeTermsCount: Int, subscribedPlatforms: [String], cachedFeedCount: Int))? = nil,
        submit: ((ClientDiagnosticReport, TimeInterval) async throws -> Void)? = nil
    ) {
        self.defaults = defaults
        self.now = now
        self.paidBackendConfigured = paidBackendConfigured ?? { PlusStore.shouldSyncBackend }
        self.activeEntitlement = activeEntitlement ?? { PlusStore.shared.hasActiveEntitlement }
        self.diagnosticsEnabled = diagnosticsEnabled ?? {
            defaults.bool(forKey: Self.consentKey)
        }
        self.activeProfileID = activeProfileID ?? { LocalProfileStore.shared.activeProfileID }
        self.environment = environment ?? { BackendClient.shared.apnsEnvironment }
        self.appMetadata = appMetadata ?? {
            let info = Bundle.main.infoDictionary
            return (
                info?["CFBundleShortVersionString"] as? String,
                info?["CFBundleVersion"] as? String
            )
        }
        self.snapshot = snapshot ?? {
            let db = LocalDB.shared
            return (
                db.terms.lazy.filter(\.is_active).count,
                db.subscribedPlatforms,
                db.feedItems.count
            )
        }
        self.submit = submit ?? { report, timeout in
            try await BackendClient.shared.submitClientDiagnostic(report, timeout: timeout)
        }
    }

    func report(_ operation: PaidHostedDiagnosticOperation, error: Error) async {
        guard paidBackendConfigured(), activeEntitlement(), diagnosticsEnabled(),
              let category = Self.sanitizedErrorCategory(error) else { return }
        let profileID = activeProfileID()
        let timestamp = now()
        let checkpointKey = Self.checkpointKey(profileID: profileID)
        let lastSuccess = defaults.double(forKey: checkpointKey)
        guard lastSuccess <= 0 || timestamp.timeIntervalSince1970 - lastSuccess >= Self.throttleInterval,
              profilesInFlight.insert(profileID).inserted else { return }
        defer { profilesInFlight.remove(profileID) }

        let values = snapshot()
        let metadata = appMetadata()
        let allowedPlatformIDs = Set(PlatformRegistry.all.map(\.id))
        let report = ClientDiagnosticReport(
            reason: "paid_hosted_operation_failed",
            environment: String(environment().prefix(80)),
            api_base: "hosted",
            app_version: metadata.version.map { String($0.prefix(80)) },
            build: metadata.build.map { String($0.prefix(80)) },
            active_terms_count: min(max(0, values.activeTermsCount), 1_000),
            subscribed_platforms: Array(values.subscribedPlatforms
                .map(PlatformRegistry.normalizeID)
                .filter(allowedPlatformIDs.contains)
                .sorted()
                .prefix(80)),
            cached_feed_count: min(max(0, values.cachedFeedCount), 10_000),
            events: [ClientDiagnosticEvent(
                strategy: operation.rawValue,
                status: "failed",
                item_count: 0,
                added_count: 0,
                detail: category
            )]
        )
        do {
            try await submit(report, 12)
            defaults.set(now().timeIntervalSince1970, forKey: checkpointKey)
        } catch {
            AppLogger.network.warning("Optional paid diagnostic upload failed")
        }
    }

    static func sanitizedErrorCategory(_ error: Error) -> String? {
        if error is CancellationError { return nil }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled: return nil
            case .timedOut: return "timeout"
            case .notConnectedToInternet, .dataNotAllowed: return "offline"
            case .networkConnectionLost: return "connection_lost"
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed: return "unreachable"
            case .secureConnectionFailed, .serverCertificateHasBadDate,
                    .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
                    .serverCertificateNotYetValid, .clientCertificateRejected,
                    .clientCertificateRequired:
                return "tls"
            default: return "network"
            }
        }
        if case BackendClientError.httpStatus(let status, let code, _) = error {
            if code == "paid_backend_required" { return nil }
            return "http_\(min(max(status, 0), 999))"
        }
        if case BackendClientError.invalidResponse = error { return "invalid_response" }
        if error is DecodingError { return "decode" }
        return "other"
    }

    static func checkpointKey(profileID: UUID) -> String {
        LocalProfileStore.defaultsKey(
            "paid_backend.diagnostics_last_uploaded_at",
            profileID: profileID
        )
    }
}

struct PaidBackendRefreshResult: Equatable {
    let addedCount: Int
    let succeeded: Bool

    static let unavailable = PaidBackendRefreshResult(addedCount: 0, succeeded: false)
}

/// Synchronizes the active local profile to the hosted polling service without
/// making the backend authoritative for terms or feed storage. Free refreshes
/// continue to run through LocalRefreshCoordinator regardless of this result.
@MainActor
final class PaidBackendFeedCoordinator: ObservableObject {
    static let shared = PaidBackendFeedCoordinator()

    private struct HostedMuteKey: Hashable {
        let profileID: UUID
        let normalizedKeyword: String
        let sourceItemID: String
    }

    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshSucceeded: Bool?
    @Published private(set) var lastRefreshedAt: Date?
    @Published var errorMessage: String?

    private var scheduledSync: Task<Void, Never>?
    /// Single-flight guard for `synchronizeActiveProfileTerms()`. Without it,
    /// two overlapping runs (e.g. `refresh()` racing `scheduleSynchronization()`
    /// or `AppDelegate.applicationDidBecomeActive`) both see "no backend row
    /// for keyword X" and both call `createBackendTerm`, producing duplicate
    /// server rows. Keyed by profile so a run started before a profile switch
    /// is never reused for the new profile.
    private var activeTermSync: (profileID: UUID, task: Task<[Int], Error>)?
    private var backendTermIDsByProfile: [UUID: [String: Int]] = [:]
    private var hostedMutesInFlight = Set<HostedMuteKey>()
    private let incrementalOverlap: TimeInterval = 15 * 60
    private static let backgroundPollInterval: TimeInterval = 170 * 60
    private let paidBackendConfigured: () -> Bool
    private let activeEntitlement: () -> Bool
    private let activeProfileID: () -> UUID
    private let localTerm: (String) -> WatchTerm?
    private let fetchHostedTerms: () async throws -> [BackendWatchTerm]
    private let muteHostedItem: (String, Int, TimeInterval) async throws -> Void
    private let refreshEntitlement: () async -> Void
    private let reportHostedFailure: (PaidHostedDiagnosticOperation, Error) async -> Void
    private let synchronizeHostedTerms: (() async throws -> [Int])?
    private let fetchHostedFeed: (String?, [Int], Int, Int, String?, String) async throws -> [FeedItem]

    init(
        paidBackendConfigured: (() -> Bool)? = nil,
        activeEntitlement: (() -> Bool)? = nil,
        activeProfileID: (() -> UUID)? = nil,
        localTerm: ((String) -> WatchTerm?)? = nil,
        fetchHostedTerms: (() async throws -> [BackendWatchTerm])? = nil,
        muteHostedItem: ((String, Int, TimeInterval) async throws -> Void)? = nil,
        refreshEntitlement: (() async -> Void)? = nil,
        reportHostedFailure: ((PaidHostedDiagnosticOperation, Error) async -> Void)? = nil,
        synchronizeHostedTerms: (() async throws -> [Int])? = nil,
        fetchHostedFeed: ((String?, [Int], Int, Int, String?, String) async throws -> [FeedItem])? = nil
    ) {
        self.paidBackendConfigured = paidBackendConfigured ?? { PlusStore.shouldSyncBackend }
        self.activeEntitlement = activeEntitlement ?? { PlusStore.shared.hasActiveEntitlement }
        self.activeProfileID = activeProfileID ?? { LocalProfileStore.shared.activeProfileID }
        self.localTerm = localTerm ?? { LocalDB.shared.term(matchingKeyword: $0) }
        self.fetchHostedTerms = fetchHostedTerms ?? { try await BackendClient.shared.fetchPushTerms() }
        self.muteHostedItem = muteHostedItem ?? { sourceItemID, watchTermID, timeout in
            try await BackendClient.shared.muteHostedFeedItem(
                sourceItemID: sourceItemID,
                watchTermID: watchTermID,
                timeout: timeout
            )
        }
        self.refreshEntitlement = refreshEntitlement ?? { await PlusStore.shared.refreshStatus() }
        self.reportHostedFailure = reportHostedFailure ?? { operation, error in
            await PaidHostedDiagnosticReporter.shared.report(operation, error: error)
        }
        self.synchronizeHostedTerms = synchronizeHostedTerms
        self.fetchHostedFeed = fetchHostedFeed ?? { platform, termIDs, pageSize, days, since, until in
            try await BackendClient.shared.fetchAllBackendFeed(
                platform: platform, termIDs: termIDs, pageSize: pageSize, days: days, since: since, until: until
            )
        }
    }

    var isAvailable: Bool {
        PlusStore.isPaidPushConfigured && PlusStore.shared.hasActiveEntitlement
    }

    func scheduleSynchronization() {
        guard PlusStore.shouldSyncBackend else { return }
        scheduledSync?.cancel()
        scheduledSync = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await synchronizeTerms()
        }
    }

    func synchronizeTerms() async {
        guard paidBackendConfigured() else { return }
        if !activeEntitlement() {
            await refreshEntitlement()
        }
        guard activeEntitlement() else { return }
        do {
            _ = try await synchronizeActiveProfileTerms()
            errorMessage = nil
        } catch {
            await reportHostedFailure(.termSynchronization, error)
            await refreshEntitlementAfterAccessRejection(error)
            errorMessage = "Hosted refresh could not synchronize: \(error.localizedDescription)"
        }
    }

    /// Keeps Local hiding authoritative while best-effort removing the same
    /// term/item match from the paid hosted feed.
    func muteHiddenItem(_ item: FeedItem, timeout: TimeInterval = 30) async {
        guard paidBackendConfigured() else { return }
        if !activeEntitlement() {
            await refreshEntitlement()
        }
        guard activeEntitlement() else { return }

        let profileID = activeProfileID()
        guard let term = localTerm(item.watch_term_keyword) else { return }
        let muteKey = HostedMuteKey(
            profileID: profileID,
            normalizedKeyword: Self.normalizedKeyword(term.keyword),
            sourceItemID: item.id
        )
        guard hostedMutesInFlight.insert(muteKey).inserted else { return }
        defer { hostedMutesInFlight.remove(muteKey) }

        guard activeProfileID() == profileID,
              let backendTermID = await resolveBackendTermID(for: term, profileID: profileID),
              activeProfileID() == profileID else { return }
        do {
            try await muteHostedItem(item.id, backendTermID, timeout)
        } catch {
            await refreshEntitlementAfterAccessRejection(error)
            AppLogger.network.warning("Hosted feed mute failed; the item remains hidden locally")
        }
    }

    func refresh(
        _ request: LocalRefreshRequest,
        sourceRevision: Int,
        profileID: UUID
    ) async -> PaidBackendRefreshResult {
        guard paidBackendConfigured() else { return .unavailable }
        if !activeEntitlement() {
            await refreshEntitlement()
        }
        guard activeEntitlement() else { return .unavailable }

        isRefreshing = true
        defer { isRefreshing = false }
        do {
            if request == .background, shouldTriggerBackgroundPoll() {
                if (try? await BackendClient.shared.triggerBackgroundPoll(timeout: 8)) != nil {
                    UserDefaults.standard.set(
                        Date().timeIntervalSince1970,
                        forKey: LocalProfileStore.defaultsKey("paid_backend.last_poll_triggered_at", profileID: profileID)
                    )
                }
            }
            let backendTermIDs = try await synchronizeActiveProfileTerms()
            let platform: String?
            switch request {
            case .platform(let value):
                let normalized = PlatformRegistry.normalizeID(value)
                platform = normalized == "custom" ? nil : normalized
            case .foreground, .background:
                platform = nil
            }
            let cursorKey = Self.refreshCursorKey(profileID: profileID, platform: platform)
            let refreshCutoff = Date()
            let since = refreshCursor(forKey: cursorKey).map {
                iso8601String(from: $0.addingTimeInterval(-incrementalOverlap))
            }
            let fetched: [FeedItem]
            if backendTermIDs.isEmpty {
                fetched = []
            } else {
                fetched = try await fetchHostedFeed(
                    platform,
                    backendTermIDs,
                    request == .background ? 100 : 200,
                    FeedDatePolicy.maximumLookbackDays,
                    since,
                    iso8601String(from: refreshCutoff)
                )
            }
            guard LocalProfileStore.shared.activeProfileID == profileID,
                  LocalDB.shared.dataRevision == sourceRevision,
                  !Task.isCancelled else { return .unavailable }

            let activeKeywords = Dictionary(
                LocalDB.shared.terms.filter(\.is_active).map {
                    ($0.keyword.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current), $0.keyword)
                },
                uniquingKeysWith: { first, _ in first }
            )
            let relevant = fetched.compactMap { item -> FeedItem? in
                let key = item.watch_term_keyword.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                )
                guard let localKeyword = activeKeywords[key] else { return nil }
                return item.with(watch_term_keyword: localKeyword)
            }
            let added = LocalDB.shared.mergeItems(newItems: relevant, sourceRevision: sourceRevision)
            UserDefaults.standard.set(refreshCutoff.timeIntervalSince1970, forKey: cursorKey)
            lastRefreshSucceeded = true
            lastRefreshedAt = Date()
            errorMessage = nil
            return PaidBackendRefreshResult(addedCount: added, succeeded: true)
        } catch {
            await reportHostedFailure(.feedRefresh, error)
            await refreshEntitlementAfterAccessRejection(error)
            lastRefreshSucceeded = false
            errorMessage = "Hosted refresh failed; on-device refresh is still available: \(error.localizedDescription)"
            return .unavailable
        }
    }

    private func shouldTriggerBackgroundPoll() -> Bool {
        let key = LocalProfileStore.defaultsKey(
            "paid_backend.last_poll_triggered_at",
            profileID: LocalProfileStore.shared.activeProfileID
        )
        let last = UserDefaults.standard.double(forKey: key)
        return last <= 0 || Date().timeIntervalSince1970 - last >= Self.backgroundPollInterval
    }

    private func synchronizeActiveProfileTerms() async throws -> [Int] {
        if let synchronizeHostedTerms {
            return try await synchronizeHostedTerms()
        }
        let profileID = LocalProfileStore.shared.currentProfileIDThreadSafe
        if let activeTermSync, activeTermSync.profileID == profileID {
            return try await activeTermSync.task.value
        }
        let task = Task { try await self.performActiveProfileTermSync(profileID: profileID) }
        activeTermSync = (profileID, task)
        defer { activeTermSync = nil }
        return try await task.value
    }

    private func performActiveProfileTermSync(profileID: UUID) async throws -> [Int] {
        let pushBoundLocalIDs = Set(
            PushTermRegistry.shared.bindings(for: profileID).map(\.localTermID)
        )
        // Inactive ordinary terms do not consume hosted polling. An inactive
        // guaranteed-push term still needs its backend row updated to inactive;
        // otherwise disabling the local term would leave remote delivery on.
        let localTerms = Self.termsForBackendSync(
            LocalDB.shared.terms,
            pushBoundLocalIDs: pushBoundLocalIDs
        )
        var backendTerms = try await BackendClient.shared.fetchPushTerms()
        var usedBackendIDs = Set<Int>()

        for term in localTerms {
            if let index = backendTerms.firstIndex(where: {
                $0.keyword.caseInsensitiveCompare(term.keyword) == .orderedSame
            }) {
                let existing = backendTerms[index]
                usedBackendIDs.insert(existing.id)
                if needsUpdate(existing, from: term) {
                    let updated = try await BackendClient.shared.updateBackendTerm(
                        id: existing.id,
                        term: term,
                        notifyOnNew: existing.notify_on_new
                    )
                    backendTerms[index] = updated
                }
            } else {
                let created = try await BackendClient.shared.createBackendTerm(term, notifyOnNew: false)
                backendTerms.append(created)
                usedBackendIDs.insert(created.id)
            }
        }

        // Guaranteed-push rows from other profiles remain on the server. Only
        // silent rows that are no longer part of the active profile are pruned.
        for backend in backendTerms where !backend.notify_on_new && !usedBackendIDs.contains(backend.id) {
            try await BackendClient.shared.deletePushTerm(id: backend.id)
        }
        cacheBackendTermMappings(backendTerms, localTerms: localTerms, profileID: profileID)
        return usedBackendIDs.sorted()
    }

    private func resolveBackendTermID(for term: WatchTerm, profileID: UUID) async -> Int? {
        if let backendTermID = term.backendTermID { return backendTermID }
        let keywordKey = Self.normalizedKeyword(term.keyword)
        if let cached = backendTermIDsByProfile[profileID]?[keywordKey] { return cached }
        do {
            let backendTerms = try await fetchHostedTerms()
            guard activeProfileID() == profileID,
                  let match = backendTerms.first(where: {
                      $0.keyword.caseInsensitiveCompare(term.keyword) == .orderedSame
                  }) else { return nil }
            backendTermIDsByProfile[profileID, default: [:]][keywordKey] = match.id
            return match.id
        } catch {
            await refreshEntitlementAfterAccessRejection(error)
            AppLogger.network.warning("Hosted feed term lookup failed; the item remains hidden locally")
            return nil
        }
    }

    func cacheBackendTermMappings(
        _ backendTerms: [BackendWatchTerm],
        localTerms: [WatchTerm],
        profileID: UUID
    ) {
        var mapping: [String: Int] = [:]
        for term in localTerms {
            guard let backend = backendTerms.first(where: {
                $0.keyword.caseInsensitiveCompare(term.keyword) == .orderedSame
            }) else { continue }
            mapping[Self.normalizedKeyword(term.keyword)] = backend.id
        }
        backendTermIDsByProfile[profileID] = mapping
    }

    private static func normalizedKeyword(_ keyword: String) -> String {
        keyword.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private func needsUpdate(_ backend: BackendWatchTerm, from local: WatchTerm) -> Bool {
        backend.aliases != local.aliases
            || backend.collection_mode != local.collection_mode
            || backend.source_mode != local.source_mode.rawValue
            || backend.selected_platforms != local.selected_platforms
            || backend.is_active != local.is_active
            || backend.refresh_tier != "standard"
    }

    static func refreshCursorKey(profileID: UUID, platform: String?) -> String {
        // Changing the horizon must backfill existing installations too, rather
        // than reusing their 90-day cursor and fetching only incremental updates.
        "paid_backend_feed.cursor.days\(FeedDatePolicy.maximumLookbackDays).\(profileID.uuidString).\(platform ?? "all")"
    }

    private func refreshCursor(forKey key: String) -> Date? {
        let timestamp = UserDefaults.standard.double(forKey: key)
        return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
    }

    private func refreshEntitlementAfterAccessRejection(_ error: Error) async {
        guard case BackendClientError.httpStatus(_, let code, _) = error,
              code == "paid_backend_required" else { return }
        await refreshEntitlement()
    }

    static func termsForBackendSync(
        _ terms: [WatchTerm],
        pushBoundLocalIDs: Set<String>
    ) -> [WatchTerm] {
        terms.filter { $0.is_active || pushBoundLocalIDs.contains($0.id) }
    }
}
