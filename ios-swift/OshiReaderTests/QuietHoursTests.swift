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

    func testQuietHoursDigestStateAccumulatesAcrossCallsSameDayAndResetsOnNewDay() throws {
        let suiteName = "QuietHoursDigestTest-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let day1 = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-01T20:00:00Z"))
        let firstState = QuietHoursDigestState.accumulating(["Oshi A": 2], now: day1, defaults: defaults)
        firstState.save(defaults: defaults)
        XCTAssertEqual(firstState.totalCount, 2)

        let secondState = QuietHoursDigestState.accumulating(
            ["Oshi A": 1, "Oshi B": 3],
            now: day1.addingTimeInterval(3600),
            defaults: defaults
        )
        XCTAssertEqual(secondState.countsByKeyword["Oshi A"], 3)
        XCTAssertEqual(secondState.countsByKeyword["Oshi B"], 3)
        XCTAssertEqual(secondState.totalCount, 6)
        secondState.save(defaults: defaults)

        let nextDay = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-02T20:00:00Z"))
        let thirdState = QuietHoursDigestState.accumulating(["Oshi C": 1], now: nextDay, defaults: defaults)
        XCTAssertEqual(thirdState.totalCount, 1, "a new calendar day should reset the accumulator")
    }
}
