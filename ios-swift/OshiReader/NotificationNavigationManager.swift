import Foundation

@MainActor
final class NotificationNavigationManager: ObservableObject {
    static let shared = NotificationNavigationManager()

    @Published var selectedItem: FeedItem?

    private init() {}

    func open(userInfo: [AnyHashable: Any]) {
        selectedItem = item(from: userInfo)
        if let keyword = selectedItem?.watch_term_keyword {
            RecentTermUsageStore.shared.markUsed(keyword: keyword, terms: LocalDB.shared.terms)
        }
    }

    func save(userInfo: [AnyHashable: Any]) {
        guard let item = item(from: userInfo) else { return }
        if !LocalDB.shared.savedPages.contains(where: { $0.id == item.id }) {
            _ = LocalDB.shared.toggleSaved(item: item)
        }
    }

    private func item(from userInfo: [AnyHashable: Any]) -> FeedItem? {
        guard let id = userInfo["feed_item_id"] as? String else { return nil }
        let keyword = userInfo["watch_term_keyword"] as? String
        if let cached = LocalDB.shared.feedItems.first(where: {
            $0.id == id && (keyword == nil || $0.watch_term_keyword == keyword)
        }) {
            return cached
        }

        guard let url = userInfo["url"] as? String else { return nil }
        let now = ISO8601DateFormatter().string(from: Date())
        return FeedItem(
            id: id,
            platform: userInfo["platform"] as? String ?? "web",
            url: url,
            title: userInfo["title"] as? String,
            content_text: userInfo["content_text"] as? String,
            author: userInfo["author"] as? String,
            thumbnail_url: userInfo["thumbnail_url"] as? String,
            media_type: userInfo["media_type"] as? String ?? "article",
            published_at: userInfo["published_at"] as? String ?? now,
            watch_term_keyword: keyword ?? "",
            fetched_at: userInfo["fetched_at"] as? String ?? now
        )
    }
}
