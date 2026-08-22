import Foundation
import StoreKit
import UIKit

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

    private var updatesTask: Task<Void, Never>?

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
        do { apply(try await BackendClient.shared.entitlementStatus()) }
        catch { AppLogger.network.warning("Push entitlement refresh failed: \(error.localizedDescription)") }
    }

    private func handle(_ result: VerificationResult<Transaction>) async {
        do {
            let status = try await BackendClient.shared.verifyTransaction(result.jwsRepresentation)
            apply(status)
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

    private func apply(_ status: EntitlementStatus) {
        hasActiveEntitlement = status.is_active
        pushTermLimit = status.is_active ? status.push_term_limit : 0
        pushTermCount = status.push_term_count
        pushDeliveryState = status.push_delivery_state
        currentProductID = status.product_id
        expiresAt = status.expires_at.flatMap { ISO8601DateFormatter().date(from: $0) }
        if pushTermLimit > 0 { UIApplication.shared.registerForRemoteNotifications() }
    }

    func setPushDeliveryStateForTesting(_ state: PushDeliveryState) {
        pushDeliveryState = state
    }

    private static var isTesting: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTest.XCTestCase") != nil
    }
}
