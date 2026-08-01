import BackgroundTasks
import Foundation

private actor RefreshCompletion {
    private var result: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?

    func wait() async -> Bool {
        if let result { return result }
        return await withCheckedContinuation { continuation in
            if let result = self.result {
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
            }
        }
    }

    func finish(_ result: Bool) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(returning: result)
        continuation = nil
    }
}

/// Keeps the local-only feed useful when the app has not been opened recently.
/// iOS decides the exact execution time; this is a best-effort refresh, not a
/// replacement for a server scheduler.
@MainActor
final class BackgroundRefreshManager {
    static let shared = BackgroundRefreshManager()
    static let taskIdentifier = "com.otterpia.oshireader.feed-refresh"
    static let minimumInterval: TimeInterval = 30 * 60
    private static let operationDeadline: TimeInterval = 25
    private static let maxConcurrentTerms = 2

    private(set) var isRefreshing = false
    private var activeRefreshTask: Task<Void, Never>?
    private var activeRefreshGeneration: UUID?

    private init() {}

    static var lastCompletedAt: Date? {
        let timestamp = UserDefaults.standard.double(forKey: "background_refresh.last_completed_at")
        return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
    }

    func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                await Self.shared.handle(refreshTask)
            }
        }
    }

    func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: Self.minimumInterval)
        do {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
            try BGTaskScheduler.shared.submit(request)
        } catch {
            #if DEBUG
            print("Background refresh scheduling failed: \(error)")
            #endif
        }
    }

    func refreshNow() async -> Bool {
        guard !isRefreshing, activeRefreshTask == nil else { return false }
        guard !ProcessInfo.processInfo.arguments.contains("--uitesting") else { return false }

        isRefreshing = true
        defer { isRefreshing = false }

        let completion = RefreshCompletion()
        let generation = UUID()
        activeRefreshGeneration = generation
        let worker = Task { @MainActor in
            defer { self.finishRefresh(generation: generation) }
            let result: Bool
            do {
                result = try await self.performRefresh(generation: generation)
            } catch {
                result = false
            }
            await completion.finish(result)
        }
        activeRefreshTask = worker
        let timeout = Task { [completion] in
            do {
                try await Task.sleep(nanoseconds: UInt64(Self.operationDeadline * 1_000_000_000))
                await completion.finish(false)
            } catch {
                // The worker completed before the deadline.
            }
        }
        return await withTaskCancellationHandler(operation: {
            let result = await completion.wait()
            timeout.cancel()
            if !result {
                self.invalidateRefresh(generation: generation)
                worker.cancel()
            }
            return result
        }, onCancel: {
            worker.cancel()
            timeout.cancel()
            Task { @MainActor in
                self.invalidateRefresh(generation: generation)
                await completion.finish(false)
            }
        })
    }

    private func invalidateRefresh(generation: UUID) {
        guard activeRefreshGeneration == generation else { return }
        activeRefreshGeneration = nil
    }

    private func finishRefresh(generation: UUID) {
        guard activeRefreshGeneration == generation || activeRefreshTask != nil else { return }
        activeRefreshGeneration = nil
        activeRefreshTask = nil
    }

    private func cancelActiveRefresh() {
        activeRefreshTask?.cancel()
    }

    private func performRefresh(generation: UUID) async throws -> Bool {
        try Task.checkCancellation()
        let activeTerms = LocalDB.shared.terms.filter(\.is_active)
        let platforms = Set(LocalDB.shared.subscribedPlatforms.filter { $0 != "custom" })
        let sourceRevision = LocalDB.shared.dataRevision

        if !activeTerms.isEmpty && !platforms.isEmpty {
            try await withThrowingTaskGroup(of: [FeedItem].self) { group in
                var iterator = activeTerms.makeIterator()
                var running = 0
                var batches = [[FeedItem]]()
                while running < Self.maxConcurrentTerms, let term = iterator.next() {
                    group.addTask {
                        await IngestionService.shared.ingest(term: term, platforms: platforms)
                    }
                    running += 1
                }
                do {
                    for try await items in group {
                        try Task.checkCancellation()
                        guard activeRefreshGeneration == generation else { throw CancellationError() }
                        if !items.isEmpty {
                            batches.append(items)
                        }
                        running -= 1
                        if let term = iterator.next() {
                            group.addTask {
                                await IngestionService.shared.ingest(term: term, platforms: platforms)
                            }
                            running += 1
                        }
                    }
                } catch {
                    // Keep completed term results when the refresh is cancelled or invalidated.
                    if !batches.isEmpty {
                        _ = LocalDB.shared.mergeItemsBatched(newItemsBatches: batches, sourceRevision: sourceRevision)
                    }
                    throw error
                }
                if !batches.isEmpty {
                    _ = LocalDB.shared.mergeItemsBatched(newItemsBatches: batches, sourceRevision: sourceRevision)
                }
            }
        }

        try Task.checkCancellation()
        guard activeRefreshGeneration == generation else { throw CancellationError() }
        let customItems = await NetworkManager.shared.scrapeCustomUrls(LocalDB.shared.customUrls)
        try Task.checkCancellation()
        guard activeRefreshGeneration == generation else { throw CancellationError() }
        if !customItems.isEmpty {
            _ = LocalDB.shared.mergeItems(newItems: customItems, sourceRevision: sourceRevision)
        }

        LocalDB.shared.flushPendingFeedItemsSave()

        guard activeRefreshGeneration == generation else { throw CancellationError() }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "background_refresh.last_completed_at")
        return true
    }

    private func handle(_ task: BGAppRefreshTask) async {
        task.expirationHandler = { [weak self] in
            Task { @MainActor in self?.cancelActiveRefresh() }
        }
        let success = await refreshNow()
        task.setTaskCompleted(success: success)
        schedule()
    }
}
