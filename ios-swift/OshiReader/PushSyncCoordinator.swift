import Foundation
import UIKit

@MainActor
final class PushSyncCoordinator: ObservableObject {
    static let shared = PushSyncCoordinator()
    @Published private(set) var termBeingUpdated: String?
    @Published var errorMessage: String?
    private let registry = PushTermRegistry.shared

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
                    registry.enqueueDelete(binding)
                } else {
                    registry.clearMissingBackendBinding(binding)
                }
            }
            let registeredIDs = Set(registry.bindings.map(\.backendTermID))
            for orphanedID in allBackendIDs.subtracting(registeredIDs) {
                registry.enqueueDelete(backendTermID: orphanedID)
            }
            await retryPendingOperations()
            errorMessage = nil
        } catch {
            errorMessage = "Guaranteed push could not be reconciled: \(error.localizedDescription)"
        }
        await PlusStore.shared.refreshStatus()
    }

    func recordAPNSRegistrationFailure(_ error: Error) {
        errorMessage = "Push registration failed: \(error.localizedDescription)"
    }

    private func ensureAPNSRegistration(timeout: TimeInterval = 12) async -> Bool {
        if BackendClient.shared.hasRegisteredAPNSDeviceForCurrentEnvironment { return true }
        UIApplication.shared.registerForRemoteNotifications()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if BackendClient.shared.hasRegisteredAPNSDeviceForCurrentEnvironment { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }
}
