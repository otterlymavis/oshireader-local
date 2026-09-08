import BackgroundTasks
import Foundation

private actor BackgroundRefreshWaiter {
    private var result: LocalRefreshResult?
    private var continuation: CheckedContinuation<LocalRefreshResult, Never>?

    func wait() async -> LocalRefreshResult {
        if let result { return result }
        return await withCheckedContinuation { continuation in
            if let result = self.result {
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
            }
        }
    }

    func finish(_ result: LocalRefreshResult) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(returning: result)
        continuation = nil
    }
}

enum BackgroundRefreshOutcome: Equatable {
    case newData
    case noData
    case failed
}

/// Keeps the local-first feed useful when the app has not been opened recently.
/// iOS decides the exact timing of the free on-device work; an entitled hosted
/// refresh can supplement it but never replaces it.
@MainActor
final class BackgroundRefreshManager {
    static let shared = BackgroundRefreshManager()
    static let taskIdentifier = "com.otterpia.oshireader.feed-refresh"
    static let minimumInterval: TimeInterval = 15 * 60
    private static let operationDeadline: TimeInterval = 25

    private init() {}

    static var lastCompletedAt: Date? {
        let timestamp = UserDefaults.standard.double(forKey: LocalProfileStore.defaultsKey("background_refresh.last_completed_at"))
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
            // Submitting the same refresh identifier replaces its pending
            // request; do not cancel first, so a failed submission leaves the
            // existing request queued and background refresh can still recover.
            // Submission must also complete before returning: handle(_:) queues
            // the next opportunity before its current background task can expire
            // or complete and the process becomes eligible for suspension.
            try BGTaskScheduler.shared.submit(request)
            AppLogger.network.notice("Background refresh request submitted")
        } catch {
            AppLogger.network.warning("Background refresh scheduling failed: \(error.localizedDescription)")
        }
    }

    func refreshNow() async -> BackgroundRefreshOutcome {
        guard !ProcessInfo.processInfo.arguments.contains("--uitesting") else { return .failed }

        // A foreground refresh already in progress covers this silent-push / BG
        // wake. Report `.noData` (success) instead of letting `refreshIfIdle`'s
        // nil map to `.failed` — repeated spurious `.failed` results make iOS
        // throttle silent-push delivery and background execution.
        if LocalRefreshCoordinator.shared.isRefreshing {
            return .noData
        }

        let waiter = BackgroundRefreshWaiter()
        let worker = Task { @MainActor in
            let result = await LocalRefreshCoordinator.shared.refreshIfIdle(.background)
                // Another refresh can start after the `isRefreshing` check but
                // before this task reaches `refreshIfIdle`. That work already
                // covers the wake, so preserve the same successful `.noData`
                // result as the fast path above instead of reporting a false
                // background failure to iOS.
                ?? LocalRefreshResult(completion: .completed, addedCount: 0, sourceStatuses: [], customRefreshCompleted: true)
            await waiter.finish(result)
        }
        let timeout = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(Self.operationDeadline * 1_000_000_000))
                await waiter.finish(LocalRefreshResult(completion: .expired, addedCount: 0, sourceStatuses: [], customRefreshCompleted: false))
            } catch {
                // The refresh completed before the deadline.
            }
        }
        let result = await withTaskCancellationHandler {
            await waiter.wait()
        } onCancel: {
            // BGTask expiration cancels the task running `refreshNow`. Wake the
            // waiter immediately so the caller can report failure before iOS
            // suspends or terminates the process.
            Task {
                await waiter.finish(LocalRefreshResult(
                    completion: .expired,
                    addedCount: 0,
                    sourceStatuses: [],
                    customRefreshCompleted: false
                ))
            }
        }
        timeout.cancel()
        if Task.isCancelled || result.completion == .expired {
            LocalRefreshCoordinator.shared.cancel()
            worker.cancel()
            return .failed
        }
        guard result.completion == .completed else { return .failed }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: LocalProfileStore.defaultsKey("background_refresh.last_completed_at"))
        guard result.succeeded else { return .failed }
        return result.addedCount > 0 ? .newData : .noData
    }

    private func cancelActiveRefresh() {
        LocalRefreshCoordinator.shared.cancel()
    }

    private func handle(_ task: BGAppRefreshTask) async {
        // Queue the next opportunity before starting network work. If iOS
        // expires or terminates this run, a future refresh remains pending.
        schedule()
        let operation = Task { @MainActor in
            await refreshNow()
        }
        task.expirationHandler = { [weak self, operation] in
            operation.cancel()
            Task { @MainActor in self?.cancelActiveRefresh() }
        }
        let outcome = await operation.value
        task.setTaskCompleted(success: outcome != .failed)
    }
}
