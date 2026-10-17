import XCTest
import BackgroundTasks
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

final class BackgroundRefreshSchedulingTests: XCTestCase {
    private let launchTime = Date(timeIntervalSince1970: 1_700_000_000)

    private enum SubmissionError: Error {
        case unavailable
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "BackgroundRefreshSchedulingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    @MainActor
    func testFirstOpportunityIsSubmittedSynchronouslyWithFiveMinuteEligibility() {
        var submitted = [BGAppRefreshTaskRequest]()
        let manager = BackgroundRefreshManager(
            defaults: isolatedDefaults(),
            now: { self.launchTime },
            submit: { submitted.append($0) }
        )

        manager.schedule()

        XCTAssertEqual(submitted.count, 1, "Submission must finish before the app can be suspended")
        XCTAssertEqual(submitted.first?.identifier, BackgroundRefreshManager.taskIdentifier)
        XCTAssertEqual(submitted.first?.earliestBeginDate, launchTime.addingTimeInterval(5 * 60))
    }

    @MainActor
    func testRepeatedAppOpeningsDoNotPostponePendingOpportunity() {
        var now = launchTime
        var submitted = [BGAppRefreshTaskRequest]()
        let manager = BackgroundRefreshManager(
            defaults: isolatedDefaults(),
            now: { now },
            submit: { submitted.append($0) }
        )

        manager.schedule()
        now = launchTime.addingTimeInterval(2 * 60)
        manager.schedule()
        now = launchTime.addingTimeInterval(4 * 60)
        manager.schedule()

        XCTAssertEqual(submitted.count, 3)
        XCTAssertEqual(submitted.map(\.earliestBeginDate), Array(repeating: launchTime.addingTimeInterval(5 * 60), count: 3))
    }

    @MainActor
    func testRelaunchPreservesEarlierOpportunity() {
        let defaults = isolatedDefaults()
        var submitted = [BGAppRefreshTaskRequest]()
        BackgroundRefreshManager(
            defaults: defaults,
            now: { self.launchTime },
            submit: { submitted.append($0) }
        ).schedule()

        let relaunched = BackgroundRefreshManager(
            defaults: defaults,
            now: { self.launchTime.addingTimeInterval(3 * 60) },
            submit: { submitted.append($0) }
        )
        relaunched.schedule()

        XCTAssertEqual(submitted.count, 2)
        XCTAssertEqual(submitted.last?.earliestBeginDate, launchTime.addingTimeInterval(5 * 60))
    }

    @MainActor
    func testDroppedSystemRequestIsRecreatedWithoutDelayingOverdueEligibility() throws {
        let defaults = isolatedDefaults()
        var submitted = [BGAppRefreshTaskRequest]()
        BackgroundRefreshManager(
            defaults: defaults,
            now: { self.launchTime },
            submit: { submitted.append($0) }
        ).schedule()

        // The system queue may disappear independently of the saved hint.
        submitted.removeAll()
        let now = launchTime.addingTimeInterval(60 * 60)
        let relaunched = BackgroundRefreshManager(
            defaults: defaults,
            now: { now },
            submit: { submitted.append($0) }
        )
        relaunched.schedule()

        XCTAssertEqual(submitted.count, 1, "A saved hint must never suppress submission")
        XCTAssertEqual(submitted.first?.earliestBeginDate, launchTime.addingTimeInterval(5 * 60))
        XCTAssertLessThan(try XCTUnwrap(submitted.first?.earliestBeginDate), now)
    }

    @MainActor
    func testActualTaskLaunchQueuesFreshOpportunityAndLaterLifecyclePreservesIt() {
        var now = launchTime
        var submitted = [BGAppRefreshTaskRequest]()
        let manager = BackgroundRefreshManager(
            defaults: isolatedDefaults(),
            now: { now },
            submit: { submitted.append($0) }
        )
        manager.schedule()

        now = launchTime.addingTimeInterval(20 * 60)
        manager.schedule(afterTaskLaunch: true)
        now = launchTime.addingTimeInterval(21 * 60)
        manager.schedule()

        XCTAssertEqual(submitted.map(\.earliestBeginDate), [
            launchTime.addingTimeInterval(5 * 60),
            launchTime.addingTimeInterval(25 * 60),
            launchTime.addingTimeInterval(25 * 60)
        ])
    }

    @MainActor
    func testFailedInitialSubmissionDoesNotLeaveAnUnsubmittedSchedulingHint() {
        let defaults = isolatedDefaults()
        let unavailable = BackgroundRefreshManager(
            defaults: defaults,
            now: { self.launchTime },
            submit: { _ in throw SubmissionError.unavailable }
        )
        unavailable.schedule()

        var submitted = [BGAppRefreshTaskRequest]()
        let recovered = BackgroundRefreshManager(
            defaults: defaults,
            now: { self.launchTime.addingTimeInterval(2 * 60) },
            submit: { submitted.append($0) }
        )
        recovered.schedule()

        XCTAssertEqual(submitted.first?.earliestBeginDate, launchTime.addingTimeInterval(7 * 60))
    }

    @MainActor
    func testFailedReplacementAfterTaskLaunchKeepsEarlierHintForImmediateRetry() {
        let defaults = isolatedDefaults()
        var now = launchTime
        var shouldFail = false
        var submitted = [BGAppRefreshTaskRequest]()
        let manager = BackgroundRefreshManager(
            defaults: defaults,
            now: { now },
            submit: {
                if shouldFail { throw SubmissionError.unavailable }
                submitted.append($0)
            }
        )
        manager.schedule()

        now = launchTime.addingTimeInterval(20 * 60)
        shouldFail = true
        manager.schedule(afterTaskLaunch: true)

        shouldFail = false
        let recovered = BackgroundRefreshManager(defaults: defaults, now: { now }, submit: { submitted.append($0) })
        recovered.schedule()

        XCTAssertEqual(submitted.count, 2)
        XCTAssertEqual(submitted.last?.earliestBeginDate, launchTime.addingTimeInterval(5 * 60))
    }

    @MainActor
    func testClockMovingBackwardsDoesNotRetainAnExcessivelyDistantOpportunity() {
        var now = launchTime
        var submitted = [BGAppRefreshTaskRequest]()
        let manager = BackgroundRefreshManager(
            defaults: isolatedDefaults(),
            now: { now },
            submit: { submitted.append($0) }
        )
        manager.schedule()

        now = launchTime.addingTimeInterval(-60 * 60)
        manager.schedule()

        XCTAssertEqual(submitted.last?.earliestBeginDate, now.addingTimeInterval(5 * 60))
    }
}
