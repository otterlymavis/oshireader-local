import SwiftUI
import Combine

/// Refreshes on launch and on returning from the background. The optional
/// interval controls additional refreshes while the app stays open.
///
/// It is deliberately foreground-only. iOS suspends the timer and the whole
/// process shortly after the app leaves the screen, so this never fires in the
/// background — closed-app catch-up stays with `BackgroundRefreshManager`
/// (`BGAppRefreshTask`, timed by iOS).
struct ForegroundAutoRefresh: ViewModifier {
    /// Owned by the host view so a manual pull-to-refresh resets the interval
    /// too — not just the auto path. `ForegroundAutoRefresh` only reads it;
    /// `performRefresh` is the sole writer. `nil` means no foreground refresh
    /// has run this session yet, which is also how the opening refresh is
    /// recognised — keeping that signal in the host's state (not this
    /// modifier's `@State`) means tearing the modifier down and rebuilding it
    /// doesn't re-arm an unthrottled refresh.
    let lastRefreshStartedAt: Date?
    let isRefreshing: Bool
    let performRefresh: () async -> Void

    /// A return from the background refreshes only if this much time has passed
    /// since the last refresh, so flicking between apps (or a Home-bar peek)
    /// doesn't run a full ingestion pass every time — the throttle the
    /// user-configurable interval can't provide when it's set to off.
    private let backgroundReturnMinimumGap: TimeInterval = 60

    @Environment(\.scenePhase) private var scenePhase
    /// Set while the app is actually backgrounded (not merely `.inactive` for
    /// Control Center / a permission alert), so only a real background→active
    /// round trip counts as a return from the background.
    @State private var didEnterBackground = false
    /// `@State` so the publisher survives `FeedView.body` rebuilding this
    /// modifier — SwiftUI keeps the first value and discards later initializers,
    /// so the 60s countdown is anchored once instead of restarting on every
    /// re-evaluation.
    @State private var ticker = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private var needsOpeningRefresh: Bool { lastRefreshStartedAt == nil }

    func body(content: Content) -> some View {
        content
            // A cold launch can begin with `scenePhase == .active`, so there is
            // no phase transition for `onChange` to observe. Evaluate on first
            // appearance as well, independently of the repeating interval.
            .onAppear { evaluate() }
            // `.onReceive`'s action closure IS refreshed on every body pass, so
            // `evaluate()` always sees the current `isRefreshing` /
            // `lastRefreshStartedAt` — unlike a `.task`, whose closure would
            // capture them once at first appearance.
            .onReceive(ticker) { _ in evaluate() }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background:
                    didEnterBackground = true
                case .active:
                    let returnedFromBackground = didEnterBackground
                    didEnterBackground = false
                    evaluate(returnedFromBackground: returnedFromBackground)
                default:
                    break
                }
            }
            .onChange(of: isRefreshing) { _, refreshing in
                // An in-flight background pass must not swallow the opening
                // refresh. Retry once it releases the coordinator.
                if !refreshing, needsOpeningRefresh { evaluate() }
            }
    }

    private func evaluate(returnedFromBackground: Bool = false) {
        guard scenePhase == .active, !isRefreshing else { return }
        guard !ProcessInfo.processInfo.arguments.contains("--uitesting") else { return }
        guard shouldRefresh(returnedFromBackground: returnedFromBackground) else { return }
        let wasOpeningRefresh = needsOpeningRefresh
        // Don't stamp the interval anchor here — `performRefresh` (refreshFeed)
        // re-checks `isRefreshing` and may no-op. Letting it be the only writer
        // means a skipped run doesn't burn the whole interval.
        Task { @MainActor in
            await performRefresh()
            // `refreshFeed` advances `lastRefreshStartedAt` as its first step
            // unless a background pass held the coordinator and it bailed. If
            // the opening refresh never actually started, retry so the
            // `isRefreshing` change (or the next tick) runs it once free.
            if wasOpeningRefresh, needsOpeningRefresh {
                evaluate()
            }
        }
    }

    private func shouldRefresh(returnedFromBackground: Bool) -> Bool {
        if needsOpeningRefresh { return true }
        let now = Date()
        if returnedFromBackground {
            guard let lastRefreshStartedAt else { return true }
            if now.timeIntervalSince(lastRefreshStartedAt) >= backgroundReturnMinimumGap {
                return true
            }
        }
        return AutoRefreshSettings.isRefreshDue(
            intervalMinutes: AutoRefreshSettings.current().intervalMinutes,
            lastRefreshAt: lastRefreshStartedAt,
            now: now
        )
    }
}
