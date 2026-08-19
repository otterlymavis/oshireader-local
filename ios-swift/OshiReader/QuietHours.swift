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
}

/// Accumulates per-keyword new-item counts across a single quiet-hours
/// window so repeated refreshes coalesce into one trailing digest instead
/// of a notification each time. Resets whenever the calendar day changes,
/// since a quiet-hours window is nightly.
struct QuietHoursDigestState: Codable, Equatable {
    var day: String
    var countsByKeyword: [String: Int]

    private static var defaultsKey: String { LocalProfileStore.defaultsKey("quiet_hours_digest_state") }
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

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

    static func dayString(for date: Date) -> String {
        dayFormatter.string(from: date)
    }

    /// Merges `newCounts` into whatever was already accumulated today,
    /// starting fresh if the stored state is from an earlier day.
    static func accumulating(_ newCounts: [String: Int], now: Date, defaults: UserDefaults = .standard) -> QuietHoursDigestState {
        let today = dayString(for: now)
        var state = load(defaults: defaults).flatMap { $0.day == today ? $0 : nil }
            ?? QuietHoursDigestState(day: today, countsByKeyword: [:])
        for (keyword, count) in newCounts {
            state.countsByKeyword[keyword, default: 0] += count
        }
        return state
    }

    var totalCount: Int {
        countsByKeyword.values.reduce(0, +)
    }
}
