import Foundation

/// How often the feed refreshes on its own while the app is on screen.
///
/// iOS suspends the app within seconds of it leaving the foreground, so this
/// only runs during an active session — it is *not* a background scheduler.
/// Closed-app catch-up stays with `BackgroundRefreshManager` (`BGAppRefreshTask`,
/// timed by iOS). Stored as a plain minute count so it is trivial to persist
/// and profile-scoped like the other per-profile settings.
struct AutoRefreshSettings: Equatable {
    /// Minutes between foreground auto-refreshes. `off` (0) disables it.
    var intervalMinutes: Int

    static let off = 0
    /// Offered in the Settings picker, in order. `off` first.
    static let allowedIntervalMinutes = [off, 5, 15, 30, 60]

    private static var key: String {
        LocalProfileStore.defaultsKey("auto_refresh_interval_minutes")
    }

    static func current(defaults: UserDefaults = .standard) -> AutoRefreshSettings {
        let stored = defaults.object(forKey: key) as? Int
        let value = allowedIntervalMinutes.contains(stored ?? -1) ? (stored ?? off) : off
        return AutoRefreshSettings(intervalMinutes: value)
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(intervalMinutes, forKey: Self.key)
    }

    var isEnabled: Bool { intervalMinutes > 0 }

    /// Whether a foreground auto-refresh is due now. A nil `lastRefreshAt`
    /// (nothing refreshed yet this session) counts as due, so returning to the
    /// app after a while refreshes right away instead of waiting a full
    /// interval.
    static func isRefreshDue(intervalMinutes: Int, lastRefreshAt: Date?, now: Date) -> Bool {
        guard intervalMinutes > 0 else { return false }
        guard let lastRefreshAt else { return true }
        return now.timeIntervalSince(lastRefreshAt) >= Double(intervalMinutes) * 60
    }
}
