import Foundation

enum LocalRefreshRequest: Equatable {
    case foreground
    case background
    case platform(String)

    static let backgroundMaximumAliases = 2
    static let backgroundMaximumCustomURLs = 4

    var maxConcurrentTerms: Int {
        switch self {
        case .background: return 2
        case .foreground, .platform: return 3
        }
    }

    var maximumAliases: Int? {
        switch self {
        case .background: return Self.backgroundMaximumAliases
        case .foreground, .platform: return nil
        }
    }

    var maximumCustomURLs: Int? {
        switch self {
        case .background: return Self.backgroundMaximumCustomURLs
        case .foreground, .platform: return nil
        }
    }

    func customURLsToRefresh(_ urls: [CustomUrl]) -> [CustomUrl] {
        guard let maximumCustomURLs else { return urls }
        return Array(urls.prefix(maximumCustomURLs))
    }

    func hasCappedCustomURLs(_ urls: [CustomUrl]) -> Bool {
        guard let maximumCustomURLs else { return false }
        return urls.count > maximumCustomURLs
    }

    func platforms(subscribedPlatforms: [String]) -> Set<String> {
        switch self {
        case .platform(let platform):
            return Set(PlatformRegistry.normalizeIDs([platform]).filter { $0 != "custom" })
        case .foreground, .background:
            return Set(PlatformRegistry.normalizeIDs(subscribedPlatforms).filter { $0 != "custom" })
        }
    }

    func refreshesCustomURLs() -> Bool {
        switch self {
        case .platform(let platform):
            return PlatformRegistry.normalizeID(platform) == "custom"
        case .foreground, .background:
            return true
        }
    }
}

enum LocalRefreshCompletion: Equatable {
    case completed
    case cancelled
    case expired
    case failed
}

struct LocalRefreshResult: Equatable {
    let completion: LocalRefreshCompletion
    let addedCount: Int
    let sourceStatuses: [SourceRefreshStatus]
    let customRefreshCompleted: Bool
    let cappedWorkCount: Int

    init(
        completion: LocalRefreshCompletion,
        addedCount: Int,
        sourceStatuses: [SourceRefreshStatus],
        customRefreshCompleted: Bool,
        cappedWorkCount: Int = 0
    ) {
        self.completion = completion
        self.addedCount = addedCount
        self.sourceStatuses = sourceStatuses
        self.customRefreshCompleted = customRefreshCompleted
        self.cappedWorkCount = cappedWorkCount
    }

    var succeeded: Bool {
        completion == .completed && customRefreshCompleted
    }

    var wasPartial: Bool {
        completion != .completed || !customRefreshCompleted || hasSourceFailures || cappedWorkCount > 0
    }

    var hasSourceFailures: Bool { sourceStatuses.hasFailures }
}

/// Single owner for foreground and background local ingestion. A second
/// caller coalesces onto the active task instead of starting duplicate work.
@MainActor
final class LocalRefreshCoordinator: ObservableObject {
    static let shared = LocalRefreshCoordinator()

    @Published private(set) var isRefreshing = false
    private var activeTask: Task<LocalRefreshResult, Never>?
    private var activeRequest: LocalRefreshRequest?
    private var generation = 0

    private init() {}

    func refresh(_ request: LocalRefreshRequest = .foreground) async -> LocalRefreshResult {
        if let activeTask {
            if activeRequest == .background, request != .background {
                activeTask.cancel()
                _ = await activeTask.value
                return await refresh(request)
            }
            return await activeTask.value
        }

        isRefreshing = true
        RefreshDiagnostics.shared.begin()
        RefreshDiagnostics.shared.resetSourceStatuses()
        generation &+= 1
        let refreshGeneration = generation
        let profileID = LocalDB.shared.activeProfile.id

        let task = Task { @MainActor [weak self] in
            guard let self else {
                return LocalRefreshResult(completion: .failed, addedCount: 0, sourceStatuses: [], customRefreshCompleted: false)
            }
            let result = await self.perform(
                request,
                generation: refreshGeneration,
                profileID: profileID
            )
            let isCurrent = self.isCurrent(generation: refreshGeneration, profileID: profileID)
            let isSameProfile = LocalDB.shared.activeProfile.id == profileID
            // Cancellation intentionally invalidates the generation so stale
            // results cannot merge, but the task still owns the coordinator's
            // loading state. Always clear that state when this task exits.
            // A cancelled task on the same profile must finish diagnostics;
            // after a profile switch, the new profile's diagnostics must win.
            if isCurrent || isSameProfile {
                RefreshDiagnostics.shared.finish(
                    succeeded: result.succeeded,
                    addedCount: result.addedCount,
                    partial: result.wasPartial
                )
            }
            self.isRefreshing = false
            self.activeRequest = nil
            self.activeTask = nil
            return result
        }
        activeTask = task
        activeRequest = request
        return await task.value
    }

    /// Starts only when no refresh is active. This closes the check/start
    /// race for background execution without allowing its deadline to attach
    /// to a foreground refresh that begins concurrently.
    func refreshIfIdle(_ request: LocalRefreshRequest) async -> LocalRefreshResult? {
        guard activeTask == nil else { return nil }
        return await refresh(request)
    }

    func cancel() {
        generation &+= 1
        activeTask?.cancel()
    }

    private func perform(
        _ request: LocalRefreshRequest,
        generation: Int,
        profileID: UUID
    ) async -> LocalRefreshResult {
        let db = LocalDB.shared
        let activeTerms = db.terms.filter(\.is_active)
        let orderedTerms = RecentTermUsageStore.shared.priorityOrdered(activeTerms)
        let platforms = request.platforms(subscribedPlatforms: db.subscribedPlatforms)
        let refreshesCustomURLs = request.refreshesCustomURLs()
        let sourceRevision = db.dataRevision

        guard !orderedTerms.isEmpty, !platforms.isEmpty else {
            let customCompleted: Bool
            let customStatuses: [SourceRefreshStatus]
            let customAddedCount: Int
            let cappedWorkCount: Int
            if refreshesCustomURLs, !db.customUrls.isEmpty, isCurrent(generation: generation, profileID: profileID) {
                let custom = await refreshCustomURLs(
                    request: request,
                    db: db,
                    sourceRevision: sourceRevision,
                    generation: generation,
                    profileID: profileID
                )
                customCompleted = custom.completed
                customStatuses = custom.statuses
                customAddedCount = custom.addedCount
                cappedWorkCount = custom.cappedWorkCount
            } else {
                customCompleted = true
                customStatuses = []
                customAddedCount = 0
                cappedWorkCount = 0
            }
            let aggregatedCustomStatuses: [SourceRefreshStatus]
            if !customStatuses.isEmpty, isCurrent(generation: generation, profileID: profileID) {
                RefreshDiagnostics.shared.recordSourceStatuses(customStatuses)
                aggregatedCustomStatuses = RefreshDiagnostics.shared.sourceStatuses
                RefreshDiagnostics.shared.recordCompletedSourceStatuses(aggregatedCustomStatuses)
            } else {
                aggregatedCustomStatuses = customStatuses
            }
            return LocalRefreshResult(
                completion: Task.isCancelled ? .cancelled : .completed,
                addedCount: customAddedCount,
                sourceStatuses: aggregatedCustomStatuses,
                customRefreshCompleted: customCompleted,
                cappedWorkCount: cappedWorkCount
            )
        }

        let reports = await ingest(
            terms: orderedTerms,
            platforms: platforms,
            sourceRevision: sourceRevision,
            request: request,
            db: db,
            generation: generation,
            profileID: profileID
        )
        var addedCount = reports.addedCount
        var sourceStatuses = reports.statuses
        var customCompleted = true
        var cappedWorkCount = 0
        if refreshesCustomURLs {
            if !Task.isCancelled, isCurrent(generation: generation, profileID: profileID) {
                let custom = await refreshCustomURLs(
                    request: request,
                    db: db,
                    sourceRevision: sourceRevision,
                    generation: generation,
                    profileID: profileID
                )
                customCompleted = custom.completed
                addedCount += custom.addedCount
                sourceStatuses.append(contentsOf: custom.statuses)
                cappedWorkCount += custom.cappedWorkCount
            } else {
                customCompleted = false
            }
        }

        guard isCurrent(generation: generation, profileID: profileID) else {
            return LocalRefreshResult(
                completion: .cancelled,
                addedCount: 0,
                sourceStatuses: sourceStatuses,
                customRefreshCompleted: false,
                cappedWorkCount: cappedWorkCount
            )
        }
        RefreshDiagnostics.shared.recordSourceStatuses(sourceStatuses)
        let aggregatedSourceStatuses = RefreshDiagnostics.shared.sourceStatuses
        RefreshDiagnostics.shared.recordCompletedSourceStatuses(aggregatedSourceStatuses)
        let completion: LocalRefreshCompletion = Task.isCancelled ? .cancelled : .completed
        return LocalRefreshResult(
            completion: completion,
            addedCount: addedCount,
            sourceStatuses: aggregatedSourceStatuses,
            customRefreshCompleted: customCompleted,
            cappedWorkCount: cappedWorkCount
        )
    }

    private func ingest(
        terms: [WatchTerm],
        platforms: Set<String>,
        sourceRevision: Int,
        request: LocalRefreshRequest,
        db: LocalDB,
        generation: Int,
        profileID: UUID
    ) async -> (addedCount: Int, statuses: [SourceRefreshStatus]) {
        let skippedSourceIDs = RefreshDiagnostics.shared.sourcesInCooldown()
        return await withTaskGroup(of: IngestionReport.self, returning: (Int, [SourceRefreshStatus]).self) { group in
            var iterator = terms.makeIterator()
            var running = 0
            var batches = [[FeedItem]]()
            var statuses = [SourceRefreshStatus]()

            func add(_ term: WatchTerm) {
                group.addTask {
                    await IngestionService.shared.ingestReport(
                        term: term,
                        platforms: platforms,
                        maximumAliases: request.maximumAliases,
                        skippedSourceIDs: skippedSourceIDs
                    )
                }
            }

            while running < request.maxConcurrentTerms, let term = iterator.next() {
                add(term)
                running += 1
            }

            for await report in group {
                if !report.items.isEmpty { batches.append(report.items) }
                statuses.append(contentsOf: report.sourceStatuses)
                running -= 1
                if !Task.isCancelled, let term = iterator.next() {
                    add(term)
                    running += 1
                }
            }

            let added: Int
            if isCurrent(generation: generation, profileID: profileID), !Task.isCancelled {
                added = batches.isEmpty ? 0 : db.mergeItemsBatched(newItemsBatches: batches, sourceRevision: sourceRevision)
            } else {
                added = 0
            }
            // Surface cooldown as its own status instead of the source
            // silently having no entry this cycle — recordSourceStatuses
            // below folds these into the diagnostics the export reads, so
            // "why isn't source X updating" shows a deliberate skip rather
            // than a stale leftover from before cooldown started.
            let cooldownStatuses = skippedSourceIDs.intersection(platforms).map {
                SourceRefreshStatus(id: $0, outcome: .cooldown, itemCount: 0, queryCount: 0)
            }
            return (added, statuses + cooldownStatuses)
        }
    }

    private func refreshCustomURLs(
        request: LocalRefreshRequest,
        db: LocalDB,
        sourceRevision: Int,
        generation: Int,
        profileID: UUID
    ) async -> (completed: Bool, addedCount: Int, statuses: [SourceRefreshStatus], cappedWorkCount: Int) {
        guard !Task.isCancelled, isCurrent(generation: generation, profileID: profileID) else { return (false, 0, [], 0) }
        let allCustomUrlsCount = db.customUrls.count
        let customUrls = request.customURLsToRefresh(db.customUrls)
        let wasCapped = request.hasCappedCustomURLs(db.customUrls)
        let customReport = await NetworkManager.shared.scrapeCustomUrlsReport(customUrls)
        guard !Task.isCancelled, isCurrent(generation: generation, profileID: profileID) else { return (false, 0, [], 0) }
        var addedCount = 0
        let currentItems = db.currentCustomFeedItems(customReport.items)
        if !currentItems.isEmpty {
            addedCount = db.mergeItems(newItems: currentItems, sourceRevision: sourceRevision)
        }
        let outcome: SourceRefreshOutcome
        if !customReport.completed {
            outcome = .failed(.httpFailure)
        } else if !currentItems.isEmpty {
            outcome = .received
        } else {
            outcome = .noResults
        }
        let status = SourceRefreshStatus(
            id: "custom",
            outcome: outcome,
            itemCount: currentItems.count,
            queryCount: customUrls.count
        )
        return (
            customReport.completed,
            addedCount,
            [status],
            wasCapped ? max(0, allCustomUrlsCount - customUrls.count) : 0
        )
    }

    private func isCurrent(generation: Int, profileID: UUID) -> Bool {
        self.generation == generation && LocalDB.shared.activeProfile.id == profileID
    }
}
