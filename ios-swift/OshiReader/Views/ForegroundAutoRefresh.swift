import SwiftUI
import Combine

/// Drives `AutoRefreshSettings` on the feed: while the app is in the foreground,
/// it checks about once a minute (and again on every return-to-foreground)
/// whether the user's chosen interval has elapsed, and if so runs a refresh.
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
    /// `@State` so the publisher survives `FeedView.body` rebuilding this
    /// modifier — SwiftUI keeps the first value and discards later initializers,
    /// so the 60s countdown is anchored once instead of restarting on every
    /// re-evaluation.
    @State private var ticker = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    func body(content: Content) -> some View {
        content
            // `.onReceive`'s action closure IS refreshed on every body pass, so
            // `evaluate()` always sees the current `isRefreshing` /
            // `lastRefreshStartedAt` — unlike a `.task`, whose closure would
            // capture them once at first appearance.
            .onReceive(ticker) { _ in evaluate() }
            .onChange(of: scenePhase) { _, phase in
                // Returning after a while: check now instead of waiting up to a
                // minute for the next tick.
                if phase == .active { evaluate() }
            }
    }

    private func evaluate() {
        guard scenePhase == .active, !isRefreshing else { return }
        guard !ProcessInfo.processInfo.arguments.contains("--uitesting") else { return }
        guard AutoRefreshSettings.isRefreshDue(
            intervalMinutes: AutoRefreshSettings.current().intervalMinutes,
            lastRefreshAt: lastRefreshStartedAt,
            now: Date()
        ) else { return }
        // Don't stamp the interval anchor here — `performRefresh` (refreshFeed)
        // re-checks `isRefreshing` and may no-op. Letting it be the only writer
        // means a skipped run doesn't burn the whole interval.
        Task { await performRefresh() }
    }
}
