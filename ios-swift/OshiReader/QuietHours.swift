import Foundation

/// A daily do-not-disturb window for new-item notifications. Stored as
/// minutes-since-midnight (not `Date`) so it's timezone-stable and trivial
/// to persist — the UI converts to/from `Date` only for the time pickers.
struct QuietHoursSettings: Equatable {
    var enabled: Bool
    var startMinuteOfDay: Int
    var endMinuteOfDay: Int

    static let defaultStartMinuteOfDay = 22 * 60
    static let defaultEndMinuteOfDay = 8 * 60

    private static func key(_ suffix: String) -> String {
        LocalProfileStore.defaultsKey("quiet_hours_\(suffix)")
    }

    static func current(defaults: UserDefaults = .standard) -> QuietHoursSettings {
        QuietHoursSettings(
            enabled: defaults.bool(forKey: key("enabled")),
            startMinuteOfDay: defaults.object(forKey: key("start")) as? Int ?? defaultStartMinuteOfDay,
            endMinuteOfDay: defaults.object(forKey: key("end")) as? Int ?? defaultEndMinuteOfDay
        )
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: Self.key("enabled"))
        defaults.set(startMinuteOfDay, forKey: Self.key("start"))
        defaults.set(endMinuteOfDay, forKey: Self.key("end"))
    }

    /// Whether `date` falls within the window. A window where start == end
    /// is treated as disabled (zero-length), and a window that crosses
    /// midnight (e.g. 22:00–08:00) wraps correctly.
    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled, startMinuteOfDay != endMinuteOfDay else { return false }
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        let minuteOfDay = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        if startMinuteOfDay < endMinuteOfDay {
            return minuteOfDay >= startMinuteOfDay && minuteOfDay < endMinuteOfDay
        }
        return minuteOfDay >= startMinuteOfDay || minuteOfDay < endMinuteOfDay
    }

    /// The next moment (today or tomorrow) this window's end time occurs —
    /// used to schedule a single trailing digest notification.
    func nextEndDate(after now: Date, calendar: Calendar = .current) -> Date {
        var comps = calendar.dateComponents([.year, .month, .day], from: now)
        comps.hour = endMinuteOfDay / 60
        comps.minute = endMinuteOfDay % 60
        comps.second = 0
        guard var candidate = calendar.date(from: comps) else { return now.addingTimeInterval(3600) }
        if candidate <= now {
            candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate.addingTimeInterval(86400)
        }
        return candidate
    }

    /// The most recent moment (today or yesterday) this window's start time
    /// occurred at or before `now` — an anchor identifying which continuous
    /// window `now` falls in, stable across the midnight boundary an
    /// overnight window (e.g. 22:00–08:00) crosses.
    func currentWindowStart(before now: Date, calendar: Calendar = .current) -> Date {
        var comps = calendar.dateComponents([.year, .month, .day], from: now)
        comps.hour = startMinuteOfDay / 60
        comps.minute = startMinuteOfDay % 60
        comps.second = 0
        guard var candidate = calendar.date(from: comps) else { return now }
        if candidate > now {
            candidate = calendar.date(byAdding: .day, value: -1, to: candidate) ?? candidate.addingTimeInterval(-86400)
        }
        return candidate
    }
}

/// Accumulates per-keyword new-item counts across a single quiet-hours
/// window so repeated refreshes coalesce into one trailing digest instead
/// of a notification each time. Keyed by the window's start moment (not
/// calendar day) so an overnight window — e.g. 22:00–08:00 — keeps
/// accumulating correctly across the midnight boundary instead of resetting
/// partway through.
struct QuietHoursDigestState: Codable, Equatable {
    var windowStart: TimeInterval
    var countsByKeyword: [String: Int]

    private static var defaultsKey: String { LocalProfileStore.defaultsKey("quiet_hours_digest_state") }

    static func load(defaults: UserDefaults = .standard) -> QuietHoursDigestState? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(QuietHoursDigestState.self, from: data)
    }

    func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }

    /// Merges `newCounts` into whatever was already accumulated for the
    /// window `now` currently falls in, starting fresh if the stored state
    /// belongs to an earlier window (i.e. a previous night's digest already
    /// fired and this is the start of a new one).
    static func accumulating(_ newCounts: [String: Int], settings: QuietHoursSettings, now: Date, defaults: UserDefaults = .standard) -> QuietHoursDigestState {
        let windowStart = settings.currentWindowStart(before: now).timeIntervalSince1970
        var state = load(defaults: defaults).flatMap { $0.windowStart == windowStart ? $0 : nil }
            ?? QuietHoursDigestState(windowStart: windowStart, countsByKeyword: [:])
        for (keyword, count) in newCounts {
            state.countsByKeyword[keyword, default: 0] += count
        }
        return state
    }

    var totalCount: Int {
        countsByKeyword.values.reduce(0, +)
    }
}
