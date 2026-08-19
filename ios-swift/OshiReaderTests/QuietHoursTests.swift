import XCTest
import SwiftUI
import UIKit
import UserNotifications
@testable import OshiReader

final class QuietHoursTests: XCTestCase {

    private var db: LocalDB!

    override func setUpWithError() throws {
        try super.setUpWithError()
        db = LocalDB.shared
        db.terms.removeAll()
        db.feedItems.removeAll()
        db.savedPages.removeAll()
        db.customUrls.removeAll()
        db.amebloBlogs.removeAll()
        db.hiddenItems.removeAll()
        db.compositions.removeAll()
        db.setSubscribedPlatforms(platforms: ["news", "tver", "youtube", "yahoonews", "custom"])
    }

    override func tearDownWithError() throws {
        db = nil
        try super.tearDownWithError()
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func utcDate(_ calendar: Calendar, _ hour: Int, _ minute: Int, day: Int = 1) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 1, day: day, hour: hour, minute: minute))!
    }

    func testQuietHoursContainsHandlesOvernightWrap() throws {
        let calendar = utcCalendar()
        let overnight = QuietHoursSettings(enabled: true, startMinuteOfDay: 22 * 60, endMinuteOfDay: 8 * 60)
        XCTAssertTrue(overnight.contains(utcDate(calendar, 23, 30), calendar: calendar))
        XCTAssertTrue(overnight.contains(utcDate(calendar, 2, 0), calendar: calendar))
        XCTAssertTrue(overnight.contains(utcDate(calendar, 7, 59), calendar: calendar))
        XCTAssertFalse(overnight.contains(utcDate(calendar, 8, 0), calendar: calendar))
        XCTAssertFalse(overnight.contains(utcDate(calendar, 12, 0), calendar: calendar))
        XCTAssertFalse(overnight.contains(utcDate(calendar, 21, 59), calendar: calendar))
    }

    func testQuietHoursContainsSameDayWindow() throws {
        let calendar = utcCalendar()
        let daytime = QuietHoursSettings(enabled: true, startMinuteOfDay: 13 * 60, endMinuteOfDay: 14 * 60)
        XCTAssertTrue(daytime.contains(utcDate(calendar, 13, 30), calendar: calendar))
        XCTAssertFalse(daytime.contains(utcDate(calendar, 14, 0), calendar: calendar))
        XCTAssertFalse(daytime.contains(utcDate(calendar, 12, 59), calendar: calendar))
    }

    func testQuietHoursDisabledOrZeroLengthNeverContains() throws {
        let calendar = utcCalendar()
        let now = utcDate(calendar, 23, 0)
        let disabled = QuietHoursSettings(enabled: false, startMinuteOfDay: 22 * 60, endMinuteOfDay: 8 * 60)
        XCTAssertFalse(disabled.contains(now, calendar: calendar))
        let zeroLength = QuietHoursSettings(enabled: true, startMinuteOfDay: 9 * 60, endMinuteOfDay: 9 * 60)
        XCTAssertFalse(zeroLength.contains(now, calendar: calendar))
    }

    func testQuietHoursNextEndDateAdvancesToTomorrowOnlyWhenAlreadyPast() throws {
        let calendar = utcCalendar()
        let settings = QuietHoursSettings(enabled: true, startMinuteOfDay: 22 * 60, endMinuteOfDay: 8 * 60)

        // 23:00 on day 1 — 08:00 has already passed today, so the next
        // occurrence is tomorrow morning.
        let lateNight = utcDate(calendar, 23, 0)
        let expectedNextMorning = utcDate(calendar, 8, 0, day: 2)
        XCTAssertEqual(settings.nextEndDate(after: lateNight, calendar: calendar), expectedNextMorning)

        // 07:00 on day 1 — 08:00 is still ahead of us today.
        let earlyMorning = utcDate(calendar, 7, 0)
        let expectedSameMorning = utcDate(calendar, 8, 0)
        XCTAssertEqual(settings.nextEndDate(after: earlyMorning, calendar: calendar), expectedSameMorning)
    }

    func testQuietHoursDigestStateAccumulatesAcrossCallsWithinSameWindow() throws {
        let suiteName = "QuietHoursDigestTest-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = QuietHoursSettings(enabled: true, startMinuteOfDay: 22 * 60, endMinuteOfDay: 8 * 60)
        let calendar = utcCalendar()
        let firstMoment = utcDate(calendar, 22, 30)

        let firstState = QuietHoursDigestState.accumulating(["Oshi A": 2], settings: settings, now: firstMoment, defaults: defaults)
        firstState.save(defaults: defaults)
        XCTAssertEqual(firstState.totalCount, 2)

        let secondState = QuietHoursDigestState.accumulating(
            ["Oshi A": 1, "Oshi B": 3],
            settings: settings,
            now: firstMoment.addingTimeInterval(3600),
            defaults: defaults
        )
        XCTAssertEqual(secondState.countsByKeyword["Oshi A"], 3)
        XCTAssertEqual(secondState.countsByKeyword["Oshi B"], 3)
        XCTAssertEqual(secondState.totalCount, 6)
    }

    /// Regression test: an overnight window (22:00–08:00) crosses midnight,
    /// so the accumulator must key off the window's start moment, not the
    /// calendar day — otherwise counts from before midnight are silently
    /// dropped the moment a refresh lands after 00:00, even though it's
    /// still the same continuous quiet-hours window.
    func testQuietHoursDigestStateSurvivesMidnightWithinSameWindowAndResetsForNewWindow() throws {
        let suiteName = "QuietHoursDigestTest-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = QuietHoursSettings(enabled: true, startMinuteOfDay: 22 * 60, endMinuteOfDay: 8 * 60)
        let calendar = utcCalendar()

        // 23:30 on day 1 — inside the first overnight window.
        let beforeMidnight = utcDate(calendar, 23, 30)
        let firstState = QuietHoursDigestState.accumulating(["Oshi A": 2], settings: settings, now: beforeMidnight, defaults: defaults)
        firstState.save(defaults: defaults)

        // 02:00 on day 2 — still the SAME window (hasn't hit 08:00 yet), so
        // this must add to the existing total, not reset it.
        let afterMidnight = utcDate(calendar, 2, 0, day: 2)
        let secondState = QuietHoursDigestState.accumulating(["Oshi B": 3], settings: settings, now: afterMidnight, defaults: defaults)
        XCTAssertEqual(secondState.totalCount, 5, "counts from before midnight must survive into the same overnight window")
        secondState.save(defaults: defaults)

        // 23:00 on day 2 — the previous window already ended at 08:00, so
        // this is a genuinely new window and must start fresh.
        let nextWindow = utcDate(calendar, 23, 0, day: 2)
        let thirdState = QuietHoursDigestState.accumulating(["Oshi C": 1], settings: settings, now: nextWindow, defaults: defaults)
        XCTAssertEqual(thirdState.totalCount, 1, "a new quiet-hours window should reset the accumulator")
    }
}
