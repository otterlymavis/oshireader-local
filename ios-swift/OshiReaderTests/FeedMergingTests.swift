import XCTest
import SwiftUI
import UIKit
import UserNotifications
@testable import OshiReader

final class FeedMergingTests: XCTestCase {

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
    func testMergeSearchFallbackItemsAreDroppedByPrefixOnly() throws {
        let nowString = ISO8601DateFormatter().string(from: Date())
        let fallbackItem = FeedItem(
            id: "search:fallback",
            platform: "news",
            url: "https://example.com/search",
            title: "search: result",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "article",
            published_at: nowString,
            watch_term_keyword: "Oshi",
            fetched_at: nowString
        )
        let legitimateItem = FeedItem(
            id: "news:how-to-search:guide",
            platform: "news",
            url: "https://example.com/how-to-search-guide",
            title: "Oshi guide: search: advanced tips",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "article",
            published_at: nowString,
            watch_term_keyword: "Oshi",
            fetched_at: nowString
        )

        XCTAssertEqual(db.mergeItems(newItems: [fallbackItem]), 0)
        XCTAssertTrue(db.feedItems.isEmpty)

        XCTAssertEqual(db.mergeItems(newItems: [legitimateItem]), 1)
        XCTAssertEqual(db.queryFeed(keyword: nil, days: 0).map(\.id), [legitimateItem.id])
    }

    @MainActor
    func testFeedItemsMerge() throws {
        let nowString = ISO8601DateFormatter().string(from: Date())
        let item1 = FeedItem(
            id: "youtube:123",
            platform: "youtube",
            url: "https://youtube.com/watch?v=123",
            title: "Oshi Concert",
            content_text: "Oshi sings wonderfully",
            author: "Oshi Channel",
            thumbnail_url: nil,
            media_type: "video",
            published_at: nowString,
            watch_term_keyword: "Oshi",
            fetched_at: nowString,
            source: "youtube_scrape"
        )
        
        // Duplicate item with shorter title
        let item1Duplicate = FeedItem(
            id: "youtube:123",
            platform: "youtube",
            url: "https://youtube.com/watch?v=123",
            title: "Oshi",
            content_text: "Oshi sings wonderfully",
            author: "Oshi Channel",
            thumbnail_url: nil,
            media_type: "video",
            published_at: nowString,
            watch_term_keyword: "Oshi",
            fetched_at: nowString,
            source: "youtube_scrape"
        )
        
        let item2 = FeedItem(
            id: "tver:456",
            platform: "tver",
            url: "https://tver.jp/episodes/456",
            title: "Oshi Drama",
            content_text: "Oshi acts nicely",
            author: "Drama Channel",
            thumbnail_url: nil,
            media_type: "video",
            published_at: nowString,
            watch_term_keyword: "Oshi",
            fetched_at: nowString
        )
        
        // Merge item1
        let added1 = db.mergeItems(newItems: [item1])
        XCTAssertEqual(added1, 1)
        XCTAssertEqual(db.feedItems.count, 1)
        XCTAssertEqual(db.feedItems.first?.title, "Oshi Concert")
        
        // Merge duplicate - title should NOT be shortened because original title is longer and better
        let addedDup = db.mergeItems(newItems: [item1Duplicate])
        XCTAssertEqual(addedDup, 0) // No new item added
        XCTAssertEqual(db.feedItems.count, 1)
        XCTAssertEqual(db.feedItems.first?.title, "Oshi Concert")
        
        // Merge item2
        let added2 = db.mergeItems(newItems: [item2])
        XCTAssertEqual(added2, 1)
        XCTAssertEqual(db.feedItems.count, 2)
    }

    @MainActor
    func testMergeItemsBackfillsMissingTitleWithoutForceUnwrap() throws {
        let nowString = ISO8601DateFormatter().string(from: Date())
        let original = FeedItem(
            id: "youtube:nil-title",
            platform: "youtube",
            url: "https://youtube.com/watch?v=nil-title",
            title: nil,
            content_text: "Initial content",
            author: nil,
            thumbnail_url: nil,
            media_type: "video",
            published_at: nowString,
            watch_term_keyword: "Oshi",
            fetched_at: nowString,
            source: "youtube_scrape"
        )
        let updated = FeedItem(
            id: original.id,
            platform: original.platform,
            url: original.url,
            title: "Recovered video title",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: original.media_type,
            published_at: nowString,
            watch_term_keyword: original.watch_term_keyword,
            fetched_at: nowString,
            source: "youtube_scrape"
        )

        XCTAssertEqual(db.mergeItems(newItems: [original]), 1)
        XCTAssertEqual(db.mergeItems(newItems: [updated]), 0)

        XCTAssertEqual(db.feedItems.first?.title, "Recovered video title")
    }

    @MainActor
    func testMergeRefreshesExistingArticlePublishedDateForCurrentFeed() throws {
        let formatter = ISO8601DateFormatter()
        let oldDate = formatter.string(from: Date().addingTimeInterval(-45 * 86400))
        let newDate = formatter.string(from: Date())
        let original = FeedItem(
            id: "news:updated-article",
            platform: "news",
            url: "https://example.com/updated-article",
            title: "Oshi old article",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "article",
            published_at: oldDate,
            watch_term_keyword: "Oshi",
            fetched_at: oldDate,
            source: "google_news"
        )
        let refreshed = FeedItem(
            id: original.id,
            platform: original.platform,
            url: original.url,
            title: "Oshi updated article with fresh details",
            content_text: "Fresh source summary",
            author: nil,
            thumbnail_url: nil,
            media_type: original.media_type,
            published_at: newDate,
            watch_term_keyword: original.watch_term_keyword,
            fetched_at: newDate,
            source: "google_news"
        )

        db.setSubscribedPlatforms(platforms: ["news"])
        XCTAssertEqual(db.mergeItems(newItems: [original]), 1)
        XCTAssertTrue(db.queryFeed(keyword: "Oshi", days: 30).isEmpty)

        XCTAssertEqual(db.mergeItems(newItems: [refreshed]), 0)

        XCTAssertEqual(db.feedItems.first?.published_at, newDate)
        XCTAssertEqual(db.queryFeed(keyword: "Oshi", days: 30).map(\.id), [original.id])
    }

    @MainActor
    func testBatchedMergeMatchesSingleMergeSemantics() throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let first = FeedItem(
            id: "batch:first", platform: "news", url: "https://example.com/first",
            title: "First", content_text: nil, author: nil, thumbnail_url: nil,
            media_type: "article", published_at: now, watch_term_keyword: "Batch", fetched_at: now
        )
        let second = FeedItem(
            id: "batch:second", platform: "news", url: "https://example.com/second",
            title: "Second", content_text: nil, author: nil, thumbnail_url: nil,
            media_type: "article", published_at: now, watch_term_keyword: "Batch", fetched_at: now
        )

        let added = db.mergeItemsBatched(newItemsBatches: [[first], [second]])
        XCTAssertEqual(added, 2)
        XCTAssertEqual(Set(db.feedItems.map(\.id)), Set([first.id, second.id]))
    }

    @MainActor
    func testMergePreservesNewlyAddedItemThroughFeedCap() throws {
        let formatter = ISO8601DateFormatter()
        let baseDate = Date(timeIntervalSince1970: 1_800_000_000)
        db.feedItems = (0..<600).map { index in
            FeedItem(
                id: "existing:\(index)",
                platform: "news",
                url: "https://example.com/existing/\(index)",
                title: "Existing \(index)",
                content_text: nil,
                author: nil,
                thumbnail_url: nil,
                media_type: "article",
                published_at: formatter.string(from: baseDate.addingTimeInterval(TimeInterval(-index))),
                watch_term_keyword: "Cap Oshi",
                fetched_at: formatter.string(from: baseDate)
            )
        }
        let evictedExistingID = "existing:599"
        let incoming = FeedItem(
            id: "incoming:older",
            platform: "news",
            url: "https://example.com/incoming/older",
            title: "Older incoming",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "article",
            published_at: formatter.string(from: baseDate.addingTimeInterval(-10_000)),
            watch_term_keyword: "Cap Oshi",
            fetched_at: formatter.string(from: baseDate)
        )

        XCTAssertEqual(db.mergeItems(newItems: [incoming]), 1)

        XCTAssertEqual(db.feedItems.count, 600)
        XCTAssertTrue(db.feedItems.contains { $0.id == incoming.id })
        XCTAssertFalse(db.feedItems.contains { $0.id == evictedExistingID })
    }

    @MainActor
    func testLegacyYouTubeFallbackPolicyIdentifiesOldCacheRows() {
        let now = ISO8601DateFormatter().string(from: Date())
        let unmarkedYouTube = FeedItem(
            id: "youtube:legacy",
            platform: "youtube",
            url: "https://youtube.com/watch?v=legacy",
            title: "Legacy",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "video",
            published_at: now,
            watch_term_keyword: "Legacy Oshi",
            fetched_at: now
        )
        let googleNewsYouTube = FeedItem(
            id: "youtube:gnews:legacy",
            platform: "youtube",
            url: "https://news.google.com/rss/articles/legacy",
            title: "Legacy Google News",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "video",
            published_at: now,
            watch_term_keyword: "Legacy Oshi",
            fetched_at: now,
            source: "google_news"
        )
        let paddedGoogleNewsYouTube = FeedItem(
            id: "youtube:padded-source",
            platform: "youtube",
            url: "https://youtube.com/watch?v=padded",
            title: "Padded source",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "video",
            published_at: now,
            watch_term_keyword: "Legacy Oshi",
            fetched_at: now,
            source: " Google_News "
        )
        let currentYouTube = FeedItem(
            id: "youtube:current",
            platform: "youtube",
            url: "https://youtube.com/watch?v=current",
            title: "Current",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "video",
            published_at: now,
            watch_term_keyword: "Legacy Oshi",
            fetched_at: now,
            source: "youtube_scrape"
        )

        XCTAssertTrue(FeedItemPolicy.shouldPruneLegacyYouTubeItem(unmarkedYouTube))
        XCTAssertTrue(FeedItemPolicy.shouldPruneLegacyYouTubeItem(googleNewsYouTube))
        XCTAssertTrue(FeedItemPolicy.shouldPruneLegacyYouTubeItem(paddedGoogleNewsYouTube))
        XCTAssertFalse(FeedItemPolicy.shouldPruneLegacyYouTubeItem(currentYouTube))
    }

    @MainActor
    func testMergeItemsDropsLegacyYouTubeRowsButKeepsCurrentScrapeRows() {
        let now = ISO8601DateFormatter().string(from: Date())
        db.setSubscribedPlatforms(platforms: ["youtube"])
        db.feedItems = [
            FeedItem(
                id: "youtube:cached-legacy",
                platform: "youtube",
                url: "https://youtube.com/watch?v=cached-legacy",
                title: "Cached legacy",
                content_text: nil,
                author: nil,
                thumbnail_url: nil,
                media_type: "video",
                published_at: now,
                watch_term_keyword: "YouTube Oshi",
                fetched_at: now
            )
        ]
        let incomingLegacy = FeedItem(
            id: "youtube:gnews:incoming",
            platform: "youtube",
            url: "https://news.google.com/rss/articles/incoming",
            title: "Incoming legacy",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "video",
            published_at: now,
            watch_term_keyword: "YouTube Oshi",
            fetched_at: now,
            source: "google_news"
        )
        let current = FeedItem(
            id: "youtube:current",
            platform: "youtube",
            url: "https://youtube.com/watch?v=current",
            title: "Current",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "video",
            published_at: now,
            watch_term_keyword: "YouTube Oshi",
            fetched_at: now,
            source: "youtube_scrape"
        )

        XCTAssertEqual(db.mergeItems(newItems: [incomingLegacy, current]), 1)
        XCTAssertEqual(db.feedItems.map(\.id), ["youtube:current"])
        XCTAssertEqual(db.queryFeed(keyword: nil, days: 30).map(\.id), ["youtube:current"])
    }

    @MainActor
    func testQueryFeedDedupesCanonicalURLVariants() throws {
        let now = ISO8601DateFormatter().string(from: Date())
        db.setSubscribedPlatforms(platforms: ["news"])
        _ = db.saveTerm(keyword: "Aiko")

        let trackedURL = FeedItem(
            id: "news:tracked",
            platform: "news",
            url: "http://www.example.com/story/123/?utm_source=feed&ref=home",
            title: "Aiko announces new tour",
            content_text: "Aiko announces new tour",
            author: nil,
            thumbnail_url: nil,
            media_type: "article",
            published_at: now,
            watch_term_keyword: "Aiko",
            fetched_at: now
        )
        let cleanURL = FeedItem(
            id: "news:clean",
            platform: "news",
            url: "https://example.com/story/123",
            title: "Aiko announces new tour",
            content_text: "Aiko announces new tour",
            author: nil,
            thumbnail_url: nil,
            media_type: "article",
            published_at: now,
            watch_term_keyword: "Aiko",
            fetched_at: now
        )

        _ = db.mergeItems(newItems: [trackedURL, cleanURL])

        XCTAssertEqual(db.queryFeed(keyword: "Aiko", days: 30).map(\.id), ["news:clean", "news:tracked"])
        XCTAssertEqual(db.queryFeed(keyword: nil, days: 30).map(\.id), ["news:clean"])
    }

    @MainActor
    func testQueryFeedDoesNotDedupeCaseSensitiveURLPaths() throws {
        let now = ISO8601DateFormatter().string(from: Date())
        db.setSubscribedPlatforms(platforms: ["news"])
        _ = db.saveTerm(keyword: "Aiko")

        let upperPath = FeedItem(
            id: "news:upper-path",
            platform: "news",
            url: "https://example.com/Story/Aiko",
            title: "Aiko announces north tour",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "article",
            published_at: now,
            watch_term_keyword: "Aiko",
            fetched_at: now
        )
        let lowerPath = FeedItem(
            id: "news:lower-path",
            platform: "news",
            url: "https://example.com/story/Aiko",
            title: "Aiko announces south tour",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "article",
            published_at: now,
            watch_term_keyword: "Aiko",
            fetched_at: now
        )

        _ = db.mergeItems(newItems: [upperPath, lowerPath])

        XCTAssertEqual(
            Set(db.queryFeed(keyword: "Aiko", days: 30).map(\.id)),
            Set(["news:upper-path", "news:lower-path"])
        )
    }

    @MainActor
    func testQueryFeedDedupesArticleTitlePublisherSuffixes() throws {
        let formatter = ISO8601DateFormatter()
        let newer = formatter.string(from: Date(timeIntervalSince1970: 1_800_000_060))
        let older = formatter.string(from: Date(timeIntervalSince1970: 1_800_000_000))
        db.setSubscribedPlatforms(platforms: ["mdpr", "oricon"])
        _ = db.saveTerm(keyword: "Aiko")

        let mdprCopy = FeedItem(
            id: "mdpr:copy",
            platform: "mdpr",
            url: "https://mdpr.jp/news/123",
            title: "Aiko 新曲と全国ツアー開催を発表！ - モデルプレス",
            content_text: "Aiko 新曲と全国ツアー開催を発表",
            author: nil,
            thumbnail_url: nil,
            media_type: "article",
            published_at: newer,
            watch_term_keyword: "Aiko",
            fetched_at: newer
        )
        let oriconCopy = FeedItem(
            id: "oricon:copy",
            platform: "oricon",
            url: "https://oricon.co.jp/news/456/",
            title: "Aiko 新曲と全国ツアー開催を発表！（ORICON NEWS）",
            content_text: "Aiko 新曲と全国ツアー開催を発表",
            author: nil,
            thumbnail_url: nil,
            media_type: "article",
            published_at: older,
            watch_term_keyword: "Aiko",
            fetched_at: older
        )

        _ = db.mergeItems(newItems: [oriconCopy, mdprCopy])

        XCTAssertEqual(db.queryFeed(keyword: "Aiko", days: 30).map(\.id), ["mdpr:copy", "oricon:copy"])
        XCTAssertEqual(db.queryFeed(keyword: nil, days: 30).map(\.id), ["mdpr:copy"])
    }

    @MainActor
    func testFeedCapRetainsMoreDiscussionPlatformItems() throws {
        db.setSubscribedPlatforms(platforms: ["news", "5ch"])
        let formatter = ISO8601DateFormatter()
        let baseDate = Date(timeIntervalSince1970: 1_800_000_000)
        let newsItems = (0..<600).map { index in
            FeedItem(
                id: "news:cap:\(index)",
                platform: "news",
                url: "https://example.com/news/\(index)",
                title: "Aiko news \(index)",
                content_text: "Aiko news content",
                author: nil,
                thumbnail_url: nil,
                media_type: "article",
                published_at: formatter.string(from: baseDate.addingTimeInterval(TimeInterval(600 - index))),
                watch_term_keyword: "Aiko",
                fetched_at: formatter.string(from: baseDate)
            )
        }
        let fiveChItems = (0..<30).map { index in
            FeedItem(
                id: "5ch:cap:\(index)",
                platform: "5ch",
                url: "https://example.5ch.net/test/read.cgi/thread/\(index)",
                title: "Aiko thread \(index)",
                content_text: "Aiko discussion",
                author: nil,
                thumbnail_url: nil,
                media_type: "article",
                published_at: formatter.string(from: baseDate.addingTimeInterval(TimeInterval(index))),
                watch_term_keyword: "Aiko",
                fetched_at: formatter.string(from: baseDate)
            )
        }

        XCTAssertEqual(db.mergeItems(newItems: newsItems + fiveChItems), 630)

        XCTAssertEqual(db.feedItems.count, 600)
        XCTAssertEqual(db.feedItems.filter { $0.platform == "5ch" }.count, 25)
    }

    @MainActor
    func testNotificationManagerSchedulesTestNotificationAfterAuthorization() async throws {
        let center = MockNotificationCenter(status: .notDetermined, grantsAuthorization: true)
        let manager = NotificationManager(center: center)

        try await manager.sendTestNotification()

        XCTAssertEqual(center.authorizationRequestCount, 1)
        XCTAssertEqual(center.requests.count, 1)
        XCTAssertEqual(center.requests.first?.content.title, "OshiReader")
        XCTAssertEqual(center.requests.first?.content.body, "Notifications are ready.")
        XCTAssertNotNil(center.requests.first?.trigger)
    }

    @MainActor
    func testRemoteRegistrationRetriesSameTokenAfterTransientBackendFailure() async {
        let center = MockNotificationCenter(status: .authorized)
        var attempts: [String] = []
        let manager = NotificationManager(
            center: center,
            registeredTokenProvider: { nil },
            remoteRegistration: {},
            registerDeviceToken: { token in
                attempts.append(token)
                if attempts.count == 1 { throw URLError(.timedOut) }
            },
            registrationRetryDelays: [0],
            retrySleeper: { _ in }
        )

        await manager.handleRegisteredDeviceToken(Data([0x0a, 0xff]))
        while attempts.count < 2 { await Task.yield() }

        XCTAssertEqual(attempts, ["0aff", "0aff"])
        XCTAssertTrue(manager.hasRemoteDeviceToken)
        XCTAssertNil(manager.lastRemoteRegistrationError)
    }

    @MainActor
    func testRemoteRegistrationStopsAfterBoundedRetryBudget() async {
        let center = MockNotificationCenter(status: .authorized)
        var attempts = 0
        let manager = NotificationManager(
            center: center,
            registeredTokenProvider: { nil },
            remoteRegistration: {},
            registerDeviceToken: { _ in
                attempts += 1
                throw URLError(.cannotConnectToHost)
            },
            registrationRetryDelays: [0, 0],
            retrySleeper: { _ in }
        )

        await manager.handleRegisteredDeviceToken(Data([0x01]))
        while attempts < 3 { await Task.yield() }
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(attempts, 3)
        XCTAssertFalse(manager.hasRemoteDeviceToken)
        XCTAssertNotNil(manager.lastRemoteRegistrationError)
    }

    @MainActor
    func testInvalidatingRemoteRegistrationClearsPersistedAndInMemoryState() {
        let originalToken = KeychainHelper.read(.apnsDeviceToken)
        let originalEnvironment = KeychainHelper.read(.apnsDeviceEnvironment)
        defer {
            _ = KeychainHelper.save(.apnsDeviceToken, originalToken)
            _ = KeychainHelper.save(.apnsDeviceEnvironment, originalEnvironment)
        }
        _ = KeychainHelper.save(.apnsDeviceToken, "cached-token")
        _ = KeychainHelper.save(.apnsDeviceEnvironment, BackendClient.shared.apnsEnvironment)
        let center = MockNotificationCenter(status: .authorized)
        let manager = NotificationManager(
            center: center,
            initialRegisteredDeviceToken: "cached-token",
            registeredTokenProvider: {
                BackendClient.shared.hasRegisteredAPNSDeviceForCurrentEnvironment
                    ? KeychainHelper.read(.apnsDeviceToken)
                    : nil
            },
            remoteRegistration: {}
        )
        XCTAssertTrue(manager.hasRemoteDeviceToken)

        manager.invalidateRemoteNotificationRegistration()

        XCTAssertFalse(manager.hasRemoteDeviceToken)
        XCTAssertNil(KeychainHelper.read(.apnsDeviceToken))
        XCTAssertNil(KeychainHelper.read(.apnsDeviceEnvironment))
        XCTAssertFalse(BackendClient.shared.hasRegisteredAPNSDeviceForCurrentEnvironment)
    }

    @MainActor
    func testConditionalRemoteRegistrationInvalidationPreservesNewerTokenAndEnvironment() async {
        let originalToken = KeychainHelper.read(.apnsDeviceToken)
        let originalEnvironment = KeychainHelper.read(.apnsDeviceEnvironment)
        defer {
            _ = KeychainHelper.save(.apnsDeviceToken, originalToken)
            _ = KeychainHelper.save(.apnsDeviceEnvironment, originalEnvironment)
        }
        _ = KeychainHelper.save(.apnsDeviceToken, "old-token")
        _ = KeychainHelper.save(.apnsDeviceEnvironment, "sandbox")
        let center = MockNotificationCenter(status: .authorized)
        let manager = NotificationManager(
            center: center,
            initialRegisteredDeviceToken: "old-token",
            registeredTokenProvider: { KeychainHelper.read(.apnsDeviceToken) },
            remoteRegistration: {},
            registerDeviceToken: { token in
                _ = KeychainHelper.save(.apnsDeviceToken, token)
                _ = KeychainHelper.save(.apnsDeviceEnvironment, "production")
            },
            registrationRetryDelays: []
        )

        await manager.handleRegisteredDeviceToken(Data([0xab, 0xcd]))
        let cleared = manager.invalidateRemoteNotificationRegistration(
            ifTokenMatches: "old-token",
            environment: "sandbox"
        )

        XCTAssertFalse(cleared)
        XCTAssertTrue(manager.hasRemoteDeviceToken)
        XCTAssertEqual(KeychainHelper.read(.apnsDeviceToken), "abcd")
        XCTAssertEqual(KeychainHelper.read(.apnsDeviceEnvironment), "production")
    }

    @MainActor
    func testConditionalRemoteRegistrationInvalidationClearsMatchingState() {
        let originalToken = KeychainHelper.read(.apnsDeviceToken)
        let originalEnvironment = KeychainHelper.read(.apnsDeviceEnvironment)
        defer {
            _ = KeychainHelper.save(.apnsDeviceToken, originalToken)
            _ = KeychainHelper.save(.apnsDeviceEnvironment, originalEnvironment)
        }
        _ = KeychainHelper.save(.apnsDeviceToken, "matching-token")
        _ = KeychainHelper.save(.apnsDeviceEnvironment, "sandbox")
        let manager = NotificationManager(
            center: MockNotificationCenter(status: .authorized),
            initialRegisteredDeviceToken: "matching-token",
            registeredTokenProvider: { KeychainHelper.read(.apnsDeviceToken) },
            remoteRegistration: {}
        )

        let cleared = manager.invalidateRemoteNotificationRegistration(
            ifTokenMatches: "matching-token",
            environment: "sandbox"
        )

        XCTAssertTrue(cleared)
        XCTAssertFalse(manager.hasRemoteDeviceToken)
        XCTAssertNil(KeychainHelper.read(.apnsDeviceToken))
        XCTAssertNil(KeychainHelper.read(.apnsDeviceEnvironment))
    }

    @MainActor
    func testGuaranteedPushPreflightRevalidatesCachedTokenWithoutSystemCallback() async {
        let center = MockNotificationCenter(status: .authorized)
        var registeredTokens: [String] = []
        var systemRegistrationCount = 0
        let manager = NotificationManager(
            center: center,
            initialRegisteredDeviceToken: "cached-token",
            registeredTokenProvider: { "cached-token" },
            remoteRegistration: { systemRegistrationCount += 1 },
            registerDeviceToken: { registeredTokens.append($0) },
            registrationRetryDelays: [],
            retrySleeper: { _ in }
        )

        let registered = await manager.ensureRemoteNotificationsRegistered(
            timeout: 1,
            forceRefresh: true
        )

        XCTAssertTrue(registered)
        XCTAssertEqual(registeredTokens, ["cached-token"])
        XCTAssertEqual(systemRegistrationCount, 0)
    }

    @MainActor
    func testNotificationStatusAndPreviewCategoryUseLocalizedPlusContract() async {
        let i18n = I18nManager.shared
        let originalLanguage = i18n.lang
        defer { i18n.setLanguage(originalLanguage) }
        i18n.setLanguage("ja")

        let enabledCenter = MockNotificationCenter(status: .authorized)
        let enabledManager = NotificationManager(center: enabledCenter)
        await enabledManager.refreshAuthorizationStatus()
        XCTAssertEqual(enabledManager.statusText, "有効")

        let quietCenter = MockNotificationCenter(status: .provisional)
        let quietManager = NotificationManager(center: quietCenter)
        await quietManager.refreshAuthorizationStatus()
        XCTAssertEqual(quietManager.statusText, "控えめに有効")

        let deniedCenter = MockNotificationCenter(status: .denied)
        let deniedManager = NotificationManager(center: deniedCenter)
        await deniedManager.refreshAuthorizationStatus()
        XCTAssertEqual(deniedManager.statusText, "iOS設定で無効")

        enabledManager.registerNotificationCategories()
        let category = enabledCenter.categories.first
        XCTAssertEqual(enabledCenter.categories.count, 1)
        XCTAssertEqual(category?.identifier, NotificationManager.categoryIdentifier)
        XCTAssertEqual(category?.actions.map(\.identifier), [
            NotificationManager.openActionIdentifier,
            NotificationManager.saveActionIdentifier,
        ])
        XCTAssertEqual(category?.actions.map(\.title), [i18n.t("openNotification"), i18n.t("save")])
        XCTAssertTrue(category?.options.contains(.customDismissAction) == true)
    }

    @MainActor
    func testLocalAlertPermissionHelperRequestsWhenNeeded() async throws {
        let center = MockNotificationCenter(status: .notDetermined, grantsAuthorization: true)
        let manager = NotificationManager(center: center)

        let canSchedule = await manager.requestAuthorizationIfNeededForLocalAlerts()

        XCTAssertTrue(canSchedule)
        XCTAssertEqual(center.authorizationRequestCount, 1)
        XCTAssertEqual(center.status, .authorized)
    }

    @MainActor
    func testLocalAlertPermissionHelperDoesNotRequestWhenAlreadyAllowed() async throws {
        let center = MockNotificationCenter(status: .authorized)
        let manager = NotificationManager(center: center)
        await manager.refreshAuthorizationStatus()

        let canSchedule = await manager.requestAuthorizationIfNeededForLocalAlerts()

        XCTAssertTrue(canSchedule)
        XCTAssertEqual(center.authorizationRequestCount, 0)
    }

    @MainActor
    func testLocalAlertPermissionHelperDoesNotRequestWhenDenied() async throws {
        let center = MockNotificationCenter(status: .denied, grantsAuthorization: true)
        let manager = NotificationManager(center: center)
        await manager.refreshAuthorizationStatus()

        let canSchedule = await manager.requestAuthorizationIfNeededForLocalAlerts()

        XCTAssertFalse(canSchedule)
        XCTAssertEqual(center.authorizationRequestCount, 0)
        XCTAssertEqual(center.status, .denied)
    }

    @MainActor
    func testConcurrentAuthorizationRequestsShareOneSystemPrompt() async throws {
        let center = MockNotificationCenter(status: .notDetermined, grantsAuthorization: true)
        let manager = NotificationManager(center: center)

        async let first = manager.requestAuthorization()
        async let second = manager.requestAuthorization()
        let results = await (first, second)

        XCTAssertTrue(results.0)
        XCTAssertTrue(results.1)
        XCTAssertEqual(center.authorizationRequestCount, 1)
    }

    @MainActor
    func testWallpaperRendererFlattensComposition() throws {
        // Solid-color stand-in for a downloaded sticker (no network).
        let sz = CGSize(width: 40, height: 40)
        let sticker = UIGraphicsImageRenderer(size: sz).image { ctx in
            UIColor.systemPink.setFill()
            ctx.fill(CGRect(origin: .zero, size: sz))
        }
        let layer = AvatarLayer(imageUrl: "stub", x: 100, y: 100, scale: 1.0, zIndex: 1)

        let composed = WallpaperRenderer.compose([(layer, sticker)])
        XCTAssertNotNil(composed, "compose should flatten layers into an image")
        XCTAssertGreaterThan(composed?.size.width ?? 0, 0)
        XCTAssertNotNil(composed?.pngData(), "composed image should encode to PNG")

        // No layers → nothing to draw.
        XCTAssertNil(WallpaperRenderer.compose([]))
    }

    @MainActor
    func testWallpaperRendererWritesUniqueFileAndRemovesOlderRenderedWallpaper() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        let png = try XCTUnwrap(image.pngData())

        let first = try XCTUnwrap(WallpaperRenderer.writeRenderedPNGForTesting(png))
        let firstURL = WallpaperRenderer.localURL(for: first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path))

        let second = try XCTUnwrap(WallpaperRenderer.writeRenderedPNGForTesting(png))
        let secondURL = WallpaperRenderer.localURL(for: second)
        defer { try? FileManager.default.removeItem(at: secondURL) }

        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.hasPrefix("oshi_wallpaper_"))
        XCTAssertTrue(second.hasPrefix("oshi_wallpaper_"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
    }

    @MainActor
    func testPerTermNotificationsOnlyScheduleForEnabledTerms() async throws {
        let center = MockNotificationCenter(status: .authorized)
        let manager = NotificationManager(center: center)
        let oldString = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_800_000_000))
        let newString = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_800_000_060))

        let enabledTerm = WatchTerm(id: "enabled", keyword: "Enabled Oshi", notify_on_new: true)
        let disabledTerm = WatchTerm(id: "disabled", keyword: "Muted Oshi", notify_on_new: false)
        let items = [
            FeedItem(
                id: "youtube:enabled-1", platform: "youtube", url: "https://youtube.com/1",
                title: "Enabled first", content_text: "Enabled first details", author: nil, thumbnail_url: nil,
                media_type: "video", published_at: oldString, watch_term_keyword: enabledTerm.keyword,
                fetched_at: oldString, source: "youtube_scrape"
            ),
            FeedItem(
                id: "note:enabled-2", platform: "note", url: "https://note.com/2",
                title: "Enabled second", content_text: "Enabled second details", author: nil, thumbnail_url: nil,
                media_type: "article", published_at: newString, watch_term_keyword: enabledTerm.keyword,
                fetched_at: newString,
                source: "note_rss"
            ),
            FeedItem(
                id: "tver:muted", platform: "tver", url: "https://tver.jp/episodes/3",
                title: "Muted", content_text: nil, author: nil, thumbnail_url: nil,
                media_type: "video", published_at: newString, watch_term_keyword: disabledTerm.keyword,
                fetched_at: newString
            )
        ]

        await manager.notifyForNewItems(items, terms: [enabledTerm, disabledTerm])

        XCTAssertEqual(center.requests.count, 2)
        XCTAssertTrue(center.requests.allSatisfy { $0.content.title == "Enabled Oshi" })
        // Requests are submitted oldest-to-newest so iOS places the newest
        // delivery at the top of Notification Center.
        XCTAssertEqual(center.requests.first?.content.subtitle, "Enabled first")
        XCTAssertEqual(center.requests.first?.content.body, "Enabled first details")
        XCTAssertEqual(center.requests.last?.content.subtitle, "Enabled second")
        XCTAssertEqual(center.requests.last?.content.body, "Enabled second details")
        XCTAssertEqual(center.requests.last?.content.userInfo["source"] as? String, "note_rss")
        XCTAssertEqual(center.requests.last?.content.userInfo["item_title"] as? String, "Enabled second")
        XCTAssertEqual(
            (center.requests.last?.content.userInfo["preview_item"] as? [String: Any])?["content_text"] as? String,
            "Enabled second details"
        )
        XCTAssertEqual(center.requests.last?.content.threadIdentifier, center.requests.last?.identifier)
        XCTAssertEqual(Set(center.requests.map(\.content.threadIdentifier)).count, 2)
        XCTAssertEqual(center.requests.last?.content.targetContentIdentifier, "note:enabled-2")
        XCTAssertNil(center.requests.first?.trigger)
    }

    @MainActor
    func testNotificationBurstSchedulesEveryItemIndividually() async throws {
        let previousQuietHours = QuietHoursSettings.current()
        QuietHoursSettings(enabled: false, startMinuteOfDay: 22 * 60, endMinuteOfDay: 8 * 60).save()
        defer { previousQuietHours.save() }

        let center = MockNotificationCenter(status: .authorized)
        let manager = NotificationManager(center: center)
        let term = WatchTerm(id: "burst", keyword: "Burst Oshi", notify_on_new: true)
        let nowString = ISO8601DateFormatter().string(from: Date())
        let items = (1...4).map { index in
            FeedItem(
                id: "news:burst-\(index)", platform: "news", url: "https://example.com/burst-\(index)",
                title: "Burst item \(index)", content_text: nil, author: nil, thumbnail_url: nil,
                media_type: "article", published_at: nowString, watch_term_keyword: term.keyword,
                fetched_at: nowString
            )
        }

        await manager.notifyForNewItems(items, terms: [term], includeAttachments: false)

        XCTAssertEqual(center.requests.count, 4)
        XCTAssertEqual(
            Set(center.requests.map(\.identifier)),
            Set((1...4).map { "oshireader-new-term-burst-news:burst-\($0)" })
        )
        XCTAssertEqual(Set(center.requests.map(\.content.subtitle)), Set((1...4).map { "Burst item \($0)" }))
        XCTAssertEqual(Set(center.requests.map(\.content.threadIdentifier)), Set(center.requests.map(\.identifier)))
        // The batch trickles out: the first (oldest) banner fires immediately,
        // each subsequent one offset by a fixed 30s spacing.
        XCTAssertNil(center.requests.first?.trigger)
        let intervals = center.requests.dropFirst().map {
            ($0.trigger as? UNTimeIntervalNotificationTrigger)?.timeInterval
        }
        XCTAssertEqual(intervals, [30, 60, 90])
    }

    @MainActor
    func testNotificationBurstOverflowFoldsRemainderIntoPerKeywordSummary() async throws {
        let previousQuietHours = QuietHoursSettings.current()
        QuietHoursSettings(enabled: false, startMinuteOfDay: 22 * 60, endMinuteOfDay: 8 * 60).save()
        defer { previousQuietHours.save() }

        let center = MockNotificationCenter(status: .authorized)
        let manager = NotificationManager(center: center)
        let term = WatchTerm(id: "burst", keyword: "Burst Oshi", notify_on_new: true)
        // Staggered timestamps so newest-first order is index 27 -> 1.
        let items = (1...27).map { index in
            FeedItem(
                id: "news:burst-\(index)", platform: "news", url: "https://example.com/burst-\(index)",
                title: "Burst item \(index)", content_text: nil, author: nil, thumbnail_url: nil,
                media_type: "article",
                published_at: ISO8601DateFormatter().string(from: Date().addingTimeInterval(TimeInterval(index))),
                watch_term_keyword: term.keyword,
                fetched_at: ISO8601DateFormatter().string(from: Date())
            )
        }

        await manager.notifyForNewItems(items, terms: [term], includeAttachments: false)

        // 24 newest scheduled individually (index 4...27) + one summary for the rest.
        XCTAssertEqual(center.requests.count, 25)
        let summaries = center.requests.filter { $0.identifier == "oshireader-new-term-burst-summary" }
        XCTAssertEqual(summaries.count, 1)
        let summary = try XCTUnwrap(summaries.first)
        XCTAssertEqual(summary.content.title, "Burst Oshi")
        XCTAssertTrue(summary.content.body.contains("3"), "summary should count the 3 overflow items, got \(summary.content.body)")
        XCTAssertEqual(summary.content.threadIdentifier, summary.identifier)
        XCTAssertEqual(summary.content.targetContentIdentifier, "news:burst-3")
        XCTAssertNil(summary.trigger)

        let individual = center.requests.filter { $0.identifier != summary.identifier }
        XCTAssertEqual(
            Set(individual.map(\.identifier)),
            Set((4...27).map { "oshireader-new-term-burst-news:burst-\($0)" })
        )
        XCTAssertEqual(Set(individual.map(\.content.threadIdentifier)), Set(individual.map(\.identifier)))
        // Slot 0 is reserved for the immediately-delivered summary, so every
        // individual banner is time-triggered and none exceeds the 3 min spread.
        let individualIntervals = individual.compactMap {
            ($0.trigger as? UNTimeIntervalNotificationTrigger)?.timeInterval
        }
        XCTAssertEqual(individualIntervals.count, individual.count, "every individual banner is time-triggered when an overflow summary takes slot 0")
        XCTAssertTrue(individualIntervals.allSatisfy { $0 > 0 && $0 <= 180 }, "intervals within the spread, got \(individualIntervals.sorted())")
    }

    @MainActor
    func testLocalNotificationUsesPlusAlertLimitsAndSuppressesDuplicateBody() async throws {
        let center = MockNotificationCenter(status: .authorized)
        let manager = NotificationManager(center: center)
        let term = WatchTerm(id: "layout", keyword: "Layout Oshi", notify_on_new: true)
        let nowString = ISO8601DateFormatter().string(from: Date())
        let longTitle = String(repeating: "T", count: 60)
        let longBody = String(repeating: "B", count: 110)
        let longItem = FeedItem(
            id: "news:long-layout", platform: "news", url: "https://example.com/long-layout",
            title: longTitle, content_text: longBody, author: nil, thumbnail_url: nil,
            media_type: "article", published_at: nowString, watch_term_keyword: term.keyword,
            fetched_at: nowString
        )

        await manager.notifyForNewItems([longItem], terms: [term], includeAttachments: false)

        let content = try XCTUnwrap(center.requests.first?.content)
        XCTAssertEqual(content.title, "Layout Oshi")
        XCTAssertEqual(content.subtitle.count, 50)
        XCTAssertTrue(content.subtitle.hasSuffix("..."))
        XCTAssertEqual(content.body.count, 100)
        XCTAssertTrue(content.body.hasSuffix("..."))
        XCTAssertEqual(content.userInfo["item_title"] as? String, longTitle)
        XCTAssertEqual(content.userInfo["item_content_text"] as? String, longBody)

        let duplicateItem = FeedItem(
            id: "news:duplicate-layout", platform: "news", url: "https://example.com/duplicate-layout",
            title: "Same preview", content_text: "Same preview", author: nil, thumbnail_url: nil,
            media_type: "article", published_at: nowString, watch_term_keyword: term.keyword,
            fetched_at: nowString
        )
        await manager.notifyForNewItems([duplicateItem], terms: [term], includeAttachments: false)

        XCTAssertEqual(center.requests.last?.content.subtitle, "Same preview")
        XCTAssertEqual(center.requests.last?.content.body, "")
    }

    @MainActor
    func testBackendPushTermFallsBackLocallyWhenAPNSIsNotRegistered() async {
        PlusStore.shared.setPushDeliveryStateForTesting(.active)
        defer { PlusStore.shared.setPushDeliveryStateForTesting(.inactive) }
        let center = MockNotificationCenter(status: .authorized)
        let manager = NotificationManager(center: center)
        let term = WatchTerm(
            id: "backend-push",
            keyword: "Push Oshi",
            notify_on_new: true,
            backendTermID: 42
        )
        let now = ISO8601DateFormatter().string(from: Date())
        let item = FeedItem(
            id: "news:push", platform: "news", url: "https://example.com/push",
            title: "Push Oshi update", content_text: nil, author: nil, thumbnail_url: nil,
            media_type: "article", published_at: now, watch_term_keyword: term.keyword,
            fetched_at: now
        )

        await manager.notifyForNewItems([item], terms: [term])

        XCTAssertEqual(center.requests.count, 1)
    }

    func testPaidNotificationOwnershipRequiresBindingActiveDeliveryAndRegisteredAPNS() {
        let backendTerm = WatchTerm(
            id: "backend-routing",
            keyword: "Backend Oshi",
            notify_on_new: true,
            backendTermID: 44
        )
        let localTerm = WatchTerm(
            id: "local-routing",
            keyword: "Local Oshi",
            notify_on_new: true
        )
        let mutedTerm = WatchTerm(
            id: "muted-routing",
            keyword: "Muted Oshi",
            notify_on_new: false,
            backendTermID: 45
        )

        XCTAssertFalse(NotificationManager.shouldScheduleLocalNotification(
            for: backendTerm,
            pushDeliveryState: .active,
            hasRegisteredAPNSDevice: true
        ))
        XCTAssertTrue(NotificationManager.shouldScheduleLocalNotification(
            for: backendTerm,
            pushDeliveryState: .active,
            hasRegisteredAPNSDevice: false
        ))
        XCTAssertTrue(NotificationManager.shouldScheduleLocalNotification(
            for: backendTerm,
            pushDeliveryState: .inactive,
            hasRegisteredAPNSDevice: true
        ))
        XCTAssertTrue(NotificationManager.shouldScheduleLocalNotification(
            for: backendTerm,
            pushDeliveryState: .selectionRequired,
            hasRegisteredAPNSDevice: true
        ))
        XCTAssertTrue(NotificationManager.shouldScheduleLocalNotification(
            for: localTerm,
            pushDeliveryState: .active,
            hasRegisteredAPNSDevice: true
        ))
        XCTAssertFalse(NotificationManager.shouldScheduleLocalNotification(
            for: mutedTerm,
            pushDeliveryState: .inactive,
            hasRegisteredAPNSDevice: false
        ))
    }

    @MainActor
    func testPausedBackendPushTermFallsBackToLocalNotification() async {
        PlusStore.shared.setPushDeliveryStateForTesting(.selectionRequired)
        defer { PlusStore.shared.setPushDeliveryStateForTesting(.inactive) }
        let center = MockNotificationCenter(status: .authorized)
        let manager = NotificationManager(center: center)
        let term = WatchTerm(
            id: "paused-backend-push",
            keyword: "Fallback Oshi",
            notify_on_new: true,
            backendTermID: 43
        )
        let now = ISO8601DateFormatter().string(from: Date())
        let item = FeedItem(
            id: "news:fallback", platform: "news", url: "https://example.com/fallback",
            title: "Fallback Oshi update", content_text: nil, author: nil, thumbnail_url: nil,
            media_type: "article", published_at: now, watch_term_keyword: term.keyword,
            fetched_at: now
        )

        await manager.notifyForNewItems([item], terms: [term])

        XCTAssertEqual(center.requests.count, 1)
    }

    @MainActor
    func testTwitterPublicIndexItemsStayFeedOnly() async {
        let center = MockNotificationCenter(status: .authorized)
        let manager = NotificationManager(center: center)
        let term = WatchTerm(id: "twitter-index", keyword: "Index Oshi", notify_on_new: true)
        let nowString = ISO8601DateFormatter().string(from: Date())
        let item = FeedItem(
            id: "twitter:index-result",
            platform: "twitter",
            url: "https://news.google.com/rss/articles/index-result",
            title: "Index Oshi posted an update - x.com",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "text",
            published_at: nowString,
            watch_term_keyword: term.keyword,
            fetched_at: nowString,
            source: IngestionService.twitterPublicIndexSource
        )

        await manager.notifyForNewItems([item], terms: [term])

        XCTAssertTrue(center.requests.isEmpty)
    }

    @MainActor
    func testUnverifiedDateGoogleNewsItemsStayFeedOnly() async {
        let center = MockNotificationCenter(status: .authorized)
        let manager = NotificationManager(center: center)
        let term = WatchTerm(id: "stale-index", keyword: "Stale Oshi", notify_on_new: true)
        let nowString = ISO8601DateFormatter().string(from: Date())
        let item = FeedItem(
            id: "5ch:stale-thread",
            platform: "5ch",
            url: "https://news.google.com/rss/articles/stale-thread",
            title: "Stale Oshi thread",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "text",
            published_at: nowString,
            watch_term_keyword: term.keyword,
            fetched_at: nowString,
            source: IngestionService.unverifiedDateGoogleNewsSource
        )

        await manager.notifyForNewItems([item], terms: [term])

        XCTAssertTrue(center.requests.isEmpty)
    }

    @MainActor
    func testFiveChThreadCreationFallbackItemsStayFeedOnly() async {
        let center = MockNotificationCenter(status: .authorized)
        let manager = NotificationManager(center: center)
        let term = WatchTerm(id: "5ch-created", keyword: "Created Oshi", notify_on_new: true)
        let nowString = ISO8601DateFormatter().string(from: Date())
        let item = FeedItem(
            id: "2ch.sc:toro.2ch.sc:nogizaka:1787000000",
            platform: "5ch",
            url: "https://toro.2ch.sc/test/read.cgi/nogizaka/1787000000/",
            title: "Created Oshi thread",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "text",
            published_at: nowString,
            watch_term_keyword: term.keyword,
            fetched_at: nowString,
            source: IngestionService.fiveChThreadCreatedSource
        )

        await manager.notifyForNewItems([item], terms: [term])

        XCTAssertTrue(center.requests.isEmpty)
    }

    @MainActor
    func testLocalDigestDoesNotScheduleWithoutNotificationPermission() async throws {
        let center = MockNotificationCenter(status: .notDetermined)
        let manager = NotificationManager(center: center)
        let nowString = ISO8601DateFormatter().string(from: Date())
        let term = WatchTerm(id: "needs-permission", keyword: "Permission Oshi", notify_on_new: true)
        let item = FeedItem(
            id: "news:needs-permission", platform: "news", url: "https://example.com/permission",
            title: "Permission", content_text: nil, author: nil, thumbnail_url: nil,
            media_type: "article", published_at: nowString, watch_term_keyword: term.keyword,
            fetched_at: nowString
        )

        await manager.notifyForNewItems([item], terms: [term])

        XCTAssertTrue(center.requests.isEmpty)
        XCTAssertEqual(center.authorizationRequestCount, 0)
    }

    @MainActor
    func testLocalDigestDoesNotScheduleWhenNotificationsDenied() async throws {
        let center = MockNotificationCenter(status: .denied, grantsAuthorization: false)
        let manager = NotificationManager(center: center)
        await manager.refreshAuthorizationStatus()
        let nowString = ISO8601DateFormatter().string(from: Date())
        let term = WatchTerm(id: "denied", keyword: "Denied Oshi", notify_on_new: true)
        let item = FeedItem(
            id: "news:denied", platform: "news", url: "https://example.com/denied",
            title: "Denied", content_text: nil, author: nil, thumbnail_url: nil,
            media_type: "article", published_at: nowString, watch_term_keyword: term.keyword,
            fetched_at: nowString
        )

        await manager.notifyForNewItems([item], terms: [term])

        XCTAssertTrue(center.requests.isEmpty)
        XCTAssertEqual(center.authorizationRequestCount, 0)
    }

    @MainActor
    func testRepeatedTermDigestReplacesPendingNotification() async throws {
        let center = MockNotificationCenter(status: .authorized)
        let manager = NotificationManager(center: center)
        let nowString = ISO8601DateFormatter().string(from: Date())
        let term = WatchTerm(id: "digest", keyword: "Digest Oshi", notify_on_new: true)
        let item = FeedItem(
            id: "news:digest", platform: "news", url: "https://example.com/digest",
            title: "Digest", content_text: nil, author: nil, thumbnail_url: nil,
            media_type: "article", published_at: nowString, watch_term_keyword: term.keyword,
            fetched_at: nowString
        )

        await manager.notifyForNewItems([item], terms: [term])
        await manager.notifyForNewItems([item], terms: [term])

        XCTAssertEqual(center.requests.count, 1)
        XCTAssertEqual(center.requests.first?.identifier, "oshireader-new-term-digest-news:digest")
        XCTAssertEqual(center.removedPendingIdentifiers.count, 2)
    }

    @MainActor
    func testRenamedTermKeepsStableNotificationIdentifier() async throws {
        let center = MockNotificationCenter(status: .authorized)
        let manager = NotificationManager(center: center)
        let nowString = ISO8601DateFormatter().string(from: Date())
        let original = WatchTerm(id: "stable-term", keyword: "Original Oshi", notify_on_new: true)
        let renamed = WatchTerm(id: original.id, keyword: "Renamed Oshi", notify_on_new: true)

        let originalItem = FeedItem(
            id: "news:same-item", platform: "news", url: "https://example.com/same-item",
            title: "Original", content_text: nil, author: nil, thumbnail_url: nil,
            media_type: "article", published_at: nowString, watch_term_keyword: original.keyword,
            fetched_at: nowString
        )
        let renamedItem = FeedItem(
            id: "news:same-item", platform: "news", url: "https://example.com/same-item",
            title: "Renamed", content_text: nil, author: nil, thumbnail_url: nil,
            media_type: "article", published_at: nowString, watch_term_keyword: renamed.keyword,
            fetched_at: nowString
        )

        await manager.notifyForNewItems([originalItem], terms: [original])
        await manager.notifyForNewItems([renamedItem], terms: [renamed])

        XCTAssertEqual(center.requests.count, 1)
        XCTAssertEqual(center.requests.first?.identifier, "oshireader-new-term-stable-term-news:same-item")
    }

    @MainActor
    func testTermNotificationCanBeClearedByStableID() async {
        let center = MockNotificationCenter(status: .authorized)
        let manager = NotificationManager(center: center)
        let nowString = ISO8601DateFormatter().string(from: Date())
        let term = WatchTerm(id: "term-to-clear", keyword: "Clear Oshi", notify_on_new: true)
        let items = [
            FeedItem(
                id: "news:clear-1", platform: "news", url: "https://example.com/clear-1",
                title: "One", content_text: nil, author: nil, thumbnail_url: nil,
                media_type: "article", published_at: nowString, watch_term_keyword: term.keyword,
                fetched_at: nowString
            ),
            FeedItem(
                id: "news:clear-2", platform: "news", url: "https://example.com/clear-2",
                title: "Two", content_text: nil, author: nil, thumbnail_url: nil,
                media_type: "article", published_at: nowString, watch_term_keyword: term.keyword,
                fetched_at: nowString
            )
        ]
        await manager.notifyForNewItems(items, terms: [term])
        center.deliveredIdentifiers = center.requests.map(\.identifier)

        await manager.clearNotification(forTermID: "term-to-clear")

        XCTAssertEqual(
            Set(center.removedPendingIdentifiers.last ?? []),
            Set(["oshireader-new-term-term-to-clear-news:clear-1", "oshireader-new-term-term-to-clear-news:clear-2"])
        )
        XCTAssertEqual(
            Set(center.removedDeliveredIdentifiers.last ?? []),
            Set(["oshireader-new-term-term-to-clear-news:clear-1", "oshireader-new-term-term-to-clear-news:clear-2"])
        )
    }

    @MainActor
    func testClearDuringNotificationSchedulingDropsStaleRequests() async throws {
        let center = MockNotificationCenter(status: .authorized)
        let manager = NotificationManager(center: center)
        center.onAuthorizationStatus = {
            manager.clearLocalNotifications()
        }
        let nowString = ISO8601DateFormatter().string(from: Date())
        let term = WatchTerm(id: "notify", keyword: "Notify Oshi", notify_on_new: true)
        let item = FeedItem(
            id: "youtube:notify-stale", platform: "youtube", url: "https://youtube.com/watch?v=notify-stale",
            title: "Stale notification", content_text: nil, author: nil, thumbnail_url: nil,
            media_type: "video", published_at: nowString, watch_term_keyword: term.keyword,
            fetched_at: nowString,
            source: "youtube_scrape"
        )

        await manager.notifyForNewItems([item], terms: [term])

        XCTAssertTrue(center.requests.isEmpty)
        XCTAssertGreaterThanOrEqual(center.removeAllPendingCount, 1)
        XCTAssertGreaterThanOrEqual(center.removeAllDeliveredCount, 1)
    }

    @MainActor
    func testMergeItemsOnlyNotifiesForNewItems() throws {
        let nowString = ISO8601DateFormatter().string(from: Date())
        let item = FeedItem(
            id: "youtube:notify-once",
            platform: "youtube",
            url: "https://youtube.com/watch?v=notify-once",
            title: "Notify once",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "video",
            published_at: nowString,
            watch_term_keyword: "Notify Oshi",
            fetched_at: nowString,
            source: "youtube_scrape"
        )

        XCTAssertEqual(db.mergeItems(newItems: [item]), 1)
        XCTAssertEqual(db.mergeItems(newItems: [item]), 0)
    }

    @MainActor
    func testMergeItemsCanHandNotificationWorkToBackgroundCoordinator() {
        let nowString = ISO8601DateFormatter().string(from: Date())
        let existing = FeedItem(
            id: "news:existing", platform: "news", url: "https://example.com/existing",
            title: "Existing", content_text: nil, author: nil, thumbnail_url: nil,
            media_type: "article", published_at: nowString, watch_term_keyword: "Existing",
            fetched_at: nowString
        )
        let incoming = FeedItem(
            id: "news:incoming", platform: "news", url: "https://example.com/incoming",
            title: "Incoming", content_text: nil, author: nil, thumbnail_url: nil,
            media_type: "article", published_at: nowString, watch_term_keyword: "Incoming",
            fetched_at: nowString
        )
        XCTAssertEqual(db.mergeItems(newItems: [existing]), 1)
        var handedOffItems = [FeedItem]()

        XCTAssertEqual(db.mergeItems(newItems: [incoming], notificationHandler: { items, _ in
            handedOffItems = items
        }), 1)

        XCTAssertEqual(handedOffItems.map(\.id), [incoming.id])
    }

    @MainActor
    func testVerifiedFiveChReplyUpdateNotifiesOnceWithoutIncreasingAddedCount() {
        let formatter = ISO8601DateFormatter()
        let oldDate = formatter.string(from: Date().addingTimeInterval(-3600))
        let newDate = formatter.string(from: Date())
        let existing = FeedItem(
            id: "2ch.sc:toro.2ch.sc:nogizaka:1787000000",
            platform: "5ch",
            url: "https://toro.2ch.sc/test/read.cgi/nogizaka/1787000000/",
            title: "Reply Oshi thread",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "text",
            published_at: oldDate,
            watch_term_keyword: "Reply Oshi",
            fetched_at: oldDate,
            source: IngestionService.fiveChVerifiedActivitySource
        )
        let updated = existing.with(
            published_at: newDate,
            fetched_at: newDate,
            source: IngestionService.fiveChVerifiedActivitySource
        )
        db.setSubscribedPlatforms(platforms: ["5ch"])
        db.feedItems = [existing]
        var handedOffItems = [FeedItem]()

        let first = db.mergeItemsResult(newItems: [updated], notificationHandler: { items, _ in
            handedOffItems.append(contentsOf: items)
        })
        let second = db.mergeItemsResult(newItems: [updated], notificationHandler: { items, _ in
            handedOffItems.append(contentsOf: items)
        })

        XCTAssertEqual(first.addedCount, 0)
        XCTAssertTrue(first.didMutate)
        XCTAssertEqual(second.addedCount, 0)
        XCTAssertFalse(second.didMutate)
        XCTAssertEqual(handedOffItems.map(\.id), [existing.id])
        XCTAssertEqual(db.feedItems.first?.published_at, newDate)
    }

    @MainActor
    func testVerifiedFiveChReplyUpdateRefreshesFeedAndNotificationPreview() {
        let formatter = ISO8601DateFormatter()
        let oldDate = formatter.string(from: Date().addingTimeInterval(-3600))
        let newDate = formatter.string(from: Date())
        let existing = FeedItem(
            id: "2ch.sc:toro.2ch.sc:nogizaka:1787000001",
            platform: "5ch",
            url: "https://toro.2ch.sc/test/read.cgi/nogizaka/1787000001/",
            title: "Preview Oshi original discussion title",
            content_text: "Original preview",
            author: "Original author",
            thumbnail_url: "https://example.com/original.jpg",
            media_type: "article",
            published_at: oldDate,
            watch_term_keyword: "Preview Oshi",
            fetched_at: oldDate,
            source: IngestionService.fiveChVerifiedActivitySource
        )
        let updated = existing.with(
            url: "https://toro.2ch.sc/test/read.cgi/nogizaka/1787000001/latest",
            title: "Preview Oshi updated",
            content_text: "Latest reply preview",
            author: "Updated author",
            thumbnail_url: "https://example.com/updated.jpg",
            media_type: "text",
            published_at: newDate,
            fetched_at: newDate,
            source: IngestionService.fiveChVerifiedActivitySource
        )
        db.setSubscribedPlatforms(platforms: ["5ch"])
        db.feedItems = [existing]
        var handedOffItems = [FeedItem]()

        let result = db.mergeItemsResult(newItems: [updated], notificationHandler: { items, _ in
            handedOffItems = items
        })

        XCTAssertEqual(result.addedCount, 0)
        XCTAssertTrue(result.didMutate)
        let merged = db.feedItems.first
        XCTAssertEqual(merged?.url, updated.url)
        XCTAssertEqual(merged?.title, updated.title)
        XCTAssertEqual(merged?.content_text, updated.content_text)
        XCTAssertEqual(merged?.author, updated.author)
        XCTAssertEqual(merged?.thumbnail_url, updated.thumbnail_url)
        XCTAssertEqual(merged?.media_type, updated.media_type)
        XCTAssertEqual(handedOffItems, merged.map { [$0] } ?? [])
    }

    @MainActor
    func testFiveChReplyUpdateRejectsOlderAndUnverifiedActivityNotifications() {
        let formatter = ISO8601DateFormatter()
        let currentDate = formatter.string(from: Date())
        let oldDate = formatter.string(from: Date().addingTimeInterval(-3600))
        let futureDate = formatter.string(from: Date().addingTimeInterval(60))
        let existing = FeedItem(
            id: "2ch.sc:toro.2ch.sc:nogizaka:1787000000",
            platform: "5ch",
            url: "https://toro.2ch.sc/test/read.cgi/nogizaka/1787000000/",
            title: "Quiet Oshi thread",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "text",
            published_at: currentDate,
            watch_term_keyword: "Quiet Oshi",
            fetched_at: currentDate,
            source: IngestionService.fiveChVerifiedActivitySource
        )
        db.setSubscribedPlatforms(platforms: ["5ch"])
        db.feedItems = [existing]
        var handedOffItems = [FeedItem]()

        _ = db.mergeItemsResult(newItems: [existing.with(
            published_at: oldDate,
            fetched_at: oldDate,
            source: IngestionService.fiveChVerifiedActivitySource
        )], notificationHandler: { items, _ in
            handedOffItems.append(contentsOf: items)
        })
        _ = db.mergeItemsResult(newItems: [existing.with(
            published_at: futureDate,
            fetched_at: currentDate,
            source: IngestionService.fiveChThreadCreatedSource
        )], notificationHandler: { items, _ in
            handedOffItems.append(contentsOf: items)
        })

        XCTAssertTrue(handedOffItems.isEmpty)
        XCTAssertEqual(db.feedItems.first?.published_at, futureDate)
    }

    @MainActor
    func testVerifiedFiveChInitialLoadDoesNotNotify() {
        let nowString = ISO8601DateFormatter().string(from: Date())
        let item = FeedItem(
            id: "2ch.sc:toro.2ch.sc:nogizaka:1787000000",
            platform: "5ch",
            url: "https://toro.2ch.sc/test/read.cgi/nogizaka/1787000000/",
            title: "Initial Oshi thread",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "text",
            published_at: nowString,
            watch_term_keyword: "Initial Oshi",
            fetched_at: nowString,
            source: IngestionService.fiveChVerifiedActivitySource
        )
        db.setSubscribedPlatforms(platforms: ["5ch"])
        var handedOffItems = [FeedItem]()

        XCTAssertEqual(db.mergeItems(newItems: [item], notificationHandler: { items, _ in
            handedOffItems.append(contentsOf: items)
        }), 1)

        XCTAssertTrue(handedOffItems.isEmpty)
    }

    @MainActor
    func testPrunedFiveChReplyUpdateDoesNotNotify() {
        let formatter = ISO8601DateFormatter()
        let futureBase = Date().addingTimeInterval(30 * 86400)
        let oldDate = formatter.string(from: Date().addingTimeInterval(-7200))
        let updatedDate = formatter.string(from: Date().addingTimeInterval(-3600))
        let targetID = "2ch.sc:toro.2ch.sc:nogizaka:1787000000"
        let target = FeedItem(
            id: targetID,
            platform: "5ch",
            url: "https://toro.2ch.sc/test/read.cgi/nogizaka/1787000000/",
            title: "Pruned Oshi thread",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "text",
            published_at: oldDate,
            watch_term_keyword: "Pruned Oshi",
            fetched_at: oldDate,
            source: IngestionService.fiveChVerifiedActivitySource
        )
        db.setSubscribedPlatforms(platforms: ["5ch"])
        db.feedItems = (0..<600).map { index in
            let date = formatter.string(from: futureBase.addingTimeInterval(TimeInterval(-index)))
            return FeedItem(
                id: "5ch:newer:\(index)", platform: "5ch",
                url: "https://example.com/5ch/\(index)", title: "Newer \(index)",
                content_text: nil, author: nil, thumbnail_url: nil, media_type: "text",
                published_at: date, watch_term_keyword: "Pruned Oshi", fetched_at: date,
                source: IngestionService.fiveChVerifiedActivitySource
            )
        } + [target]
        var handedOffItems = [FeedItem]()

        let result = db.mergeItemsResult(newItems: [target.with(
            published_at: updatedDate,
            fetched_at: updatedDate,
            source: IngestionService.fiveChVerifiedActivitySource
        )], notificationHandler: { items, _ in
            handedOffItems.append(contentsOf: items)
        })

        XCTAssertEqual(result.addedCount, 0)
        XCTAssertTrue(result.didMutate)
        XCTAssertFalse(db.feedItems.contains { $0.id == targetID })
        XCTAssertTrue(handedOffItems.isEmpty)
    }

    @MainActor
    func testMergeResultReportsExistingItemMutationWithoutAddition() {
        let oldDate = "2026-08-13T10:00:00Z"
        let newDate = "2026-08-14T10:00:00Z"
        let original = FeedItem(
            id: "news:refresh-existing", platform: "news", url: "https://example.com/refresh-existing",
            title: "Old", content_text: nil, author: nil, thumbnail_url: nil,
            media_type: "article", published_at: oldDate, watch_term_keyword: "Refresh",
            fetched_at: oldDate
        )
        let refreshed = FeedItem(
            id: original.id, platform: original.platform, url: original.url,
            title: "A much longer refreshed title", content_text: "Updated", author: nil, thumbnail_url: nil,
            media_type: original.media_type, published_at: newDate, watch_term_keyword: original.watch_term_keyword,
            fetched_at: newDate
        )
        db.feedItems = [original]

        let result = db.mergeItemsResult(newItems: [refreshed])

        XCTAssertEqual(result.addedCount, 0)
        XCTAssertTrue(result.didMutate)
        XCTAssertEqual(db.feedItems.first?.fetched_at, newDate)
    }

    func testBackgroundNotificationBatchSuppressesEntireInitialLoad() {
        let item = FeedItem(
            id: "news:bootstrap", platform: "news", url: "https://example.com/bootstrap",
            title: "Bootstrap", content_text: nil, author: nil, thumbnail_url: nil,
            media_type: "article", published_at: "2026-08-14T10:00:00Z",
            watch_term_keyword: "Bootstrap", fetched_at: "2026-08-14T10:00:00Z"
        )
        var batch = BackgroundRefreshNotificationBatch(feedWasEmptyAtStart: true)

        batch.capture([item])

        XCTAssertTrue(batch.survivingItems(in: [item]).isEmpty)
    }

    func testBackgroundNotificationBatchDropsItemsEvictedByLaterUnits() {
        let evicted = FeedItem(
            id: "news:evicted", platform: "news", url: "https://example.com/evicted",
            title: "Evicted", content_text: nil, author: nil, thumbnail_url: nil,
            media_type: "article", published_at: "2026-08-13T10:00:00Z",
            watch_term_keyword: "Cap", fetched_at: "2026-08-14T10:00:00Z"
        )
        let surviving = FeedItem(
            id: "news:surviving", platform: "news", url: "https://example.com/surviving",
            title: "Surviving", content_text: nil, author: nil, thumbnail_url: nil,
            media_type: "article", published_at: "2026-08-14T10:00:00Z",
            watch_term_keyword: "Cap", fetched_at: "2026-08-14T10:00:00Z"
        )
        var batch = BackgroundRefreshNotificationBatch(feedWasEmptyAtStart: false)
        batch.capture([evicted, surviving])

        XCTAssertEqual(batch.survivingItems(in: [surviving]).map(\.id), [surviving.id])
    }

    /// Simulates the merge step of a real refresh: ~20 watch terms each
    /// returning ~30 items, merged into a feed already at the 600-item cap.
    private static let perfBatchDateFormatter: ISO8601DateFormatter = ISO8601DateFormatter()

    private static func makeSyntheticRefreshBatch(runID: String, termCount: Int = 20, itemsPerTerm: Int = 30) -> [FeedItem] {
        let platforms = ["news", "tver", "youtube", "yahoonews", "custom"]
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var items: [FeedItem] = []
        items.reserveCapacity(termCount * itemsPerTerm)
        for termIndex in 0..<termCount {
            let keyword = "Oshi \(termIndex)"
            for itemIndex in 0..<itemsPerTerm {
                let platform = platforms[itemIndex % platforms.count]
                let published = Self.perfBatchDateFormatter.string(from: base.addingTimeInterval(Double(termIndex * itemsPerTerm + itemIndex)))
                items.append(FeedItem(
                    id: "\(platform):\(runID)-\(termIndex)-\(itemIndex)",
                    platform: platform,
                    url: "https://example.com/\(runID)/\(termIndex)/\(itemIndex)",
                    title: "Synthetic item \(termIndex)-\(itemIndex)",
                    content_text: "Body text for perf test item \(termIndex)-\(itemIndex)",
                    author: nil,
                    thumbnail_url: itemIndex.isMultiple(of: 2) ? "https://example.com/thumb.jpg" : nil,
                    media_type: platform == "youtube" ? "video" : "article",
                    published_at: published,
                    watch_term_keyword: keyword,
                    fetched_at: published
                ))
            }
        }
        return items
    }

    @MainActor
    func testMergePerformanceForFullRefreshBatch() throws {
        db.feedItems = Self.makeSyntheticRefreshBatch(runID: "seed", termCount: 20, itemsPerTerm: 30)
        XCTAssertFalse(db.feedItems.isEmpty)

        // Pre-generate batches outside the measured closure — measure()
        // invokes its block 10 times by default, and building the fixture
        // data (date formatting, string interpolation) is test overhead,
        // not part of what we're actually timing.
        let batches = (0..<10).map { Self.makeSyntheticRefreshBatch(runID: "run\($0)", termCount: 20, itemsPerTerm: 30) }
        var runIndex = 0
        measure {
            let batch = batches[runIndex % batches.count]
            runIndex += 1
            _ = db.mergeItemsBatchedResult(newItemsBatches: [batch])
        }
    }

    /// queryFeed's single-slot cache means calling it back-to-back with the
    /// same arguments would only measure a cache hit. Rotating the keyword
    /// across a set of terms the feed actually contains forces a cache miss
    /// (a full computeQueryFeed run) on every call — the shape that
    /// writeWidgetSnapshotNow() hits once per watch term, uncached, on the
    /// main actor.
    @MainActor
    func testQueryFeedPerformanceForFullFeed() throws {
        db.feedItems = Self.makeSyntheticRefreshBatch(runID: "query-perf", termCount: 20, itemsPerTerm: 30)
        XCTAssertEqual(db.feedItems.count, 600)

        var runIndex = 0
        measure {
            let keyword = "Oshi \(runIndex % 20)"
            runIndex += 1
            _ = db.queryFeed(keyword: keyword, days: 0)
        }
    }

    @MainActor
    func testCancelledNotificationTaskDoesNotScheduleRequest() async {
        let center = MockNotificationCenter(status: .authorized)
        let manager = NotificationManager(center: center)
        let term = WatchTerm(id: "cancelled", keyword: "Cancelled", notify_on_new: true)
        let nowString = ISO8601DateFormatter().string(from: Date())
        let item = FeedItem(
            id: "news:cancelled", platform: "news", url: "https://example.com/cancelled",
            title: "Cancelled", content_text: nil, author: nil, thumbnail_url: nil,
            media_type: "article", published_at: nowString, watch_term_keyword: term.keyword,
            fetched_at: nowString
        )

        let task = Task { await manager.notifyForNewItems([item], terms: [term], includeAttachments: false) }
        task.cancel()
        await task.value

        XCTAssertTrue(center.requests.isEmpty)
    }
}

private final class MockNotificationCenter: NotificationCenterClient {
    private(set) var status: UNAuthorizationStatus
    private let grantsAuthorization: Bool
    var onAuthorizationStatus: (() async -> Void)?
    private(set) var authorizationRequestCount = 0
    private(set) var requests: [UNNotificationRequest] = []
    private(set) var categories: Set<UNNotificationCategory> = []
    private(set) var removedPendingIdentifiers: [[String]] = []
    private(set) var removedDeliveredIdentifiers: [[String]] = []
    private(set) var removeAllPendingCount = 0
    private(set) var removeAllDeliveredCount = 0

    init(status: UNAuthorizationStatus, grantsAuthorization: Bool = true) {
        self.status = status
        self.grantsAuthorization = grantsAuthorization
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await onAuthorizationStatus?()
        return status
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        authorizationRequestCount += 1
        if grantsAuthorization {
            status = .authorized
        }
        return grantsAuthorization
    }

    func add(_ request: UNNotificationRequest) async throws {
        requests.append(request)
    }

    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
        self.categories = categories
    }

    func removeAllPendingNotificationRequests() {
        removeAllPendingCount += 1
        requests.removeAll()
    }

    func removeAllDeliveredNotifications() {
        removeAllDeliveredCount += 1
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        removedPendingIdentifiers.append(identifiers)
        requests.removeAll { identifiers.contains($0.identifier) }
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        removedDeliveredIdentifiers.append(identifiers)
        deliveredIdentifiers.removeAll { identifiers.contains($0) }
    }

    var deliveredIdentifiers: [String] = []

    func pendingNotificationRequests() async -> [UNNotificationRequest] {
        requests
    }

    func deliveredNotificationIdentifiers() async -> [String] {
        deliveredIdentifiers
    }
}
