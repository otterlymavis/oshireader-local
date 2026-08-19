import Foundation

/// A URL the Share Extension queued for the host app to add as a Custom URL.
/// The extension runs in its own sandboxed process and can't reach
/// `LocalDB`'s Documents-directory storage, so it drops shares here instead;
/// the host app drains the queue (see `LocalDB.processPendingShares`) and
/// runs them through the normal `addCustomUrl` + scrape pipeline.
struct PendingSharedURL: Codable, Identifiable, Hashable {
    let id: String
    let url: String
    let title: String?
    let sharedAt: String
}

enum PendingShareStore {
    private static let fileName = "pending_shares.json"

    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: oshiReaderAppGroupID)?
            .appendingPathComponent(fileName)
    }

    /// Called from the Share Extension process.
    static func enqueue(url: String, title: String?) {
        guard let fileURL else { return }
        var pending = readAll()
        pending.append(PendingSharedURL(
            id: UUID().uuidString,
            url: url,
            title: title,
            sharedAt: ISO8601DateFormatter().string(from: Date())
        ))
        guard let data = try? JSONEncoder().encode(pending) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }

    /// Called from the host app. Returns whatever was queued and clears it —
    /// each share is drained exactly once.
    static func drain() -> [PendingSharedURL] {
        guard let fileURL else { return [] }
        let pending = readAll()
        guard !pending.isEmpty else { return [] }
        try? FileManager.default.removeItem(at: fileURL)
        return pending
    }

    private static func readAll() -> [PendingSharedURL] {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([PendingSharedURL].self, from: data) else { return [] }
        return decoded
    }
}
