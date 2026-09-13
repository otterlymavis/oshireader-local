import Foundation

enum LocalRefreshRequest: Equatable {
    case foreground
    case background
    case platform(String)

    static let backgroundMaximumAliases = 1

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

enum BackgroundRefreshUnit: Hashable {
    case source(term: WatchTerm, platform: String)
    case custom(CustomUrl)

    var stableID: String {
        switch self {
        case .source(let term, let platform): return "source|\(term.id)|\(platform)"
        case .custom(let url): return "custom|\(url.id)"
        }
    }
}

struct BackgroundRefreshPlan: Equatable {
    let units: [BackgroundRefreshUnit]
    let totalWorkCount: Int

    /// Builds a stable, rotating queue. Callers checkpoint one unit at a time
    /// and persist the cursor only after that unit's data and health status.
    static func make(
        terms: [WatchTerm],
        subscribedPlatforms: [String],
        customURLs: [CustomUrl] = [],
        lastCompletedUnitID: String? = nil,
        legacyCursor: Int = 0
    ) -> BackgroundRefreshPlan {
        let orderedPlatformIDs = PlatformRegistry.normalizeIDs(subscribedPlatforms)
            .filter { $0 != "custom" }
            .sorted()
        let availablePlatforms = Set(orderedPlatformIDs)
        let sourcesByTerm = terms.sorted { $0.id < $1.id }.map { term -> (WatchTerm, [String]) in
            let effective = IngestionService.effectivePlatforms(for: term, available: availablePlatforms)
            return (term, orderedPlatformIDs.filter(effective.contains))
        }
        let maximumSourceCount = sourcesByTerm.map { $0.1.count }.max() ?? 0
        let sourceUnits = (0..<maximumSourceCount).flatMap { sourceIndex in
            sourcesByTerm.compactMap { pair -> BackgroundRefreshUnit? in
                let (term, sources) = pair
                guard sourceIndex < sources.count else { return nil }
                return BackgroundRefreshUnit.source(term: term, platform: sources[sourceIndex])
            }
        }
        let customUnits = customURLs.sorted { $0.id < $1.id }.map(BackgroundRefreshUnit.custom)
        var units = [BackgroundRefreshUnit]()
        for index in 0..<max(sourceUnits.count, customUnits.count) {
            if index < sourceUnits.count { units.append(sourceUnits[index]) }
            if index < customUnits.count { units.append(customUnits[index]) }
        }
        guard !units.isEmpty else {
            return BackgroundRefreshPlan(units: [], totalWorkCount: 0)
        }
        let start: Int
        if let lastCompletedUnitID,
           let completedIndex = units.firstIndex(where: { $0.stableID == lastCompletedUnitID }) {
            start = (completedIndex + 1) % units.count
        } else {
            start = max(0, legacyCursor) % units.count
        }
        units = Array(units[start...]) + Array(units[..<start])
        return BackgroundRefreshPlan(units: units, totalWorkCount: units.count)
    }
}

enum BackgroundRefreshCheckpoint {
    static func isValid(
        sourceRevision: Int,
        currentRevision: Int,
        completedAt: Date,
        deadline: Date
    ) -> Bool {
        sourceRevision == currentRevision && completedAt <= deadline
    }
}

struct BackgroundRefreshNotificationBatch {
    private let suppressesNotifications: Bool
    private var candidateKeys: [String] = []
    private var candidateKeySet = Set<String>()

    init(feedWasEmptyAtStart: Bool) {
        suppressesNotifications = feedWasEmptyAtStart
    }

    mutating func capture(_ items: [FeedItem]) {
        guard !suppressesNotifications else { return }
        for item in items {
            let key = Self.key(for: item)
            if candidateKeySet.insert(key).inserted {
                candidateKeys.append(key)
            }
        }
    }

    func survivingItems(in finalFeed: [FeedItem]) -> [FeedItem] {
        guard !suppressesNotifications, !candidateKeys.isEmpty else { return [] }
        var finalItemsByKey = [String: FeedItem]()
        for item in finalFeed {
            finalItemsByKey[Self.key(for: item)] = item
        }
        return candidateKeys.compactMap { finalItemsByKey[$0] }
    }

    private static func key(for item: FeedItem) -> String {
        "\(item.id)::\(item.watch_term_keyword)"
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
    // A background wake is rare and the OS only grants ~30s total; leave
    // headroom under `BackgroundRefreshManager.operationDeadline` (25s) for
    // `maintainFiveChIndex` (bounded by the same `backgroundUnitDeadline`)
    // plus this loop. The loop's own continuation check below only starts a
    // chunk when the remaining budget can fit one more `backgroundUnitDeadline`,
    // so its wall time is bounded by `backgroundWorkBudget` itself, not
    // `backgroundWorkBudget + backgroundUnitDeadline`.
    private static let backgroundWorkBudget: TimeInterval = 16
    private static let backgroundUnitDeadline: TimeInterval = 7
    // Units are independent network fetches (one term+platform, or one custom
    // URL) — running a couple concurrently covers more of the rotation per
    // wake instead of the previous strictly-serial one-at-a-time pass, without
    // changing the per-unit timeout or the checkpointing granularity by more
    // than a chunk.
    private static let backgroundConcurrentUnits = 2

    private init() {}

    func refresh(_ request: LocalRefreshRequest = .foreground) async -> LocalRefreshResult {
        if let activeTask {
            if activeRequest == .background, request != .background {
                activeTask.cancel()
                _ = await activeTask.value
                return await refresh(request)
            }
            // A single-source (.platform) tap must actually fetch that source.
            // Coalescing it onto an unrelated in-flight refresh silently drops
            // it — the user taps a chip and nothing ever loads for it. Wait for
            // the active work to finish, then run this request's own pass.
            if case .platform = request, activeRequest != request {
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
            let sourceRevision = LocalDB.shared.dataRevision
            async let paidBackendResult = PaidBackendFeedCoordinator.shared.refresh(
                request,
                sourceRevision: sourceRevision,
                profileID: profileID
            )
            let localResult = await self.perform(
                request,
                generation: refreshGeneration,
                profileID: profileID
            )
            let paidResult = await paidBackendResult
            let result = LocalRefreshResult(
                completion: localResult.completion,
                addedCount: localResult.addedCount + paidResult.addedCount,
                sourceStatuses: localResult.sourceStatuses,
                customRefreshCompleted: localResult.customRefreshCompleted,
                cappedWorkCount: localResult.cappedWorkCount
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
        if request == .background {
            return await performBackground(generation: generation, profileID: profileID)
        }
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
            var cappedWorkCount = 0
            if refreshesCustomURLs, !db.customUrls.isEmpty, isCurrent(generation: generation, profileID: profileID) {
                let custom = await refreshCustomURLs(
                    db: db,
                    sourceRevision: sourceRevision,
                    generation: generation,
                    profileID: profileID,
                    customURLs: db.customUrls
                )
                customCompleted = custom.completed
                customStatuses = custom.statuses
                customAddedCount = custom.addedCount
                cappedWorkCount += custom.cappedWorkCount
            } else {
                customCompleted = true
                customStatuses = []
                customAddedCount = 0
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
                    db: db,
                    sourceRevision: sourceRevision,
                    generation: generation,
                    profileID: profileID,
                    customURLs: db.customUrls
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

    private func performBackground(generation: Int, profileID: UUID) async -> LocalRefreshResult {
        let db = LocalDB.shared
        let sourceRevision = db.dataRevision
        let completedUnitKey = LocalProfileStore.defaultsKey("background_refresh.last_completed_unit_id", profileID: profileID)
        let legacyCursorKey = LocalProfileStore.defaultsKey("background_refresh.selection_cursor", profileID: profileID)
        let terms = RecentTermUsageStore.shared.priorityOrdered(db.terms.filter(\.is_active))
        let plan = BackgroundRefreshPlan.make(
            terms: terms,
            subscribedPlatforms: db.subscribedPlatforms,
            customURLs: db.customUrls,
            lastCompletedUnitID: UserDefaults.standard.string(forKey: completedUnitKey),
            legacyCursor: UserDefaults.standard.integer(forKey: legacyCursorKey)
        )
        // The 5ch subject index is disposable cache maintenance and is kept
        // outside source ingestion/status accounting.
        await IngestionService.shared.maintainFiveChIndex(
            profileID: profileID,
            deadline: Date(timeIntervalSinceNow: min(Self.backgroundUnitDeadline, Self.backgroundWorkBudget))
        )
        guard !plan.units.isEmpty else {
            return LocalRefreshResult(completion: .completed, addedCount: 0, sourceStatuses: [], customRefreshCompleted: true)
        }

        let startedAt = Date()
        var completedCount = 0
        var addedCount = 0
        var customCompleted = true
        var didRecordSourceStatuses = false
        let cooldown = RefreshDiagnostics.shared.sourcesInCooldown()
        var notificationBatch = BackgroundRefreshNotificationBatch(feedWasEmptyAtStart: db.feedItems.isEmpty)

        var unitIndex = 0
        backgroundLoop: while unitIndex < plan.units.count {
            guard !Task.isCancelled,
                  isCurrent(generation: generation, profileID: profileID),
                  Date().timeIntervalSince(startedAt) + Self.backgroundUnitDeadline <= Self.backgroundWorkBudget
            else { break }

            let chunkEnd = min(unitIndex + Self.backgroundConcurrentUnits, plan.units.count)
            let chunk = Array(plan.units[unitIndex..<chunkEnd])
            // Shared across the chunk: every member starts at the same instant,
            // so they share one fetch deadline rather than each getting its own
            // clock re-based on however long its predecessor took.
            let unitDeadline = Date(timeIntervalSinceNow: Self.backgroundUnitDeadline)

            let fetchResults: [Int: (items: [FeedItem], statuses: [SourceRefreshStatus], customCompleted: Bool)] =
                await withTaskGroup(
                    of: (offset: Int, items: [FeedItem], statuses: [SourceRefreshStatus], customCompleted: Bool).self
                ) { group in
                    for (offset, unit) in chunk.enumerated() {
                        group.addTask {
                            let result = await self.fetchBackgroundUnit(unit, db: db, cooldown: cooldown, unitDeadline: unitDeadline)
                            return (offset, result.items, result.statuses, result.customCompleted)
                        }
                    }
                    var collected: [Int: (items: [FeedItem], statuses: [SourceRefreshStatus], customCompleted: Bool)] = [:]
                    for await outcome in group {
                        collected[outcome.offset] = (outcome.items, outcome.statuses, outcome.customCompleted)
                    }
                    return collected
                }

            // One combined check for the whole chunk in place of the former
            // per-unit checks — if it fails, nothing in this chunk merges and
            // the checkpoint doesn't advance past the last fully-committed chunk.
            guard !Task.isCancelled,
                  isCurrent(generation: generation, profileID: profileID),
                  BackgroundRefreshCheckpoint.isValid(
                      sourceRevision: sourceRevision,
                      currentRevision: db.dataRevision,
                      completedAt: Date(),
                      deadline: unitDeadline
                  )
            else { break backgroundLoop }

            for (offset, unit) in chunk.enumerated() {
                guard let unitResult = fetchResults[offset] else { continue }
                let mergeResult = unitResult.items.isEmpty
                    ? LocalDB.FeedMergeResult(addedCount: 0, didMutate: false)
                    : db.mergeItemsResult(
                        newItems: unitResult.items,
                        sourceRevision: sourceRevision,
                        notificationHandler: { items, _ in
                            notificationBatch.capture(items)
                        }
                    )
                if mergeResult.didMutate {
                    db.flushPendingFeedItemsSave()
                }
                addedCount += mergeResult.addedCount
                customCompleted = customCompleted && unitResult.customCompleted
                if !unitResult.statuses.isEmpty {
                    RefreshDiagnostics.shared.recordSourceStatuses(unitResult.statuses)
                    // `persist: false` — the health history is re-encoded and
                    // written to UserDefaults once after the loop
                    // (`flushPendingHealthRecords`) rather than on every unit (O6).
                    // `replacingRecordsSince: startedAt` makes each call rewrite
                    // this refresh's records for the seen sources, so the final
                    // in-memory state equals what a single end-of-loop call
                    // produces.
                    RefreshDiagnostics.shared.recordCompletedSourceStatuses(
                        RefreshDiagnostics.shared.sourceStatuses,
                        replacingRecordsSince: startedAt,
                        persist: false
                    )
                    didRecordSourceStatuses = true
                }
                completedCount += 1
                UserDefaults.standard.set(unit.stableID, forKey: completedUnitKey)
                UserDefaults.standard.removeObject(forKey: legacyCursorKey)
            }
            unitIndex = chunkEnd
        }

        // O6: single end-of-refresh write of the health history, covering both
        // normal completion and an early `break` (deadline / cancellation).
        if didRecordSourceStatuses {
            RefreshDiagnostics.shared.flushPendingHealthRecords()
        }

        let notificationItems = notificationBatch.survivingItems(in: db.feedItems)
        if !Task.isCancelled,
           isCurrent(generation: generation, profileID: profileID),
           !notificationItems.isEmpty {
            await NotificationManager.shared.notifyForNewItems(
                notificationItems,
                terms: db.terms,
                includeAttachments: false
            )
        }

        let completion: LocalRefreshCompletion = Task.isCancelled || !isCurrent(generation: generation, profileID: profileID)
            ? .cancelled
            : .completed
        return LocalRefreshResult(
            completion: completion,
            addedCount: addedCount,
            sourceStatuses: RefreshDiagnostics.shared.sourceStatuses,
            customRefreshCompleted: customCompleted,
            cappedWorkCount: max(0, plan.totalWorkCount - completedCount)
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
        // Cooldown only applies to routine (foreground/background) refreshes.
        // .platform is the user explicitly tapping a source to fetch it now
        // — honor that override rather than silently no-op-ing for up to
        // cooldownDuration with no feedback.
        let skippedSourceIDs: Set<String>
        if case .platform = request {
            skippedSourceIDs = []
        } else {
            skippedSourceIDs = RefreshDiagnostics.shared.sourcesInCooldown()
        }
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
                        skippedSourceIDs: skippedSourceIDs,
                        fetchScope: request == .background ? .background : .foreground
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
        db: LocalDB,
        sourceRevision: Int,
        generation: Int,
        profileID: UUID,
        customURLs: [CustomUrl],
        requestTimeout: TimeInterval = 12
    ) async -> (completed: Bool, addedCount: Int, statuses: [SourceRefreshStatus], cappedWorkCount: Int) {
        guard !Task.isCancelled, isCurrent(generation: generation, profileID: profileID) else { return (false, 0, [], 0) }
        let fetched = await fetchCustomURLs(db: db, customURLs: customURLs, requestTimeout: requestTimeout)
        guard !Task.isCancelled, isCurrent(generation: generation, profileID: profileID) else { return (false, 0, [], 0) }
        let addedCount = fetched.items.isEmpty ? 0 : db.mergeItems(newItems: fetched.items, sourceRevision: sourceRevision)
        return (fetched.completed, addedCount, fetched.statuses, fetched.cappedWorkCount)
    }

    /// Fetches one background rotation unit. Called concurrently (one child
    /// task per chunk member) from `performBackground`'s task group — the
    /// `.source` branch calls `IngestionService.shared` directly with no
    /// actor-isolated state, and `.custom` awaits `self.fetchCustomURLs`,
    /// which briefly hops back onto the main actor around its own network
    /// await; either way the actual network wait happens off the main actor,
    /// so running several of these concurrently overlaps their real latency
    /// instead of serializing it.
    private func fetchBackgroundUnit(
        _ unit: BackgroundRefreshUnit,
        db: LocalDB,
        cooldown: Set<String>,
        unitDeadline: Date
    ) async -> (items: [FeedItem], statuses: [SourceRefreshStatus], customCompleted: Bool) {
        switch unit {
        case .source(let term, let platform):
            if cooldown.contains(platform) {
                return ([], [SourceRefreshStatus(id: platform, outcome: .cooldown, itemCount: 0, queryCount: 0)], true)
            }
            let report = await IngestionService.shared.ingestReport(
                term: term,
                platforms: [platform],
                maximumAliases: LocalRefreshRequest.background.maximumAliases,
                fetchScope: .background,
                transportAttemptLimit: 1,
                requestTimeoutCap: Self.backgroundUnitDeadline,
                requestDeadline: unitDeadline
            )
            return (report.items, report.sourceStatuses, true)
        case .custom(let customURL):
            let custom = await fetchCustomURLs(
                db: db,
                customURLs: [customURL],
                requestTimeout: max(0.1, unitDeadline.timeIntervalSinceNow)
            )
            return (custom.items, custom.statuses, custom.completed)
        }
    }

    private func fetchCustomURLs(
        db: LocalDB,
        customURLs: [CustomUrl],
        requestTimeout: TimeInterval
    ) async -> (completed: Bool, items: [FeedItem], statuses: [SourceRefreshStatus], cappedWorkCount: Int) {
        let allCustomUrlsCount = db.customUrls.count
        let wasCapped = customURLs.count < allCustomUrlsCount
        let customReport = await NetworkManager.shared.scrapeCustomUrlsReport(customURLs, requestTimeout: requestTimeout)
        let currentItems = db.currentCustomFeedItems(customReport.items)
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
            queryCount: customURLs.count
        )
        return (
            customReport.completed,
            currentItems,
            [status],
            wasCapped ? max(0, allCustomUrlsCount - customURLs.count) : 0
        )
    }

    private func isCurrent(generation: Int, profileID: UUID) -> Bool {
        self.generation == generation && LocalDB.shared.activeProfile.id == profileID
    }
}
