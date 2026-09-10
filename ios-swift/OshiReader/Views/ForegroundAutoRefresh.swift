import SwiftUI
import Combine

/// Refreshes on launch and return from the background. The optional interval
/// controls additional refreshes while the app stays open.
///
/// It is deliberately foreground-only. iOS suspends the timer and the whole
/// process shortly after the app leaves the screen, so this never fires in the
/// background — closed-app catch-up stays with `BackgroundRefreshManager`
/// (`BGAppRefreshTask`, timed by iOS).
struct ForegroundAutoRefresh: ViewModifier {
    /// Owned by the host view so a manual pull-to-refresh resets the interval
    /// too — not just the auto path. `ForegroundAutoRefresh` only reads it;
    /// `performRefresh` is the sole writer.
    let lastRefreshStartedAt: Date?
    let isRefreshing: Bool
    let performRefresh: () async -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var needsOpeningRefresh = true
    /// `@State` so the publisher survives `FeedView.body` rebuilding this
    /// modifier — SwiftUI keeps the first value and discards later initializers,
    /// so the 60s countdown is anchored once instead of restarting on every
    /// re-evaluation.
    @State private var ticker = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

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
                // Temporary inactivity (Control Center, permission prompts)
                // must not count as another app opening.
                if phase == .background { needsOpeningRefresh = true }
                if phase == .active { evaluate() }
            }
            .onChange(of: isRefreshing) { _, refreshing in
                // An in-flight background pass must not swallow the opening
                // refresh. Retry once it releases the coordinator.
                if !refreshing, needsOpeningRefresh { evaluate() }
            }
    }

    private func evaluate() {
        guard scenePhase == .active, !isRefreshing else { return }
        guard !ProcessInfo.processInfo.arguments.contains("--uitesting") else { return }
        guard needsOpeningRefresh || AutoRefreshSettings.isRefreshDue(
            intervalMinutes: AutoRefreshSettings.current().intervalMinutes,
            lastRefreshAt: lastRefreshStartedAt,
            now: Date()
        ) else { return }
        let wasOpeningRefresh = needsOpeningRefresh
        let stampBeforeRefresh = lastRefreshStartedAt
        needsOpeningRefresh = false
        // Don't stamp the interval anchor here — `performRefresh` (refreshFeed)
        // re-checks `isRefreshing` and may no-op. Letting it be the only writer
        // means a skipped run doesn't burn the whole interval.
        Task { @MainActor in
            await performRefresh()
            // `refreshFeed` advances `lastRefreshStartedAt` as its first step
            // unless a background pass held the coordinator and it bailed. If
            // the opening refresh never actually started, re-arm so the
            // `isRefreshing` retry (or the next tick) runs it once free.
            if wasOpeningRefresh, lastRefreshStartedAt == stampBeforeRefresh {
                needsOpeningRefresh = true
                evaluate()
            }
        }
    }
}
