import XCTest
@testable import OshiReader

private actor PaidNotificationOperationGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

final class PaidPushTests: XCTestCase {
    private func backendTerm(
        id: Int,
        keyword: String,
        notifyOnNew: Bool = false
    ) -> BackendWatchTerm {
        BackendWatchTerm(
            id: id,
            keyword: keyword,
            aliases: [],
            collection_mode: WatchTerm.allInfoCollectionMode,
            source_mode: SourceMode.all.rawValue,
            selected_platforms: [],
            is_active: true,
            notify_on_new: notifyOnNew,
            refresh_tier: "standard",
            created_at: "2026-08-26T00:00:00Z"
        )
    }

    private func feedItem(id: String = "news:hosted-1", keyword: String = "Aiko") -> FeedItem {
        FeedItem(
            id: id,
            platform: "news",
            url: "https://example.com/\(id)",
            title: "\(keyword) update",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "article",
            published_at: "2026-08-26T00:00:00Z",
            watch_term_keyword: keyword,
            fetched_at: "2026-08-26T00:00:00Z"
        )
    }

    func testPaidPushNotificationCategoryMatchesBackendContract() {
        XCTAssertEqual(NotificationManager.categoryIdentifier, "OSHI_RESULT_PREVIEW")
    }

    @MainActor
    func testPaidPushCatalogAvailabilityUsesNonemptyConfiguredIDs() {
        XCTAssertTrue(PlusStore.parseProductIDs("  ").isEmpty)
        XCTAssertEqual(
            PlusStore.parseProductIDs("local.basic.monthly, local.pro.annual"),
            ["local.basic.monthly", "local.pro.annual"]
        )
    }

    @MainActor
    func testOneWatchWordPlanUsesOnlyTheLifetimeProduct() {
        XCTAssertTrue(
            PlusStore.isOneWatchWordPlan(productID: "com.otterpia.oshireader.hosted.lifetime")
        )
        XCTAssertFalse(
            PlusStore.isOneWatchWordPlan(productID: "com.otterpia.oshireader.hosted.monthly")
        )
        XCTAssertFalse(PlusStore.isOneWatchWordPlan(productID: "unconfigured.product"))
    }

    func testProductLoadingRetriesAreBounded() {
        XCTAssertTrue(ProductLoadRetryPolicy.shouldRetry(afterAttempt: 1))
        XCTAssertTrue(ProductLoadRetryPolicy.shouldRetry(afterAttempt: 2))
        XCTAssertFalse(ProductLoadRetryPolicy.shouldRetry(afterAttempt: 3))
    }

    @MainActor
    func testNewestEntitlementRequestGenerationRemainsAuthoritative() {
        var gate = PaidEntitlementRequestGate()
        let olderInactive = gate.beginRequest()
        let newerActive = gate.beginRequest()
        var entitlementIsActive = false

        if gate.isCurrent(newerActive) {
            entitlementIsActive = true
        }
        if gate.isCurrent(olderInactive) {
            entitlementIsActive = false
        }

        XCTAssertTrue(entitlementIsActive)
        XCTAssertFalse(gate.isCurrent(olderInactive))
        XCTAssertTrue(gate.isCurrent(newerActive))
    }

    func testEntitlementStatusDecodesSelectionRequiredAndUsage() throws {
        let data = Data(
            """
            {
              "is_active": true,
              "product_id": "configured.tier",
              "expires_at": null,
              "push_term_limit": 2,
              "push_term_count": 3,
              "push_delivery_state": "selection_required"
            }
            """.utf8
        )

        let status = try JSONDecoder().decode(EntitlementStatus.self, from: data)

        XCTAssertEqual(status.push_term_limit, 2)
        XCTAssertEqual(status.push_term_count, 3)
        XCTAssertEqual(status.push_delivery_state, .selectionRequired)
        XCTAssertNil(status.expires_at)
    }

    func testLegacyEntitlementStatusGetsCompatibleDeliveryDefaults() throws {
        let data = Data("{\"is_active\":true,\"product_id\":null,\"expires_at\":null}".utf8)

        let status = try JSONDecoder().decode(EntitlementStatus.self, from: data)

        XCTAssertEqual(status.push_term_limit, 0)
        XCTAssertEqual(status.push_term_count, 0)
        XCTAssertEqual(status.push_delivery_state, .active)
    }

    @MainActor
    func testBackendSyncRetainsInactivePushBindingButDropsOrdinaryInactiveTerm() {
        let active = WatchTerm(id: "active", keyword: "Active", is_active: true)
        let inactivePush = WatchTerm(id: "push", keyword: "Push", is_active: false)
        let inactiveLocal = WatchTerm(id: "local", keyword: "Local", is_active: false)

        let selected = PaidBackendFeedCoordinator.termsForBackendSync(
            [active, inactivePush, inactiveLocal],
            pushBoundLocalIDs: [inactivePush.id]
        )

        XCTAssertEqual(selected.map(\.id), [active.id, inactivePush.id])
    }

    @MainActor
    func testRegistryCountsBindingsAcrossProfilesAndRejectsDuplicateKeyword() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = PushTermRegistry(directory: directory)
        let firstProfile = UUID()
        let secondProfile = UUID()
        registry.add(
            PushTermBinding(
                profileID: firstProfile,
                localTermID: "one",
                backendTermID: 101,
                keyword: "Shared Oshi"
            )
        )

        XCTAssertEqual(registry.usedSlotCount, 1)
        XCTAssertEqual(
            registry.conflictingBinding(
                keyword: "shared oshi",
                excludingProfileID: secondProfile,
                localTermID: "two"
            )?.backendTermID,
            101
        )
    }

    @MainActor
    func testFailedDeleteOperationPersistsForRetry() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binding = PushTermBinding(
            profileID: UUID(),
            localTermID: "delete-me",
            backendTermID: 202,
            keyword: "Delete Oshi"
        )
        let registry = PushTermRegistry(directory: directory)
        registry.add(binding)
        registry.enqueueDelete(binding)

        let reloaded = PushTermRegistry(directory: directory)

        XCTAssertTrue(reloaded.bindings.isEmpty)
        XCTAssertEqual(reloaded.pendingOperations.map(\.backendTermID), [202])
    }

    func testPendingNotificationActionsAppearOnlyForBackendBoundTerms() {
        XCTAssertTrue(PaidNotificationControlPolicy.showsPendingActions(backendTermID: 42))
        XCTAssertFalse(PaidNotificationControlPolicy.showsPendingActions(backendTermID: nil))
    }

    @MainActor
    func testNotifyPendingRequiresSuccessfulPaidAndAPNSPreflight() async {
        var registrationChecks = 0
        var triggerCalls = 0
        let coordinator = PushSyncCoordinator(
            triggerPending: { _, _ in
                triggerCalls += 1
                return BackendNotificationDelivery(term_id: 42, keyword: "Aiko", count: 1, cleared: true)
            },
            clearPending: { _, _ in },
            ensureRemoteRegistration: { _ in
                registrationChecks += 1
                return false
            },
            hasActiveEntitlement: { true },
            pushDeliveryState: { .active },
            refreshEntitlement: {}
        )
        let term = WatchTerm(id: "local-42", keyword: "Aiko", backendTermID: 42)

        await coordinator.notifyPendingNow(for: term)

        XCTAssertEqual(registrationChecks, 1)
        XCTAssertEqual(triggerCalls, 0)
        XCTAssertEqual(
            coordinator.errorMessage,
            I18nManager.shared.t("paidPushRegistrationUnavailable")
        )
        XCTAssertNil(coordinator.manualOperationTermID)
    }

    @MainActor
    func testNotifyPendingDoesNotPreflightOrRequestWhilePaidDeliveryIsPaused() async {
        var registrationChecks = 0
        var triggerCalls = 0
        let coordinator = PushSyncCoordinator(
            triggerPending: { _, _ in
                triggerCalls += 1
                return BackendNotificationDelivery(term_id: 42, keyword: "Aiko", count: 1, cleared: true)
            },
            clearPending: { _, _ in },
            ensureRemoteRegistration: { _ in
                registrationChecks += 1
                return true
            },
            hasActiveEntitlement: { false },
            pushDeliveryState: { .inactive },
            refreshEntitlement: {}
        )

        await coordinator.notifyPendingNow(
            for: WatchTerm(id: "paused", keyword: "Aiko", backendTermID: 42)
        )

        XCTAssertEqual(registrationChecks, 0)
        XCTAssertEqual(triggerCalls, 0)
        XCTAssertEqual(coordinator.errorMessage, I18nManager.shared.t("paidPushDeliveryUnavailable"))
    }

    @MainActor
    func testClearPendingRemainsAvailableWhilePaidDeliveryIsPaused() async {
        var clearedIDs: [Int] = []
        let coordinator = PushSyncCoordinator(
            triggerPending: { _, _ in
                BackendNotificationDelivery(term_id: 42, keyword: "Aiko", count: 1, cleared: true)
            },
            clearPending: { id, _ in clearedIDs.append(id) },
            ensureRemoteRegistration: { _ in false },
            hasActiveEntitlement: { false },
            pushDeliveryState: { .inactive },
            refreshEntitlement: {}
        )

        await coordinator.clearPendingNotification(
            for: WatchTerm(id: "paused-clear", keyword: "Aiko", backendTermID: 42)
        )

        XCTAssertEqual(clearedIDs, [42])
        XCTAssertNil(coordinator.errorMessage)
    }

    @MainActor
    func testPaidAccessRejectionRefreshesEntitlementAndMapsError() async {
        var entitlementRefreshes = 0
        let coordinator = PushSyncCoordinator(
            triggerPending: { _, _ in
                throw BackendClientError.httpStatus(
                    402,
                    code: "paid_backend_required",
                    message: "Paid access required"
                )
            },
            clearPending: { _, _ in },
            ensureRemoteRegistration: { _ in true },
            hasActiveEntitlement: { true },
            pushDeliveryState: { .active },
            refreshEntitlement: { entitlementRefreshes += 1 }
        )

        await coordinator.notifyPendingNow(
            for: WatchTerm(id: "expired", keyword: "Aiko", backendTermID: 42)
        )

        XCTAssertEqual(entitlementRefreshes, 1)
        XCTAssertEqual(coordinator.errorMessage, I18nManager.shared.t("paidPushDeliveryUnavailable"))
    }

    @MainActor
    func testManualNotificationErrorsMapDeterministically() {
        let cases: [(Error, String)] = [
            (BackendClientError.httpStatus(409, code: "no_pending_content", message: nil), "paidPushNothingPending"),
            (BackendClientError.httpStatus(409, code: "push_delivery_paused", message: nil), "paidPushDeliveryUnavailable"),
            (BackendClientError.httpStatus(409, code: "notifications_disabled", message: nil), "paidPushTermDisabled"),
            (BackendClientError.httpStatus(409, code: "apns_unverified", message: nil), "paidPushRegistrationUnavailable"),
            (BackendClientError.httpStatus(404, code: nil, message: nil), "paidPushTermStale"),
            (URLError(.notConnectedToInternet), "paidPushActionFailed"),
        ]
        for (error, expectedKey) in cases {
            XCTAssertEqual(PushSyncCoordinator.manualOperationErrorKey(for: error), expectedKey)
        }
    }

    @MainActor
    func testManualNotificationOperationsRejectConcurrentActions() async {
        let gate = PaidNotificationOperationGate()
        var triggerCalls = 0
        var clearCalls = 0
        let coordinator = PushSyncCoordinator(
            triggerPending: { _, _ in
                triggerCalls += 1
                await gate.wait()
                return BackendNotificationDelivery(term_id: 42, keyword: "Aiko", count: 1, cleared: true)
            },
            clearPending: { _, _ in clearCalls += 1 },
            ensureRemoteRegistration: { _ in true },
            hasActiveEntitlement: { true },
            pushDeliveryState: { .active },
            refreshEntitlement: {}
        )
        let term = WatchTerm(id: "concurrent", keyword: "Aiko", backendTermID: 42)
        let otherTerm = WatchTerm(id: "other", keyword: "Mone", backendTermID: 99)

        let first = Task { await coordinator.notifyPendingNow(for: term) }
        while coordinator.manualOperationTermID == nil { await Task.yield() }
        await coordinator.clearPendingNotification(for: otherTerm)

        XCTAssertEqual(triggerCalls, 1)
        XCTAssertEqual(clearCalls, 0)
        await gate.open()
        await first.value
        XCTAssertNil(coordinator.manualOperationTermID)
    }

    @MainActor
    func testHostedMutePrefersGuaranteedPushBackendTermID() async {
        let profileID = UUID()
        var fetchCalls = 0
        var muteCalls: [(String, Int)] = []
        let term = WatchTerm(id: "local", keyword: "Aiko", backendTermID: 42)
        let coordinator = PaidBackendFeedCoordinator(
            paidBackendConfigured: { true },
            activeEntitlement: { true },
            activeProfileID: { profileID },
            localTerm: { _ in term },
            fetchHostedTerms: {
                fetchCalls += 1
                return []
            },
            muteHostedItem: { sourceItemID, watchTermID, _ in
                muteCalls.append((sourceItemID, watchTermID))
            },
            refreshEntitlement: {}
        )

        await coordinator.muteHiddenItem(feedItem())

        XCTAssertEqual(fetchCalls, 0)
        XCTAssertEqual(muteCalls.map(\.0), ["news:hosted-1"])
        XCTAssertEqual(muteCalls.map(\.1), [42])
    }

    @MainActor
    func testHostedMuteUsesStrictProfileScopedSynchronizedMappings() async {
        let firstProfile = UUID()
        let secondProfile = UUID()
        var currentProfile = firstProfile
        var mutedIDs: [Int] = []
        let term = WatchTerm(id: "local", keyword: "Aiko")
        let coordinator = PaidBackendFeedCoordinator(
            paidBackendConfigured: { true },
            activeEntitlement: { true },
            activeProfileID: { currentProfile },
            localTerm: { _ in term },
            fetchHostedTerms: { XCTFail("Synchronized mapping should avoid a cold fetch"); return [] },
            muteHostedItem: { _, watchTermID, _ in mutedIDs.append(watchTermID) },
            refreshEntitlement: {}
        )
        coordinator.cacheBackendTermMappings(
            [backendTerm(id: 10, keyword: "Aiko"), backendTerm(id: 11, keyword: "Aiko News")],
            localTerms: [term],
            profileID: firstProfile
        )
        coordinator.cacheBackendTermMappings(
            [backendTerm(id: 20, keyword: "AIKO")],
            localTerms: [term],
            profileID: secondProfile
        )

        await coordinator.muteHiddenItem(feedItem(id: "news:first"))
        currentProfile = secondProfile
        await coordinator.muteHiddenItem(feedItem(id: "news:second"))

        XCTAssertEqual(mutedIDs, [10, 20])
    }

    @MainActor
    func testHostedMuteColdLookupMatchesExactKeywordAndCachesResult() async {
        let profileID = UUID()
        var fetchCalls = 0
        var mutedIDs: [Int] = []
        let term = WatchTerm(id: "local", keyword: "Aiko")
        let coordinator = PaidBackendFeedCoordinator(
            paidBackendConfigured: { true },
            activeEntitlement: { true },
            activeProfileID: { profileID },
            localTerm: { _ in term },
            fetchHostedTerms: {
                fetchCalls += 1
                return [
                    self.backendTerm(id: 90, keyword: "Aiko News"),
                    self.backendTerm(id: 91, keyword: "AIKO"),
                ]
            },
            muteHostedItem: { _, watchTermID, _ in mutedIDs.append(watchTermID) },
            refreshEntitlement: {}
        )

        await coordinator.muteHiddenItem(feedItem(id: "news:first"))
        await coordinator.muteHiddenItem(feedItem(id: "news:second"))

        XCTAssertEqual(fetchCalls, 1)
        XCTAssertEqual(mutedIDs, [91, 91])
    }

    @MainActor
    func testHostedMuteSkipsUnavailableAndMissingBackendRoutes() async {
        let profileID = UUID()
        var refreshCalls = 0
        var fetchCalls = 0
        var muteCalls = 0
        let term = WatchTerm(id: "local", keyword: "Aiko")
        let inactive = PaidBackendFeedCoordinator(
            paidBackendConfigured: { true },
            activeEntitlement: { false },
            activeProfileID: { profileID },
            localTerm: { _ in term },
            fetchHostedTerms: { fetchCalls += 1; return [] },
            muteHostedItem: { _, _, _ in muteCalls += 1 },
            refreshEntitlement: { refreshCalls += 1 }
        )
        await inactive.muteHiddenItem(feedItem())

        let missing = PaidBackendFeedCoordinator(
            paidBackendConfigured: { true },
            activeEntitlement: { true },
            activeProfileID: { profileID },
            localTerm: { _ in term },
            fetchHostedTerms: {
                fetchCalls += 1
                return [self.backendTerm(id: 7, keyword: "Aiko News")]
            },
            muteHostedItem: { _, _, _ in muteCalls += 1 },
            refreshEntitlement: {}
        )
        await missing.muteHiddenItem(feedItem())

        let unconfigured = PaidBackendFeedCoordinator(
            paidBackendConfigured: { false },
            activeEntitlement: { true },
            activeProfileID: { profileID },
            localTerm: { _ in term },
            fetchHostedTerms: { fetchCalls += 1; return [] },
            muteHostedItem: { _, _, _ in muteCalls += 1 },
            refreshEntitlement: {}
        )
        await unconfigured.muteHiddenItem(feedItem())

        let noLocalTerm = PaidBackendFeedCoordinator(
            paidBackendConfigured: { true },
            activeEntitlement: { true },
            activeProfileID: { profileID },
            localTerm: { _ in nil },
            fetchHostedTerms: { fetchCalls += 1; return [] },
            muteHostedItem: { _, _, _ in muteCalls += 1 },
            refreshEntitlement: {}
        )
        await noLocalTerm.muteHiddenItem(feedItem())

        XCTAssertEqual(refreshCalls, 1)
        XCTAssertEqual(fetchCalls, 1)
        XCTAssertEqual(muteCalls, 0)
    }

    @MainActor
    func testHostedMutePaidRejectionRefreshesEntitlementWithoutChangingLocalState() async {
        let profileID = UUID()
        var refreshCalls = 0
        let term = WatchTerm(id: "local", keyword: "Aiko", backendTermID: 42)
        let item = feedItem()
        let db = LocalDB.shared
        let originalItems = db.feedItems
        let originalHiddenItems = db.hiddenItems
        defer {
            db.feedItems = originalItems
            db.hiddenItems = originalHiddenItems
        }
        db.feedItems = [item]
        db.hiddenItems.removeAll()
        db.deleteFeedItem(id: item.id, watchTermKeyword: item.watch_term_keyword)
        let coordinator = PaidBackendFeedCoordinator(
            paidBackendConfigured: { true },
            activeEntitlement: { true },
            activeProfileID: { profileID },
            localTerm: { _ in term },
            fetchHostedTerms: { [] },
            muteHostedItem: { _, _, _ in
                throw BackendClientError.httpStatus(
                    402,
                    code: "paid_backend_required",
                    message: "Paid access required"
                )
            },
            refreshEntitlement: { refreshCalls += 1 }
        )

        await coordinator.muteHiddenItem(item)

        XCTAssertFalse(db.feedItems.contains(item))
        XCTAssertTrue(db.hiddenItems.contains("\(item.id)::\(item.watch_term_keyword)"))
        XCTAssertEqual(refreshCalls, 1)
    }

    @MainActor
    func testHostedMuteTransportFailureStaysSilent() async {
        let profileID = UUID()
        let term = WatchTerm(id: "local", keyword: "Aiko", backendTermID: 42)
        var diagnosticReports = 0
        let coordinator = PaidBackendFeedCoordinator(
            paidBackendConfigured: { true },
            activeEntitlement: { true },
            activeProfileID: { profileID },
            localTerm: { _ in term },
            fetchHostedTerms: { [] },
            muteHostedItem: { _, _, _ in throw URLError(.notConnectedToInternet) },
            refreshEntitlement: {},
            reportHostedFailure: { _, _ in diagnosticReports += 1 }
        )

        await coordinator.muteHiddenItem(feedItem())

        XCTAssertNil(coordinator.errorMessage)
        XCTAssertEqual(diagnosticReports, 0)
    }

    @MainActor
    func testHostedMuteCoalescesDuplicateInFlightRequests() async {
        let profileID = UUID()
        let gate = PaidNotificationOperationGate()
        var muteCalls = 0
        let term = WatchTerm(id: "local", keyword: "Aiko", backendTermID: 42)
        let coordinator = PaidBackendFeedCoordinator(
            paidBackendConfigured: { true },
            activeEntitlement: { true },
            activeProfileID: { profileID },
            localTerm: { _ in term },
            fetchHostedTerms: { [] },
            muteHostedItem: { _, _, _ in
                muteCalls += 1
                await gate.wait()
            },
            refreshEntitlement: {}
        )
        let item = feedItem()

        let first = Task { await coordinator.muteHiddenItem(item) }
        while muteCalls == 0 { await Task.yield() }
        await coordinator.muteHiddenItem(item)
        XCTAssertEqual(muteCalls, 1)
        await gate.open()
        await first.value
    }

    @MainActor
    func testPaidHostedDiagnosticsRequireConfiguredActiveOptInAndSkipNonReportableErrors() async {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var configured = false
        var active = true
        var enabled = true
        var submissions = 0
        let reporter = PaidHostedDiagnosticReporter(
            defaults: defaults,
            paidBackendConfigured: { configured },
            activeEntitlement: { active },
            diagnosticsEnabled: { enabled },
            activeProfileID: { UUID() },
            environment: { "sandbox" },
            appMetadata: { (nil, nil) },
            snapshot: { (0, [], 0) },
            submit: { _, _ in submissions += 1 }
        )

        await reporter.report(.feedRefresh, error: URLError(.timedOut))
        configured = true
        active = false
        await reporter.report(.feedRefresh, error: URLError(.timedOut))
        active = true
        enabled = false
        await reporter.report(.feedRefresh, error: URLError(.timedOut))
        enabled = true
        await reporter.report(.feedRefresh, error: CancellationError())
        await reporter.report(
            .feedRefresh,
            error: BackendClientError.httpStatus(
                402,
                code: "paid_backend_required",
                message: "Paid access required"
            )
        )

        XCTAssertEqual(submissions, 0)
    }

    @MainActor
    func testPaidHostedDiagnosticPayloadIsBoundedSanitizedAndProfileThrottled() async throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let firstProfile = UUID()
        let secondProfile = UUID()
        var profileID = firstProfile
        var currentDate = Date(timeIntervalSince1970: 10_000)
        var reports: [ClientDiagnosticReport] = []
        let reporter = PaidHostedDiagnosticReporter(
            defaults: defaults,
            now: { currentDate },
            paidBackendConfigured: { true },
            activeEntitlement: { true },
            diagnosticsEnabled: { true },
            activeProfileID: { profileID },
            environment: { "sandbox" },
            appMetadata: { (String(repeating: "v", count: 100), "42") },
            snapshot: {
                (1_500, ["youtube", "news", "custom"], 20_000)
            },
            submit: { report, timeout in
                XCTAssertEqual(timeout, 12)
                reports.append(report)
            }
        )
        let sensitiveMessage = "keyword=Aiko token=secret https://example.com/private"

        await reporter.report(
            .feedRefresh,
            error: BackendClientError.httpStatus(500, code: "upstream_secret", message: sensitiveMessage)
        )
        await reporter.report(.termSynchronization, error: URLError(.timedOut))
        profileID = secondProfile
        await reporter.report(.termSynchronization, error: URLError(.timedOut))
        profileID = firstProfile
        currentDate = currentDate.addingTimeInterval(PaidHostedDiagnosticReporter.throttleInterval)
        await reporter.report(.termSynchronization, error: URLError(.timedOut))

        XCTAssertEqual(reports.count, 3)
        let first = try XCTUnwrap(reports.first)
        XCTAssertEqual(first.reason, "paid_hosted_operation_failed")
        XCTAssertEqual(first.api_base, "hosted")
        XCTAssertEqual(first.active_terms_count, 1_000)
        XCTAssertEqual(first.cached_feed_count, 10_000)
        XCTAssertEqual(first.subscribed_platforms, ["custom", "news", "youtube"])
        XCTAssertEqual(first.events, [ClientDiagnosticEvent(
            strategy: "hosted_feed_refresh",
            status: "failed",
            item_count: 0,
            added_count: 0,
            detail: "http_500"
        )])
        XCTAssertEqual(first.app_version?.count, 80)
        let encoded = String(data: try JSONEncoder().encode(first), encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains("Aiko"))
        XCTAssertFalse(encoded.contains("secret"))
        XCTAssertFalse(encoded.contains("example.com"))
        XCTAssertGreaterThan(
            defaults.double(forKey: PaidHostedDiagnosticReporter.checkpointKey(profileID: firstProfile)),
            0
        )
        XCTAssertGreaterThan(
            defaults.double(forKey: PaidHostedDiagnosticReporter.checkpointKey(profileID: secondProfile)),
            0
        )
    }

    @MainActor
    func testPaidHostedDiagnosticFailedUploadRetriesAndConcurrentUploadsCoalesce() async {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let profileID = UUID()
        var attempts = 0
        let retrying = PaidHostedDiagnosticReporter(
            defaults: defaults,
            paidBackendConfigured: { true },
            activeEntitlement: { true },
            diagnosticsEnabled: { true },
            activeProfileID: { profileID },
            environment: { "sandbox" },
            appMetadata: { (nil, nil) },
            snapshot: { (0, [], 0) },
            submit: { _, _ in
                attempts += 1
                if attempts == 1 { throw URLError(.cannotConnectToHost) }
            }
        )

        await retrying.report(.feedRefresh, error: URLError(.timedOut))
        await retrying.report(.feedRefresh, error: URLError(.timedOut))
        XCTAssertEqual(attempts, 2)

        let coalescingSuite = UUID().uuidString
        let coalescingDefaults = UserDefaults(suiteName: coalescingSuite)!
        defer { coalescingDefaults.removePersistentDomain(forName: coalescingSuite) }
        let gate = PaidNotificationOperationGate()
        var coalescedAttempts = 0
        let coalescing = PaidHostedDiagnosticReporter(
            defaults: coalescingDefaults,
            paidBackendConfigured: { true },
            activeEntitlement: { true },
            diagnosticsEnabled: { true },
            activeProfileID: { UUID(uuidString: "00000000-0000-0000-0000-000000000001")! },
            environment: { "sandbox" },
            appMetadata: { (nil, nil) },
            snapshot: { (0, [], 0) },
            submit: { _, _ in
                coalescedAttempts += 1
                await gate.wait()
            }
        )
        let first = Task { await coalescing.report(.feedRefresh, error: URLError(.timedOut)) }
        while coalescedAttempts == 0 { await Task.yield() }
        await coalescing.report(.termSynchronization, error: URLError(.timedOut))
        XCTAssertEqual(coalescedAttempts, 1)
        await gate.open()
        await first.value
    }

    @MainActor
    func testPaidBackendFailuresReportByOperationWithoutChangingRefreshResult() async {
        var operations: [PaidHostedDiagnosticOperation] = []
        let coordinator = PaidBackendFeedCoordinator(
            paidBackendConfigured: { true },
            activeEntitlement: { true },
            activeProfileID: { LocalProfileStore.shared.activeProfileID },
            localTerm: { _ in nil },
            fetchHostedTerms: { [] },
            muteHostedItem: { _, _, _ in },
            refreshEntitlement: {},
            reportHostedFailure: { operation, _ in operations.append(operation) },
            synchronizeHostedTerms: { throw URLError(.timedOut) }
        )

        await coordinator.synchronizeTerms()
        let result = await coordinator.refresh(
            .foreground,
            sourceRevision: LocalDB.shared.dataRevision,
            profileID: LocalProfileStore.shared.activeProfileID
        )

        XCTAssertEqual(operations, [.termSynchronization, .feedRefresh])
        XCTAssertEqual(result, .unavailable)
        XCTAssertFalse(coordinator.lastRefreshSucceeded ?? true)
    }

    @MainActor
    func testSuccessfulEmptyHostedRefreshDoesNotReportDiagnostic() async {
        var diagnosticReports = 0
        let coordinator = PaidBackendFeedCoordinator(
            paidBackendConfigured: { true },
            activeEntitlement: { true },
            activeProfileID: { LocalProfileStore.shared.activeProfileID },
            localTerm: { _ in nil },
            fetchHostedTerms: { [] },
            muteHostedItem: { _, _, _ in },
            refreshEntitlement: {},
            reportHostedFailure: { _, _ in diagnosticReports += 1 },
            synchronizeHostedTerms: { [] }
        )

        let result = await coordinator.refresh(
            .foreground,
            sourceRevision: LocalDB.shared.dataRevision,
            profileID: LocalProfileStore.shared.activeProfileID
        )

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.addedCount, 0)
        XCTAssertEqual(diagnosticReports, 0)
    }

    @MainActor
    func testPaidDiagnosticsVisibilityRequiresActiveEntitlement() {
        XCTAssertTrue(SettingsView.shouldShowPaidDiagnostics(isPaidConfigured: true, hasActiveEntitlement: true))
        XCTAssertFalse(SettingsView.shouldShowPaidDiagnostics(isPaidConfigured: true, hasActiveEntitlement: false))
        XCTAssertFalse(SettingsView.shouldShowPaidDiagnostics(isPaidConfigured: false, hasActiveEntitlement: true))
    }

    @MainActor
    func testPaidAPNSLifecycleCleansOnlyConfirmedInactiveCachedRegistration() async {
        var hasCachedRegistration = true
        var cleanupTimeouts: [TimeInterval] = []
        let coordinator = PaidAPNSLifecycleCoordinator(
            hasCachedRegistration: { hasCachedRegistration },
            unregister: { timeout in
                cleanupTimeouts.append(timeout)
                hasCachedRegistration = false
            }
        )

        await coordinator.reconcile(isEntitlementActive: true)
        XCTAssertTrue(cleanupTimeouts.isEmpty)

        await coordinator.reconcile(isEntitlementActive: false)
        XCTAssertEqual(cleanupTimeouts, [15])

        await coordinator.reconcile(isEntitlementActive: false)
        XCTAssertEqual(cleanupTimeouts, [15])
    }

    @MainActor
    func testPaidAPNSLifecycleCoalescesConcurrentInactiveCleanup() async {
        let gate = PaidNotificationOperationGate()
        var cleanupCalls = 0
        let coordinator = PaidAPNSLifecycleCoordinator(
            hasCachedRegistration: { true },
            unregister: { _ in
                cleanupCalls += 1
                await gate.wait()
            }
        )

        let first = Task { await coordinator.reconcile(isEntitlementActive: false) }
        while cleanupCalls == 0 { await Task.yield() }
        let second = Task { await coordinator.reconcile(isEntitlementActive: false) }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(cleanupCalls, 1)

        await gate.open()
        await first.value
        await second.value
        XCTAssertEqual(cleanupCalls, 1)
    }

    @MainActor
    func testPaidAPNSLifecycleRetriesAfterFailedInactiveCleanup() async {
        var cleanupCalls = 0
        let coordinator = PaidAPNSLifecycleCoordinator(
            hasCachedRegistration: { true },
            unregister: { _ in
                cleanupCalls += 1
                if cleanupCalls == 1 { throw URLError(.cannotConnectToHost) }
            }
        )

        await coordinator.reconcile(isEntitlementActive: false)
        await coordinator.reconcile(isEntitlementActive: false)

        XCTAssertEqual(cleanupCalls, 2)
    }

    @MainActor
    func testPaidAPNSLifecycleRepairsRegistrationAfterActiveStateSupersedesCleanup() async {
        let gate = PaidNotificationOperationGate()
        var cleanupCalls = 0
        var registrationCalls = 0
        let coordinator = PaidAPNSLifecycleCoordinator(
            hasCachedRegistration: { true },
            unregister: { _ in
                cleanupCalls += 1
                await gate.wait()
            },
            register: { registrationCalls += 1 }
        )

        let cleanup = Task {
            await coordinator.reconcile(isEntitlementActive: false)
        }
        while cleanupCalls == 0 { await Task.yield() }

        await coordinator.reconcile(
            isEntitlementActive: true,
            isPushEligible: true
        )
        XCTAssertEqual(registrationCalls, 1)

        await gate.open()
        await cleanup.value
        XCTAssertEqual(cleanupCalls, 1)
        XCTAssertEqual(registrationCalls, 2)
    }

    @MainActor
    func testPaidAPNSLifecycleDoesNotRepairWhenNewerStateIsInactive() async {
        let gate = PaidNotificationOperationGate()
        var cleanupCalls = 0
        var registrationCalls = 0
        let coordinator = PaidAPNSLifecycleCoordinator(
            hasCachedRegistration: { true },
            unregister: { _ in
                cleanupCalls += 1
                await gate.wait()
            },
            register: { registrationCalls += 1 }
        )

        let cleanup = Task {
            await coordinator.reconcile(isEntitlementActive: false)
        }
        while cleanupCalls == 0 { await Task.yield() }
        await coordinator.reconcile(isEntitlementActive: true, isPushEligible: true)
        let newerInactive = Task {
            await coordinator.reconcile(isEntitlementActive: false)
        }
        for _ in 0..<10 { await Task.yield() }

        await gate.open()
        await cleanup.value
        await newerInactive.value
        XCTAssertEqual(registrationCalls, 1)
    }
}


extension PaidPushTests {
    @MainActor
    func testHostedSixMonthBackfillIgnoresLegacyCursorThenResumesIncrementally() async {
        let db = LocalDB.shared
        let profileID = LocalProfileStore.shared.activeProfileID
        let legacyKey = "paid_backend_feed.cursor.\(profileID.uuidString).all"
        let newKey = PaidBackendFeedCoordinator.refreshCursorKey(profileID: profileID, platform: nil)
        let previousLegacy = UserDefaults.standard.object(forKey: legacyKey)
        let previousNew = UserDefaults.standard.object(forKey: newKey)
        let previousTerms = db.terms
        let previousItems = db.feedItems
        defer {
            UserDefaults.standard.set(previousLegacy, forKey: legacyKey)
            UserDefaults.standard.set(previousNew, forKey: newKey)
            db.terms = previousTerms
            db.feedItems = previousItems
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: legacyKey)
        UserDefaults.standard.removeObject(forKey: newKey)
        db.terms = [WatchTerm(keyword: "Backfill Oshi")]
        db.feedItems = []
        var windows: [Int] = []
        var cursors: [String?] = []
        var notificationPolicies: [Bool] = []
        let published = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-120 * 86400))
        let coordinator = PaidBackendFeedCoordinator(
            paidBackendConfigured: { true }, activeEntitlement: { true },
            refreshEntitlement: {}, synchronizeHostedTerms: { [123] },
            fetchHostedFeed: { _, ids, _, days, since, until in
                XCTAssertEqual(ids, [123])
                XCTAssertNotNil(parseISO8601Date(until))
                windows.append(days)
                cursors.append(since)
                return [FeedItem(id: "news:backfill", platform: "news", url: "https://example.com/backfill",
                    title: "Backfill Oshi", content_text: nil, author: nil, thumbnail_url: nil, media_type: "article",
                    published_at: published, watch_term_keyword: "Backfill Oshi", fetched_at: until)]
            },
            mergeHostedItems: { items, sourceRevision, shouldNotify in
                notificationPolicies.append(shouldNotify)
                return db.mergeItems(
                    newItems: items,
                    sourceRevision: sourceRevision,
                    notificationHandler: shouldNotify ? nil : { _, _ in }
                )
            }
        )
        let first = await coordinator.refresh(.foreground, sourceRevision: db.dataRevision, profileID: profileID)
        XCTAssertTrue(first.succeeded)
        XCTAssertEqual(first.addedCount, 1)
        XCTAssertEqual(db.feedItems.first?.published_at, published)
        let second = await coordinator.refresh(.foreground, sourceRevision: db.dataRevision, profileID: profileID)
        XCTAssertTrue(second.succeeded)
        XCTAssertEqual(windows, [180, 180])
        XCTAssertNil(cursors[0])
        XCTAssertNotNil(cursors[1])
        XCTAssertEqual(notificationPolicies, [false, true])
    }
}
