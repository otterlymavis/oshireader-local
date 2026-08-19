import XCTest
import SwiftUI
import UIKit
import UserNotifications
@testable import OshiReader

final class CustomURLsTests: XCTestCase {

    private var db: LocalDB!

    override func setUpWithError() throws {
        try super.setUpWithError()
        db = LocalDB.shared
        db.terms.removeAll()
        db.feedItems.removeAll()
        db.savedPages.removeAll()
        db.customUrls.removeAll()
        db.amebloBlogs.removeAll()
        db.hiddenItems.removeAll()
        db.compositions.removeAll()
        db.setSubscribedPlatforms(platforms: ["news", "tver", "youtube", "yahoonews", "custom"])
    }

    override func tearDownWithError() throws {
        db = nil
        try super.tearDownWithError()
    }

    func testCustomUrls() throws {
        XCTAssertEqual(db.customUrls.count, 0)
        
        db.addCustomUrl(url: "https://myoshi-blog.com/feed", title: "Oshi Blog")
        XCTAssertEqual(db.customUrls.count, 1)
        XCTAssertEqual(db.customUrls.first?.title, "Oshi Blog")
        XCTAssertEqual(db.customUrls.first?.url, "https://myoshi-blog.com/feed")

        db.addCustomUrl(url: "myoshi-blog.com/second-feed", title: "Second Feed")
        XCTAssertEqual(db.customUrls.count, 2)
        XCTAssertEqual(db.customUrls.first?.url, "https://myoshi-blog.com/second-feed")

        db.addCustomUrl(url: "HTTPS://MYOSHI-BLOG.COM/second-feed/", title: "Duplicate Feed")
        XCTAssertEqual(db.customUrls.count, 2)

        db.addCustomUrl(url: "https://www.myoshi-blog.com/second-feed", title: "WWW Duplicate Feed")
        XCTAssertEqual(db.customUrls.count, 2)

        db.addCustomUrl(url: "https://myoshi-blog.com:443/second-feed", title: "Default Port Duplicate")
        XCTAssertEqual(db.customUrls.count, 2)

        db.addCustomUrl(url: "https://myoshi-blog.com/query-feed?b=2&utm_source=app&a=1#top", title: "Query Feed")
        XCTAssertEqual(db.customUrls.count, 3)
        XCTAssertEqual(db.customUrls.first?.url, "https://myoshi-blog.com/query-feed?a=1&b=2")
        db.addCustomUrl(url: "https://myoshi-blog.com/query-feed?b=2&a=1", title: "Query Feed Duplicate")
        XCTAssertEqual(db.customUrls.count, 3)

        db.addCustomUrl(url: "javascript://alert.example/feed", title: "Bad Feed")
        XCTAssertEqual(db.customUrls.count, 3)

        db.addCustomUrl(url: "mailto:test@example.com", title: "Mail Feed")
        db.addCustomUrl(url: "javascript:alert(1)", title: "Script Feed")
        XCTAssertEqual(db.customUrls.count, 3)

        db.addCustomUrl(url: "", title: "Empty Feed")
        db.addCustomUrl(url: "https://", title: "No Host Feed")
        db.addCustomUrl(url: "https://javascript/feed", title: "Single Label Feed")
        XCTAssertEqual(db.customUrls.count, 3)

        db.addCustomUrl(url: "http://localhost:8080/feed", title: "Local Feed")
        XCTAssertEqual(db.customUrls.count, 4)
        XCTAssertEqual(db.customUrls.first?.url, "http://localhost:8080/feed")

        db.addCustomUrl(url: "localhost:9090/scheme-less-feed", title: "Scheme-less Local Feed")
        XCTAssertEqual(db.customUrls.count, 5)
        XCTAssertEqual(db.customUrls.first?.url, "https://localhost:9090/scheme-less-feed")

        let longPrefix = "https://feeds.example.com/" + String(repeating: "same-prefix-", count: 8)
        db.addCustomUrl(url: "\(longPrefix)a.xml", title: "Long Feed A")
        db.addCustomUrl(url: "\(longPrefix)b.xml", title: "Long Feed B")
        XCTAssertEqual(db.customUrls.count, 7)
        
        for id in db.customUrls.map(\.id) {
            db.removeCustomUrl(id: id)
        }
        XCTAssertEqual(db.customUrls.count, 0)
    }

    @MainActor
    func testRemoveCustomUrlPrunesCachedCustomFeedItem() throws {
        db.setSubscribedPlatforms(platforms: ["custom"])
        db.addCustomUrl(url: "https://myoshi-blog.com/feed", title: "Oshi Blog")
        let custom = try XCTUnwrap(db.customUrls.first)
        let now = ISO8601DateFormatter().string(from: Date())
        let item = FeedItem(
            id: custom.id,
            platform: "custom",
            url: custom.url,
            title: "Oshi Blog",
            content_text: nil,
            author: "myoshi-blog.com",
            thumbnail_url: nil,
            media_type: "article",
            published_at: now,
            watch_term_keyword: "",
            fetched_at: now,
            source: "custom_url"
        )

        XCTAssertEqual(db.mergeItems(newItems: [item]), 1)
        XCTAssertTrue(db.toggleSaved(item: item))
        XCTAssertEqual(db.savedPages.map(\.id), [custom.id])
        XCTAssertEqual(db.queryFeed(keyword: nil, days: 0).map(\.id), [custom.id])
        db.hiddenItems.insert("\(item.id)::\(item.watch_term_keyword)")

        db.removeCustomUrl(id: custom.id)

        XCTAssertTrue(db.customUrls.isEmpty)
        XCTAssertTrue(db.feedItems.isEmpty)
        XCTAssertTrue(db.savedPages.isEmpty)
        XCTAssertFalse(db.hiddenItems.contains("\(item.id)::\(item.watch_term_keyword)"))
        XCTAssertTrue(db.queryFeed(keyword: nil, days: 0).isEmpty)
    }

    @MainActor
    func testRemoveCustomUrlClearsHiddenCustomTombstoneWithoutCachedItem() throws {
        db.addCustomUrl(url: "https://myoshi-blog.com/feed", title: "Oshi Blog")
        let custom = try XCTUnwrap(db.customUrls.first)
        let hiddenKey = "\(custom.id)::Aiko"
        let unrelatedHiddenKey = "youtube:v1::Aiko"
        db.hiddenItems.insert(hiddenKey)
        db.hiddenItems.insert(unrelatedHiddenKey)

        db.removeCustomUrl(id: custom.id)

        XCTAssertFalse(db.hiddenItems.contains(hiddenKey))
        XCTAssertTrue(db.hiddenItems.contains(unrelatedHiddenKey))
    }

    @MainActor
    func testRemoveCustomUrlPreservesHiddenKeysForRemainingPrefixedCustomID() throws {
        db.addCustomUrl(url: "https://example.com/a", title: "Short")
        db.addCustomUrl(url: "https://example.com/a::b", title: "Long")
        let short = try XCTUnwrap(db.customUrls.first { $0.url == "https://example.com/a" })
        let long = try XCTUnwrap(db.customUrls.first { $0.url == "https://example.com/a::b" })
        let shortHiddenKey = "\(short.id)::"
        let longHiddenKey = "\(long.id)::"
        db.hiddenItems.insert(shortHiddenKey)
        db.hiddenItems.insert(longHiddenKey)

        db.removeCustomUrl(id: short.id)

        XCTAssertFalse(db.hiddenItems.contains(shortHiddenKey))
        XCTAssertTrue(db.hiddenItems.contains(longHiddenKey))
    }

    @MainActor
    func testRemoveCustomUrlKeepsUnrelatedCachedFeedItems() throws {
        db.setSubscribedPlatforms(platforms: ["custom", "youtube"])
        db.addCustomUrl(url: "https://myoshi-blog.com/feed", title: "Oshi Blog")
        let custom = try XCTUnwrap(db.customUrls.first)
        let now = ISO8601DateFormatter().string(from: Date())
        let staleCustom = FeedItem(
            id: custom.id,
            platform: "CUSTOM",
            url: custom.url,
            title: "Oshi Blog",
            content_text: nil,
            author: "myoshi-blog.com",
            thumbnail_url: nil,
            media_type: "article",
            published_at: now,
            watch_term_keyword: "",
            fetched_at: now,
            source: "custom_url"
        )
        let regular = FeedItem(
            id: "youtube:v1",
            platform: "youtube",
            url: "https://youtube.com/watch?v=v1",
            title: "Video",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "video",
            published_at: now,
            watch_term_keyword: "Aiko",
            fetched_at: now,
            source: "youtube_scrape"
        )
        db.feedItems = [staleCustom, regular]
        db.savedPages = [
            SavedPage(
                id: staleCustom.id,
                url: staleCustom.url,
                title: staleCustom.title,
                platform: staleCustom.platform,
                saved_at: now,
                source: staleCustom.source
            ),
            SavedPage(
                id: regular.id,
                url: regular.url,
                title: regular.title,
                platform: regular.platform,
                saved_at: now,
                source: regular.source
            )
        ]
        db.hiddenItems.insert("\(staleCustom.id)::\(staleCustom.watch_term_keyword)")
        db.hiddenItems.insert("\(regular.id)::\(regular.watch_term_keyword)")

        db.removeCustomUrl(id: custom.id)

        XCTAssertEqual(db.feedItems, [regular])
        XCTAssertEqual(db.savedPages.map(\.id), [regular.id])
        XCTAssertFalse(db.hiddenItems.contains("\(staleCustom.id)::\(staleCustom.watch_term_keyword)"))
        XCTAssertTrue(db.hiddenItems.contains("\(regular.id)::\(regular.watch_term_keyword)"))
    }

    @MainActor
    func testCurrentCustomFeedItemsFiltersRemovedCustomSourceResults() throws {
        db.addCustomUrl(url: "https://myoshi-blog.com/feed", title: "Oshi Blog")
        let custom = try XCTUnwrap(db.customUrls.first)
        let now = ISO8601DateFormatter().string(from: Date())
        let currentCustom = FeedItem(
            id: custom.id,
            platform: "custom",
            url: custom.url,
            title: "Current Oshi Blog",
            content_text: nil,
            author: "myoshi-blog.com",
            thumbnail_url: nil,
            media_type: "article",
            published_at: now,
            watch_term_keyword: "",
            fetched_at: now,
            source: "custom_url"
        )
        let removedCustom = FeedItem(
            id: "custom:https%3A%2F%2Fold.example.com%2Ffeed.xml",
            platform: "CUSTOM",
            url: "https://old.example.com/feed.xml",
            title: "Removed Custom Feed",
            content_text: nil,
            author: "old.example.com",
            thumbnail_url: nil,
            media_type: "article",
            published_at: now,
            watch_term_keyword: "",
            fetched_at: now,
            source: "custom_url"
        )
        let regular = FeedItem(
            id: "youtube:v1",
            platform: "youtube",
            url: "https://youtube.com/watch?v=v1",
            title: "Video",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "video",
            published_at: now,
            watch_term_keyword: "Aiko",
            fetched_at: now,
            source: "youtube_scrape"
        )

        XCTAssertEqual(
            db.currentCustomFeedItems([removedCustom, currentCustom, regular]).map(\.id),
            [currentCustom.id, regular.id]
        )
    }
}
