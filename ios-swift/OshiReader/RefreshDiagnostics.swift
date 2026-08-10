import Foundation
import Combine

struct SourceHealthSummary: Identifiable, Equatable {
    let id: String
    let currentStatus: SourceRefreshStatus?
    let receivedCount: Int
    let emptyCount: Int
    let failedCount: Int
    let totalItemCount: Int
    let lastCheckedAt: Date
    let lastFailure: SourceRefreshFailure?
}

/// Durable, backend-free refresh metadata used to explain whether the feed is
/// live, cached, or waiting for its first refresh.
@MainActor
final class RefreshDiagnostics: ObservableObject {
    static let shared = RefreshDiagnostics()

    @Published private(set) var isRefreshing = false
    @Published private(set) var lastStartedAt: Date?
    @Published private(set) var lastCompletedAt: Date?
    @Published private(set) var lastSucceeded: Bool?
    @Published private(set) var lastWasPartial = false
    @Published private(set) var lastAddedCount = 0
    @Published private(set) var sourceStatuses: [SourceRefreshStatus] = []
    @Published private(set) var sourceHealthSummaries: [SourceHealthSummary] = []

    static let healthHistoryKey = "refresh_diagnostics.source_health_history"
    static let healthHistoryRetention: TimeInterval = 7 * 24 * 60 * 60

    private enum HealthOutcome: String, Codable {
        case received
        case noResults
        case failed
    }

    private struct HealthRecord: Codable, Equatable {
        let sourceID: String
        let checkedAt: Date
        let outcome: HealthOutcome
        let itemCount: Int
        let queryCount: Int
        let failure: SourceRefreshFailure?
    }

    private enum Key {
        static let lastStartedAt = "refresh_diagnostics.last_started_at"
        static let lastCompletedAt = "refresh_diagnostics.last_completed_at"
        static let lastSucceeded = "refresh_diagnostics.last_succeeded"
        static let lastAddedCount = "refresh_diagnostics.last_added_count"
        static let lastWasPartial = "refresh_diagnostics.last_was_partial"
    }

    private let defaults: UserDefaults
    private var healthRecords: [HealthRecord]
    private var profileID: UUID?
    private let shouldScopeProfile: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.healthRecords = []
        self.profileID = nil
        self.shouldScopeProfile = defaults === UserDefaults.standard
        configure(profileID: LocalProfileStore.shared.activeProfileID)
    }

    func configure(profileID: UUID) {
        self.profileID = profileID
        lastStartedAt = Self.date(defaults, key: storageKey(Key.lastStartedAt))
        lastCompletedAt = Self.date(defaults, key: storageKey(Key.lastCompletedAt))
        lastSucceeded = defaults.object(forKey: storageKey(Key.lastSucceeded)) == nil
            ? nil
            : defaults.bool(forKey: storageKey(Key.lastSucceeded))
        lastWasPartial = defaults.bool(forKey: storageKey(Key.lastWasPartial))
        lastAddedCount = defaults.integer(forKey: storageKey(Key.lastAddedCount))
        healthRecords = Self.loadHealthRecords(defaults: defaults, key: storageKey(Self.healthHistoryKey))
        sourceStatuses = []
        isRefreshing = false
        rebuildHealthSummaries(now: Date())
    }

    func begin() {
        let now = Date()
        isRefreshing = true
        lastStartedAt = now
        defaults.set(now.timeIntervalSince1970, forKey: storageKey(Key.lastStartedAt))
    }

    func finish(succeeded: Bool, addedCount: Int = 0, partial: Bool = false) {
        let now = Date()
        isRefreshing = false
        lastCompletedAt = now
        lastSucceeded = succeeded
        lastAddedCount = max(0, addedCount)
        lastWasPartial = partial

        defaults.set(now.timeIntervalSince1970, forKey: storageKey(Key.lastCompletedAt))
        defaults.set(succeeded, forKey: storageKey(Key.lastSucceeded))
        defaults.set(lastAddedCount, forKey: storageKey(Key.lastAddedCount))
        defaults.set(partial, forKey: storageKey(Key.lastWasPartial))
    }

    func recordSourceStatuses(_ statuses: [SourceRefreshStatus]) {
        var merged: [String: SourceRefreshStatus] = [:]
        for status in sourceStatuses + statuses {
            let existing = merged[status.id]
            let itemCount = (existing?.itemCount ?? 0) + status.itemCount
            let queryCount = (existing?.queryCount ?? 0) + status.queryCount
            let outcome: SourceRefreshOutcome
            if itemCount > 0 {
                outcome = .received
            } else if case .failed(let failure) = status.outcome {
                outcome = .failed(failure)
            } else if case .failed(let failure) = existing?.outcome {
                outcome = .failed(failure)
            } else {
                outcome = .noResults
            }
            merged[status.id] = SourceRefreshStatus(
                id: status.id,
                outcome: outcome,
                itemCount: itemCount,
                queryCount: queryCount
            )
        }
        sourceStatuses = merged.values.sorted { $0.id < $1.id }
    }

    func resetSourceStatuses() {
        sourceStatuses = []
    }

    /// Persists one source-health record per source for a completed refresh.
    /// Callers pass statuses already aggregated across terms and aliases.
    func recordCompletedSourceStatuses(_ statuses: [SourceRefreshStatus], completedAt: Date = Date()) {
        let cutoff = completedAt.addingTimeInterval(-Self.healthHistoryRetention)
        var records = healthRecords.filter { $0.checkedAt >= cutoff }
        records.append(contentsOf: statuses.map { Self.healthRecord(from: $0, completedAt: completedAt) })
        healthRecords = records.sorted { $0.checkedAt < $1.checkedAt }
        persistHealthRecords()
        rebuildHealthSummaries(now: completedAt)
    }

    var statusText: String {
        if isRefreshing { return "Refreshing on device…" }
        guard let completed = lastCompletedAt else { return "Not refreshed yet" }
        let relative = Self.relativeRefreshTime(for: completed, relativeTo: Date())
        guard lastSucceeded == true else {
            return lastWasPartial
                ? "Refresh incomplete \(relative) · showing cached items"
                : "Refresh failed \(relative) · showing cached items"
        }
        if lastWasPartial {
            return lastAddedCount > 0
                ? "Updated \(relative) · \(lastAddedCount) new · some sources failed"
                : "Checked \(relative) · some sources failed"
        }
        return lastAddedCount > 0
            ? "Updated \(relative) · \(lastAddedCount) new"
            : "Checked \(relative) · feed is current"
    }

    var sourceSummaryText: String {
        let received = sourceStatuses.filter { $0.outcome == .received }.count
        let empty = sourceStatuses.filter { $0.outcome == .noResults }.count
        let failed = sourceStatuses.filter {
            if case .failed = $0.outcome { return true }
            return false
        }.count
        guard !sourceStatuses.isEmpty else { return "No sources checked" }
        return "\(received) with items · \(empty) empty · \(failed) failed"
    }

    /// The UI should still explain the current refresh when history has not
    /// been persisted yet (for example, an expired or cancelled refresh).
    var visibleSourceHealthSummaries: [SourceHealthSummary] {
        var summariesByID = Dictionary(uniqueKeysWithValues: sourceHealthSummaries.map { ($0.id, $0) })
        for status in sourceStatuses {
            let failure: SourceRefreshFailure?
            if case .failed(let value) = status.outcome {
                failure = value
            } else {
                failure = nil
            }
            if let existing = summariesByID[status.id] {
                summariesByID[status.id] = SourceHealthSummary(
                    id: existing.id,
                    currentStatus: status,
                    receivedCount: existing.receivedCount,
                    emptyCount: existing.emptyCount,
                    failedCount: existing.failedCount,
                    totalItemCount: existing.totalItemCount,
                    lastCheckedAt: existing.lastCheckedAt,
                    lastFailure: failure ?? existing.lastFailure
                )
            } else {
                summariesByID[status.id] = SourceHealthSummary(
                    id: status.id,
                    currentStatus: status,
                    receivedCount: status.outcome == .received ? 1 : 0,
                    emptyCount: status.outcome == .noResults ? 1 : 0,
                    failedCount: failure == nil ? 0 : 1,
                    totalItemCount: status.itemCount,
                    lastCheckedAt: Date(),
                    lastFailure: failure
                )
            }
        }
        return summariesByID.values.sorted { $0.id < $1.id }
    }

    var hasSourceFailures: Bool { sourceStatuses.hasFailures }

    private func rebuildHealthSummaries(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.healthHistoryRetention)
        healthRecords = healthRecords.filter { $0.checkedAt >= cutoff }
        let grouped = Dictionary(grouping: healthRecords, by: \.sourceID)
        sourceHealthSummaries = grouped.keys.sorted().compactMap { sourceID in
            guard let records = grouped[sourceID],
                  let latest = records.max(by: { $0.checkedAt < $1.checkedAt }) else { return nil }
            let current = SourceRefreshStatus(
                id: sourceID,
                outcome: Self.refreshOutcome(from: latest),
                itemCount: latest.itemCount,
                queryCount: latest.queryCount
            )
            return SourceHealthSummary(
                id: sourceID,
                currentStatus: current,
                receivedCount: records.filter { $0.outcome == .received }.count,
                emptyCount: records.filter { $0.outcome == .noResults }.count,
                failedCount: records.filter { $0.outcome == .failed }.count,
                totalItemCount: records.reduce(0) { $0 + $1.itemCount },
                lastCheckedAt: latest.checkedAt,
                lastFailure: records
                    .filter { $0.outcome == .failed && $0.failure != nil }
                    .max(by: { $0.checkedAt < $1.checkedAt })?.failure
            )
        }
        persistHealthRecords()
    }

    private static func relativeRefreshTime(for date: Date, relativeTo now: Date) -> String {
        guard abs(now.timeIntervalSince(date)) >= 5 else { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }

    private func persistHealthRecords() {
        guard let data = try? JSONEncoder().encode(healthRecords) else { return }
        defaults.set(data, forKey: storageKey(Self.healthHistoryKey))
    }

    private static func loadHealthRecords(defaults: UserDefaults, key: String) -> [HealthRecord] {
        guard let data = defaults.data(forKey: key),
              let records = try? JSONDecoder().decode([HealthRecord].self, from: data) else { return [] }
        return records
    }

    private func storageKey(_ key: String) -> String {
        shouldScopeProfile ? LocalProfileStore.defaultsKey(key, profileID: profileID) : key
    }

    private static func healthRecord(from status: SourceRefreshStatus, completedAt: Date) -> HealthRecord {
        switch status.outcome {
        case .received:
            return HealthRecord(sourceID: status.id, checkedAt: completedAt, outcome: .received, itemCount: status.itemCount, queryCount: status.queryCount, failure: nil)
        case .noResults:
            return HealthRecord(sourceID: status.id, checkedAt: completedAt, outcome: .noResults, itemCount: status.itemCount, queryCount: status.queryCount, failure: nil)
        case .failed(let failure):
            return HealthRecord(sourceID: status.id, checkedAt: completedAt, outcome: .failed, itemCount: status.itemCount, queryCount: status.queryCount, failure: failure)
        }
    }

    private static func refreshOutcome(from record: HealthRecord) -> SourceRefreshOutcome {
        switch record.outcome {
        case .received: return .received
        case .noResults: return .noResults
        case .failed: return .failed(record.failure ?? .httpFailure)
        }
    }

    private static func date(_ defaults: UserDefaults, key: String) -> Date? {
        let value = defaults.double(forKey: key)
        return value > 0 ? Date(timeIntervalSince1970: value) : nil
    }
}
