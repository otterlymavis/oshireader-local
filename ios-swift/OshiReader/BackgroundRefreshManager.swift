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
    // This is an earliest eligibility hint, not a guaranteed polling interval.
    static let minimumInterval: TimeInterval = 5 * 60
    private static let operationDeadline: TimeInterval = 25

    // The OS task identifier is app-wide, so its scheduling hint must survive
    // process relaunches and profile switches without belonging to one profile.
    private static let earliestBeginDateDefaultsKey = "background_refresh.earliest_begin_date"
    private let schedulingDefaults: UserDefaults
    private let schedulingNow: () -> Date
    private let submitRefreshRequest: (BGAppRefreshTaskRequest) throws -> Void

    init(
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = { Date() },
        submit: @escaping (BGAppRefreshTaskRequest) throws -> Void = {
            try BGTaskScheduler.shared.submit($0)
        }
    ) {
        schedulingDefaults = defaults
        schedulingNow = now
        submitRefreshRequest = submit
    }

    private static let lastCompletedAtDefaultsKey = LocalProfileStore.defaultsKey("background_refresh.last_completed_at")

    static var lastCompletedAt: Date? {
        let timestamp = UserDefaults.standard.double(forKey: lastCompletedAtDefaultsKey)
        return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
    }

    /// Stamps "the background task actually ran" independently of whether it
    /// found anything to do — a foreground refresh covering the wake (below)
    /// still means iOS invoked the task, so it must count too, not just the
    /// path that reaches `LocalRefreshCoordinator.refreshIfIdle`.
    private static func recordCompletion() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCompletedAtDefaultsKey)
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

    func schedule(afterTaskLaunch: Bool = false) {
        let nextEligibility = schedulingNow().addingTimeInterval(Self.minimumInterval)
        let savedTimestamp = schedulingDefaults.double(forKey: Self.earliestBeginDateDefaultsKey)
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        if !afterTaskLaunch, savedTimestamp.isFinite, savedTimestamp > 0 {
            // Reopening or backgrounding the app must not push an existing
            // opportunity later. An overdue date remains eligible immediately.
            request.earliestBeginDate = min(Date(timeIntervalSince1970: savedTimestamp), nextEligibility)
        } else {
            // An actual BG task launch consumes its request. Queue a fresh
            // opportunity before starting work, even if this run later expires.
            request.earliestBeginDate = nextEligibility
        }
        do {
            // Submitting the same refresh identifier replaces its pending
            // request; do not cancel first, so a failed submission leaves the
            // existing request queued. Always submit synchronously: the saved
            // date is only a hint, and iOS may have dropped the previous request.
            // An async pending-request lookup can be suspended before submission.
            try submitRefreshRequest(request)
            schedulingDefaults.set(
                request.earliestBeginDate?.timeIntervalSince1970,
                forKey: Self.earliestBeginDateDefaultsKey
            )
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
            Self.recordCompletion()
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
        Self.recordCompletion()
        guard result.succeeded else { return .failed }
        return result.addedCount > 0 ? .newData : .noData
    }

    private func cancelActiveRefresh() {
        LocalRefreshCoordinator.shared.cancel()
    }

    private func handle(_ task: BGAppRefreshTask) async {
        // Queue the next opportunity before starting network work. If iOS
        // expires or terminates this run, a future refresh remains pending.
        schedule(afterTaskLaunch: true)
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
