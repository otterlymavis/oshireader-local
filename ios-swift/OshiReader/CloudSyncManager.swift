import CloudKit
import Combine
import Foundation

enum CloudSyncStatus: Equatable {
    case idle
    case syncing
    case succeeded(Date)
    case failed(String)
    case unavailable(String)
}

/// Optional iCloud sync of the active local profile, layered entirely on top
/// of the existing manual backup format — no new persistence model. Each
/// sync cycle pulls the shared CKRecord if it's newer than what this device
/// last saw, otherwise pushes local changes if the data revision has moved.
/// This is whole-profile, last-write-wins sync (not field-level merging):
/// simple and predictable, at the cost of losing the loser's edits if two
/// devices genuinely edit offline at the same time — an accepted tradeoff
/// for a personal single/dual-device reader app.
///
/// Scoped to a single profile: only usable while exactly one local profile
/// exists (see `SettingsView`'s guard), since two local profiles syncing to
/// the same fixed cloud record would silently clobber each other.
@MainActor
final class CloudSyncManager: ObservableObject {
    static let shared = CloudSyncManager()

    @Published private(set) var status: CloudSyncStatus = .idle
    @Published private(set) var lastSyncedAt: Date?
    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled {
                Task { await self.syncNow() }
            }
        }
    }

    private static let recordType = "ProfileSnapshot"
    private static let recordName = "profile-snapshot-v1"
    private static let enabledKey = "icloud_sync_enabled"
    private static let lastSyncedAtKey = "icloud_sync_last_synced_at"
    private static let lastPushedRevisionKey = "icloud_sync_last_pushed_revision"

    // Lazy and untouched until a sync actually runs (always gated behind
    // `isEnabled` — see `syncNow()`): CKContainer.default() reads the app's
    // iCloud entitlements and raises an uncatchable NSException if they're
    // absent or not yet provisioned (e.g. an unsigned/CI build, or a real
    // device before the one-time Xcode capability setup). Constructing it
    // eagerly for every user on every launch — rather than only for users
    // who opted into sync — would crash the whole app in exactly those cases.
    private var lazyContainer: CKContainer?
    private var container: CKContainer {
        if let lazyContainer { return lazyContainer }
        let container = CKContainer.default()
        lazyContainer = container
        return container
    }
    private var database: CKDatabase { container.privateCloudDatabase }
    private var revisionObservation: AnyCancellable?
    private var pushDebounceTask: Task<Void, Never>?
    private var isSyncing = false

    private init() {
        let defaults = UserDefaults.standard
        self.isEnabled = defaults.bool(forKey: Self.enabledKey)
        if defaults.object(forKey: Self.lastSyncedAtKey) != nil {
            self.lastSyncedAt = Date(timeIntervalSince1970: defaults.double(forKey: Self.lastSyncedAtKey))
        }
        observeLocalChanges()
    }

    private func observeLocalChanges() {
        revisionObservation = LocalDB.shared.$dataRevision
            .dropFirst()
            .sink { [weak self] _ in
                self?.scheduleDebouncedPush()
            }
    }

    private func scheduleDebouncedPush() {
        guard isEnabled else { return }
        pushDebounceTask?.cancel()
        pushDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    func accountStatus() async -> CKAccountStatus {
        (try? await container.accountStatus()) ?? .couldNotDetermine
    }

    @discardableResult
    func syncNow() async -> Bool {
        guard isEnabled, !isSyncing else { return false }
        // Settings hides the enable toggle once a second local profile
        // exists, but that alone doesn't stop a sync already left running
        // from a single-profile session — two profiles pushing/pulling the
        // same fixed cloud record would silently clobber each other, so
        // enforce the constraint here too rather than relying on the UI.
        guard LocalProfileStore.shared.profiles.count <= 1 else {
            status = .unavailable(Self.multipleProfilesMessage)
            return false
        }
        isSyncing = true
        defer { isSyncing = false }
        status = .syncing

        let account = await accountStatus()
        guard account == .available else {
            status = .unavailable(Self.message(for: account))
            return false
        }

        do {
            if try await pullIfNewer() {
                // We just adopted the remote's exact state — it already
                // represents this revision, so there's nothing new to push.
                markSynced(pushedRevision: LocalDB.shared.dataRevision)
            } else {
                try await pushIfChanged()
                markSynced(pushedRevision: LocalDB.shared.dataRevision)
            }
            status = .succeeded(lastSyncedAt ?? Date())
            return true
        } catch {
            status = .failed(error.localizedDescription)
            return false
        }
    }

    private func markSynced(pushedRevision: Int) {
        let now = Date()
        lastSyncedAt = now
        let defaults = UserDefaults.standard
        defaults.set(now.timeIntervalSince1970, forKey: Self.lastSyncedAtKey)
        defaults.set(pushedRevision, forKey: Self.lastPushedRevisionKey)
    }

    private func recordID() -> CKRecord.ID {
        CKRecord.ID(recordName: Self.recordName)
    }

    private func fetchRemoteRecord() async throws -> CKRecord? {
        do {
            return try await database.record(for: recordID())
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    /// Returns true if a newer remote snapshot was found and imported.
    private func pullIfNewer() async throws -> Bool {
        guard let record = try await fetchRemoteRecord(),
              let asset = record["data"] as? CKAsset,
              let fileURL = asset.fileURL,
              let remoteUpdatedAt = record["updatedAt"] as? Date else {
            return false
        }
        if let lastSyncedAt, remoteUpdatedAt <= lastSyncedAt { return false }

        let data = try Data(contentsOf: fileURL)
        try LocalDB.shared.importBackupData(data)
        return true
    }

    private func pushIfChanged() async throws {
        let currentRevision = LocalDB.shared.dataRevision
        let lastPushedRevision = UserDefaults.standard.object(forKey: Self.lastPushedRevisionKey) as? Int
        guard lastPushedRevision != currentRevision else { return }

        let data = try LocalDB.shared.exportBackupData()
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("oshireader-icloud-\(UUID().uuidString).json")
        try data.write(to: tempURL, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let record = (try? await fetchRemoteRecord()) ?? CKRecord(recordType: Self.recordType, recordID: recordID())
        record["data"] = CKAsset(fileURL: tempURL)
        record["updatedAt"] = Date()

        do {
            _ = try await database.save(record)
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Someone else pushed between our fetch and save — retry once
            // against the freshest record rather than clobbering it outright.
            guard let latest = try await fetchRemoteRecord() else { throw error }
            latest["data"] = CKAsset(fileURL: tempURL)
            latest["updatedAt"] = Date()
            _ = try await database.save(latest)
        }
    }

    private static let multipleProfilesMessage = "iCloud Sync only supports a single local profile."

    private static func message(for status: CKAccountStatus) -> String {
        switch status {
        case .noAccount: return "No iCloud account signed in."
        case .restricted: return "iCloud access is restricted on this device."
        case .temporarilyUnavailable: return "iCloud is temporarily unavailable."
        case .couldNotDetermine: return "Could not determine iCloud account status."
        case .available: return ""
        @unknown default: return "iCloud is unavailable."
        }
    }
}
