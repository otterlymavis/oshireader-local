import SwiftUI

/// Drives `AutoRefreshSettings` on the feed: while the app is in the foreground,
/// it checks once a minute (and again on every return-to-foreground) whether the
/// user's chosen interval has elapsed, and if so runs a refresh.
///
/// It is deliberately foreground-only. iOS suspends both the timer and the whole
/// process shortly after the app leaves the screen, so this never fires in the
/// background — closed-app catch-up stays with `BackgroundRefreshManager`
/// (`BGAppRefreshTask`, timed by iOS).
struct ForegroundAutoRefresh: ViewModifier {
    /// Owned by the host view so a manual pull-to-refresh can reset the interval
    /// too — not just the auto path.
    @Binding var lastRefreshStartedAt: Date?
    let isRefreshing: Bool
    let performRefresh: () async -> Void

    @Environment(\.scenePhase) private var scenePhase
    private let tick = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    func body(content: Content) -> some View {
        content
            .onReceive(tick) { _ in evaluate() }
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
        lastRefreshStartedAt = Date()
        Task { await performRefresh() }
    }
}
