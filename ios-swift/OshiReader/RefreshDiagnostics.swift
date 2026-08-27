import Foundation
import Combine

struct SourceHealthSummary: Identifiable, Equatable {
    let id: String
    let currentStatus: SourceRefreshStatus?
    let receivedCount: Int
    let staleCount: Int
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
    static let healthHistoryRetention: TimeInterval = 10 * 24 * 60 * 60

    /// Consecutive failed checks (from the most recent, unbroken by a
    /// success) before a source is considered chronically broken and put in
    /// cooldown, instead of being retried at full frequency every refresh.
    private static let cooldownFailureThreshold = 3
    private static let cooldownDuration: TimeInterval = 30 * 60

    private enum HealthOutcome: String, Codable {
        case received
        case stale
        case noResults
        case failed
        case cooldown
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
            // Regular sources intentionally let "received" win over "failed"
            // when merging multiple queries (e.g. keyword aliases) for the
            // same platform — one alias succeeding is still good news even
            // if another failed (see testSourceHealthHistoryUsesReceivedPrecedenceAndKeepsLatestFailure).
            // "custom" is scoped out of that precedence: each custom URL is
            // an independent source, so a failed one must stay visible even
            // if another custom URL in the same batch returned items.
            let outcome: SourceRefreshOutcome
            if status.id == "custom", case .failed(let failure) = status.outcome {
                outcome = .failed(failure)
            } else if status.id == "custom", case .failed(let failure) = existing?.outcome {
                outcome = .failed(failure)
            } else if status.outcome == .received || existing?.outcome == .received {
                outcome = .received
            } else if case .failed(let failure) = status.outcome {
                outcome = .failed(failure)
            } else if case .failed(let failure) = existing?.outcome {
                outcome = .failed(failure)
            } else if status.outcome == .stale || existing?.outcome == .stale {
                outcome = .stale
            } else if status.outcome == .cooldown || existing?.outcome == .cooldown {
                outcome = .cooldown
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
    func recordCompletedSourceStatuses(
        _ statuses: [SourceRefreshStatus],
        completedAt: Date = Date(),
        replacingRecordsSince replacementStart: Date? = nil,
        persist: Bool = true
    ) {
        let cutoff = completedAt.addingTimeInterval(-Self.healthHistoryRetention)
        var records = healthRecords.filter { $0.checkedAt >= cutoff }
        if let replacementStart {
            let sourceIDs = Set(statuses.map(\.id))
            records.removeAll {
                sourceIDs.contains($0.sourceID) && $0.checkedAt >= replacementStart
            }
        }
        records.append(contentsOf: statuses.map { Self.healthRecord(from: $0, completedAt: completedAt) })
        healthRecords = records.sorted { $0.checkedAt < $1.checkedAt }
        if persist { persistHealthRecords() }
        // The rebuild is always `persist: false`: when this call persisted
        // above, re-encoding the identical bytes there is pure duplicate I/O;
        // when it didn't (background loop passes `persist: false`), the caller
        // flushes once via `flushPendingHealthRecords()` after the last unit
        // instead of re-encoding the whole history on every refresh unit (O6).
        rebuildHealthSummaries(now: completedAt, persist: false)
    }

    /// Encodes and writes the accumulated `healthRecords` to `UserDefaults`
    /// once. The background refresh loop records each unit with
    /// `persist: false` and calls this a single time when the loop ends.
    func flushPendingHealthRecords() {
        persistHealthRecords()
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
                ? "Updated \(relative) · \(lastAddedCount) new · some sources incomplete"
                : "Checked \(relative) · some sources incomplete"
        }
        return lastAddedCount > 0
            ? "Updated \(relative) · \(lastAddedCount) new"
            : "Checked \(relative) · feed is current"
    }

    var sourceSummaryText: String {
        let received = sourceStatuses.filter { $0.outcome == .received }.count
        let stale = sourceStatuses.filter { $0.outcome == .stale }.count
        let empty = sourceStatuses.filter { $0.outcome == .noResults }.count
        let failed = sourceStatuses.filter {
            if case .failed = $0.outcome { return true }
            return false
        }.count
        let cooldown = sourceStatuses.filter { $0.outcome == .cooldown }.count
        guard !sourceStatuses.isEmpty else { return "No sources checked" }
        let base = "\(received) current · \(stale) stale · \(empty) empty · \(failed) failed"
        return cooldown > 0 ? base + " · \(cooldown) cooling down" : base
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
                    staleCount: existing.staleCount,
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
                    staleCount: status.outcome == .stale ? 1 : 0,
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

    /// Source IDs with `cooldownFailureThreshold`+ consecutive failed checks
    /// (no success in between) whose most recent check was within
    /// `cooldownDuration`. Callers should skip fetching these sources for
    /// this refresh instead of retrying a chronically broken source at full
    /// frequency; the source is retried again once the cooldown elapses, and
    /// any success (even during a later refresh) clears the streak.
    func sourcesInCooldown(at now: Date = Date()) -> Set<String> {
        let grouped = Dictionary(grouping: healthRecords, by: \.sourceID)
        var cooldown = Set<String>()
        for (sourceID, records) in grouped {
            // Ignore .cooldown records themselves — they're not a real check
            // outcome, and treating one as "latest" would end the cooldown
            // after a single skipped cycle since it isn't .failed. Cooldown
            // duration is measured from the last genuine failure, not from
            // the last time we merely skipped checking.
            let realRecords = records.filter { $0.outcome != .cooldown }.sorted { $0.checkedAt < $1.checkedAt }
            guard let latest = realRecords.last, latest.outcome == .failed,
                  now.timeIntervalSince(latest.checkedAt) < Self.cooldownDuration else { continue }
            var streak = 0
            for record in realRecords.reversed() {
                guard record.outcome == .failed else { break }
                streak += 1
            }
            if streak >= Self.cooldownFailureThreshold {
                cooldown.insert(sourceID)
            }
        }
        return cooldown
    }

    private func rebuildHealthSummaries(now: Date, persist: Bool = true) {
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
                staleCount: records.filter { $0.outcome == .stale }.count,
                emptyCount: records.filter { $0.outcome == .noResults }.count,
                failedCount: records.filter { $0.outcome == .failed }.count,
                totalItemCount: records.reduce(0) { $0 + $1.itemCount },
                lastCheckedAt: latest.checkedAt,
                lastFailure: records
                    .filter { $0.outcome == .failed && $0.failure != nil }
                    .max(by: { $0.checkedAt < $1.checkedAt })?.failure
            )
        }
        if persist { persistHealthRecords() }
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
        case .stale:
            return HealthRecord(sourceID: status.id, checkedAt: completedAt, outcome: .stale, itemCount: status.itemCount, queryCount: status.queryCount, failure: nil)
        case .noResults:
            return HealthRecord(sourceID: status.id, checkedAt: completedAt, outcome: .noResults, itemCount: status.itemCount, queryCount: status.queryCount, failure: nil)
        case .failed(let failure):
            return HealthRecord(sourceID: status.id, checkedAt: completedAt, outcome: .failed, itemCount: status.itemCount, queryCount: status.queryCount, failure: failure)
        case .cooldown:
            return HealthRecord(sourceID: status.id, checkedAt: completedAt, outcome: .cooldown, itemCount: status.itemCount, queryCount: status.queryCount, failure: nil)
        }
    }

    private static func refreshOutcome(from record: HealthRecord) -> SourceRefreshOutcome {
        switch record.outcome {
        case .received: return .received
        case .stale: return .stale
        case .noResults: return .noResults
        case .failed: return .failed(record.failure ?? .httpFailure)
        case .cooldown: return .cooldown
        }
    }

    private static func date(_ defaults: UserDefaults, key: String) -> Date? {
        let value = defaults.double(forKey: key)
        return value > 0 ? Date(timeIntervalSince1970: value) : nil
    }

    private struct HealthExportSummary: Encodable {
        let id: String
        /// The live outcome for this refresh cycle (e.g. "cooldown" when the
        /// source was deliberately skipped), not just historical counts —
        /// this is what actually answers "why isn't source X updating".
        let currentOutcome: String?
        let receivedCount: Int
        let staleCount: Int
        let emptyCount: Int
        let failedCount: Int
        let totalItemCount: Int
        let lastCheckedAt: Date
        let lastFailure: String?
    }

    private static func describe(_ outcome: SourceRefreshOutcome) -> String {
        switch outcome {
        case .received: return "received"
        case .stale: return "stale"
        case .noResults: return "noResults"
        case .cooldown: return "cooldown"
        case .failed(let failure): return "failed(\(failure.rawValue))"
        }
    }

    private struct HealthExport: Encodable {
        let generatedAt: Date
        let retentionDays: Int
        let summaries: [HealthExportSummary]
        let records: [HealthRecord]
    }

    /// Serializes the current per-source health summary and raw check
    /// history to JSON. There's no server-side log to inspect in this
    /// local-only app, so this is the way to explain a "why isn't source X
    /// updating" report.
    func exportHealthHistoryJSON() -> Data? {
        // visibleSourceHealthSummaries, not sourceHealthSummaries — the
        // latter is only the persisted-history view, which wouldn't reflect
        // this cycle's in-progress/cooldown status until the next refresh
        // completes and persists it.
        let summaries = visibleSourceHealthSummaries.map {
            HealthExportSummary(
                id: $0.id,
                currentOutcome: $0.currentStatus.map { Self.describe($0.outcome) },
                receivedCount: $0.receivedCount,
                staleCount: $0.staleCount,
                emptyCount: $0.emptyCount,
                failedCount: $0.failedCount,
                totalItemCount: $0.totalItemCount,
                lastCheckedAt: $0.lastCheckedAt,
                lastFailure: $0.lastFailure?.rawValue
            )
        }
        let export = HealthExport(
            generatedAt: Date(),
            retentionDays: Int(Self.healthHistoryRetention / (24 * 60 * 60)),
            summaries: summaries,
            records: healthRecords
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(export)
    }
}
