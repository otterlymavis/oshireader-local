import Foundation

/// The subset of a `WatchTerm` the widget's configuration picker needs —
/// keeping this separate from `WatchTerm` means the widget extension never
/// needs the full watch-term model (source selection, collection mode, etc).
struct WidgetTermOption: Codable, Identifiable, Hashable {
    let id: String
    let keyword: String
}

/// Snapshot of feed data the host app publishes into the shared App Group
/// container so the widget extension — which can't reach `LocalDB` or the
/// app's Documents directory — has something to read.
struct WidgetSnapshot: Codable {
    let terms: [WidgetTermOption]
    let itemsByTermID: [String: [FeedItem]]
    let updatedAt: Date
}

enum WidgetSnapshotStore {
    private static let fileName = "widget_snapshot.json"

    private static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: oshiReaderAppGroupID)
    }

    static func write(_ snapshot: WidgetSnapshot) {
        guard let containerURL else { return }
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: containerURL.appendingPathComponent(fileName), options: [.atomic])
        } catch {
            AppLogger.persistence.error("Failed to write widget snapshot: \(error.localizedDescription)")
        }
    }

    static func read() -> WidgetSnapshot? {
        guard let containerURL,
              let data = try? Data(contentsOf: containerURL.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}

/// Builds the `oshireader://article` deep link a widget tap opens, carrying
/// enough fields for `NotificationNavigationManager` to reconstruct the item
/// without a `LocalDB` lookup — mirrors the local-notification `userInfo`
/// payload so both entry points share one parser.
func widgetArticleURL(for item: FeedItem) -> URL? {
    var components = URLComponents()
    components.scheme = "oshireader"
    components.host = "article"
    var queryItems = [
        URLQueryItem(name: "feed_item_id", value: item.id),
        URLQueryItem(name: "url", value: item.url),
        URLQueryItem(name: "platform", value: item.platform),
        URLQueryItem(name: "media_type", value: item.media_type),
        URLQueryItem(name: "published_at", value: item.published_at),
        URLQueryItem(name: "watch_term_keyword", value: item.watch_term_keyword)
    ]
    let optionalFields: [(String, String?)] = [
        ("title", item.title),
        ("content_text", item.content_text),
        ("author", item.author),
        ("thumbnail_url", item.thumbnail_url),
        ("source", item.source)
    ]
    for (name, value) in optionalFields {
        if let value { queryItems.append(URLQueryItem(name: name, value: value)) }
    }
    components.queryItems = queryItems
    return components.url
}
