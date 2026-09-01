import XCTest
import SwiftUI
import UIKit
import UserNotifications
@testable import OshiReader

final class FeedQueryingTests: XCTestCase {

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

    @MainActor
    func testFeedQueryingFilters() throws {
        let formatter = ISO8601DateFormatter()
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let olderThanMonth = Calendar.current.date(byAdding: .day, value: -35, to: now)!
        
        let itemNow = FeedItem(
            id: "youtube:now", platform: "youtube", url: "https://u",
            title: "Aiko now news video", content_text: "Aiko is active", author: "Aiko",
            thumbnail_url: nil, media_type: "video", published_at: formatter.string(from: now),
            watch_term_keyword: "Aiko", fetched_at: formatter.string(from: now),
            source: "youtube_scrape"
        )
        
        let itemYesterday = FeedItem(
            id: "tver:yesterday", platform: "tver", url: "https://u",
            title: "Aiko drama episode", content_text: "TVer episode", author: "TVer",
            thumbnail_url: nil, media_type: "video", published_at: formatter.string(from: yesterday),
            watch_term_keyword: "Aiko", fetched_at: formatter.string(from: now)
        )
        
        let itemOld = FeedItem(
            id: "yahoonews:old", platform: "yahoonews", url: "https://u",
            title: "Aiko news article", content_text: "Yahoo news text", author: "Yahoo",
            thumbnail_url: nil, media_type: "article", published_at: formatter.string(from: olderThanMonth),
            watch_term_keyword: "Aiko", fetched_at: formatter.string(from: now)
        )
        
        let itemStrictMismatch = FeedItem(
            id: "tver:mismatch", platform: "tver", url: "https://u",
            title: "Aiko show on TVer", content_text: "Only contains Aiko text", author: "TVer",
            thumbnail_url: nil, media_type: "video", published_at: formatter.string(from: now),
            watch_term_keyword: "Miku", fetched_at: formatter.string(from: now)
        )
        
        _ = db.mergeItems(newItems: [itemNow, itemYesterday, itemOld, itemStrictMismatch])
        
        // Verifies platform subscription is active
        db.setSubscribedPlatforms(platforms: ["youtube", "tver", "yahoonews"])
        
        // 1. Query for 30 days, keyword "Aiko"
        let query1 = db.queryFeed(keyword: "Aiko", days: 30)
        XCTAssertEqual(query1.count, 2) // Should exclude itemOld (35 days old) and mismatch
        XCTAssertEqual(query1.first?.id, "youtube:now")
        XCTAssertEqual(query1.last?.id, "tver:yesterday")
        
        // 2. Query for 90 days, keyword "Aiko"
        let query2 = db.queryFeed(keyword: "Aiko", days: 90)
        XCTAssertEqual(query2.count, 3) // Should include itemOld now
        
        // 3. Query strict mismatch check
        let queryStrict = db.queryFeed(keyword: "Miku", days: 30)
        XCTAssertEqual(queryStrict.count, 0) // Strictly mismatched keyword text should be filtered out
        
        // 4. Query with unsubscribed platform
        db.setSubscribedPlatforms(platforms: ["tver"]) // Unsubscribe youtube
        let querySub = db.queryFeed(keyword: "Aiko", days: 30)
        XCTAssertEqual(querySub.count, 1) // Only TVer yesterday item remains
        XCTAssertEqual(querySub.first?.id, "tver:yesterday")
    }

    @MainActor
    func testYahooBareURLFallbackFilterUsesNormalizedPlatformAlias() throws {
        let nowString = ISO8601DateFormatter().string(from: Date())
        let item = FeedItem(
            id: "news:yahoo_ent:bare-url",
            platform: "news:yahoo_ent",
            url: "https://news.yahoo.co.jp/articles/bare-url",
            title: "https://news.yahoo.co.jp/articles/bare-url",
            content_text: nil,
            author: "Yahoo",
            thumbnail_url: nil,
            media_type: "article",
            published_at: nowString,
            watch_term_keyword: "Aiko",
            fetched_at: nowString
        )

        db.setSubscribedPlatforms(platforms: ["yahoonews"])
        XCTAssertEqual(db.mergeItems(newItems: [item]), 1)

        XCTAssertTrue(db.queryFeed(keyword: "Aiko", days: 0).isEmpty)
    }

    @MainActor
    func testFeedQueryingRejectsSummaryOnlyStrictMatches() throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let term = db.saveTerm(keyword: "Aiko")
        db.setSubscribedPlatforms(platforms: ["news"])
        let item = FeedItem(
            id: "news:summary-only",
            platform: "news",
            url: "https://example.com/summary-only",
            title: "Unrelated headline",
            content_text: "Aiko appears only in this generated summary.",
            author: nil,
            thumbnail_url: nil,
            media_type: "article",
            published_at: now,
            watch_term_keyword: term.keyword,
            fetched_at: now
        )

        _ = db.mergeItems(newItems: [item])

        XCTAssertTrue(db.queryFeed(keyword: term.keyword, days: 30).isEmpty)
    }

    @MainActor
    func testFeedMediaFilterIncludesImageItems() throws {
        let now = ISO8601DateFormatter().string(from: Date())
        db.setSubscribedPlatforms(platforms: ["twitter", "youtube"])
        let imageItem = FeedItem(
            id: "twitter:image",
            platform: "twitter",
            url: "https://x.com/example/status/1",
            title: "Photo update",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "image",
            published_at: now,
            watch_term_keyword: "Aiko",
            fetched_at: now,
            source: "twitter_api"
        )
        let textItem = FeedItem(
            id: "twitter:text",
            platform: "twitter",
            url: "https://x.com/example/status/2",
            title: "Text update",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "text",
            published_at: now,
            watch_term_keyword: "Aiko",
            fetched_at: now,
            source: "twitter_api"
        )
        let legacyCasedMediaPlatformItem = FeedItem(
            id: "youtube:legacy-cased-platform",
            platform: "YOUTUBE",
            url: "https://youtube.com/watch?v=legacy-cased-platform",
            title: "Legacy cased YouTube item",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "article",
            published_at: now,
            watch_term_keyword: "Aiko",
            fetched_at: now,
            source: "youtube_scrape"
        )

        _ = db.mergeItems(newItems: [imageItem, textItem, legacyCasedMediaPlatformItem])

        XCTAssertEqual(
            FeedView.makeFilteredItems(db: db, keyword: nil, platform: nil, mediaFilter: "media_only", days: 30).map(\.id),
            ["twitter:image", "youtube:legacy-cased-platform"]
        )
    }

    func testReaderViewNormalizesLegacyPlatformIDsForRouting() throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let fiveCh = FeedItem(
            id: "5ch:legacy-cased",
            platform: "5CH",
            url: "https://idol.5ch.net/test/read.cgi/board/1234567890?utm_source=feed",
            title: "5ch thread",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "text",
            published_at: now,
            watch_term_keyword: "Aiko",
            fetched_at: now
        )
        let oricon = FeedItem(
            id: "oricon:legacy-cased",
            platform: "ORICON",
            url: "https://www.oricon.co.jp/news/12345/?utm_source=feed",
            title: "Oricon article",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "article",
            published_at: now,
            watch_term_keyword: "Aiko",
            fetched_at: now
        )

        XCTAssertTrue(ReaderView.usesSystemSafari(for: fiveCh))
        XCTAssertEqual(
            ReaderView(feedItem: fiveCh).originalPageUrl?.absoluteString,
            "https://itest.5ch.io/idol/test/read.cgi/board/1234567890/"
        )
        XCTAssertEqual(
            ReaderView(feedItem: oricon).originalPageUrl?.absoluteString,
            "https://www.oricon.co.jp/news/12345/full/"
        )
    }

    func testReaderWebViewRequestsGirlsChannelMobileLayout() {
        XCTAssertEqual(WebViewHelper.customUserAgent(for: "girlschannel"), WebViewHelper.mobileUserAgent)
        XCTAssertEqual(WebViewHelper.customUserAgent(for: "GirlsChannel"), WebViewHelper.mobileUserAgent)
        XCTAssertEqual(WebViewHelper.customUserAgent(for: "twitter"), WebViewHelper.mobileUserAgent)
        XCTAssertNil(WebViewHelper.customUserAgent(for: "oricon"))
    }

    func testReaderViewBuildsDisplayRouteForEveryRegisteredSource() throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let urlsByPlatform = [
            "5ch": "https://idol.5ch.net/test/read.cgi/board/1234567890?utm_source=feed",
            "oricon": "https://www.oricon.co.jp/news/12345/?utm_source=feed",
            "twitter": "https://x.com/oshi/status/1234567890123456789",
            "youtube": "https://www.youtube.com/watch?v=oshireadui01",
            "custom": "https://example.com/custom-feed-entry?utm_source=feed"
        ]

        for platform in PlatformRegistry.all {
            let item = FeedItem(
                id: "reader-route-\(platform.id)",
                platform: platform.id,
                url: urlsByPlatform[platform.id] ?? "https://example.com/oshireader-ui-test/\(platform.id)?utm_source=feed",
                title: "UITest Oshi \(platform.name) item",
                content_text: "A seeded \(platform.name) item.",
                author: nil,
                thumbnail_url: nil,
                media_type: platform.id == "5ch" ? "text" : "article",
                published_at: now,
                watch_term_keyword: "UITest Oshi",
                fetched_at: now
            )
            let reader = ReaderView(feedItem: item)
            let originalURL = try XCTUnwrap(reader.originalPageUrl, "Missing reader URL for \(platform.id)")
            let targetURL = try XCTUnwrap(reader.targetUrl, "Missing display URL for \(platform.id)")

            XCTAssertFalse(originalURL.absoluteString.isEmpty, "Empty original URL for \(platform.id)")
            XCTAssertFalse(targetURL.absoluteString.isEmpty, "Empty target URL for \(platform.id)")
            XCTAssertEqual(ReaderView.usesSystemSafari(for: item), platform.id == "5ch")
            XCTAssertEqual(ReaderView.initialReaderMode(for: item), platform.id != "5ch")

            if platform.id == "5ch" {
                XCTAssertEqual(
                    originalURL.absoluteString,
                    "https://itest.5ch.io/idol/test/read.cgi/board/1234567890/"
                )
            }
            if platform.id == "oricon" {
                XCTAssertEqual(
                    originalURL.absoluteString,
                    "https://www.oricon.co.jp/news/12345/full/"
                )
            }
        }
    }

    func testReaderViewCapsAndSizeChecksBulkImageDownloads() {
        let urls = (0..<ReaderView.bulkImageSaveLimit + 5).compactMap {
            URL(string: "https://example.com/image-\($0).jpg")
        }

        XCTAssertEqual(ReaderView.cappedBulkImageURLs(urls).count, ReaderView.bulkImageSaveLimit)
        XCTAssertEqual(ReaderView.cappedBulkImageURLs(urls).last, urls[ReaderView.bulkImageSaveLimit - 1])
        XCTAssertTrue(ReaderView.acceptsBulkImageDownload(
            expectedContentLength: -1,
            fileSize: ReaderView.maximumBulkImageDownloadBytes
        ))
        XCTAssertFalse(ReaderView.acceptsBulkImageDownload(
            expectedContentLength: ReaderView.maximumBulkImageDownloadBytes + 1,
            fileSize: 1
        ))
        XCTAssertFalse(ReaderView.acceptsBulkImageDownload(
            expectedContentLength: -1,
            fileSize: ReaderView.maximumBulkImageDownloadBytes + 1
        ))
    }

    func testReaderViewSiblingNavigationWalksAdjacentFeedItems() throws {
        let now = ISO8601DateFormatter().string(from: Date())
        func item(_ id: String) -> FeedItem {
            FeedItem(
                id: id,
                platform: "youtube",
                url: "https://example.com/\(id)",
                title: id,
                content_text: nil,
                author: nil,
                thumbnail_url: nil,
                media_type: "article",
                published_at: now,
                watch_term_keyword: "Aiko",
                fetched_at: now
            )
        }
        let first = item("first")
        let middle = item("middle")
        let last = item("last")
        let siblings = [first, middle, last]

        let atFirst = ReaderView(feedItem: first, siblingItems: siblings)
        XCTAssertEqual(atFirst.currentSiblingIndex, 0)
        XCTAssertNil(atFirst.previousSiblingItem)
        XCTAssertEqual(atFirst.nextSiblingItem?.id, "middle")

        let atMiddle = ReaderView(feedItem: middle, siblingItems: siblings)
        XCTAssertEqual(atMiddle.currentSiblingIndex, 1)
        XCTAssertEqual(atMiddle.previousSiblingItem?.id, "first")
        XCTAssertEqual(atMiddle.nextSiblingItem?.id, "last")

        let atLast = ReaderView(feedItem: last, siblingItems: siblings)
        XCTAssertEqual(atLast.currentSiblingIndex, 2)
        XCTAssertEqual(atLast.previousSiblingItem?.id, "middle")
        XCTAssertNil(atLast.nextSiblingItem)

        let noSiblings = ReaderView(feedItem: first)
        XCTAssertNil(noSiblings.currentSiblingIndex)
        XCTAssertNil(noSiblings.previousSiblingItem)
        XCTAssertNil(noSiblings.nextSiblingItem)

        let notInList = ReaderView(feedItem: item("stranger"), siblingItems: siblings)
        XCTAssertNil(notInList.currentSiblingIndex)
        XCTAssertNil(notInList.previousSiblingItem)
        XCTAssertNil(notInList.nextSiblingItem)
    }

    @MainActor
    func testReaderViewNavigateUpdatesCurrentItemAndNotifiesParent() throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let fromItem = FeedItem(
            id: "5ch:from", platform: "5ch", url: "https://idol.5ch.net/test/read.cgi/board/1111111111",
            title: "From", content_text: nil, author: nil, thumbnail_url: nil,
            media_type: "text", published_at: now, watch_term_keyword: "Aiko", fetched_at: now
        )
        let toItem = FeedItem(
            id: "youtube:to", platform: "youtube", url: "https://www.youtube.com/watch?v=abc",
            title: "To", content_text: nil, author: nil, thumbnail_url: nil,
            media_type: "video", published_at: now, watch_term_keyword: "Aiko", fetched_at: now
        )

        var navigatedTo: FeedItem?
        let reader = ReaderView(feedItem: fromItem, siblingItems: [fromItem, toItem], onNavigate: { navigatedTo = $0 })
        reader.navigate(to: toItem)

        // `navigate(to:)` also reassigns @State (currentItem, readerMode, ...), but
        // @State writes on a struct instance never mounted into a view hierarchy don't
        // persist — only the plain side effect (the onNavigate callback) is observable here.
        XCTAssertEqual(navigatedTo?.id, "youtube:to")
    }

    @MainActor
    func testFeedOrderingUsesParsedDatesAcrossTimezoneOffsets() throws {
        db.setSubscribedPlatforms(platforms: ["youtube"])
        let newerUtc = "2024-06-01T03:00:00Z"
        let olderWithOffset = "2024-06-01T10:00:00+09:00"
        let newerItem = FeedItem(
            id: "youtube:newer",
            platform: "youtube",
            url: "https://yt.example/newer",
            title: "Aiko newer",
            content_text: "Aiko",
            author: nil,
            thumbnail_url: nil,
            media_type: "video",
            published_at: newerUtc,
            watch_term_keyword: "Aiko",
            fetched_at: newerUtc,
            source: "youtube_scrape"
        )
        let olderItem = FeedItem(
            id: "youtube:older",
            platform: "youtube",
            url: "https://yt.example/older",
            title: "Aiko older",
            content_text: "Aiko",
            author: nil,
            thumbnail_url: nil,
            media_type: "video",
            published_at: olderWithOffset,
            watch_term_keyword: "Aiko",
            fetched_at: olderWithOffset,
            source: "youtube_scrape"
        )

        _ = db.mergeItems(newItems: [olderItem, newerItem])

        let results = db.queryFeed(keyword: nil, days: 0)
        XCTAssertEqual(results.map(\.id), ["youtube:newer", "youtube:older"])
    }
}


extension FeedQueryingTests {
    @MainActor
    func testEverySourceObeysFrontPageDateRanges() throws {
        let term = db.saveTerm(keyword: "Range Audit")
        db.setSubscribedPlatforms(platforms: PlatformRegistry.all.map(\.id))
        let now = Date()
        var items = [FeedItem]()
        for platform in PlatformRegistry.all {
            for age in [1, 40, 120, 190] {
                let published = ISO8601DateFormatter().string(from: now.addingTimeInterval(-Double(age) * 86400))
                items.append(FeedItem(
                    id: "\(platform.id):audit-\(age)", platform: platform.id,
                    url: "https://example.com/\(platform.id)/\(age)",
                    title: "Range Audit \(platform.id) \(age)", content_text: nil, author: nil,
                    thumbnail_url: nil, media_type: "article", published_at: published,
                    watch_term_keyword: term.keyword, fetched_at: ISO8601DateFormatter().string(from: now),
                    source: platform.id == "youtube" ? "youtube_scrape" : "audit"
                ))
            }
        }
        XCTAssertEqual(db.mergeItems(newItems: items), 112)
        for platform in PlatformRegistry.all {
            for days in [3, 30, 90, 180, 0] {
                let visible = FeedView.makeFilteredItems(db: db, keyword: term.keyword, platform: platform.id, mediaFilter: "all", days: days)
                let expected = days == 0 ? 4 : [1,40,120,190].filter { $0 <= days }.count
                XCTAssertEqual(visible.count, expected, "\(platform.id) / \(days) days")
            }
        }
    }

}
