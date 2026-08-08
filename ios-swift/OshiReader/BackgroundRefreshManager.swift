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

/// Keeps the local-only feed useful when the app has not been opened recently.
/// iOS decides the exact execution time; this is a best-effort refresh, not a
/// replacement for a server scheduler.
@MainActor
final class BackgroundRefreshManager {
    static let shared = BackgroundRefreshManager()
    static let taskIdentifier = "com.otterpia.oshireader.feed-refresh"
    static let minimumInterval: TimeInterval = 30 * 60
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
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
            try BGTaskScheduler.shared.submit(request)
        } catch {
            AppLogger.network.warning("Background refresh scheduling failed: \(error.localizedDescription)")
        }
    }

    func refreshNow() async -> Bool {
        guard !ProcessInfo.processInfo.arguments.contains("--uitesting") else { return false }
        let waiter = BackgroundRefreshWaiter()
        let worker = Task { @MainActor in
            let result = await LocalRefreshCoordinator.shared.refreshIfIdle(.background)
                ?? LocalRefreshResult(completion: .cancelled, addedCount: 0, sourceStatuses: [], customRefreshCompleted: false)
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
        let result = await waiter.wait()
        timeout.cancel()
        if result.completion == .expired {
            LocalRefreshCoordinator.shared.cancel()
            worker.cancel()
            return false
        }
        guard result.completion == .completed else { return false }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: LocalProfileStore.defaultsKey("background_refresh.last_completed_at"))
        return result.succeeded
    }

    private func cancelActiveRefresh() {
        LocalRefreshCoordinator.shared.cancel()
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
