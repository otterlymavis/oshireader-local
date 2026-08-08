import Foundation

enum LocalRefreshRequest: Equatable {
    case foreground
    case background
    case platform(String)

    var maxConcurrentTerms: Int {
        switch self {
        case .background: return 2
        case .foreground, .platform: return 3
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

    var succeeded: Bool {
        completion == .completed && customRefreshCompleted && !sourceStatuses.contains {
            if case .failed = $0.outcome { return true }
            return false
        }
    }
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
                    partial: result.completion != .completed || !result.customRefreshCompleted
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
        let platforms: Set<String>
        switch request {
        case .platform(let platform): platforms = [platform]
        default: platforms = Set(db.subscribedPlatforms.filter { $0 != "custom" })
        }
        let sourceRevision = db.dataRevision

        guard !orderedTerms.isEmpty, !platforms.isEmpty else {
            let customCompleted: Bool
            if case .platform = request {
                customCompleted = true
            } else if !db.customUrls.isEmpty, isCurrent(generation: generation, profileID: profileID) {
                customCompleted = await refreshCustomURLs(
                    db: db,
                    sourceRevision: sourceRevision,
                    generation: generation,
                    profileID: profileID
                ).completed
            } else {
                customCompleted = true
            }
            return LocalRefreshResult(completion: Task.isCancelled ? .cancelled : .completed, addedCount: 0, sourceStatuses: [], customRefreshCompleted: customCompleted)
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
        var customCompleted = true
        if case .platform = request {
            customCompleted = true
        } else if !Task.isCancelled, isCurrent(generation: generation, profileID: profileID) {
            let custom = await refreshCustomURLs(
                db: db,
                sourceRevision: sourceRevision,
                generation: generation,
                profileID: profileID
            )
            customCompleted = custom.completed
            addedCount += custom.addedCount
        } else {
            customCompleted = false
        }

        guard isCurrent(generation: generation, profileID: profileID) else {
            return LocalRefreshResult(
                completion: .cancelled,
                addedCount: 0,
                sourceStatuses: reports.statuses,
                customRefreshCompleted: false
            )
        }
        RefreshDiagnostics.shared.recordSourceStatuses(reports.statuses)
        RefreshDiagnostics.shared.recordCompletedSourceStatuses(RefreshDiagnostics.shared.sourceStatuses)
        let completion: LocalRefreshCompletion = Task.isCancelled ? .cancelled : .completed
        return LocalRefreshResult(completion: completion, addedCount: addedCount, sourceStatuses: reports.statuses, customRefreshCompleted: customCompleted)
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
        await withTaskGroup(of: IngestionReport.self, returning: (Int, [SourceRefreshStatus]).self) { group in
            var iterator = terms.makeIterator()
            var running = 0
            var batches = [[FeedItem]]()
            var statuses = [SourceRefreshStatus]()

            func add(_ term: WatchTerm) {
                group.addTask {
                    await IngestionService.shared.ingestReport(term: term, platforms: platforms)
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
            return (added, statuses)
        }
    }

    private func refreshCustomURLs(
        db: LocalDB,
        sourceRevision: Int,
        generation: Int,
        profileID: UUID
    ) async -> (completed: Bool, addedCount: Int) {
        guard !Task.isCancelled, isCurrent(generation: generation, profileID: profileID) else { return (false, 0) }
        let customReport = await NetworkManager.shared.scrapeCustomUrlsReport(db.customUrls)
        guard !Task.isCancelled, isCurrent(generation: generation, profileID: profileID) else { return (false, 0) }
        var addedCount = 0
        if !customReport.items.isEmpty {
            addedCount = db.mergeItems(newItems: customReport.items, sourceRevision: sourceRevision)
        }
        return (customReport.completed, addedCount)
    }

    private func isCurrent(generation: Int, profileID: UUID) -> Bool {
        self.generation == generation && LocalDB.shared.activeProfile.id == profileID
    }
}
