import Foundation
import StoreKit
import UIKit

struct PaidEntitlementRequestGate {
    private(set) var latestGeneration: UInt64 = 0

    mutating func beginRequest() -> UInt64 {
        latestGeneration &+= 1
        return latestGeneration
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        generation == latestGeneration
    }
}

@MainActor
final class PaidAPNSLifecycleCoordinator {
    private let hasCachedRegistration: () -> Bool
    private let unregister: (TimeInterval) async throws -> Void
    private let register: @MainActor () -> Void
    private var cleanupTask: Task<Void, Error>?
    private var shouldMaintainRegistration = false

    init(
        hasCachedRegistration: @escaping () -> Bool = {
            guard let token = KeychainHelper.read(.apnsDeviceToken) else { return false }
            return !token.isEmpty
        },
        unregister: @escaping (TimeInterval) async throws -> Void = { timeout in
            try await BackendClient.shared.unregisterAPNSToken(timeout: timeout)
        },
        register: @escaping @MainActor () -> Void = {
            NotificationManager.shared.registerForRemoteNotificationsForDeviceAuthentication()
        }
    ) {
        self.hasCachedRegistration = hasCachedRegistration
        self.unregister = unregister
        self.register = register
    }

    func reconcile(
        isEntitlementActive: Bool,
        isPushEligible: Bool = false,
        timeout: TimeInterval = 15
    ) async {
        shouldMaintainRegistration = isEntitlementActive && isPushEligible
        if shouldMaintainRegistration {
            register()
            // A DELETE that has already reached the server cannot be reliably
            // cancelled. Its owner repairs registration after it completes.
            return
        }

        guard !isEntitlementActive, hasCachedRegistration() else { return }
        if let cleanupTask {
            _ = try? await cleanupTask.value
            return
        }

        let task = Task { try await unregister(timeout) }
        cleanupTask = task
        do {
            try await task.value
        } catch {
            AppLogger.network.warning(
                "Paid APNs registration cleanup failed; cached registration retained"
            )
        }
        cleanupTask = nil
        if shouldMaintainRegistration {
            register()
        }
    }
}

@MainActor
final class PlusStore: ObservableObject {
    static let shared = PlusStore()

    static var productIDs: [String] {
        let raw = Bundle.main.object(forInfoDictionaryKey: "PushSubscriptionProductIDs") as? String ?? ""
        let configured = parseProductIDs(raw)
        if configured.isEmpty,
           ProcessInfo.processInfo.arguments.contains("--uitesting"),
           ProcessInfo.processInfo.arguments.contains("--uitesting-paid-push") {
            return ["uitest.basic"]
        }
        return configured
    }

    static var isPaidPushConfigured: Bool { !productIDs.isEmpty }
    static var shouldSyncBackend: Bool {
        isPaidPushConfigured && !ProcessInfo.processInfo.arguments.contains("--uitesting")
    }

    static func parseProductIDs(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    @Published private(set) var products: [Product] = []
    @Published private(set) var pushTermLimit = 0
    @Published private(set) var pushTermCount = 0
    @Published private(set) var pushDeliveryState: PushDeliveryState = .inactive
    @Published private(set) var hasActiveEntitlement = false
    @Published private(set) var currentProductID: String?
    @Published private(set) var expiresAt: Date?
    @Published private(set) var isLoadingProducts = false
    @Published private(set) var isPurchasing = false
    @Published var errorMessage: String?

    private static let iso8601 = ISO8601DateFormatter()
    private var updatesTask: Task<Void, Never>?
    private let apnsLifecycle = PaidAPNSLifecycleCoordinator()
    private var entitlementRequestGate = PaidEntitlementRequestGate()

    private init() {
        guard !Self.isTesting, Self.isPaidPushConfigured else { return }
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates { await self?.handle(update) }
        }
        Task {
            await syncCurrentEntitlements()
            await refreshStatus()
        }
    }

    deinit { updatesTask?.cancel() }

    var activePushTermCount: Int {
        max(pushTermCount, PushTermRegistry.shared.usedSlotCount)
    }

    func billingLabel(for product: Product) -> String {
        switch product.type {
        case .autoRenewable:
            guard let period = product.subscription?.subscriptionPeriod else { return "Subscription" }
            switch period.unit {
            case .day: return period.value == 1 ? "Daily" : "Every \(period.value) days"
            case .week: return period.value == 1 ? "Weekly" : "Every \(period.value) weeks"
            case .month: return period.value == 1 ? "Monthly" : "Every \(period.value) months"
            case .year: return period.value == 1 ? "Yearly" : "Every \(period.value) years"
            @unknown default: return "Subscription"
            }
        case .nonConsumable:
            return "Lifetime"
        default:
            return "One-time"
        }
    }

    func loadProductsIfNeeded() async {
        guard products.isEmpty, !isLoadingProducts, !Self.productIDs.isEmpty else { return }
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        do { products = try await Product.products(for: Self.productIDs).sorted { $0.price < $1.price } }
        catch { errorMessage = error.localizedDescription }
    }

    func purchase(_ product: Product) async {
        isPurchasing = true
        errorMessage = nil
        defer { isPurchasing = false }
        do {
            if case .success(let verification) = try await product.purchase() { await handle(verification) }
        } catch { errorMessage = error.localizedDescription }
    }

    func restorePurchases() async {
        do { try await AppStore.sync() } catch { errorMessage = error.localizedDescription }
        await syncCurrentEntitlements()
        await refreshStatus()
    }

    func refreshStatus() async {
        let generation = entitlementRequestGate.beginRequest()
        do {
            let status = try await BackendClient.shared.entitlementStatus()
            guard entitlementRequestGate.isCurrent(generation) else { return }
            await apply(status)
        }
        catch { AppLogger.network.warning("Push entitlement refresh failed: \(error.localizedDescription)") }
    }

    private func handle(_ result: VerificationResult<Transaction>) async {
        let generation = entitlementRequestGate.beginRequest()
        do {
            let status = try await BackendClient.shared.verifyTransaction(result.jwsRepresentation)
            if entitlementRequestGate.isCurrent(generation) {
                await apply(status)
            }
            switch result {
            case .verified(let transaction), .unverified(let transaction, _): await transaction.finish()
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func syncCurrentEntitlements() async {
        var current: [VerificationResult<Transaction>] = []
        for await result in Transaction.currentEntitlements {
            let transaction: Transaction
            switch result {
            case .verified(let value), .unverified(let value, _): transaction = value
            }
            if Self.productIDs.contains(transaction.productID) { current.append(result) }
        }
        // A permanent purchase has no expiration and is applied last. For
        // subscription changes, the transaction with the latest expiry wins.
        current.sort { lhs, rhs in
            func expiration(_ result: VerificationResult<Transaction>) -> Date {
                switch result {
                case .verified(let value), .unverified(let value, _):
                    return value.expirationDate ?? .distantFuture
                }
            }
            return expiration(lhs) < expiration(rhs)
        }
        for result in current { await handle(result) }
    }

    private func apply(_ status: EntitlementStatus) async {
        hasActiveEntitlement = status.is_active
        pushTermLimit = status.is_active ? status.push_term_limit : 0
        pushTermCount = status.push_term_count
        pushDeliveryState = status.push_delivery_state
        currentProductID = status.product_id
        expiresAt = status.expires_at.flatMap { Self.iso8601.date(from: $0) }
        await apnsLifecycle.reconcile(
            isEntitlementActive: status.is_active,
            isPushEligible: pushTermLimit > 0
        )
    }

    func setPushDeliveryStateForTesting(_ state: PushDeliveryState) {
        pushDeliveryState = state
    }

    private static var isTesting: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTest.XCTestCase") != nil
    }
}
