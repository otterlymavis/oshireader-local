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
    ///
    /// Moves the file aside before reading it, rather than read-then-delete:
    /// `enqueue()` runs in a separate process and could append a new share
    /// between a plain read and delete, which the delete would then wipe out
    /// along with the file. A move is atomic (same-volume rename), so a
    /// concurrent `enqueue()` either lands in the moved-aside copy (and gets
    /// drained normally) or recreates the queue file fresh afterward (and
    /// survives to the next drain) — never both, never neither.
    static func drain() -> [PendingSharedURL] {
        guard let fileURL else { return [] }
        let stagingURL = fileURL.appendingPathExtension("draining")
        // A staging file already existing means a previous drain moved the
        // queue aside and got interrupted (e.g. app killed) before reading
        // and cleaning it up — resume from it rather than re-moving (which
        // would throw) or discarding it (which would lose those shares).
        // Anything `enqueue()` has written to `fileURL` since is left alone
        // for the next drain.
        if !FileManager.default.fileExists(atPath: stagingURL.path) {
            do {
                try FileManager.default.moveItem(at: fileURL, to: stagingURL)
            } catch {
                return []
            }
        }
        defer { try? FileManager.default.removeItem(at: stagingURL) }
        guard let data = try? Data(contentsOf: stagingURL),
              let decoded = try? JSONDecoder().decode([PendingSharedURL].self, from: data) else { return [] }
        return decoded
    }

    private static func readAll() -> [PendingSharedURL] {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([PendingSharedURL].self, from: data) else { return [] }
        return decoded
    }
}
