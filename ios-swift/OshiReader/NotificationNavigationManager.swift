import Foundation

@MainActor
final class NotificationNavigationManager: ObservableObject {
    static let shared = NotificationNavigationManager()

    @Published var selectedItem: FeedItem?

    private struct NotificationPayload {
        let item: FeedItem
        let hasPlatform: Bool
        let hasMediaType: Bool
        let hasPublishedAt: Bool
        let hasWatchTermKeyword: Bool
    }

    private init() {}

    func open(userInfo: [AnyHashable: Any]) {
        guard let payload = notificationPayload(from: userInfo) else { return }
        selectedItem = Self.preferredNotificationItem(
            payload.item,
            cachedItems: LocalDB.shared.feedItems,
            hasPlatform: payload.hasPlatform,
            hasMediaType: payload.hasMediaType,
            hasPublishedAt: payload.hasPublishedAt,
            hasWatchTermKeyword: payload.hasWatchTermKeyword
        )
        if let keyword = selectedItem?.watch_term_keyword {
            RecentTermUsageStore.shared.markUsed(keyword: keyword, terms: LocalDB.shared.terms)
        }
    }

    func save(userInfo: [AnyHashable: Any]) {
        guard let payload = notificationPayload(from: userInfo) else { return }
        let item = Self.preferredNotificationItem(
            payload.item,
            cachedItems: LocalDB.shared.feedItems,
            hasPlatform: payload.hasPlatform,
            hasMediaType: payload.hasMediaType,
            hasPublishedAt: payload.hasPublishedAt,
            hasWatchTermKeyword: payload.hasWatchTermKeyword
        )
        if !LocalDB.shared.savedPages.contains(where: { $0.id == item.id }) {
            _ = LocalDB.shared.toggleSaved(item: item)
        }
    }

    /// Makes a compact APNs preview visible immediately while the hosted feed
    /// catches up. Merging without a notification handler prevents a second
    /// local alert for the same server-delivered item.
    @discardableResult
    func mergeNotificationItem(userInfo: [AnyHashable: Any]) -> Bool {
        guard let payload = notificationPayload(from: userInfo) else { return false }
        // Only pre-seed a preview when the payload carries a real publish date.
        // `notificationPayload` otherwise fills `published_at` with `now`, which
        // would pin the item to the top of the feed permanently: when the hosted
        // feed later delivers the same item with its true (older) date,
        // `LocalDB.mergedPublishedAt` keeps the newer of the two — the fabricated
        // `now` — so the real date can never take over. Items without a payload
        // date are picked up by the `refreshNow()` that follows this call.
        guard payload.hasPublishedAt else { return false }
        let item = Self.preferredNotificationItem(
            payload.item,
            cachedItems: LocalDB.shared.feedItems,
            hasPlatform: payload.hasPlatform,
            hasMediaType: payload.hasMediaType,
            hasPublishedAt: payload.hasPublishedAt,
            hasWatchTermKeyword: payload.hasWatchTermKeyword
        )
        _ = LocalDB.shared.mergeItems(newItems: [item])
        return LocalDB.shared.feedItems.contains {
            $0.id == item.id &&
                (item.watch_term_keyword.isEmpty || $0.watch_term_keyword == item.watch_term_keyword)
        }
    }

    static func preferredNotificationItem(
        _ notificationItem: FeedItem,
        cachedItems: [FeedItem],
        hasPlatform: Bool = true,
        hasMediaType: Bool = true,
        hasPublishedAt: Bool = true,
        hasWatchTermKeyword: Bool = true
    ) -> FeedItem {
        let existing = cachedItems.first {
            $0.id == notificationItem.id &&
                (
                    notificationItem.watch_term_keyword.isEmpty ||
                    $0.watch_term_keyword == notificationItem.watch_term_keyword
                )
        }
        guard let existing else { return notificationItem }
        let notificationPlatform = Self.normalizedNotificationPlatform(notificationItem.platform)

        return FeedItem(
            id: notificationItem.id,
            platform: hasPlatform ? (notificationPlatform ?? existing.platform) : existing.platform,
            url: notificationItem.url,
            title: notificationItem.title ?? existing.title,
            content_text: notificationItem.content_text ?? existing.content_text,
            author: notificationItem.author ?? existing.author,
            thumbnail_url: notificationItem.thumbnail_url ?? existing.thumbnail_url,
            media_type: hasMediaType ? notificationItem.media_type : existing.media_type,
            published_at: hasPublishedAt ? notificationItem.published_at : existing.published_at,
            watch_term_keyword: hasWatchTermKeyword && !notificationItem.watch_term_keyword.isEmpty
                ? notificationItem.watch_term_keyword
                : existing.watch_term_keyword,
            fetched_at: existing.fetched_at,
            source: notificationItem.source ?? existing.source
        )
    }

    private func notificationPayload(from userInfo: [AnyHashable: Any]) -> NotificationPayload? {
        let previewItem = dictionaryValue(userInfo["preview_item"])
        guard let id = stringValue(userInfo["item_id"])
                ?? stringValue(previewItem?["id"])
                ?? stringValue(userInfo["feed_item_id"]),
              let url = stringValue(userInfo["item_url"])
                ?? stringValue(previewItem?["url"])
                ?? stringValue(userInfo["url"]) else { return nil }
        let now = iso8601String(from: Date())
        let platform = Self.normalizedNotificationPlatform(
            stringValue(userInfo["item_platform"])
                ?? stringValue(previewItem?["platform"])
                ?? stringValue(userInfo["platform"])
                ?? Self.inferredPlatform(itemID: id, itemURL: url)
        )
        let mediaType = stringValue(userInfo["item_media_type"])
            ?? stringValue(previewItem?["media_type"])
            ?? stringValue(userInfo["media_type"])
        let publishedAt = stringValue(userInfo["item_published_at"])
            ?? stringValue(previewItem?["published_at"])
            ?? stringValue(userInfo["published_at"])
        let watchTermKeyword = stringValue(userInfo["watch_term_keyword"])
        let source = stringValue(userInfo["item_source"])
            ?? stringValue(previewItem?["source"])
            ?? stringValue(userInfo["source"])
        let item = FeedItem(
            id: id,
            platform: platform ?? "web",
            url: url,
            title: stringValue(userInfo["item_title"]) ?? stringValue(previewItem?["title"]) ?? stringValue(userInfo["title"]),
            content_text: stringValue(userInfo["item_content_text"]) ?? stringValue(previewItem?["content_text"]) ?? stringValue(userInfo["content_text"]),
            author: stringValue(userInfo["item_author"]) ?? stringValue(previewItem?["author"]) ?? stringValue(userInfo["author"]),
            thumbnail_url: stringValue(userInfo["thumbnail_url"]) ?? stringValue(previewItem?["thumbnail_url"]),
            media_type: mediaType ?? "article",
            published_at: publishedAt ?? now,
            watch_term_keyword: watchTermKeyword ?? "",
            fetched_at: stringValue(userInfo["fetched_at"]) ?? now,
            source: source
        )
        return NotificationPayload(
            item: item,
            hasPlatform: platform != nil,
            hasMediaType: mediaType != nil,
            hasPublishedAt: publishedAt != nil,
            hasWatchTermKeyword: watchTermKeyword != nil
        )
    }

    private func dictionaryValue(_ value: Any?) -> [String: Any]? {
        if let dictionary = value as? [String: Any] { return dictionary }
        if let dictionary = value as? [AnyHashable: Any] {
            return Dictionary(uniqueKeysWithValues: dictionary.compactMap { key, value in
                guard let key = key as? String else { return nil }
                return (key, value)
            })
        }
        return nil
    }

    private static func normalizedNotificationPlatform(_ platform: String?) -> String? {
        guard let platform else { return nil }
        let normalized = PlatformRegistry.normalizeID(platform)
        return PlatformRegistry.definition(for: normalized)?.id
    }

    private static func inferredPlatform(itemID: String, itemURL: String) -> String? {
        let lowercasedID = itemID.lowercased()
        if lowercasedID.hasPrefix("youtube:") { return "youtube" }
        if lowercasedID.hasPrefix("twitter:") || lowercasedID.hasPrefix("x:") { return "twitter" }
        if lowercasedID.hasPrefix("5ch:") || lowercasedID.hasPrefix("2ch.sc:") { return "5ch" }

        guard let host = URL(string: itemURL)?.host?.lowercased() else { return nil }
        if host == "youtube.com" || host == "www.youtube.com" || host == "youtu.be" || host.hasSuffix(".youtube.com") {
            return "youtube"
        }
        if host == "x.com" || host == "www.x.com" || host == "twitter.com" || host == "www.twitter.com" || host.hasSuffix(".x.com") || host.hasSuffix(".twitter.com") {
            return "twitter"
        }
        if host == "5ch.io" || host == "5ch.net" || host == "itest.5ch.io" || host == "itest.5ch.net" || host == "2ch.sc" || host.hasSuffix(".5ch.io") || host.hasSuffix(".5ch.net") || host.hasSuffix(".2ch.sc") {
            return "5ch"
        }
        return nil
    }

    private func stringValue(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }
}
