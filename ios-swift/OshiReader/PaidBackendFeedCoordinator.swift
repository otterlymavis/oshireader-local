import Foundation

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

    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshSucceeded: Bool?
    @Published private(set) var lastRefreshedAt: Date?
    @Published var errorMessage: String?

    private var scheduledSync: Task<Void, Never>?
    private let incrementalOverlap: TimeInterval = 15 * 60

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
        guard PlusStore.shouldSyncBackend else { return }
        if !PlusStore.shared.hasActiveEntitlement {
            await PlusStore.shared.refreshStatus()
        }
        guard PlusStore.shared.hasActiveEntitlement else { return }
        do {
            _ = try await synchronizeActiveProfileTerms()
            errorMessage = nil
        } catch {
            await refreshEntitlementAfterAccessRejection(error)
            errorMessage = "Hosted refresh could not synchronize: \(error.localizedDescription)"
        }
    }

    func refresh(
        _ request: LocalRefreshRequest,
        sourceRevision: Int,
        profileID: UUID
    ) async -> PaidBackendRefreshResult {
        guard PlusStore.shouldSyncBackend else { return .unavailable }
        if !PlusStore.shared.hasActiveEntitlement {
            await PlusStore.shared.refreshStatus()
        }
        guard PlusStore.shared.hasActiveEntitlement else { return .unavailable }

        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let backendTermIDs = try await synchronizeActiveProfileTerms()
            let platform: String?
            switch request {
            case .platform(let value):
                let normalized = PlatformRegistry.normalizeID(value)
                platform = normalized == "custom" ? nil : normalized
            case .foreground, .background:
                platform = nil
            }
            let cursorKey = refreshCursorKey(profileID: profileID, platform: platform)
            let refreshCutoff = Date()
            let since = refreshCursor(forKey: cursorKey).map {
                ISO8601DateFormatter().string(from: $0.addingTimeInterval(-incrementalOverlap))
            }
            let fetched: [FeedItem]
            if backendTermIDs.isEmpty {
                fetched = []
            } else {
                fetched = try await BackendClient.shared.fetchAllBackendFeed(
                    platform: platform,
                    termIDs: backendTermIDs,
                    pageSize: request == .background ? 100 : 200,
                    days: 90,
                    since: since,
                    until: ISO8601DateFormatter().string(from: refreshCutoff)
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
            await refreshEntitlementAfterAccessRejection(error)
            lastRefreshSucceeded = false
            errorMessage = "Hosted refresh failed; on-device refresh is still available: \(error.localizedDescription)"
            return .unavailable
        }
    }

    private func synchronizeActiveProfileTerms() async throws -> [Int] {
        let profileID = LocalProfileStore.shared.activeProfileID
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
        return usedBackendIDs.sorted()
    }

    private func needsUpdate(_ backend: BackendWatchTerm, from local: WatchTerm) -> Bool {
        backend.aliases != local.aliases
            || backend.collection_mode != local.collection_mode
            || backend.source_mode != local.source_mode.rawValue
            || backend.selected_platforms != local.selected_platforms
            || backend.is_active != local.is_active
            || backend.refresh_tier != "standard"
    }

    private func refreshCursorKey(profileID: UUID, platform: String?) -> String {
        "paid_backend_feed.cursor.\(profileID.uuidString).\(platform ?? "all")"
    }

    private func refreshCursor(forKey key: String) -> Date? {
        let timestamp = UserDefaults.standard.double(forKey: key)
        return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
    }

    private func refreshEntitlementAfterAccessRejection(_ error: Error) async {
        guard case BackendClientError.httpStatus(_, let code, _) = error,
              code == "paid_backend_required" else { return }
        await PlusStore.shared.refreshStatus()
    }

    static func termsForBackendSync(
        _ terms: [WatchTerm],
        pushBoundLocalIDs: Set<String>
    ) -> [WatchTerm] {
        terms.filter { $0.is_active || pushBoundLocalIDs.contains($0.id) }
    }
}
