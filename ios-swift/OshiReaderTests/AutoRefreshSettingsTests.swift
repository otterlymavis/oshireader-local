import XCTest
@testable import OshiReader

final class AutoRefreshSettingsTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testDisabledIntervalIsNeverDue() {
        XCTAssertFalse(AutoRefreshSettings.isRefreshDue(intervalMinutes: 0, lastRefreshAt: nil, now: now))
        XCTAssertFalse(AutoRefreshSettings.isRefreshDue(
            intervalMinutes: 0,
            lastRefreshAt: now.addingTimeInterval(-3600),
            now: now
        ))
    }

    func testNoPriorRefreshIsDueImmediately() {
        XCTAssertTrue(AutoRefreshSettings.isRefreshDue(intervalMinutes: 15, lastRefreshAt: nil, now: now))
    }

    func testNotDueBeforeIntervalElapses() {
        XCTAssertFalse(AutoRefreshSettings.isRefreshDue(
            intervalMinutes: 15,
            lastRefreshAt: now.addingTimeInterval(-14 * 60),
            now: now
        ))
    }

    func testDueOnceIntervalElapses() {
        XCTAssertTrue(AutoRefreshSettings.isRefreshDue(
            intervalMinutes: 15,
            lastRefreshAt: now.addingTimeInterval(-15 * 60),
            now: now
        ))
        XCTAssertTrue(AutoRefreshSettings.isRefreshDue(
            intervalMinutes: 5,
            lastRefreshAt: now.addingTimeInterval(-42 * 60),
            now: now
        ))
    }

    func testCurrentClampsUnknownStoredValueToOff() {
        let defaults = UserDefaults(suiteName: "AutoRefreshSettingsTests.clamp")!
        defaults.removePersistentDomain(forName: "AutoRefreshSettingsTests.clamp")
        defer { defaults.removePersistentDomain(forName: "AutoRefreshSettingsTests.clamp") }

        AutoRefreshSettings(intervalMinutes: 15).save(defaults: defaults)
        XCTAssertEqual(AutoRefreshSettings.current(defaults: defaults).intervalMinutes, 15)

        AutoRefreshSettings(intervalMinutes: 7).save(defaults: defaults)
        XCTAssertEqual(
            AutoRefreshSettings.current(defaults: defaults).intervalMinutes,
            AutoRefreshSettings.off,
            "a value outside allowedIntervalMinutes falls back to off"
        )
    }

    func testAllowedIntervalsStartWithOff() {
        XCTAssertEqual(AutoRefreshSettings.allowedIntervalMinutes.first, AutoRefreshSettings.off)
        XCTAssertEqual(AutoRefreshSettings.allowedIntervalMinutes, [0, 5, 15, 30, 60])
    }
}
