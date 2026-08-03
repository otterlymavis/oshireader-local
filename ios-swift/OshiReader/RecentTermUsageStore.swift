import Foundation

/// Small on-device priority hint for background refresh. It intentionally
/// stores term IDs, not keywords, so renaming a term does not lose recency.
@MainActor
final class RecentTermUsageStore: ObservableObject {
    static let shared = RecentTermUsageStore()
    static let storageKey = "refresh.recent_term_usage"
    static let maximumEntries = 100

    private let defaults: UserDefaults
    private var profileID: UUID?
    @Published private(set) var timestamps: [String: Date]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.profileID = nil
        self.timestamps = [:]
        configure(profileID: LocalProfileStore.shared.activeProfileID)
    }

    func configure(profileID: UUID) {
        self.profileID = profileID
        let raw = defaults.dictionary(forKey: LocalProfileStore.defaultsKey(Self.storageKey, profileID: profileID)) as? [String: Double] ?? [:]
        timestamps = raw.reduce(into: [:]) { result, entry in
            guard entry.value > 0 else { return }
            result[entry.key] = Date(timeIntervalSince1970: entry.value)
        }
        prune()
    }

    func markUsed(termID: String) {
        guard !termID.isEmpty else { return }
        timestamps[termID] = Date()
        prune()
        persist()
    }

    func markUsed(keyword: String, terms: [WatchTerm]) {
        guard let term = terms.first(where: { $0.keyword == keyword }) else { return }
        markUsed(termID: term.id)
    }

    func remove(termID: String) {
        guard timestamps.removeValue(forKey: termID) != nil else { return }
        persist()
    }

    func removeAll() {
        timestamps.removeAll()
        defaults.removeObject(forKey: storageKey)
    }

    func ordered(_ terms: [WatchTerm]) -> [WatchTerm] {
        terms.enumerated().sorted { lhs, rhs in
            let left = timestamps[lhs.element.id]
            let right = timestamps[rhs.element.id]
            switch (left, right) {
            case let (left?, right?):
                if left != right { return left > right }
                return lhs.offset < rhs.offset
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    func priorityOrdered(_ terms: [WatchTerm]) -> [WatchTerm] {
        let recent = ordered(terms)
        return recent.enumerated().sorted { lhs, rhs in
            let leftNotify = lhs.element.notify_on_new
            let rightNotify = rhs.element.notify_on_new
            if leftNotify != rightNotify { return leftNotify && !rightNotify }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private func prune() {
        guard timestamps.count > Self.maximumEntries else { return }
        let retained = timestamps
            .sorted { $0.value > $1.value }
            .prefix(Self.maximumEntries)
        timestamps = Dictionary(uniqueKeysWithValues: retained.map { ($0.key, $0.value) })
    }

    private func persist() {
        defaults.set(timestamps.mapValues(\.timeIntervalSince1970), forKey: storageKey)
    }

    private var storageKey: String {
        LocalProfileStore.defaultsKey(Self.storageKey, profileID: profileID)
    }
}
