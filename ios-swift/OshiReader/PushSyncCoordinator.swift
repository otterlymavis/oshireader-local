import Foundation
import UIKit

enum PaidNotificationControlPolicy {
    static func showsPendingActions(backendTermID: Int?) -> Bool {
        backendTermID != nil
    }
}

@MainActor
final class PushSyncCoordinator: ObservableObject {
    static let shared = PushSyncCoordinator()
    @Published private(set) var termBeingUpdated: String?
    @Published private(set) var manualOperationTermID: String?
    @Published var errorMessage: String?
    private let registry: PushTermRegistry
    private let triggerPending: (Int, TimeInterval) async throws -> BackendNotificationDelivery
    private let clearPending: (Int, TimeInterval) async throws -> Void
    private let ensureRemoteRegistration: (TimeInterval) async -> Bool
    private let hasActiveEntitlement: () -> Bool
    private let pushDeliveryState: () -> PushDeliveryState
    private let refreshEntitlement: () async -> Void

    init(
        registry: PushTermRegistry = .shared,
        triggerPending: ((Int, TimeInterval) async throws -> BackendNotificationDelivery)? = nil,
        clearPending: ((Int, TimeInterval) async throws -> Void)? = nil,
        ensureRemoteRegistration: ((TimeInterval) async -> Bool)? = nil,
        hasActiveEntitlement: (() -> Bool)? = nil,
        pushDeliveryState: (() -> PushDeliveryState)? = nil,
        refreshEntitlement: (() async -> Void)? = nil
    ) {
        self.registry = registry
        self.triggerPending = triggerPending ?? { id, timeout in
            try await BackendClient.shared.triggerPendingNotification(backendTermID: id, timeout: timeout)
        }
        self.clearPending = clearPending ?? { id, timeout in
            try await BackendClient.shared.clearPendingNotification(backendTermID: id, timeout: timeout)
        }
        self.ensureRemoteRegistration = ensureRemoteRegistration ?? { timeout in
            await NotificationManager.shared.ensureRemoteNotificationsRegistered(
                timeout: timeout,
                forceRefresh: true
            )
        }
        self.hasActiveEntitlement = hasActiveEntitlement ?? { PlusStore.shared.hasActiveEntitlement }
        self.pushDeliveryState = pushDeliveryState ?? { PlusStore.shared.pushDeliveryState }
        self.refreshEntitlement = refreshEntitlement ?? { await PlusStore.shared.refreshStatus() }
    }

    func setPushEnabled(_ enabled: Bool, for term: WatchTerm) async {
        guard termBeingUpdated == nil else { return }
        termBeingUpdated = term.id
        errorMessage = nil
        defer { termBeingUpdated = nil }
        do {
            let profileID = LocalProfileStore.shared.activeProfileID
            if enabled {
                guard PlusStore.shared.activePushTermCount < PlusStore.shared.pushTermLimit else {
                    throw BackendClientError.httpStatus(409, code: "push_term_limit_reached", message: "Your push-term limit has been reached.")
                }
                if let conflict = registry.conflictingBinding(
                    keyword: term.keyword,
                    excludingProfileID: profileID,
                    localTermID: term.id
                ) {
                    let profileName = LocalProfileStore.shared.profiles.first(where: { $0.id == conflict.profileID })?.name
                        ?? "another profile"
                    throw BackendClientError.httpStatus(
                        409,
                        code: "duplicate_push_keyword",
                        message: "\(term.keyword) already uses guaranteed push in \(profileName)."
                    )
                }
                guard await NotificationManager.shared.requestAuthorizationIfNeededForLocalAlerts() else { return }
                guard await ensureAPNSRegistration() else {
                    throw BackendClientError.httpStatus(
                        409,
                        code: "apns_registration_unverified",
                        message: "Push registration could not be verified. Please try again."
                    )
                }
                let backend = try await BackendClient.shared.createPushTerm(term)
                let binding = PushTermBinding(
                    profileID: profileID,
                    localTermID: term.id,
                    backendTermID: backend.id,
                    keyword: term.keyword
                )
                registry.add(binding)
                registry.setBackendTermID(backend.id, for: binding)
                await PlusStore.shared.refreshStatus()
            } else if let binding = registry.binding(profileID: profileID, localTermID: term.id) {
                registry.enqueueDelete(binding)
                await retryPendingOperations()
                PaidBackendFeedCoordinator.shared.scheduleSynchronization()
            } else if let backendID = term.backendTermID {
                registry.enqueueDelete(backendTermID: backendID)
                LocalDB.shared.updateTerm(id: term.id, backendTermID: .some(nil))
                await retryPendingOperations()
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func removeLocalTerm(profileID: UUID, localTermID: String, backendTermID: Int?) {
        if let binding = registry.binding(profileID: profileID, localTermID: localTermID) {
            registry.enqueueDelete(binding)
        } else if let backendTermID {
            registry.enqueueDelete(backendTermID: backendTermID)
        }
        Task { await retryPendingOperations() }
    }

    func scheduleProfileDeletion(profileID: UUID) {
        for binding in registry.bindings(for: profileID) {
            registry.enqueueDelete(binding)
        }
        Task { await retryPendingOperations() }
    }

    func disable(_ binding: PushTermBinding) async {
        registry.enqueueDelete(binding)
        await retryPendingOperations()
    }

    func notifyPendingNow(for term: WatchTerm, timeout: TimeInterval = 30) async {
        guard manualOperationTermID == nil else { return }
        guard let backendTermID = term.backendTermID else {
            errorMessage = I18nManager.shared.t("paidPushTermStale")
            return
        }
        manualOperationTermID = term.id
        errorMessage = nil
        defer { manualOperationTermID = nil }

        guard hasActiveEntitlement(), pushDeliveryState() == .active else {
            errorMessage = I18nManager.shared.t("paidPushDeliveryUnavailable")
            return
        }
        guard await ensureRemoteRegistration(min(timeout, 12)) else {
            errorMessage = I18nManager.shared.t("paidPushRegistrationUnavailable")
            return
        }
        do {
            _ = try await triggerPending(backendTermID, timeout)
        } catch {
            await handleManualOperationError(error)
        }
    }

    func clearPendingNotification(for term: WatchTerm, timeout: TimeInterval = 30) async {
        guard manualOperationTermID == nil else { return }
        guard let backendTermID = term.backendTermID else {
            errorMessage = I18nManager.shared.t("paidPushTermStale")
            return
        }
        manualOperationTermID = term.id
        errorMessage = nil
        defer { manualOperationTermID = nil }
        do {
            try await clearPending(backendTermID, timeout)
        } catch {
            await handleManualOperationError(error)
        }
    }

    func retryPendingOperations() async {
        for operation in registry.pendingOperations {
            do {
                try await BackendClient.shared.deletePushTerm(id: operation.backendTermID)
                registry.complete(operation)
            } catch {
                errorMessage = "A guaranteed-push change is waiting to sync: \(error.localizedDescription)"
                return
            }
        }
        errorMessage = nil
        await PlusStore.shared.refreshStatus()
    }

    func reconcile() async {
        await retryPendingOperations()
        do {
            let backendTerms = try await BackendClient.shared.fetchPushTerms()
            let allBackendIDs = Set(backendTerms.map(\.id))
            let enabledBackendIDs = Set(backendTerms.filter(\.notify_on_new).map(\.id))
            for binding in registry.bindings where !enabledBackendIDs.contains(binding.backendTermID) {
                if allBackendIDs.contains(binding.backendTermID) {
                    // A hosted-feed term may remain silently active after
                    // guaranteed push was disabled. Clear only the push binding.
                    registry.clearMissingBackendBinding(binding)
                } else {
                    registry.clearMissingBackendBinding(binding)
                }
            }
            let registeredIDs = Set(registry.bindings.map(\.backendTermID))
            for orphanedID in enabledBackendIDs.subtracting(registeredIDs) {
                registry.enqueueDelete(backendTermID: orphanedID)
            }
            await retryPendingOperations()
            errorMessage = nil
        } catch {
            errorMessage = "Guaranteed push could not be reconciled: \(error.localizedDescription)"
        }
        await PlusStore.shared.refreshStatus()
    }

    private func ensureAPNSRegistration(timeout: TimeInterval = 12) async -> Bool {
        await ensureRemoteRegistration(timeout)
    }

    private func handleManualOperationError(_ error: Error) async {
        if case BackendClientError.httpStatus(_, let code, _) = error,
           code == "paid_backend_required" {
            await refreshEntitlement()
        }
        errorMessage = I18nManager.shared.t(Self.manualOperationErrorKey(for: error))
    }

    static func manualOperationErrorKey(for error: Error) -> String {
        guard case BackendClientError.httpStatus(let status, let code, _) = error else {
            return "paidPushActionFailed"
        }
        if status == 404 { return "paidPushTermStale" }
        switch code {
        case "no_pending_content":
            return "paidPushNothingPending"
        case "paid_backend_required", "push_delivery_paused":
            return "paidPushDeliveryUnavailable"
        case "notifications_disabled":
            return "paidPushTermDisabled"
        case "apns_unverified", "apns_registration_unverified":
            return "paidPushRegistrationUnavailable"
        default:
            return "paidPushActionFailed"
        }
    }
}
