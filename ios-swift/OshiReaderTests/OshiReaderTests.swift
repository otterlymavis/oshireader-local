import XCTest
import SwiftUI
import UIKit
import UserNotifications
@testable import OshiReader

private actor RequestCapture {
    private(set) var urls: [String] = []

    func record(_ url: String) {
        urls.append(url)
    }

    func count() -> Int {
        urls.count
    }

    func firstURL() -> String? {
        urls.first
    }

    func contains(_ predicate: (String) -> Bool) -> Bool {
        urls.contains(where: predicate)
    }
}

private actor RetryGate {
    private var entered = false

    func enter() {
        entered = true
    }

    func waitUntilEntered() async {
        while !entered {
            await Task.yield()
        }
    }
}

final class OshiReaderTests: XCTestCase {
    
    private var db: LocalDB!
    
    override func setUpWithError() throws {
        try super.setUpWithError()
        db = LocalDB.shared
        // Clear state before tests if needed, or work with a clean slate
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

    func testPlatformRegistryContainsReferenceSourcesWithoutChangingDefaults() {
        let ids = Set(PlatformRegistry.all.map(\.id))
        XCTAssertTrue(ids.isSuperset(of: [
            "smartnews", "ameblo", "aera", "hochi", "sponichi", "livedoor",
            "mantanweb", "realsound", "cinemacafe", "thetv", "natalie",
            "billboardjapan", "soompi", "allkpop", "kpopofficial", "barks"
        ]))
        XCTAssertEqual(PlatformRegistry.definition(for: "soompi")?.newsLocale, .englishUS)
        XCTAssertEqual(PlatformRegistry.definition(for: "soompi")?.newsLocale.acceptLanguage, "en,ko;q=0.9,ja;q=0.7")
        XCTAssertTrue(PlatformRegistry.strictKeywordPlatformIDs.contains("allkpop"))
        XCTAssertEqual(PlatformRegistry.definition(for: "natalie")?.googleNewsSite, "natalie.mu")
        XCTAssertNil(PlatformRegistry.definition(for: "twitter")?.googleNewsSite)
        XCTAssertEqual(PlatformRegistry.definition(for: "custom")?.googleNewsSite, nil)
        XCTAssertEqual(PlatformRegistry.defaultSubscribedIDs.last, "custom")
        XCTAssertFalse(PlatformRegistry.defaultSubscribedIDs.contains("soompi"))
    }

    func testDedicatedSearchLinksUseDedicatedPlatformIDs() {
        let registeredIDs = Set(PlatformRegistry.all.map(\.id))
        let mismatches = staticSearchLinks.compactMap { link -> String? in
            guard registeredIDs.contains(link.id), link.platform != link.id else { return nil }
            return "\(link.id)->\(link.platform)"
        }

        XCTAssertEqual(mismatches, [])
    }

    func testSavedSubscribedPlatformsDoNotReAddMissingDefaultsOnLoad() {
        XCTAssertEqual(
            LocalDB.subscribedPlatformsForLoadedValue(["news", " youtube ", "unknown", "news"], hasSavedFile: true),
            ["news", "youtube"]
        )
        XCTAssertEqual(
            LocalDB.subscribedPlatformsForLoadedValue(["news"], hasSavedFile: false),
            PlatformRegistry.defaultSubscribedIDs
        )
    }

    func testIngestionSearchKeywordsIncludesTrimmedUniqueAliases() {
        let term = WatchTerm(
            keyword: "  Primary Oshi ",
            aliases: ["Alias Oshi", "Primary Oshi", "  Alias Oshi  ", "", "Alias 3", "Alias 4", "Alias 5", "Alias 6", "Alias 7"]
        )

        XCTAssertEqual(IngestionService.searchKeywords(for: term), [
            "Primary Oshi", "Alias Oshi", "Alias 3", "Alias 4", "Alias 5", "Alias 6"
        ])
    }

    func testCanonicalURLForDedupRemovesTrackingParametersOnly() {
        XCTAssertEqual(
            IngestionService.canonicalURLForDedup(
                "HTTPS://Example.COM/article/123/?utm_source=news&ref=homepage&gclid=abc#comments"
            ),
            "https://example.com/article/123?ref=homepage"
        )
        XCTAssertEqual(
            IngestionService.canonicalURLForDedup(
                "https://example.com/video?id=123&utm_campaign=spring"
            ),
            "https://example.com/video?id=123"
        )
        XCTAssertEqual(
            IngestionService.canonicalURLForDedup("not a URL"),
            "not a URL"
        )
    }

    func testNatalieDedicatedRSSProducesNatalieItemsAcrossBothFeeds() async {
        let rss = """
        <rss version="2.0"><channel><item>
        <title>Natalie Oshi music update</title>
        <link>https://natalie.mu/music/news/123?utm_source=rss</link>
        <description>Natalie Oshi news</description>
        </item></channel></rss>
        """.data(using: .utf8)!
        let capture = RequestCapture()
        let service = IngestionService { request in
            await capture.record(request.url?.absoluteString ?? "")
            return (
                rss,
                try XCTUnwrap(HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                ))
            )
        }

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Natalie Oshi"),
            platforms: ["natalie"]
        )

        let requestCount = await capture.count()
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(Set(report.items.map(\.platform)), Set(["natalie"]))
        XCTAssertTrue(report.items.allSatisfy { $0.id.hasPrefix("natalie:") })
        XCTAssertEqual(report.sourceStatuses.first?.outcome, .received)
    }

    func testBarksDedicatedRSSProducesBarksItemsAndPreservesOriginalURL() async {
        let originalURL = "https://www.barks.jp/news/123?utm_campaign=feed"
        let rss = """
        <rss version="2.0"><channel><item>
        <title>BARKS Oshi feature</title>
        <link>\(originalURL)</link>
        <description>BARKS Oshi feature description</description>
        </item></channel></rss>
        """.data(using: .utf8)!
        let capture = RequestCapture()
        let service = IngestionService { request in
            await capture.record(request.url?.absoluteString ?? "")
            return (
                rss,
                try XCTUnwrap(HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                ))
            )
        }

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "BARKS Oshi"),
            platforms: ["barks"]
        )

        let requestCount = await capture.count()
        let firstURL = await capture.firstURL()
        XCTAssertEqual(requestCount, 1)
        XCTAssertTrue(firstURL?.contains("barks.jp/about") == true)
        XCTAssertEqual(report.items.first?.platform, "barks")
        XCTAssertEqual(report.items.first?.url, originalURL)
    }

    func testJapaneseDedicatedRSSSourcesUsePublisherFeedsAndPreserveSourceIDs() async {
        let rss = Data("""
        <rss version="2.0"><channel>
          <item><title>Alias Oshi publisher update</title><link>https://publisher.example/article-1?utm_source=rss</link><description>Publisher detail</description></item>
          <item><title>Alias Oshi duplicate</title><link>https://publisher.example/article-1?utm_medium=email</link></item>
        </channel></rss>
        """.utf8)
        let atom = Data("""
        <feed xmlns="http://www.w3.org/2005/Atom"><entry>
          <title>Alias Oshi Real Sound update</title><link rel="alternate" href="https://realsound.jp/2026/08/post-1.html"/><summary>Music detail</summary><published>2026-08-02T12:00:00Z</published>
        </entry></feed>
        """.utf8)
        let capture = RequestCapture()
        let service = IngestionService(
            requestExecutor: { request in
                let url = request.url?.absoluteString ?? ""
                await capture.record(url)
                let body = url.contains("realsound.jp") ? atom : rss
                return (body, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Primary Oshi", aliases: ["Alias Oshi"]),
            platforms: ["aera", "hochi", "realsound"]
        )

        let urls = await capture.urls
        XCTAssertEqual(Set(urls), Set([
            "https://dot.asahi.com/list/feed/rss4provider-all",
            "https://hochi.news/rss/index.xml",
            "https://realsound.jp/atom.xml"
        ]))
        XCTAssertEqual(Set(report.sourceStatuses.map(\.id)), Set(["aera", "hochi", "realsound"]))
        XCTAssertTrue(report.sourceStatuses.allSatisfy { $0.outcome == .received && $0.queryCount == 2 })
        XCTAssertEqual(report.items.filter { $0.platform == "aera" }.count, 1)
        XCTAssertEqual(report.items.filter { $0.platform == "hochi" }.count, 1)
        XCTAssertEqual(report.items.filter { $0.platform == "realsound" }.count, 1)
        XCTAssertTrue(report.items.allSatisfy { $0.watch_term_keyword == "Primary Oshi" })
    }

    func testSponichiRemainsOnGenericGoogleNewsFallback() async {
        let capture = RequestCapture()
        let service = IngestionService(requestExecutor: { request in
            await capture.record(request.url?.absoluteString ?? "")
            return (Data("<rss version=\"2.0\"><channel></channel></rss>".utf8), try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )))
        })

        _ = await service.ingestReport(term: WatchTerm(keyword: "Sponichi Oshi"), platforms: ["sponichi"])

        let usedGoogleNews = await capture.contains { $0.contains("news.google.com") }
        let usedSponichiRSS = await capture.contains { $0.contains("sponichi.co.jp/rss") }
        XCTAssertTrue(usedGoogleNews)
        XCTAssertFalse(usedSponichiRSS)
    }

    func testJapaneseDedicatedRSSMediaOnlySkipsAllRequests() async {
        let capture = RequestCapture()
        let service = IngestionService(requestExecutor: { request in
            await capture.record(request.url?.absoluteString ?? "")
            return (Data(), try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )))
        })

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Media Oshi", collection_mode: "media_only"),
            platforms: ["aera", "hochi", "realsound"]
        )

        XCTAssertTrue(report.items.isEmpty)
        let requestCount = await capture.count()
        XCTAssertEqual(requestCount, 0)
    }

    func testJapaneseDedicatedRSSFailureStaysAttachedToPublisher() async {
        let rss = Data("<rss version=\"2.0\"><channel><item><title>Hochi Oshi update</title><link>https://hochi.news/articles/1</link></item></channel></rss>".utf8)
        let service = IngestionService(
            requestExecutor: { request in
                if request.url?.host == "dot.asahi.com" {
                    return (Data(), try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil
                    )))
                }
                return (rss, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Oshi"),
            platforms: ["aera", "hochi"]
        )

        XCTAssertEqual(report.sourceStatuses.first { $0.id == "aera" }?.outcome, .failed(.rateLimited))
        XCTAssertEqual(report.sourceStatuses.first { $0.id == "hochi" }?.outcome, .received)
        XCTAssertEqual(report.items.first?.platform, "hochi")
    }

    func testCinemaCafeAndBillboardDedicatedRSSSourcesPreserveIDsAndDeduplicate() async {
        let cinemaURL = "https://www.cinemacafe.net/article/1.html?utm_source=rss"
        let billboardURL = "https://www.billboard-japan.com/d_news/detail/1?utm_medium=email"
        let cinemaRSS = Data("""
        <rss version="2.0"><channel>
          <item><title>Alias Oshi CinemaCafe update</title><link>\(cinemaURL)</link><description>Film detail</description></item>
          <item><title>Alias Oshi duplicate</title><link>https://www.cinemacafe.net/article/1.html?utm_medium=email</link></item>
        </channel></rss>
        """.utf8)
        let billboardRSS = Data("""
        <rss version="2.0"><channel>
          <item><title>Alias Oshi Billboard update</title><link>\(billboardURL)</link><description>Music detail</description></item>
          <item><title>Alias Oshi duplicate</title><link>https://www.billboard-japan.com/d_news/detail/1?utm_source=rss</link></item>
        </channel></rss>
        """.utf8)
        let capture = RequestCapture()
        let service = IngestionService(
            requestExecutor: { request in
                let url = request.url?.absoluteString ?? ""
                await capture.record(url)
                let body = url.contains("cinemacafe.net") ? cinemaRSS : billboardRSS
                return (body, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Primary Oshi", aliases: ["Alias Oshi"]),
            platforms: ["cinemacafe", "billboardjapan"]
        )

        let requestCount = await capture.count()
        XCTAssertEqual(requestCount, 4)
        XCTAssertEqual(Set(report.sourceStatuses.map(\.id)), Set(["cinemacafe", "billboardjapan"]))
        XCTAssertTrue(report.sourceStatuses.allSatisfy { $0.outcome == .received && $0.queryCount == 2 })
        XCTAssertEqual(report.items.filter { $0.platform == "cinemacafe" }.count, 1)
        XCTAssertEqual(report.items.filter { $0.platform == "billboardjapan" }.count, 1)
        XCTAssertEqual(report.items.first { $0.platform == "cinemacafe" }?.url, cinemaURL)
        XCTAssertEqual(report.items.first { $0.platform == "billboardjapan" }?.url, billboardURL)
    }

    func testCinemaCafeAndBillboardMediaOnlySkipRequests() async {
        let capture = RequestCapture()
        let service = IngestionService(requestExecutor: { request in
            await capture.record(request.url?.absoluteString ?? "")
            return (Data(), try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )))
        })

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Media Oshi", collection_mode: "media_only"),
            platforms: ["cinemacafe", "billboardjapan"]
        )

        let requestCount = await capture.count()
        XCTAssertTrue(report.items.isEmpty)
        XCTAssertEqual(requestCount, 0)
    }

    func testCinemaCafeFailureAndBillboardSuccessRemainSourceSpecific() async {
        let billboardRSS = Data("<rss version=\"2.0\"><channel><item><title>Oshi Billboard update</title><link>https://www.billboard-japan.com/d_news/detail/2</link></item></channel></rss>".utf8)
        let service = IngestionService(
            requestExecutor: { request in
                if request.url?.host == "www.cinemacafe.net" {
                    return (Data(), try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil
                    )))
                }
                return (billboardRSS, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Oshi"),
            platforms: ["cinemacafe", "billboardjapan"]
        )

        XCTAssertEqual(report.sourceStatuses.first { $0.id == "cinemacafe" }?.outcome, .failed(.httpFailure))
        XCTAssertEqual(report.sourceStatuses.first { $0.id == "billboardjapan" }?.outcome, .received)
        XCTAssertEqual(report.items.first?.platform, "billboardjapan")
    }

    func testDeferredJapaneseSourcesRemainOnGoogleNewsFallback() async {
        let capture = RequestCapture()
        let service = IngestionService(requestExecutor: { request in
            await capture.record(request.url?.absoluteString ?? "")
            return (Data("<rss version=\"2.0\"><channel></channel></rss>".utf8), try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )))
        })

        for sourceID in ["livedoor", "mantanweb", "thetv"] {
            _ = await service.ingestReport(
                term: WatchTerm(keyword: "Fallback Oshi"),
                platforms: [sourceID]
            )
        }

        let urls = await capture.urls
        XCTAssertEqual(urls.count, 3)
        XCTAssertTrue(urls.allSatisfy { $0.contains("news.google.com") })
    }

    func testDedicatedRSSMatchesAliasAndFiltersNonmatchingEntries() async {
        let rss = """
        <rss version="2.0"><channel><item>
        <title>Alias Oshi exclusive</title>
        <link>https://natalie.mu/music/news/alias</link>
        </item><item>
        <title>Unrelated headline</title>
        <link>https://natalie.mu/music/news/unrelated</link>
        </item></channel></rss>
        """.data(using: .utf8)!
        let service = IngestionService { request in
            (
                rss,
                try XCTUnwrap(HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                ))
            )
        }

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Primary Oshi", aliases: ["Alias Oshi"]),
            platforms: ["natalie"]
        )

        XCTAssertFalse(report.items.isEmpty)
        XCTAssertTrue(report.items.allSatisfy { $0.title?.contains("Alias Oshi") == true })
        XCTAssertTrue(report.items.allSatisfy { $0.watch_term_keyword == "Primary Oshi" })
    }

    func testDedicatedRSSNoResultsAndMediaOnlyAvoidsRequests() async {
        let emptyRSS = Data("<rss version=\"2.0\"><channel></channel></rss>".utf8)
        let capture = RequestCapture()
        let service = IngestionService { request in
            await capture.record(request.url?.absoluteString ?? "")
            return (
                emptyRSS,
                try XCTUnwrap(HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                ))
            )
        }

        let noResults = await service.ingestReport(
            term: WatchTerm(keyword: "No Match"),
            platforms: ["barks"]
        )
        XCTAssertEqual(noResults.sourceStatuses.first?.outcome, .noResults)

        let beforeMediaOnly = await capture.count()
        let mediaOnly = await service.ingestReport(
            term: WatchTerm(keyword: "Media Oshi", collection_mode: "media_only"),
            platforms: ["natalie"]
        )
        XCTAssertTrue(mediaOnly.items.isEmpty)
        let afterMediaOnly = await capture.count()
        XCTAssertEqual(afterMediaOnly, beforeMediaOnly)
    }

    func testAmebloRemainsOnGenericGoogleNewsFallback() async {
        let capture = RequestCapture()
        let service = IngestionService { request in
            await capture.record(request.url?.absoluteString ?? "")
            return (
                Data("<rss version=\"2.0\"><channel></channel></rss>".utf8),
                try XCTUnwrap(HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                ))
            )
        }

        _ = await service.ingestReport(
            term: WatchTerm(keyword: "Ameblo Oshi"),
            platforms: ["ameblo"]
        )

        let usedGoogleNews = await capture.contains { $0.contains("news.google.com") }
        let usedAmeblo = await capture.contains { $0.contains("ameblo.jp") }
        XCTAssertTrue(usedGoogleNews)
        XCTAssertTrue(usedAmeblo)
    }

    func testAmebloBlogNormalizesURLAndBuildsOfficialRSSURL() {
        let blog = AmebloBlog(
            url: " http://www.ameblo.jp/example_id/?utm_source=test#top ",
            title: "Example",
            addedAt: "2026-01-01T00:00:00Z"
        )

        XCTAssertEqual(blog?.url, "https://ameblo.jp/example_id")
        XCTAssertEqual(blog?.amebaID, "example_id")
        XCTAssertEqual(blog?.rssURL?.absoluteString, "https://rssblog.ameba.jp/example_id/rss20.xml")
        XCTAssertNil(AmebloBlog(url: "https://example.com/example_id"))
        XCTAssertNil(AmebloBlog(url: "https://ameblo.jp/example_id/posts"))
        XCTAssertNil(AmebloBlog(url: "https://ameblo.jp/"))
    }

    func testAmebloBlogLimitDuplicateAndAutomaticSubscription() {
        let originalBlogs = db.amebloBlogs
        let originalPlatforms = db.subscribedPlatforms
        defer {
            db.amebloBlogs = originalBlogs
            db.setSubscribedPlatforms(platforms: originalPlatforms)
        }

        db.amebloBlogs = []
        db.setSubscribedPlatforms(platforms: ["news"])
        XCTAssertEqual(db.addAmebloBlog(url: "https://ameblo.jp/first", title: ""), .added)
        XCTAssertTrue(db.subscribedPlatforms.contains("ameblo"))
        XCTAssertEqual(db.addAmebloBlog(url: "https://www.ameblo.jp/first/?x=1", title: ""), .duplicate)

        db.amebloBlogs = (0..<AmebloBlog.maximumCount).compactMap {
            AmebloBlog(url: "https://ameblo.jp/blog\($0)", addedAt: "2026-01-01T00:00:00Z")
        }
        XCTAssertEqual(db.addAmebloBlog(url: "https://ameblo.jp/too-many", title: ""), .limitReached)
    }

    func testAmebloDedicatedRSSMatchesAliasPreservesURLAndDeduplicates() async {
        let originalBlogs = db.amebloBlogs
        defer { db.amebloBlogs = originalBlogs }
        db.amebloBlogs = [
            AmebloBlog(url: "https://ameblo.jp/first", addedAt: "2026-01-01T00:00:00Z")!
        ]

        let originalURL = "https://ameblo.jp/first/entry-1?utm_source=rss"
        let rss = Data("""
        <rss version="2.0"><channel>
          <item><title>Alias Oshi diary</title><link>\(originalURL)</link><description>daily update</description></item>
          <item><title>Alias Oshi duplicate</title><link>https://ameblo.jp/first/entry-1?utm_medium=email</link></item>
          <item><title>Unrelated</title><link>https://ameblo.jp/first/entry-2</link></item>
        </channel></rss>
        """.utf8)
        let capture = RequestCapture()
        let service = IngestionService(
            requestExecutor: { request in
                await capture.record(request.url?.absoluteString ?? "")
                return (rss, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Primary Oshi", aliases: ["Alias Oshi"]),
            platforms: ["ameblo"]
        )

        let requestCount = await capture.count()
        let firstURL = await capture.firstURL()
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(firstURL, "https://rssblog.ameba.jp/first/rss20.xml")
        XCTAssertEqual(report.items.count, 1)
        XCTAssertEqual(report.items.first?.platform, "ameblo")
        XCTAssertEqual(report.items.first?.url, originalURL)
        XCTAssertEqual(report.sourceStatuses.first?.outcome, .received)
        XCTAssertEqual(report.sourceStatuses.first?.queryCount, 2)
    }

    func testAmebloMediaOnlySkipsConfiguredRSSRequests() async {
        let originalBlogs = db.amebloBlogs
        defer { db.amebloBlogs = originalBlogs }
        db.amebloBlogs = [AmebloBlog(url: "https://ameblo.jp/media-only")!]
        let capture = RequestCapture()
        let service = IngestionService(requestExecutor: { request in
            await capture.record(request.url?.absoluteString ?? "")
            return (Data(), try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )))
        })

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Video Oshi", collection_mode: "media_only"),
            platforms: ["ameblo"]
        )

        XCTAssertTrue(report.items.isEmpty)
        let requestCount = await capture.count()
        XCTAssertEqual(requestCount, 0)
    }

    func testAmebloPartialFailurePreservesReceivedItemsAndStatus() async {
        let originalBlogs = db.amebloBlogs
        defer { db.amebloBlogs = originalBlogs }
        db.amebloBlogs = [
            AmebloBlog(url: "https://ameblo.jp/failing")!,
            AmebloBlog(url: "https://ameblo.jp/succeeding")!
        ]
        let rss = Data("<rss version=\"2.0\"><channel><item><title>Oshi update</title><link>https://ameblo.jp/succeeding/entry-1</link></item></channel></rss>".utf8)
        let service = IngestionService(
            requestExecutor: { request in
                if request.url?.host == "rssblog.ameba.jp" && request.url?.path.contains("failing") == true {
                    return (Data(), try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil
                    )))
                }
                return (rss, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Oshi"),
            platforms: ["ameblo"]
        )

        XCTAssertEqual(report.items.count, 1)
        XCTAssertEqual(report.sourceStatuses.first?.outcome, .received)
        XCTAssertEqual(report.sourceStatuses.first?.itemCount, 1)
        XCTAssertEqual(report.sourceStatuses.first?.queryCount, 1)
    }

    @MainActor
    func testAmebloBlogsRoundTripThroughBackup() throws {
        let originalBlogs = db.amebloBlogs
        let originalPlatforms = db.subscribedPlatforms
        defer {
            db.amebloBlogs = originalBlogs
            db.setSubscribedPlatforms(platforms: originalPlatforms)
        }

        db.amebloBlogs = [AmebloBlog(url: "https://ameblo.jp/backup-blog", title: "Backup")!]
        db.setSubscribedPlatforms(platforms: ["news", "ameblo"])
        let data = try db.exportBackupData()
        db.amebloBlogs = []
        db.setSubscribedPlatforms(platforms: ["news"])
        try db.importBackupData(data)

        XCTAssertEqual(db.amebloBlogs.map(\.amebaID), ["backup-blog"])
        XCTAssertTrue(db.subscribedPlatforms.contains("ameblo"))
    }

    func testIngestionReportAggregatesSourceStatusForEmptyPlatforms() async {
        let report = await IngestionService.shared.ingestReport(
            term: WatchTerm(keyword: "Status Oshi", collection_mode: "media_only"),
            platforms: ["news"]
        )

        let news = report.sourceStatuses.first { $0.id == "news" }
        XCTAssertEqual(news?.outcome, .noResults)
        XCTAssertGreaterThan(news?.queryCount ?? 0, 0)
        XCTAssertTrue(report.items.isEmpty)
    }

    func testTypedTransportFailuresMapTimeoutNetworkAndHTTPStatuses() async {
        let cases: [(SourceRefreshFailure, Int?)] = [
            (.timeout, nil),
            (.networkUnavailable, nil),
            (.authenticationRequired, 401),
            (.authenticationRequired, 403),
            (.rateLimited, 429),
            (.httpFailure, 500),
        ]

        for (expected, statusCode) in cases {
            let service = IngestionService { _ in
                if let statusCode {
                    return (Data(), try XCTUnwrap(HTTPURLResponse(
                        url: URL(string: "https://example.com")!,
                        statusCode: statusCode,
                        httpVersion: nil,
                        headerFields: nil
                    )))
                }
                throw expected == .timeout ? URLError(.timedOut) : URLError(.notConnectedToInternet)
            }

            let report = await service.ingestReport(
                term: WatchTerm(keyword: "Transport Oshi"),
                platforms: ["news"]
            )
            XCTAssertTrue(report.sourceStatuses.contains {
                if case .failed(expected) = $0.outcome { return true }
                return false
            }, "Expected \(expected) in \(report.sourceStatuses)")
        }
    }

    func testRetryTimeoutThenSuccessReturnsItemsWithoutFailure() async {
        let rss = Data("<rss version=\"2.0\"><channel><item><title>Retry Oshi</title><link>https://example.com/retry</link></item></channel></rss>".utf8)
        let capture = RequestCapture()
        let service = IngestionService(
            requestExecutor: { request in
                await capture.record(request.url?.absoluteString ?? "")
                if await capture.count() == 1 {
                    throw URLError(.timedOut)
                }
                return (rss, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Retry Oshi"),
            platforms: ["barks"]
        )

        let requestCount = await capture.count()
        XCTAssertEqual(requestCount, 2)
        XCTAssertFalse(report.items.isEmpty)
        XCTAssertEqual(report.sourceStatuses.first?.outcome, .received)
    }

    func testRetryNetworkFailureThenSuccessCanReturnNoResults() async {
        let capture = RequestCapture()
        let service = IngestionService(
            requestExecutor: { request in
                await capture.record(request.url?.absoluteString ?? "")
                if await capture.count() == 1 {
                    throw URLError(.notConnectedToInternet)
                }
                return (Data("<rss version=\"2.0\"><channel></channel></rss>".utf8), try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Retry Empty"),
            platforms: ["barks"]
        )

        let requestCount = await capture.count()
        XCTAssertEqual(requestCount, 2)
        XCTAssertTrue(report.items.isEmpty)
        XCTAssertEqual(report.sourceStatuses.first?.outcome, .noResults)
    }

    func testRetryHTTP503ThenSuccessAndHTTP429Exhaustion() async {
        let successRSS = Data("<rss version=\"2.0\"><channel><item><title>Server Oshi</title><link>https://example.com/server</link></item></channel></rss>".utf8)
        let serverCapture = RequestCapture()
        let serverService = IngestionService(
            requestExecutor: { request in
                await serverCapture.record(request.url?.absoluteString ?? "")
                let status = await serverCapture.count() == 1 ? 503 : 200
                return (successRSS, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )
        let recovered = await serverService.ingestReport(
            term: WatchTerm(keyword: "Server Oshi"), platforms: ["barks"]
        )
        let serverRequestCount = await serverCapture.count()
        XCTAssertEqual(serverRequestCount, 2)
        XCTAssertEqual(recovered.sourceStatuses.first?.outcome, .received)

        let limitedCapture = RequestCapture()
        let limitedService = IngestionService(
            requestExecutor: { request in
                await limitedCapture.record(request.url?.absoluteString ?? "")
                return (Data(), try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )
        let limited = await limitedService.ingestReport(
            term: WatchTerm(keyword: "Limited Oshi"), platforms: ["barks"]
        )
        let limitedRequestCount = await limitedCapture.count()
        XCTAssertEqual(limitedRequestCount, 2)
        XCTAssertEqual(limited.sourceStatuses.first?.outcome, .failed(.rateLimited))
    }

    func testAuthenticationAndMalformedPayloadsAreNotRetried() async {
        for status in [401, 403] {
            let capture = RequestCapture()
            let service = IngestionService(
                requestExecutor: { request in
                    await capture.record(request.url?.absoluteString ?? "")
                    return (Data(), try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
                    )))
                },
                retrySleeper: { _ in }
            )
            let report = await service.ingestReport(
                term: WatchTerm(keyword: "Auth Oshi"), platforms: ["barks"]
            )
            let requestCount = await capture.count()
            XCTAssertEqual(requestCount, 1)
            XCTAssertEqual(report.sourceStatuses.first?.outcome, .failed(.authenticationRequired))
        }

        let malformedCapture = RequestCapture()
        let malformedService = IngestionService(
            requestExecutor: { request in
                await malformedCapture.record(request.url?.absoluteString ?? "")
                return (Data("<rss><channel>".utf8), try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )
        let malformed = await malformedService.ingestReport(
            term: WatchTerm(keyword: "Malformed Retry Oshi"), platforms: ["barks"]
        )
        let malformedRequestCount = await malformedCapture.count()
        XCTAssertEqual(malformedRequestCount, 1)
        XCTAssertEqual(malformed.sourceStatuses.first?.outcome, .failed(.invalidPayload))
    }

    func testRetryPolicyAppliesToPOSTTransport() async {
        let postCapture = RequestCapture()
        let service = IngestionService(
            requestExecutor: { request in
                if request.httpMethod == "POST" {
                    await postCapture.record(request.url?.absoluteString ?? "")
                    let status = await postCapture.count() == 1 ? 503 : 200
                    return (Data("{}".utf8), try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
                    )))
                }
                return (Data("{}".utf8), try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        _ = await service.ingestReport(
            term: WatchTerm(keyword: "POST Retry Oshi"), platforms: ["youtube"]
        )

        let postRequestCount = await postCapture.count()
        XCTAssertEqual(postRequestCount, 2)
    }

    func testCancellationDuringBackoffDoesNotLeakRequestCapacity() async {
        let capture = RequestCapture()
        let gate = RetryGate()
        let service = IngestionService(
            requestExecutor: { request in
                await capture.record(request.url?.absoluteString ?? "")
                if await capture.count() == 1 {
                    throw URLError(.timedOut)
                }
                return (Data("<rss version=\"2.0\"><channel></channel></rss>".utf8), try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in
                await gate.enter()
                while !Task.isCancelled {
                    await Task.yield()
                }
            }
        )

        let cancelled = Task {
            await service.ingestReport(
                term: WatchTerm(keyword: "Cancelled Retry"), platforms: ["barks"]
            )
        }
        await gate.waitUntilEntered()
        cancelled.cancel()
        _ = await cancelled.value

        let followUp = await service.ingestReport(
            term: WatchTerm(keyword: "Follow Up"), platforms: ["barks"]
        )
        XCTAssertEqual(followUp.sourceStatuses.first?.outcome, .noResults)
        let requestCount = await capture.count()
        XCTAssertEqual(requestCount, 2)
    }

    func testMalformedRSSIsReportedAsInvalidPayload() async {
        let service = IngestionService { _ in
            (
                Data("<rss><channel>".utf8),
                try XCTUnwrap(HTTPURLResponse(
                    url: URL(string: "https://example.com")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                ))
            )
        }

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Malformed Oshi"),
            platforms: ["news"]
        )

        XCTAssertTrue(report.sourceStatuses.contains {
            if case .failed(.invalidPayload) = $0.outcome { return true }
            return false
        })
    }

    func testMalformedJSONIsReportedAsInvalidPayload() async {
        let service = IngestionService { request in
            (
                Data("{malformed".utf8),
                try XCTUnwrap(HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                ))
            )
        }

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Malformed JSON Oshi"),
            platforms: ["niconico"]
        )

        XCTAssertTrue(report.sourceStatuses.contains {
            if case .failed(.invalidPayload) = $0.outcome { return true }
            return false
        })
    }

    func testSuccessfulRSSReturnsItemsAndCompatibilityAPIStillReturnsItems() async {
        let rss = """
        <rss version="2.0"><channel><item>
        <title>Transport Oshi headline</title>
        <link>https://example.com/transport-oshi</link>
        <description>Transport Oshi update</description>
        <pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate>
        </item></channel></rss>
        """.data(using: .utf8)!
        let service = IngestionService { _ in
            (
                rss,
                try XCTUnwrap(HTTPURLResponse(
                    url: URL(string: "https://example.com")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                ))
            )
        }

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Transport Oshi"),
            platforms: ["news"]
        )
        let items = await service.ingest(
            term: WatchTerm(keyword: "Transport Oshi"),
            platforms: ["news"]
        )

        XCTAssertFalse(report.items.isEmpty)
        XCTAssertFalse(items.isEmpty)
        XCTAssertTrue(report.sourceStatuses.contains { $0.outcome == .received })
    }

    func testMixedSourceRefreshKeepsSuccessAndFailureTogether() async {
        let rss = """
        <rss version="2.0"><channel><item>
        <title>Mixed Oshi headline</title>
        <link>https://example.com/mixed-oshi</link>
        </item></channel></rss>
        """.data(using: .utf8)!
        let service = IngestionService { request in
            if request.url?.absoluteString.contains("soompi") == true {
                return (
                    Data(),
                    try XCTUnwrap(HTTPURLResponse(
                        url: request.url!,
                        statusCode: 429,
                        httpVersion: nil,
                        headerFields: nil
                    ))
                )
            }
            return (
                rss,
                try XCTUnwrap(HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                ))
            )
        }

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Mixed Oshi"),
            platforms: ["news", "soompi"]
        )

        XCTAssertTrue(report.sourceStatuses.contains { $0.id == "news" && $0.outcome == .received })
        XCTAssertTrue(report.sourceStatuses.contains {
            $0.id == "soompi" && $0.outcome == .failed(.rateLimited)
        })
        XCTAssertFalse(report.items.isEmpty)
    }

    func testMissingTwitterCredentialIsReported() async {
        let existing = KeychainHelper.read(.twitterBearerToken)
        KeychainHelper.save(.twitterBearerToken, nil)
        defer { KeychainHelper.save(.twitterBearerToken, existing) }

        let report = await IngestionService(
            requestExecutor: { _ in
                XCTFail("Twitter should not make a request without credentials")
                throw URLError(.cancelled)
            }
        ).ingestReport(
            term: WatchTerm(keyword: "Credential Oshi"),
            platforms: ["twitter"]
        )

        XCTAssertTrue(report.sourceStatuses.contains {
            $0.outcome == .failed(.missingCredential)
        })
    }

    func testWatchTermDecodesLegacyBackupWithoutSourceSelection() throws {
        let legacy = #"{"id":"legacy","keyword":"Legacy Oshi","collection_mode":"all_info","is_active":true,"notify_on_new":false,"aliases":[],"created_at":"2026-01-01T00:00:00Z"}"#.data(using: .utf8)!
        let term = try JSONDecoder().decode(WatchTerm.self, from: legacy)

        XCTAssertEqual(term.source_mode, .all)
        XCTAssertEqual(term.selected_platforms, [])
    }

    func testISO8601DateParsingCachePreservesSupportedFormatsAndFailures() {
        let zoned = "2026-01-01T12:34:56.123Z"
        let naive = "2026-01-01T12:34:56"

        XCTAssertNotNil(parseISO8601Date(zoned))
        XCTAssertNotNil(parseISO8601Date(zoned))
        XCTAssertNotNil(parseISO8601Date(naive))
        XCTAssertNil(parseISO8601Date("not-a-date"))
        XCTAssertNil(parseISO8601Date("not-a-date"))
    }

    @MainActor
    func testSelectedSourcesAdvanceRevisionAndFilterIngestion() throws {
        let initialRevision = db.dataRevision
        let term = db.saveTerm(
            keyword: "Selected Oshi",
            sourceMode: .selected,
            selectedPlatforms: [" youtube ", "unknown", "youtube"]
        )

        XCTAssertEqual(term.source_mode, .selected)
        XCTAssertEqual(term.selected_platforms, ["youtube"])
        XCTAssertGreaterThan(db.dataRevision, initialRevision)
        XCTAssertEqual(
            IngestionService.effectivePlatforms(for: term, available: ["youtube", "news", "tver"]),
            ["youtube"]
        )

        let revisionAfterCreate = db.dataRevision
        db.updateTerm(id: term.id, sourceMode: .selected, selectedPlatforms: [])
        XCTAssertEqual(db.terms.first?.source_mode, .all)
        XCTAssertEqual(db.terms.first?.selected_platforms, [])
        XCTAssertGreaterThan(db.dataRevision, revisionAfterCreate)
    }

    @MainActor
    func testUnsubscribingSourcesNormalizesSelectedTermSources() throws {
        let term = db.saveTerm(
            keyword: "Subscription Oshi",
            sourceMode: .selected,
            selectedPlatforms: ["youtube", "news"]
        )

        db.setSubscribedPlatforms(platforms: ["news", "tver"])
        let partiallyValid = try XCTUnwrap(db.terms.first(where: { $0.id == term.id }))
        XCTAssertEqual(partiallyValid.source_mode, .selected)
        XCTAssertEqual(partiallyValid.selected_platforms, ["news"])

        db.setSubscribedPlatforms(platforms: ["tver"])
        let noLongerValid = try XCTUnwrap(db.terms.first(where: { $0.id == term.id }))
        XCTAssertEqual(noLongerValid.source_mode, .all)
        XCTAssertEqual(noLongerValid.selected_platforms, [])
    }

    func testRequestLimiterCancellationDoesNotLeakOrBlockNextAcquire() async {
        let limiter = RequestLimiter(limit: 1)
        let firstAcquire = await limiter.acquire()
        XCTAssertTrue(firstAcquire)

        let waitingTask = Task { await limiter.acquire() }
        try? await Task.sleep(nanoseconds: 30_000_000)
        waitingTask.cancel()

        let cancelledAcquire = await waitingTask.value
        XCTAssertFalse(cancelledAcquire)
        await limiter.release()
        let nextAcquire = await limiter.acquire()
        XCTAssertTrue(nextAcquire)
        await limiter.release()
    }

    @MainActor
    func testRefreshDiagnosticsPersistsSuccessfulRefreshSummary() {
        let diagnostics = RefreshDiagnostics.shared
        diagnostics.begin()
        XCTAssertTrue(diagnostics.isRefreshing)

        diagnostics.finish(succeeded: true, addedCount: 3)

        XCTAssertFalse(diagnostics.isRefreshing)
        XCTAssertEqual(diagnostics.lastSucceeded, true)
        XCTAssertEqual(diagnostics.lastAddedCount, 3)
        XCTAssertNotNil(diagnostics.lastStartedAt)
        XCTAssertNotNil(diagnostics.lastCompletedAt)
        XCTAssertTrue(diagnostics.statusText.contains("3 new"))
    }

    func testRefreshResultReportsCustomURLFailure() {
        let result = LocalRefreshResult(
            completion: .completed,
            addedCount: 0,
            sourceStatuses: [],
            customRefreshCompleted: false
        )

        XCTAssertFalse(result.succeeded)
    }

    @MainActor
    func testRefreshDiagnosticsUsesInjectedDefaultsForLifecycleMetadata() {
        let suiteName = "OshiReaderTests.lifecycle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let diagnostics = RefreshDiagnostics(defaults: defaults)
        diagnostics.begin()
        diagnostics.finish(succeeded: false)

        XCTAssertGreaterThan(defaults.double(forKey: "refresh_diagnostics.last_started_at"), 0)
        XCTAssertGreaterThan(defaults.double(forKey: "refresh_diagnostics.last_completed_at"), 0)
        XCTAssertFalse(defaults.bool(forKey: "refresh_diagnostics.last_succeeded"))
    }

    @MainActor
    func testRecentTermUsagePrioritizesNotificationsAndPreservesStableOrder() {
        let suiteName = "OshiReaderTests.recent.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RecentTermUsageStore(defaults: defaults)
        let first = WatchTerm(id: "first", keyword: "First", notify_on_new: false)
        let second = WatchTerm(id: "second", keyword: "Second", notify_on_new: true)
        let third = WatchTerm(id: "third", keyword: "Third", notify_on_new: true)

        store.markUsed(termID: first.id)
        store.markUsed(termID: third.id)

        XCTAssertEqual(store.priorityOrdered([first, second, third]).map(\.id), ["third", "second", "first"])
    }

    @MainActor
    func testRecentTermUsageIsBoundedAndDeletionRemovesTimestamp() {
        let suiteName = "OshiReaderTests.recent.bound.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RecentTermUsageStore(defaults: defaults)

        for index in 0..<(RecentTermUsageStore.maximumEntries + 5) {
            store.markUsed(termID: "term-\(index)")
        }

        XCTAssertEqual(store.timestamps.count, RecentTermUsageStore.maximumEntries)
        store.remove(termID: "term-104")
        XCTAssertNil(store.timestamps["term-104"])
    }

    @MainActor
    func testRefreshDiagnosticsMarksPartialSourceFailure() {
        let diagnostics = RefreshDiagnostics.shared
        diagnostics.resetSourceStatuses()
        diagnostics.recordSourceStatuses([
            SourceRefreshStatus(id: "natalie", outcome: .received, itemCount: 2, queryCount: 1),
            SourceRefreshStatus(id: "barks", outcome: .failed(.timeout), itemCount: 0, queryCount: 1),
        ])

        XCTAssertTrue(diagnostics.hasSourceFailures)
        XCTAssertTrue(diagnostics.sourceSummaryText.contains("1 failed"))
    }

    @MainActor
    func testRefreshDiagnosticsShowsCurrentStatusesBeforeHistoryIsPersisted() {
        let suiteName = "OshiReaderTests.health.current.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let diagnostics = RefreshDiagnostics(defaults: defaults)

        diagnostics.recordSourceStatuses([
            SourceRefreshStatus(id: "news", outcome: .received, itemCount: 1, queryCount: 1),
            SourceRefreshStatus(id: "barks", outcome: .failed(.timeout), itemCount: 0, queryCount: 1),
        ])

        XCTAssertEqual(diagnostics.visibleSourceHealthSummaries.map(\.id), ["barks", "news"])
        XCTAssertEqual(diagnostics.visibleSourceHealthSummaries.first { $0.id == "barks" }?.failedCount, 1)
    }

    @MainActor
    func testRefreshDiagnosticsMergesCurrentSourcesIntoExistingHistory() {
        let suiteName = "OshiReaderTests.health.merge.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let diagnostics = RefreshDiagnostics(defaults: defaults)

        diagnostics.recordCompletedSourceStatuses([
            SourceRefreshStatus(id: "news", outcome: .received, itemCount: 2, queryCount: 1)
        ])
        diagnostics.recordSourceStatuses([
            SourceRefreshStatus(id: "barks", outcome: .failed(.timeout), itemCount: 0, queryCount: 1)
        ])

        XCTAssertEqual(diagnostics.visibleSourceHealthSummaries.map(\.id), ["barks", "news"])
        XCTAssertEqual(diagnostics.visibleSourceHealthSummaries.first { $0.id == "barks" }?.currentStatus?.outcome, .failed(.timeout))
    }

    @MainActor
    func testSourceHealthHistoryPersistsAndReloadsAggregatedSummary() {
        let suiteName = "OshiReaderTests.health.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let checkedAt = Date(timeIntervalSinceNow: -3600)
        let diagnostics = RefreshDiagnostics(defaults: defaults)

        diagnostics.recordCompletedSourceStatuses([
            SourceRefreshStatus(id: "natalie", outcome: .received, itemCount: 3, queryCount: 1),
            SourceRefreshStatus(id: "barks", outcome: .noResults, itemCount: 0, queryCount: 1),
        ], completedAt: checkedAt)

        let reloaded = RefreshDiagnostics(defaults: defaults)
        let natalie = reloaded.sourceHealthSummaries.first { $0.id == "natalie" }
        let barks = reloaded.sourceHealthSummaries.first { $0.id == "barks" }
        XCTAssertEqual(natalie?.receivedCount, 1)
        XCTAssertEqual(natalie?.totalItemCount, 3)
        XCTAssertEqual(natalie?.currentStatus?.outcome, .received)
        XCTAssertEqual(barks?.emptyCount, 1)
        XCTAssertEqual(barks?.currentStatus?.outcome, .noResults)
    }

    @MainActor
    func testSourceHealthHistoryPrunesRecordsOlderThanSevenDays() {
        let suiteName = "OshiReaderTests.health.prune.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let diagnostics = RefreshDiagnostics(defaults: defaults)
        let now = Date()

        diagnostics.recordCompletedSourceStatuses([
            SourceRefreshStatus(id: "old", outcome: .received, itemCount: 9, queryCount: 1),
        ], completedAt: now.addingTimeInterval(-(RefreshDiagnostics.healthHistoryRetention + 1)))
        diagnostics.recordCompletedSourceStatuses([
            SourceRefreshStatus(id: "recent", outcome: .received, itemCount: 2, queryCount: 1),
        ], completedAt: now)

        XCTAssertNil(diagnostics.sourceHealthSummaries.first { $0.id == "old" })
        XCTAssertNotNil(diagnostics.sourceHealthSummaries.first { $0.id == "recent" })
    }

    @MainActor
    func testSourceHealthHistoryUsesReceivedPrecedenceAndKeepsLatestFailure() {
        let suiteName = "OshiReaderTests.health.precedence.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let diagnostics = RefreshDiagnostics(defaults: defaults)
        let first = Date(timeIntervalSinceNow: -7200)
        let second = Date(timeIntervalSinceNow: -3600)

        diagnostics.recordSourceStatuses([
            SourceRefreshStatus(id: "barks", outcome: .failed(.timeout), itemCount: 0, queryCount: 1),
            SourceRefreshStatus(id: "barks", outcome: .noResults, itemCount: 0, queryCount: 1),
            SourceRefreshStatus(id: "barks", outcome: .received, itemCount: 2, queryCount: 1),
        ])
        XCTAssertEqual(diagnostics.sourceStatuses.first?.outcome, .received)

        diagnostics.recordCompletedSourceStatuses([
            SourceRefreshStatus(id: "barks", outcome: .failed(.timeout), itemCount: 0, queryCount: 1),
        ], completedAt: first)
        diagnostics.recordCompletedSourceStatuses([
            SourceRefreshStatus(id: "barks", outcome: .failed(.rateLimited), itemCount: 0, queryCount: 1),
        ], completedAt: second)

        let summary = diagnostics.sourceHealthSummaries.first { $0.id == "barks" }
        XCTAssertEqual(summary?.failedCount, 2)
        XCTAssertEqual(summary?.lastFailure, .rateLimited)
        XCTAssertEqual(summary?.currentStatus?.outcome, .failed(.rateLimited))
    }

    @MainActor
    func testSourceHealthHistoryRetryAttemptsRemainOneLogicalRecord() {
        let suiteName = "OshiReaderTests.health.retry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let diagnostics = RefreshDiagnostics(defaults: defaults)

        diagnostics.recordCompletedSourceStatuses([
            SourceRefreshStatus(id: "natalie", outcome: .received, itemCount: 1, queryCount: 1),
        ])

        let summary = diagnostics.sourceHealthSummaries.first { $0.id == "natalie" }
        XCTAssertEqual(summary?.receivedCount, 1)
        XCTAssertEqual(summary?.totalItemCount, 1)
        XCTAssertEqual(summary?.currentStatus?.queryCount, 1)
    }

    @MainActor
    func testSourceHealthHistoryEmptyStoreIsSafe() {
        let suiteName = "OshiReaderTests.health.empty.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let diagnostics = RefreshDiagnostics(defaults: defaults)

        XCTAssertTrue(diagnostics.sourceHealthSummaries.isEmpty)
        XCTAssertTrue(diagnostics.sourceStatuses.isEmpty)
    }

    @MainActor
    func testStrictFeedMatchingAcceptsAliasOnlyArticle() throws {
        let term = db.saveTerm(keyword: "Primary Oshi")
        db.updateTerm(id: term.id, aliases: ["Alias Oshi"])
        let nowString = ISO8601DateFormatter().string(from: Date())
        let item = FeedItem(
            id: "news:alias-only",
            platform: "news",
            url: "https://example.com/alias-only",
            title: "Latest update on Alias Oshi",
            content_text: "Alias Oshi appeared in a new report.",
            author: nil,
            thumbnail_url: nil,
            media_type: "article",
            published_at: nowString,
            watch_term_keyword: term.keyword,
            fetched_at: nowString
        )

        XCTAssertEqual(db.mergeItems(newItems: [item]), 1)
        XCTAssertEqual(db.queryFeed(keyword: term.keyword, days: 30).first?.id, item.id)
    }

    @MainActor
    func testDeletingSourcesRejectsStaleIngestionResults() throws {
        let term = db.saveTerm(keyword: "Deleted Oshi")
        let staleTermRevision = db.dataRevision
        db.deleteTerm(id: term.id)

        let termItem = FeedItem(
            id: "news:stale-term",
            platform: "news",
            url: "https://example.com/stale-term",
            title: "Stale term result",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "article",
            published_at: ISO8601DateFormatter().string(from: Date()),
            watch_term_keyword: term.keyword,
            fetched_at: ISO8601DateFormatter().string(from: Date())
        )
        XCTAssertEqual(db.mergeItems(newItems: [termItem], sourceRevision: staleTermRevision), 0)
        XCTAssertFalse(db.feedItems.contains(where: { $0.id == termItem.id }))

        db.addCustomUrl(url: "https://example.com/stale-feed.xml", title: "Stale feed")
        let customURL = try XCTUnwrap(db.customUrls.first)
        let staleCustomRevision = db.dataRevision
        db.removeCustomUrl(id: customURL.id)

        let customItem = FeedItem(
            id: "custom:stale-feed",
            platform: "custom",
            url: customURL.url,
            title: "Stale custom result",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "article",
            published_at: ISO8601DateFormatter().string(from: Date()),
            watch_term_keyword: "",
            fetched_at: ISO8601DateFormatter().string(from: Date())
        )
        XCTAssertEqual(db.mergeItems(newItems: [customItem], sourceRevision: staleCustomRevision), 0)
        XCTAssertFalse(db.feedItems.contains(where: { $0.id == customItem.id }))
    }

    @MainActor
    func testChangingIngestionSourcesRejectsStaleResults() throws {
        let term = db.saveTerm(keyword: "Disabled Oshi")
        let staleTermRevision = db.dataRevision
        db.updateTerm(id: term.id, isActive: false)

        let staleTermItem = FeedItem(
            id: "news:disabled-term",
            platform: "news",
            url: "https://example.com/disabled-term",
            title: "Disabled term result",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "article",
            published_at: ISO8601DateFormatter().string(from: Date()),
            watch_term_keyword: term.keyword,
            fetched_at: ISO8601DateFormatter().string(from: Date())
        )
        XCTAssertEqual(db.mergeItems(newItems: [staleTermItem], sourceRevision: staleTermRevision), 0)

        let stalePlatformRevision = db.dataRevision
        db.setSubscribedPlatforms(platforms: ["youtube"])
        XCTAssertNotEqual(db.dataRevision, stalePlatformRevision)
        XCTAssertEqual(
            db.mergeItems(newItems: [staleTermItem], sourceRevision: stalePlatformRevision),
            0
        )
    }

    @MainActor
    func testDataRevisionTracksOnlyIngestionAffectingChanges() throws {
        let initialRevision = db.dataRevision
        let term = db.saveTerm(keyword: "Revision Oshi")
        XCTAssertNotEqual(db.dataRevision, initialRevision)

        let afterTermCreateRevision = db.dataRevision
        db.updateTerm(id: term.id, notifyOnNew: !term.notify_on_new)
        XCTAssertEqual(db.dataRevision, afterTermCreateRevision)

        db.updateTerm(id: term.id, aliases: ["Revision Alias"])
        XCTAssertNotEqual(db.dataRevision, afterTermCreateRevision)

        let afterAliasRevision = db.dataRevision
        db.addCustomUrl(url: "https://example.com/revision-feed.xml", title: "Revision Feed")
        XCTAssertNotEqual(db.dataRevision, afterAliasRevision)
    }
    
    // MARK: - Feature 1: Watch Keywords (Terms)
    func testWatchTerms() throws {
        // 1. Save watch term
        let term = db.saveTerm(keyword: "Test Oshi", collectionMode: "media_only")
        
        XCTAssertEqual(db.terms.count, 1)
        XCTAssertEqual(db.terms.first?.keyword, "Test Oshi")
        XCTAssertEqual(db.terms.first?.collection_mode, "media_only")
        XCTAssertTrue(db.terms.first?.is_active ?? false)
        
        // 2. Update watch term
        db.updateTerm(id: term.id, isActive: false, collectionMode: "all_info")
        
        XCTAssertEqual(db.terms.first?.is_active, false)
        XCTAssertEqual(db.terms.first?.collection_mode, "all_info")

        db.updateTerm(id: term.id, notifyOnNew: true)
        XCTAssertEqual(db.terms.first?.notify_on_new, true)
        
        // 3. Delete watch term
        db.deleteTerm(id: term.id)
        XCTAssertEqual(db.terms.count, 0)
    }
    
    // MARK: - Feature 2: Feed Items merging & duplicates checking
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
            fetched_at: nowString
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
            fetched_at: nowString
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

    func testAPNSDeviceTokenStringUsesLowercaseHex() throws {
        let data = Data([0x00, 0x0f, 0xa1, 0xff])
        XCTAssertEqual(NotificationManager.deviceTokenString(data), "000fa1ff")
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
    func testPerTermNotificationsOnlyScheduleForEnabledTerms() async throws {
        let center = MockNotificationCenter(status: .authorized)
        let manager = NotificationManager(center: center)
        let nowString = ISO8601DateFormatter().string(from: Date())

        let enabledTerm = WatchTerm(id: "enabled", keyword: "Enabled Oshi", notify_on_new: true)
        let disabledTerm = WatchTerm(id: "disabled", keyword: "Muted Oshi", notify_on_new: false)
        let items = [
            FeedItem(
                id: "youtube:enabled-1", platform: "youtube", url: "https://youtube.com/1",
                title: "Enabled first", content_text: nil, author: nil, thumbnail_url: nil,
                media_type: "video", published_at: nowString, watch_term_keyword: enabledTerm.keyword,
                fetched_at: nowString
            ),
            FeedItem(
                id: "note:enabled-2", platform: "note", url: "https://note.com/2",
                title: "Enabled second", content_text: nil, author: nil, thumbnail_url: nil,
                media_type: "article", published_at: nowString, watch_term_keyword: enabledTerm.keyword,
                fetched_at: nowString
            ),
            FeedItem(
                id: "tver:muted", platform: "tver", url: "https://tver.jp/episodes/3",
                title: "Muted", content_text: nil, author: nil, thumbnail_url: nil,
                media_type: "video", published_at: nowString, watch_term_keyword: disabledTerm.keyword,
                fetched_at: nowString
            )
        ]

        await manager.notifyForNewItems(items, terms: [enabledTerm, disabledTerm])

        XCTAssertEqual(center.requests.count, 1)
        XCTAssertEqual(center.requests.first?.content.title, "New items for Enabled Oshi")
        XCTAssertEqual(center.requests.first?.content.body, "2 new items found.")
        XCTAssertNil(center.requests.first?.trigger)
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
        XCTAssertEqual(center.requests.first?.identifier, "oshireader-new-term-digest")
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
            id: "news:original", platform: "news", url: "https://example.com/original",
            title: "Original", content_text: nil, author: nil, thumbnail_url: nil,
            media_type: "article", published_at: nowString, watch_term_keyword: original.keyword,
            fetched_at: nowString
        )
        let renamedItem = FeedItem(
            id: "news:renamed", platform: "news", url: "https://example.com/renamed",
            title: "Renamed", content_text: nil, author: nil, thumbnail_url: nil,
            media_type: "article", published_at: nowString, watch_term_keyword: renamed.keyword,
            fetched_at: nowString
        )

        await manager.notifyForNewItems([originalItem], terms: [original])
        await manager.notifyForNewItems([renamedItem], terms: [renamed])

        XCTAssertEqual(center.requests.count, 1)
        XCTAssertEqual(center.requests.first?.identifier, "oshireader-new-term-stable-term")
    }

    @MainActor
    func testTermNotificationCanBeClearedByStableID() {
        let center = MockNotificationCenter(status: .authorized)
        let manager = NotificationManager(center: center)

        manager.clearNotification(forTermID: "term-to-clear")

        XCTAssertEqual(center.removedPendingIdentifiers, [["oshireader-new-term-term-to-clear"]])
        XCTAssertEqual(center.removedDeliveredIdentifiers, [["oshireader-new-term-term-to-clear"]])
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
            fetched_at: nowString
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
            fetched_at: nowString
        )

        XCTAssertEqual(db.mergeItems(newItems: [item]), 1)
        XCTAssertEqual(db.mergeItems(newItems: [item]), 0)
    }
    
    // MARK: - Feature 3: Feed Querying & Filters (Strict matches, platform toggles, days)
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
            watch_term_keyword: "Aiko", fetched_at: formatter.string(from: now)
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
    
    // MARK: - Feature 4: Saved Bookmarks
    func testSavedBookmarks() throws {
        let item = FeedItem(
            id: "news:111", platform: "news", url: "https://url", title: "Bookmark test",
            content_text: nil, author: nil, thumbnail_url: nil, media_type: "article",
            published_at: "2026-06-02T12:00:00Z", watch_term_keyword: "", fetched_at: ""
        )
        
        XCTAssertEqual(db.getSaved().count, 0)
        
        // Toggle saved (Add)
        let isSaved1 = db.toggleSaved(item: item)
        XCTAssertTrue(isSaved1)
        XCTAssertEqual(db.getSaved().count, 1)
        XCTAssertEqual(db.getSaved().first?.id, "news:111")
        
        // Toggle saved (Remove)
        let isSaved2 = db.toggleSaved(item: item)
        XCTAssertFalse(isSaved2)
        XCTAssertEqual(db.getSaved().count, 0)
    }

    @MainActor
    func testLocalBackupRoundTrip() throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let term = WatchTerm(
            keyword: "Backup Oshi",
            collection_mode: "media_only",
            source_mode: .selected,
            selected_platforms: ["youtube", "news"],
            notify_on_new: true
        )
        let item = FeedItem(
            id: "news:backup",
            platform: "news",
            url: "https://example.com/backup",
            title: "Backup article",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "article",
            published_at: now,
            watch_term_keyword: term.keyword,
            fetched_at: now
        )
        db.terms = [term]
        db.feedItems = [item]
        db.savedPages = [SavedPage(id: item.id, url: item.url, title: item.title, platform: item.platform, saved_at: now)]
        db.customUrls = [CustomUrl(id: "custom:backup", url: "https://example.com/feed.xml", title: "Backup feed", added_at: now)]

        let data = try db.exportBackupData()
        db.terms.removeAll()
        db.feedItems.removeAll()
        db.savedPages.removeAll()
        db.customUrls.removeAll()
        try db.importBackupData(data)

        XCTAssertEqual(db.terms, [term])
        XCTAssertEqual(db.feedItems, [item])
        XCTAssertEqual(db.savedPages.count, 1)
        XCTAssertEqual(db.customUrls.count, 1)
    }

    @MainActor
    func testEncryptedBackupRoundTripPreservesLocalData() throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let term = WatchTerm(id: "encrypted-term", keyword: "Encrypted Oshi", notify_on_new: true)
        let item = FeedItem(
            id: "news:encrypted", platform: "news", url: "https://example.com/encrypted",
            title: "Encrypted item", content_text: "Private local content", author: "Author",
            thumbnail_url: nil, media_type: "article", published_at: now,
            watch_term_keyword: term.keyword, fetched_at: now
        )
        db.terms = [term]
        db.feedItems = [item]
        db.customUrls = [CustomUrl(id: "custom:encrypted", url: "https://example.com/feed.xml", title: "Feed", added_at: now)]
        db.amebloBlogs = [AmebloBlog(url: "https://ameblo.jp/encrypted", title: "Blog", addedAt: now)!]

        let encrypted = try db.exportEncryptedBackupData(password: "correct horse battery staple")
        XCTAssertNotEqual(encrypted, try db.exportBackupData())

        db.terms = []
        db.feedItems = []
        db.customUrls = []
        db.amebloBlogs = []
        try db.importEncryptedBackupData(encrypted, password: "correct horse battery staple")

        XCTAssertEqual(db.terms.map(\.keyword), ["Encrypted Oshi"])
        XCTAssertEqual(db.feedItems.map(\.id), ["news:encrypted"])
        XCTAssertEqual(db.customUrls.map(\.id), ["custom:encrypted"])
        XCTAssertEqual(db.amebloBlogs.map(\.amebaID), ["encrypted"])
    }

    @MainActor
    func testEncryptedBackupWrongPasswordLeavesCurrentDataUntouched() throws {
        let term = db.saveTerm(keyword: "Protected Oshi")
        let encrypted = try db.exportEncryptedBackupData(password: "correct horse battery staple")
        let beforeTerms = db.terms
        let beforeItems = db.feedItems

        XCTAssertThrowsError(try db.importEncryptedBackupData(encrypted, password: "wrong password here")) { error in
            XCTAssertEqual(error as? EncryptedBackupError, .authenticationFailed)
        }
        XCTAssertEqual(db.terms, beforeTerms)
        XCTAssertEqual(db.feedItems, beforeItems)
        XCTAssertEqual(db.terms.first?.id, term.id)
    }

    @MainActor
    func testEncryptedBackupTamperAndTruncationLeaveCurrentDataUntouched() throws {
        _ = db.saveTerm(keyword: "Untouched Oshi")
        let encrypted = try db.exportEncryptedBackupData(password: "correct horse battery staple")
        let before = db.terms

        var tampered = encrypted
        tampered[tampered.count - 1] ^= 1
        XCTAssertThrowsError(try db.importEncryptedBackupData(tampered, password: "correct horse battery staple"))
        XCTAssertThrowsError(try db.importEncryptedBackupData(Data(encrypted.prefix(10)), password: "correct horse battery staple"))
        XCTAssertEqual(db.terms, before)
    }

    func testEncryptedBackupRejectsUnsupportedAndInvalidEnvelopeVersions() throws {
        XCTAssertThrowsError(try EncryptedBackupCodec.decrypt(Data("not an encrypted backup".utf8), password: "correct horse battery staple")) { error in
            XCTAssertEqual(error as? EncryptedBackupError, .invalidEnvelope)
        }

        let encrypted = try EncryptedBackupCodec.encrypt(Data("payload".utf8), password: "correct horse battery staple")
        var unsupported = encrypted
        unsupported[EncryptedBackupCodec.magic.count] = 99
        XCTAssertThrowsError(try EncryptedBackupCodec.decrypt(unsupported, password: "correct horse battery staple")) { error in
            XCTAssertEqual(error as? EncryptedBackupError, .unsupportedVersion)
        }
    }

    func testEncryptedBackupUsesRandomSaltAndNonce() throws {
        let first = try EncryptedBackupCodec.encrypt(Data("same payload".utf8), password: "correct horse battery staple")
        let second = try EncryptedBackupCodec.encrypt(Data("same payload".utf8), password: "correct horse battery staple")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try EncryptedBackupCodec.decrypt(first, password: "correct horse battery staple"), Data("same payload".utf8))
    }

    func testEncryptedBackupPasswordValidation() {
        XCTAssertThrowsError(try EncryptedBackupCodec.validatePassword("short")) { error in
            XCTAssertEqual(error as? EncryptedBackupError, .invalidPassword)
        }
        XCTAssertNoThrow(try EncryptedBackupCodec.validatePassword(String(repeating: "🙂", count: 12)))
        XCTAssertThrowsError(try EncryptedBackupCodec.validatePassword(String(repeating: "a", count: 257)))
    }

    @MainActor
    func testProfilesIsolateDataAndProtectLastProfile() throws {
        db.clearAllData()
        let originalID = db.activeProfile.id
        for profile in db.profiles where profile.id != originalID {
            try? db.deleteProfile(id: profile.id)
        }
        let profile = try db.createProfile(name: "Profile \(UUID().uuidString)")

        try db.switchProfile(to: profile.id)
        XCTAssertTrue(db.terms.isEmpty)
        _ = db.saveTerm(keyword: "Second profile term")
        UserDefaults.standard.set("dark", forKey: LocalProfileStore.defaultsKey("app_theme_mode", profileID: profile.id))
        XCTAssertEqual(db.terms.count, 1)

        try db.switchProfile(to: originalID)
        XCTAssertTrue(db.terms.isEmpty)
        XCTAssertThrowsError(try db.renameProfile(id: originalID, name: profile.name)) { error in
            XCTAssertEqual(error as? LocalProfileError, .duplicateName)
        }

        try db.deleteProfile(id: profile.id)
        XCTAssertEqual(db.profiles.count, 1)
        XCTAssertNil(UserDefaults.standard.object(forKey: LocalProfileStore.defaultsKey("app_theme_mode", profileID: profile.id)))
        XCTAssertThrowsError(try db.deleteProfile(id: originalID)) { error in
            XCTAssertEqual(error as? LocalProfileError, .cannotDeleteLastProfile)
        }
    }

    @MainActor
    func testProfilesIsolateAppearanceAndLanguageSettings() throws {
        let originalID = db.activeProfile.id
        let theme = ThemeManager.shared
        let appearance = AppearanceManager.shared
        let i18n = I18nManager.shared
        let originalTheme = theme.mode
        let originalStyle = theme.style
        let originalFont = appearance.fontChoice
        let originalFontSize = appearance.fontSizeChoice
        let originalLanguage = i18n.lang
        let profile = try db.createProfile(name: "Settings \(UUID().uuidString)")

        theme.mode = .dark
        theme.style = .standard
        appearance.fontChoice = .comicSans
        appearance.fontSizeChoice = .extraLarge
        i18n.setLanguage("en")

        try db.switchProfile(to: profile.id)
        XCTAssertEqual(theme.mode, .light)
        XCTAssertEqual(theme.style, .colourful)
        XCTAssertEqual(appearance.fontChoice, .normal)
        XCTAssertEqual(appearance.fontSizeChoice, .normal)
        XCTAssertEqual(i18n.lang, "ja")

        try db.switchProfile(to: originalID)
        XCTAssertEqual(theme.mode, .dark)
        XCTAssertEqual(theme.style, .standard)
        XCTAssertEqual(appearance.fontChoice, .comicSans)
        XCTAssertEqual(appearance.fontSizeChoice, .extraLarge)
        XCTAssertEqual(i18n.lang, "en")

        theme.mode = originalTheme
        theme.style = originalStyle
        appearance.fontChoice = originalFont
        appearance.fontSizeChoice = originalFontSize
        i18n.setLanguage(originalLanguage)
        try db.deleteProfile(id: profile.id)
    }

    @MainActor
    func testProfileTransferCreatesNewProfileAndKeepsActiveProfile() throws {
        let originalID = db.activeProfile.id
        _ = db.saveTerm(keyword: "Transferred term")
        let data = try db.exportProfileTransferData()

        let imported = try db.importProfileTransferData(data)
        XCTAssertEqual(db.activeProfile.id, originalID)
        XCTAssertNotEqual(imported.id, originalID)
        XCTAssertTrue(db.profiles.contains(where: { $0.id == imported.id }))

        try db.switchProfile(to: imported.id)
        XCTAssertEqual(db.terms.map(\.keyword), ["Transferred term"])
        try db.switchProfile(to: originalID)
        try db.deleteProfile(id: imported.id)

        let repeatedImports = try (0..<3).map { _ in
            try db.importProfileTransferData(data)
        }
        XCTAssertEqual(Set(repeatedImports.map(\.name)).count, 3)
        for profile in repeatedImports {
            try db.deleteProfile(id: profile.id)
        }
    }

    @MainActor
    func testProfileTransferRejectsMalformedAndUnsupportedPackages() throws {
        XCTAssertThrowsError(try db.importProfileTransferData(Data("not a profile".utf8))) { error in
            XCTAssertEqual(error as? LocalProfileError, .invalidPackage)
        }

        let transfer = LocalProfileTransfer(profile: db.activeProfile, backup: LocalBackup(
            exportedAt: "",
            terms: [],
            feedItems: [],
            savedPages: [],
            customUrls: [],
            subscribedPlatforms: [],
            wallpaper: nil,
            sourcesOrder: nil,
            oshiAvatars: [:],
            compositions: [:],
            hiddenItems: []
        ))
        let encoded = try JSONEncoder().encode(transfer)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["version"] = 99
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try db.importProfileTransferData(data)) { error in
            XCTAssertEqual(error as? LocalProfileError, .unsupportedPackageVersion)
        }

        object["version"] = 0
        let legacyVersionData = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try db.importProfileTransferData(legacyVersionData)) { error in
            XCTAssertEqual(error as? LocalProfileError, .unsupportedPackageVersion)
        }
    }

    @MainActor
    func testBackupImportNormalizesAliasesToIngestionLimit() throws {
        let term = WatchTerm(
            keyword: "Primary Oshi",
            aliases: [" Alias Oshi ", "Primary Oshi", "Alias Oshi", "Alias 2", "Alias 3", "Alias 4", "Alias 5"]
        )
        let backup = LocalBackup(
            exportedAt: ISO8601DateFormatter().string(from: Date()),
            terms: [term],
            feedItems: [],
            savedPages: [],
            customUrls: [],
            subscribedPlatforms: ["news"],
            wallpaper: nil,
            sourcesOrder: nil,
            oshiAvatars: [:],
            compositions: [:],
            hiddenItems: []
        )
        let data = try JSONEncoder().encode(backup)

        try db.importBackupData(data)

        XCTAssertEqual(db.terms.first?.aliases, ["Alias Oshi", "Alias 2", "Alias 3", "Alias 4", "Alias 5"])
        XCTAssertEqual(IngestionService.searchKeywords(for: db.terms[0]).count, 6)
    }

    @MainActor
    func testBackupImportDropsUnknownPlatformIDs() throws {
        let backup = LocalBackup(
            exportedAt: ISO8601DateFormatter().string(from: Date()),
            terms: [],
            feedItems: [],
            savedPages: [],
            customUrls: [],
            subscribedPlatforms: ["news", "unknown", " youtube ", "news", "custom", "backend-only"],
            wallpaper: nil,
            sourcesOrder: ["custom", "unknown", "news", "custom", " youtube "],
            oshiAvatars: [:],
            compositions: [:],
            hiddenItems: []
        )
        let data = try JSONEncoder().encode(backup)

        try db.importBackupData(data)

        XCTAssertEqual(db.subscribedPlatforms, ["news", "youtube", "custom"])
        XCTAssertEqual(db.sourcesOrder, ["custom", "news", "youtube"])
    }

    @MainActor
    func testNotificationPayloadRecoversEvictedItem() throws {
        let item = FeedItem(
            id: "news:evicted",
            platform: "news",
            url: "https://example.com/evicted",
            title: "Evicted article",
            content_text: "Cached in the notification payload.",
            author: "Desk",
            thumbnail_url: nil,
            media_type: "article",
            published_at: "2026-07-27T00:00:00Z",
            watch_term_keyword: "Evicted Oshi",
            fetched_at: "2026-07-27T00:00:00Z"
        )
        db.feedItems = []
        NotificationNavigationManager.shared.open(userInfo: [
            "feed_item_id": item.id,
            "watch_term_keyword": item.watch_term_keyword,
            "platform": item.platform,
            "url": item.url,
            "title": item.title as Any,
            "content_text": item.content_text as Any,
            "author": item.author as Any,
            "media_type": item.media_type,
            "published_at": item.published_at,
            "fetched_at": item.fetched_at
        ])

        XCTAssertEqual(NotificationNavigationManager.shared.selectedItem, item)
        NotificationNavigationManager.shared.selectedItem = nil
    }
    
    // MARK: - Feature 5: Custom tracked URLs
    func testCustomUrls() throws {
        XCTAssertEqual(db.customUrls.count, 0)
        
        db.addCustomUrl(url: "https://myoshi-blog.com/feed", title: "Oshi Blog")
        XCTAssertEqual(db.customUrls.count, 1)
        XCTAssertEqual(db.customUrls.first?.title, "Oshi Blog")
        XCTAssertEqual(db.customUrls.first?.url, "https://myoshi-blog.com/feed")
        
        let id = db.customUrls.first!.id
        db.removeCustomUrl(id: id)
        XCTAssertEqual(db.customUrls.count, 0)
    }
    
    // MARK: - Feature 6: Oshi Avatars Compositions
    func testAvatarCompositions() throws {
        let layers = [
            AvatarLayer(id: "L1", imageUrl: "https://stickers/1.png", x: 10, y: 20, scale: 1.0, zIndex: 1),
            AvatarLayer(id: "L2", imageUrl: "https://stickers/2.png", x: 50, y: 50, scale: 1.5, zIndex: 2)
        ]
        
        db.setOshiComposition(keyword: "Aiko", layers: layers)
        
        let loaded = db.compositions["Aiko"]
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.count, 2)
        XCTAssertEqual(loaded?.first?.id, "L1")
        XCTAssertEqual(loaded?.last?.scale, 1.5)
    }
    
    // MARK: - Feature 7: Theme metadata mapping
    func testThemeMetadata() throws {
        let manager = ThemeManager.shared
        
        let youtubeMeta = manager.metadata(for: "youtube")
        XCTAssertEqual(youtubeMeta.name, "YouTube")
        XCTAssertEqual(youtubeMeta.icon, "📹")
        XCTAssertEqual(youtubeMeta.accent, Color.red)
        
        let tverMeta = manager.metadata(for: "tver")
        XCTAssertEqual(tverMeta.name, "TVer")
        XCTAssertEqual(tverMeta.icon, "📺")
        XCTAssertEqual(tverMeta.accent, Color.blue)
        
        let customMeta = manager.metadata(for: "unknown_platform")
        XCTAssertEqual(customMeta.name, "Unknown_Platform")
        XCTAssertEqual(customMeta.icon, "🌐")
    }
    
    // MARK: - Feature 8: I18n Translations
    func testTranslations() throws {
        let i18n = I18nManager.shared
        
        i18n.setLanguage("ja")
        XCTAssertEqual(i18n.lang, "ja")
        XCTAssertEqual(i18n.t("tabFeed"), "フィード")
        XCTAssertEqual(i18n.t("tabSaved"), "ブックマーク")
        
        i18n.setLanguage("en")
        XCTAssertEqual(i18n.lang, "en")
        XCTAssertEqual(i18n.t("tabFeed"), "Feed")
        XCTAssertEqual(i18n.t("tabSaved"), "Saved")
        
        i18n.setLanguage("zh-TW")
        XCTAssertEqual(i18n.lang, "zh-TW")
        XCTAssertEqual(i18n.t("tabFeed"), "動態")
        XCTAssertEqual(i18n.t("tabSaved"), "已儲存")
        
        i18n.setLanguage("zh-CN")
        XCTAssertEqual(i18n.lang, "zh-CN")
        XCTAssertEqual(i18n.t("tabFeed"), "动态")
        XCTAssertEqual(i18n.t("tabSaved"), "已保存")
    }
    
    // MARK: - Feature 9: Multi-keyword source fetching, filtering, and translation targets
    @MainActor
    func testMultiKeywordFeedAndTranslations() throws {
        // 1. Import more than 3 keywords (e.g. 4 keywords)
        let keywords = ["Aiko", "Miku", "Yamada", "Ken"]
        var savedTerms = [WatchTerm]()
        for kw in keywords {
            let term = db.saveTerm(keyword: kw, collectionMode: "all_info")
            savedTerms.append(term)
        }
        
        XCTAssertEqual(db.terms.count, 4)
        
        // 2. Mock feeds fetched for all 4 keywords
        let nowString = ISO8601DateFormatter().string(from: Date())
        var newItems = [FeedItem]()
        for i in 0..<keywords.count {
            let kw = keywords[i]
            let item = FeedItem(
                id: "news:mock:\(kw):\(i)",
                platform: "news",
                url: "https://mocknews.com/\(kw)",
                title: "Latest update on \(kw)",
                content_text: "Summary of events regarding \(kw)",
                author: "Mock Press",
                thumbnail_url: nil,
                media_type: "article",
                published_at: nowString,
                watch_term_keyword: kw,
                fetched_at: nowString
            )
            newItems.append(item)
        }
        
        // Merge feed items
        let addedCount = db.mergeItems(newItems: newItems)
        XCTAssertEqual(addedCount, 4)
        XCTAssertEqual(db.feedItems.count, 4)
        
        // Verify querying for each keyword works correctly
        for kw in keywords {
            let queryResult = db.queryFeed(keyword: kw, days: 30)
            XCTAssertEqual(queryResult.count, 1)
            XCTAssertEqual(queryResult.first?.watch_term_keyword, kw)
            XCTAssertEqual(queryResult.first?.title, "Latest update on \(kw)")
        }
        
        // 3. Test Translation target language codes mapping logic
        let testLanguages = [
            ("ja", "ja"),
            ("en", "en"),
            ("zh-CN", "zh"),
            ("zh-TW", "zh-Hant")
        ]
        
        for (selectedLang, expectedTargetCode) in testLanguages {
            I18nManager.shared.setLanguage(selectedLang)
            
            // Replicate URL translation mapping block in ReaderView
            let targetLangCode: String
            switch I18nManager.shared.lang {
            case "ja": targetLangCode = "ja"
            case "en": targetLangCode = "en"
            case "zh-CN": targetLangCode = "zh"
            case "zh-TW": targetLangCode = "zh-Hant"
            default: targetLangCode = "en"
            }
            
            XCTAssertEqual(targetLangCode, expectedTargetCode, "Language code mapping should match Google Translate expectations.")
        }
    }
}

private final class MockNotificationCenter: NotificationCenterClient {
    private(set) var status: UNAuthorizationStatus
    private let grantsAuthorization: Bool
    var onAuthorizationStatus: (() async -> Void)?
    private(set) var authorizationRequestCount = 0
    private(set) var requests: [UNNotificationRequest] = []
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
    }
}
