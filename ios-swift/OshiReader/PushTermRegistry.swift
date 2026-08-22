import Foundation

struct PushTermBinding: Codable, Identifiable, Equatable {
    let id: UUID
    let profileID: UUID
    let localTermID: String
    let backendTermID: Int
    let keyword: String

    init(
        id: UUID = UUID(),
        profileID: UUID,
        localTermID: String,
        backendTermID: Int,
        keyword: String
    ) {
        self.id = id
        self.profileID = profileID
        self.localTermID = localTermID
        self.backendTermID = backendTermID
        self.keyword = keyword
    }
}

struct PushSyncOperation: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case delete }

    let id: UUID
    let kind: Kind
    let backendTermID: Int
    let createdAt: Date

    init(id: UUID = UUID(), kind: Kind = .delete, backendTermID: Int, createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.backendTermID = backendTermID
        self.createdAt = createdAt
    }
}

@MainActor
final class PushTermRegistry: ObservableObject {
    static let shared = PushTermRegistry()

    @Published private(set) var bindings: [PushTermBinding]
    @Published private(set) var pendingOperations: [PushSyncOperation]

    private struct Store: Codable {
        var bindings: [PushTermBinding]
        var pendingOperations: [PushSyncOperation]
    }

    private let storeURL: URL
    private let profileStore: LocalProfileStore

    init(directory: URL? = nil, profileStore: LocalProfileStore = .shared) {
        self.profileStore = profileStore
        let root = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.storeURL = root.appendingPathComponent(".oshireader-push-registry.json")
        if let data = try? Data(contentsOf: storeURL),
           let stored = try? JSONDecoder().decode(Store.self, from: data) {
            self.bindings = stored.bindings
            self.pendingOperations = stored.pendingOperations
        } else {
            self.bindings = []
            self.pendingOperations = []
        }
    }

    var usedSlotCount: Int { bindings.count }

    /// Imports mappings written by the first paid-push implementation before
    /// the device-wide registry existed. This must run before reconciliation,
    /// otherwise a valid backend term could be mistaken for an orphan.
    func bootstrapFromProfiles() {
        var changed = false
        for profile in profileStore.profiles {
            let url = profileStore.fileURL(for: "terms", profileID: profile.id)
            guard let data = try? Data(contentsOf: url),
                  let terms = try? JSONDecoder().decode([WatchTerm].self, from: data) else { continue }
            for term in terms {
                guard let backendTermID = term.backendTermID,
                      binding(backendTermID: backendTermID) == nil,
                      binding(profileID: profile.id, localTermID: term.id) == nil else { continue }
                bindings.append(
                    PushTermBinding(
                        profileID: profile.id,
                        localTermID: term.id,
                        backendTermID: backendTermID,
                        keyword: term.keyword
                    )
                )
                changed = true
            }
        }
        if changed { persist() }
    }

    func binding(profileID: UUID, localTermID: String) -> PushTermBinding? {
        bindings.first { $0.profileID == profileID && $0.localTermID == localTermID }
    }

    func binding(backendTermID: Int) -> PushTermBinding? {
        bindings.first { $0.backendTermID == backendTermID }
    }

    func conflictingBinding(keyword: String, excludingProfileID: UUID, localTermID: String) -> PushTermBinding? {
        bindings.first {
            $0.keyword.caseInsensitiveCompare(keyword) == .orderedSame
                && !($0.profileID == excludingProfileID && $0.localTermID == localTermID)
        }
    }

    func add(_ binding: PushTermBinding) {
        bindings.removeAll {
            $0.backendTermID == binding.backendTermID
                || ($0.profileID == binding.profileID && $0.localTermID == binding.localTermID)
        }
        bindings.append(binding)
        persist()
    }

    @discardableResult
    func remove(backendTermID: Int) -> PushTermBinding? {
        guard let index = bindings.firstIndex(where: { $0.backendTermID == backendTermID }) else { return nil }
        let binding = bindings.remove(at: index)
        persist()
        return binding
    }

    func enqueueDelete(_ binding: PushTermBinding) {
        _ = remove(backendTermID: binding.backendTermID)
        if !pendingOperations.contains(where: { $0.backendTermID == binding.backendTermID }) {
            pendingOperations.append(PushSyncOperation(backendTermID: binding.backendTermID))
        }
        setBackendTermID(nil, for: binding)
        persist()
    }

    func enqueueDelete(backendTermID: Int) {
        if let binding = binding(backendTermID: backendTermID) {
            enqueueDelete(binding)
            return
        }
        if !pendingOperations.contains(where: { $0.backendTermID == backendTermID }) {
            pendingOperations.append(PushSyncOperation(backendTermID: backendTermID))
            persist()
        }
    }

    func complete(_ operation: PushSyncOperation) {
        pendingOperations.removeAll { $0.id == operation.id }
        persist()
    }

    func clearMissingBackendBinding(_ binding: PushTermBinding) {
        _ = remove(backendTermID: binding.backendTermID)
        setBackendTermID(nil, for: binding)
    }

    func bindings(for profileID: UUID) -> [PushTermBinding] {
        bindings.filter { $0.profileID == profileID }
    }

    func setBackendTermID(_ backendTermID: Int?, for binding: PushTermBinding) {
        if profileStore.activeProfileID == binding.profileID {
            LocalDB.shared.updateTerm(id: binding.localTermID, backendTermID: .some(backendTermID))
            return
        }
        let url = profileStore.fileURL(for: "terms", profileID: binding.profileID)
        guard let data = try? Data(contentsOf: url),
              var terms = try? JSONDecoder().decode([WatchTerm].self, from: data),
              let index = terms.firstIndex(where: { $0.id == binding.localTermID }) else { return }
        terms[index].backendTermID = backendTermID
        guard let updated = try? JSONEncoder().encode(terms) else { return }
        try? updated.write(to: url, options: [.atomic])
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(
            Store(bindings: bindings, pendingOperations: pendingOperations)
        ) else { return }
        try? data.write(to: storeURL, options: [.atomic])
    }
}
