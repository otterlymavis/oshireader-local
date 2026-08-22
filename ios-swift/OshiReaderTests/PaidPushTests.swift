import XCTest
@testable import OshiReader

final class PaidPushTests: XCTestCase {
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
}
