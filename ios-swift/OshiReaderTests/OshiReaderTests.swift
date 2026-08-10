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

private final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Data, HTTPURLResponse))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            guard let handler = Self.handler else {
                throw URLError(.badServerResponse)
            }
            var request = request
            if request.httpBody == nil, let stream = request.httpBodyStream {
                var body = Data()
                stream.open()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count > 0 {
                        body.append(buffer, count: count)
                    } else {
                        break
                    }
                }
                stream.close()
                request.httpBody = body
            }
            let (data, response) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
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

    func testFeedThumbnailLoaderDownsamplesLargeImages() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 400))
        let data = renderer.pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 800, height: 400))
        }

        let image = try XCTUnwrap(
            FeedThumbnailLoader.downsample(data: data, maxPixelSize: 144)
        )

        XCTAssertLessThanOrEqual(max(image.size.width, image.size.height), 144)
    }

    func testFeedThumbnailLoaderCoalescesConcurrentRequests() async throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/thumb.png"))
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80))
        let data = renderer.pngData { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let loader = FeedThumbnailLoader(session: session)
        let lock = NSLock()
        var requestCount = 0
        MockURLProtocol.handler = { request in
            lock.lock()
            requestCount += 1
            lock.unlock()
            Thread.sleep(forTimeInterval: 0.1)
            return (
                data,
                try XCTUnwrap(HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "image/png"]
                ))
            )
        }
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        async let first = loader.image(for: url)
        async let second = loader.image(for: url)
        let images = await [first, second]

        XCTAssertEqual(images.compactMap { $0 }.count, 2)
        lock.lock()
        let count = requestCount
        lock.unlock()
        XCTAssertEqual(count, 1)
    }

    func testFeedThumbnailLoaderUsesMemoryCacheForSequentialRequests() async throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/cached-thumb.png"))
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80))
        let data = renderer.pngData { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let loader = FeedThumbnailLoader(session: session)
        let lock = NSLock()
        var requestCount = 0
        MockURLProtocol.handler = { request in
            lock.lock()
            requestCount += 1
            lock.unlock()
            return (
                data,
                try XCTUnwrap(HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "image/png"]
                ))
            )
        }
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        let first = await loader.image(for: url)
        let second = await loader.image(for: url)

        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        lock.lock()
        let count = requestCount
        lock.unlock()
        XCTAssertEqual(count, 1)
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
        XCTAssertFalse(PlatformRegistry.defaultSubscribedIDs.contains("twitter"))
        XCTAssertFalse(PlatformRegistry.defaultSubscribedIDs.contains("soompi"))
    }

    func testPlatformRegistryExcludesRemovedTogetterSource() {
        XCTAssertNil(PlatformRegistry.definition(for: "togetter"))
        XCTAssertFalse(PlatformRegistry.defaultSubscribedIDs.contains("togetter"))
        XCTAssertFalse(PlatformRegistry.strictKeywordPlatformIDs.contains("togetter"))
        XCTAssertFalse(PlatformRegistry.googleNewsSources.contains { $0.id == "togetter" })
        XCTAssertEqual(PlatformRegistry.normalizeIDs(["togetter", "news", "youtube"]), ["news", "youtube"])
    }

    func testPlatformRegistryNormalizesLegacyRawPlatformIDs() {
        XCTAssertEqual(PlatformRegistry.normalizeID(" x "), "twitter")
        XCTAssertEqual(PlatformRegistry.normalizeID("news:mdpr"), "mdpr")
        XCTAssertEqual(PlatformRegistry.normalizeID("news:yahoo_ent"), "yahoonews")
        XCTAssertEqual(PlatformRegistry.normalizeID("news:unknown"), "news")
        XCTAssertEqual(PlatformRegistry.definition(for: "x")?.id, "twitter")
        XCTAssertEqual(PlatformRegistry.normalizeIDs(["x", "twitter", "news:mdpr", "unknown"]), ["twitter", "mdpr"])
    }

    func testDedicatedSearchLinksUseDedicatedPlatformIDs() {
        let registeredIDs = Set(PlatformRegistry.all.map(\.id))
        let mismatches = staticSearchLinks.compactMap { link -> String? in
            guard registeredIDs.contains(link.id), link.platform != link.id else { return nil }
            return "\(link.id)->\(link.platform)"
        }

        XCTAssertEqual(mismatches, [])
    }

    func testCustomSearchLinkFeedItemCarriesCustomSource() {
        let link = SearchLink(
            id: "custom:https%3A%2F%2Fexample.com%2Ffeed.xml",
            group: "Custom",
            label: "Example Feed",
            domain: "example.com",
            platform: "custom",
            makeUrl: { _ in "https://example.com/feed.xml" }
        )

        let item = link.feedItem(keyword: "  ignored  ", now: "2026-06-02T12:00:00Z")

        XCTAssertEqual(item.id, link.id)
        XCTAssertEqual(item.url, "https://example.com/feed.xml")
        XCTAssertEqual(item.title, "Example Feed")
        XCTAssertEqual(item.watch_term_keyword, "")
        XCTAssertEqual(item.source, "custom_url")
    }

    func testOrdinarySearchLinkFeedItemDoesNotCarryCustomSource() {
        let link = SearchLink(
            id: "google-news",
            group: "News",
            label: "Google News Japan",
            domain: "news.google.com",
            platform: "news",
            makeUrl: { "https://news.google.com/search?q=\($0.replacingOccurrences(of: " ", with: "+"))" }
        )

        let item = link.feedItem(keyword: "  Aiko  ", now: "2026-06-02T12:00:00Z")

        XCTAssertEqual(item.id, "search:google-news:Aiko")
        XCTAssertEqual(item.title, "Google News Japan: Aiko")
        XCTAssertEqual(item.watch_term_keyword, "Aiko")
        XCTAssertNil(item.source)
    }

    func testSavedSubscribedPlatformsDoNotReAddMissingDefaultsOnLoad() {
        XCTAssertEqual(
            LocalDB.subscribedPlatformsForLoadedValue(["news", " youtube ", "unknown", "news", "x", "news:mdpr", "NEWS:YAHOO_ENT"], hasSavedFile: true),
            ["news", "youtube", "twitter", "mdpr", "yahoonews"]
        )
        XCTAssertEqual(
            LocalDB.subscribedPlatformsForLoadedValue(["news"], hasSavedFile: false),
            PlatformRegistry.defaultSubscribedIDs
        )
    }

    @MainActor
    func testSetSourcesOrderNormalizesAliasesAndDropsUnknownIDs() {
        db.setSourcesOrder(order: ["custom", "unknown", " news:mdpr ", "x", "custom", "NEWS:YAHOO_ENT"])

        XCTAssertEqual(db.sourcesOrder, ["custom", "mdpr", "twitter", "yahoonews"])
    }

    func testLoadedSourcesOrderNormalizesAliasesAndPreservesMissingValue() {
        XCTAssertEqual(
            LocalDB.normalizedSourcesOrder(["unknown", " news:mdpr ", "x", "custom", "custom"]),
            ["mdpr", "twitter", "custom"]
        )
        XCTAssertNil(LocalDB.normalizedSourcesOrder(nil))
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
        <pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate>
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
        <pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate>
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
        XCTAssertEqual(firstURL, "https://barks.jp/feed/")
        XCTAssertEqual(report.items.first?.platform, "barks")
        XCTAssertEqual(report.items.first?.url, originalURL)
    }

    func testDedicatedRSSSortsByPublishedDateBeforeApplyingSourceCap() async {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "E, dd MMM yyyy HH:mm:ss Z"
        let baseDate = Date(timeIntervalSince1970: 1_785_000_000)
        let itemXML = (0..<27).map { index in
            let date = formatter.string(from: baseDate.addingTimeInterval(TimeInterval(index * 60)))
            return """
            <item>
            <title>Cap Oshi item \(index)</title>
            <link>https://barks.jp/articles/\(index)</link>
            <pubDate>\(date)</pubDate>
            </item>
            """
        }.joined()
        let rss = Data("<rss version=\"2.0\"><channel>\(itemXML)</channel></rss>".utf8)
        let service = IngestionService(
            requestExecutor: { request in
                return (rss, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Cap Oshi"),
            platforms: ["barks"]
        )

        XCTAssertEqual(report.items.count, 25)
        XCTAssertEqual(report.items.first?.url, "https://barks.jp/articles/26")
        XCTAssertFalse(report.items.contains { $0.url == "https://barks.jp/articles/0" })
    }

    func testIngestionReportItemsAreSortedNewestFirstAcrossSources() async {
        let olderRSS = Data("""
        <rss version="2.0"><channel><item>
        <title>Natalie Sort Oshi older</title>
        <link>https://natalie.mu/music/news/older</link>
        <pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate>
        </item></channel></rss>
        """.utf8)
        let newerRSS = Data("""
        <rss version="2.0"><channel><item>
        <title>BARKS Sort Oshi newer</title>
        <link>https://barks.jp/news/newer</link>
        <pubDate>Sun, 02 Aug 2026 09:00:00 GMT</pubDate>
        </item></channel></rss>
        """.utf8)
        let service = IngestionService(
            requestExecutor: { request in
                let data = request.url?.host == "barks.jp" ? newerRSS : olderRSS
                return (data, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Sort Oshi"),
            platforms: ["natalie", "barks"]
        )

        XCTAssertEqual(report.items.map(\.url), [
            "https://barks.jp/news/newer",
            "https://natalie.mu/music/news/older"
        ])
    }

    func testYouTubeSearchRequestsUploadDateOrderingAndDropsOldResults() async throws {
        let response = Data("""
        {
          "contents": {
            "sectionListRenderer": {
              "contents": [
                {
                  "videoRenderer": {
                    "videoId": "oldoldold01",
                    "title": { "runs": [{ "text": "Fresh Oshi old result" }] },
                    "publishedTimeText": { "simpleText": "2 years ago" }
                  }
                },
                {
                  "videoRenderer": {
                    "videoId": "freshfresh1",
                    "title": { "runs": [{ "text": "Fresh Oshi new result" }] },
                    "publishedTimeText": { "simpleText": "2 days ago" }
                  }
                }
              ]
            }
          }
        }
        """.utf8)
        let capture = RequestCapture()
        let service = IngestionService(
            requestExecutor: { request in
                await capture.record(request.url?.absoluteString ?? "")
                let body = try XCTUnwrap(request.httpBody)
                let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertEqual(payload["params"] as? String, "CAI%3D")
                return (response, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Fresh Oshi"),
            platforms: ["youtube"]
        )

        let firstURL = await capture.firstURL()
        XCTAssertEqual(firstURL, "https://www.youtube.com/youtubei/v1/search?prettyPrint=false")
        XCTAssertEqual(report.items.map(\.id), ["youtube:freshfresh1"])
    }

    func testYouTubeScrapeAcceptsPublishedTimeRunsText() async throws {
        let html = Data("""
        <html><script>
        var ytInitialData = {
          "contents": {
            "twoColumnSearchResultsRenderer": {
              "primaryContents": {
                "sectionListRenderer": {
                  "contents": [
                    {
                      "itemSectionRenderer": {
                        "contents": [
                          {
                            "videoRenderer": {
                              "videoId": "runsdate001",
                              "title": { "runs": [{ "text": "Runs Date Oshi result" }] },
                              "publishedTimeText": { "runs": [{ "text": "2 days ago" }] }
                            }
                          }
                        ]
                      }
                    }
                  ]
                }
              }
            }
          }
        };
        </script></html>
        """.utf8)
        let service = IngestionService(
            requestExecutor: { request in
                let data = request.httpMethod == "POST" ? Data("{}".utf8) : html
                return (data, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Runs Date Oshi"),
            platforms: ["youtube"]
        )

        XCTAssertEqual(report.items.map(\.id), ["youtube:runsdate001"])
    }

    func testYouTubeStructuredRenderersSkipMissingPublishedTime() async throws {
        let response = Data("""
        {
          "contents": {
            "sectionListRenderer": {
              "contents": [
                {
                  "videoRenderer": {
                    "videoId": "nodatenodt1",
                    "title": { "runs": [{ "text": "No Date Oshi structured result" }] }
                  }
                },
                {
                  "videoWithContextRenderer": {
                    "videoId": "nodatenodt2",
                    "headline": { "runs": [{ "text": "No Date Oshi mobile result" }] }
                  }
                },
                {
                  "shortsLockupViewModel": {
                    "entityId": "shorts-shelf-nodateshrt1",
                    "overlayMetadata": { "primaryText": { "content": "No Date Oshi shorts result" } },
                    "belowThumbnailMetadata": {
                      "primaryText": { "content": "Shorts channel" },
                      "secondaryText": { "content": "No publish label" }
                    },
                    "onTap": {
                      "innertubeCommand": {
                        "reelWatchEndpoint": { "videoId": "nodateshrt1" }
                      }
                    }
                  }
                }
              ]
            }
          }
        }
        """.utf8)
        let service = IngestionService(
            requestExecutor: { request in
                return (response, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "No Date Oshi"),
            platforms: ["youtube"]
        )

        XCTAssertTrue(report.items.isEmpty)
    }

    func testYouTubeVideoRendererCapAppliesAfterFreshnessFiltering() async throws {
        let staleRenderers = (0..<25).map { index in
            """
            {
              "videoRenderer": {
                "videoId": "oldold\(String(format: "%05d", index))",
                "title": { "runs": [{ "text": "Cap Oshi stale \(index)" }] },
                "publishedTimeText": { "simpleText": "2 years ago" }
              }
            }
            """
        }.joined(separator: ",")
        let response = Data("""
        {
          "contents": {
            "sectionListRenderer": {
              "contents": [
                \(staleRenderers),
                {
                  "videoRenderer": {
                    "videoId": "freshcap001",
                    "title": { "runs": [{ "text": "Cap Oshi fresh result" }] },
                    "publishedTimeText": { "simpleText": "2 days ago" }
                  }
                }
              ]
            }
          }
        }
        """.utf8)
        let capture = RequestCapture()
        let service = IngestionService(
            requestExecutor: { request in
                await capture.record(request.url?.absoluteString ?? "")
                let data = request.url?.host == "www.youtube.com" && request.httpMethod == "POST"
                    ? response
                    : Data(#"<html></html>"#.utf8)
                return (data, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Cap Oshi"),
            platforms: ["youtube"]
        )

        XCTAssertEqual(report.items.map(\.id), ["youtube:freshcap001"])
        let requestCount = await capture.count()
        XCTAssertEqual(requestCount, 1)
    }

    func testYouTubeScrapeRequestsUploadDateOrderingAndSkipsUndatedEscapedFallbackIDs() async throws {
        let capture = RequestCapture()
        let service = IngestionService(
            requestExecutor: { request in
                let url = request.url?.absoluteString ?? ""
                await capture.record(url)
                let data = url.contains("/youtubei/") ? Data("{}".utf8) : Data(#""videoId":"stalevideo1""#.utf8)
                return (data, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Fallback Oshi"),
            platforms: ["youtube"]
        )

        let urls = await capture.urls
        XCTAssertTrue(urls.contains("https://www.youtube.com/youtubei/v1/search?prettyPrint=false"))
        XCTAssertTrue(urls.contains { $0.hasPrefix("https://www.youtube.com/results?") && $0.contains("sp=CAI%253D") })
        XCTAssertTrue(report.items.isEmpty)
    }

    func testYouTubeEscapedFallbackAllowsLaterDatedDuplicateID() async throws {
        let capture = RequestCapture()
        let service = IngestionService(
            requestExecutor: { request in
                let url = request.url?.absoluteString ?? ""
                await capture.record(url)
                let data = url.contains("/youtubei/")
                    ? Data("{}".utf8)
                    : Data(#"""
                    "videoId":"freshdupe01"
                    "videoRenderer":{"videoId":"freshdupe01","publishedTimeText":{"simpleText":"2 days ago"}}
                    """#.utf8)
                return (data, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Fallback Oshi"),
            platforms: ["youtube"]
        )

        XCTAssertEqual(report.items.map(\.id), ["youtube:freshdupe01"])
    }

    func testYouTubeEscapedFallbackDoesNotBorrowNeighboringVideosDate() async throws {
        // Shorts never carry their own publishedTimeText in scrape HTML. Regression
        // coverage for a bug where an undated video preceding a dated one picked up
        // the *next* video's date instead of being dropped as undated.
        let capture = RequestCapture()
        let service = IngestionService(
            requestExecutor: { request in
                let url = request.url?.absoluteString ?? ""
                await capture.record(url)
                let data = url.contains("/youtubei/")
                    ? Data("{}".utf8)
                    : Data(#"""
                    "videoId":"undated001"
                    "videoRenderer":{"videoId":"freshvid002","publishedTimeText":{"simpleText":"2 days ago"}}
                    """#.utf8)
                return (data, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Fallback Oshi"),
            platforms: ["youtube"]
        )

        XCTAssertEqual(report.items.map(\.id), ["youtube:freshvid002"])
    }

    func testDedicatedRSSFallsBackToGoogleNewsWhenPublisherFeedIsBlocked() async {
        let googleNewsRSS = Data("""
        <rss version="2.0"><channel><item>
        <title>Blocked Oshi live item - Google</title>
        <link>https://example.com/articles/blocked-oshi</link>
        <pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate>
        </item></channel></rss>
        """.utf8)
        let capture = RequestCapture()
        let service = IngestionService(
            requestExecutor: { request in
                let url = request.url?.absoluteString ?? ""
                await capture.record(url)
                if url.contains("news.google.com") {
                    return (googleNewsRSS, try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                    )))
                }
                return (Data(), try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 405, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Blocked Oshi"),
            platforms: ["natalie"]
        )

        let urls = await capture.urls
        XCTAssertTrue(urls.contains { $0.contains("natalie.mu/music/feed/news") })
        XCTAssertTrue(urls.contains { $0.contains("news.google.com") && $0.contains("site:natalie.mu") })
        XCTAssertEqual(report.sourceStatuses.first?.outcome, .received)
        XCTAssertEqual(report.items.first?.platform, "natalie")
        XCTAssertEqual(report.items.first?.source, "google_news")
    }

    func testDedicatedRSSFallsBackWhenOnePublisherFeedIsBlockedAndOthersAreEmpty() async {
        let emptyRSS = Data("<rss version=\"2.0\"><channel></channel></rss>".utf8)
        let googleNewsRSS = Data("""
        <rss version="2.0"><channel><item>
        <title>Music Oshi partial fallback - Google</title>
        <link>https://example.com/articles/music-oshi</link>
        <pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate>
        </item></channel></rss>
        """.utf8)
        let capture = RequestCapture()
        let service = IngestionService(
            requestExecutor: { request in
                let url = request.url?.absoluteString ?? ""
                await capture.record(url)
                if url.contains("natalie.mu/music/feed/news") {
                    return (Data(), try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: 405, httpVersion: nil, headerFields: nil
                    )))
                }
                if url.contains("news.google.com") {
                    return (googleNewsRSS, try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                    )))
                }
                return (emptyRSS, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Music Oshi"),
            platforms: ["natalie"]
        )

        let urls = await capture.urls
        XCTAssertTrue(urls.contains { $0.contains("natalie.mu/music/feed/news") })
        XCTAssertTrue(urls.contains { $0.contains("natalie.mu/tv/feed/news") })
        XCTAssertTrue(urls.contains { $0.contains("news.google.com") && $0.contains("site:natalie.mu") })
        XCTAssertEqual(report.sourceStatuses.first?.outcome, .received)
        XCTAssertEqual(report.items.first?.source, "google_news")
    }

    func testKpopOfficialDedicatedRSSProducesKpopOfficialItems() async {
        let rss = Data("""
        <rss version="2.0"><channel><item>
        <title>BLACKPINK comeback schedule</title>
        <link>https://kpopofficial.com/blackpink-comeback</link>
        <description>BLACKPINK concert and album details</description>
        <pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate>
        </item></channel></rss>
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
            term: WatchTerm(keyword: "BLACKPINK"),
            platforms: ["kpopofficial"]
        )

        let urls = await capture.urls
        XCTAssertEqual(urls, ["https://kpopofficial.com/feed/"])
        XCTAssertEqual(report.sourceStatuses.first?.outcome, .received)
        XCTAssertEqual(report.items.first?.platform, "kpopofficial")
        XCTAssertEqual(report.items.first?.source, "dedicated_rss")
    }

    func testAtomUpdatedDateWinsOverPublishedDateForDedicatedRSS() async {
        let atom = Data("""
        <feed xmlns="http://www.w3.org/2005/Atom"><entry>
          <title>BLACKPINK updated schedule</title>
          <link rel="alternate" href="https://kpopofficial.com/blackpink-updated"/>
          <summary>BLACKPINK schedule details</summary>
          <published>2026-08-01T08:00:00Z</published>
          <updated>2026-08-02T09:30:00Z</updated>
        </entry></feed>
        """.utf8)
        let service = IngestionService(
            requestExecutor: { request in
                return (atom, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "BLACKPINK"),
            platforms: ["kpopofficial"]
        )

        XCTAssertEqual(report.items.first?.published_at, "2026-08-02T09:30:00Z")
        XCTAssertEqual(report.sourceStatuses.first?.outcome, .received)
    }

    func testAtomFractionalUpdatedDateWithColonOffsetIsAccepted() async {
        let atom = Data("""
        <feed xmlns="http://www.w3.org/2005/Atom"><entry>
          <title>BLACKPINK fractional offset schedule</title>
          <link rel="alternate" href="https://kpopofficial.com/blackpink-fractional-offset"/>
          <summary>BLACKPINK schedule details</summary>
          <updated>2026-08-02T09:30:00.123+09:00</updated>
        </entry></feed>
        """.utf8)
        let service = IngestionService(
            requestExecutor: { request in
                return (atom, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "BLACKPINK"),
            platforms: ["kpopofficial"]
        )

        XCTAssertEqual(report.items.first?.published_at, "2026-08-02T00:30:00Z")
        XCTAssertEqual(report.sourceStatuses.first?.outcome, .received)
    }

    func testAtomParserDoesNotLeakTextAfterClosedDateElement() async {
        let atom = Data("""
        <feed xmlns="http://www.w3.org/2005/Atom">
          <entry>
            <title>BLACKPINK parser spacing</title>
            <link rel="alternate" href="https://kpopofficial.com/parser-spacing"/>
            <summary>BLACKPINK parser spacing details</summary>
            <updated>2026-08-02T09:30:00Z</updated>
            ignored text after date close
            <category term="ignored"/>
          </entry>
        </feed>
        """.utf8)
        let service = IngestionService(
            requestExecutor: { request in
                return (atom, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "BLACKPINK"),
            platforms: ["kpopofficial"]
        )

        XCTAssertEqual(report.items.first?.title, "BLACKPINK parser spacing")
        XCTAssertEqual(report.items.first?.url, "https://kpopofficial.com/parser-spacing")
        XCTAssertEqual(report.items.first?.published_at, "2026-08-02T09:30:00Z")
    }

    func testJapaneseDedicatedRSSSourcesUsePublisherFeedsAndPreserveSourceIDs() async {
        let rss = Data("""
        <rss version="2.0"><channel>
          <item><title>Alias Oshi publisher update</title><link>https://publisher.example/article-1?utm_source=rss</link><description>Publisher detail</description><pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate></item>
          <item><title>Alias Oshi duplicate</title><link>https://publisher.example/article-1?utm_medium=email</link><pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate></item>
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
        XCTAssertEqual(urls.count, 6)
        XCTAssertTrue(urls.contains("https://dot.asahi.com/list/feed/rss4provider-all"))
        XCTAssertTrue(urls.contains("https://hochi.news/rss/index.xml"))
        XCTAssertTrue(urls.contains("https://realsound.jp/atom.xml"))
        XCTAssertFalse(urls.contains { $0.contains("news.google.com") })
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

    func testGoogleNewsTitlesStripSearchAndYahooSuffixes() async throws {
        let rss = Data("""
        <rss version="2.0"><channel>
        <item><title>Suffix Oshi appears - Google</title><link>https://example.com/google</link><pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate></item>
        <item><title>Suffix Oshi appears | Bing</title><link>https://example.com/bing</link><pubDate>Sun, 02 Aug 2026 08:01:00 GMT</pubDate></item>
        <item><title>Suffix Oshi appears (エンタメニュース) - Yahoo!ニュース</title><link>https://example.com/yahoo</link><pubDate>Sun, 02 Aug 2026 08:02:00 GMT</pubDate></item>
        </channel></rss>
        """.utf8)
        let service = IngestionService(requestExecutor: { request in
            (
                rss,
                try XCTUnwrap(HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                ))
            )
        })

        let report = await service.ingestReport(term: WatchTerm(keyword: "Suffix Oshi"), platforms: ["news"])

        XCTAssertEqual(Set(report.items.map(\.title)), Set(["Suffix Oshi appears"]))
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
        let rss = Data("<rss version=\"2.0\"><channel><item><title>Hochi Oshi update</title><link>https://hochi.news/articles/1</link><pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate></item></channel></rss>".utf8)
        let capture = RequestCapture()
        let service = IngestionService(
            requestExecutor: { request in
                await capture.record(request.url?.absoluteString ?? "")
                if request.url?.host == "dot.asahi.com" {
                    return (Data(), try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil
                    )))
                }
                if request.url?.host == "news.google.com" {
                    return (Data("<rss version=\"2.0\"><channel></channel></rss>".utf8), try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
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

        let urls = await capture.urls
        XCTAssertTrue(urls.contains { $0.contains("news.google.com") && $0.contains("site:dot.asahi.com") })
        XCTAssertEqual(report.sourceStatuses.first { $0.id == "aera" }?.outcome, .failed(.rateLimited))
        XCTAssertEqual(report.sourceStatuses.first { $0.id == "hochi" }?.outcome, .received)
        XCTAssertEqual(report.items.first?.platform, "hochi")
    }

    func testDedicatedRSSPublisherFailureIsNotOverwrittenByFallbackFailure() async {
        let service = IngestionService(
            requestExecutor: { request in
                if request.url?.host == "dot.asahi.com" {
                    return (Data(), try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil
                    )))
                }
                return (Data("<rss><channel>".utf8), try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Oshi"),
            platforms: ["aera"]
        )

        XCTAssertEqual(report.sourceStatuses.first?.outcome, .failed(.rateLimited))
    }

    func testCinemaCafeAndBillboardDedicatedRSSSourcesPreserveIDsAndDeduplicate() async {
        let cinemaURL = "https://www.cinemacafe.net/article/1.html?utm_source=rss"
        let billboardURL = "https://www.billboard-japan.com/d_news/detail/1?utm_medium=email"
        let cinemaRSS = Data("""
        <rss version="2.0"><channel>
          <item><title>Alias Oshi CinemaCafe update</title><link>\(cinemaURL)</link><description>Film detail</description><pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate></item>
          <item><title>Alias Oshi duplicate</title><link>https://www.cinemacafe.net/article/1.html?utm_medium=email</link><pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate></item>
        </channel></rss>
        """.utf8)
        let billboardRSS = Data("""
        <rss version="2.0"><channel>
          <item><title>Alias Oshi Billboard update</title><link>\(billboardURL)</link><description>Music detail</description><pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate></item>
          <item><title>Alias Oshi duplicate</title><link>https://www.billboard-japan.com/d_news/detail/1?utm_source=rss</link><pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate></item>
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
        let billboardRSS = Data("<rss version=\"2.0\"><channel><item><title>Oshi Billboard update</title><link>https://www.billboard-japan.com/d_news/detail/2</link><pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate></item></channel></rss>".utf8)
        let service = IngestionService(
            requestExecutor: { request in
                if request.url?.host == "www.cinemacafe.net" {
                    return (Data(), try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil
                    )))
                }
                if request.url?.host == "news.google.com" {
                    return (Data("<rss version=\"2.0\"><channel></channel></rss>".utf8), try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
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
        <pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate>
        </item><item>
        <title>Unrelated headline</title>
        <link>https://natalie.mu/music/news/unrelated</link>
        <pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate>
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

    func testDedicatedRSSRejectsDescriptionOnlyMatches() async {
        let rss = """
        <rss version="2.0"><channel><item>
        <title>Unrelated headline</title>
        <link>https://natalie.mu/music/news/summary-only</link>
        <description>Alias Oshi appears only in the summary.</description>
        <pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate>
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

        XCTAssertTrue(report.items.isEmpty)
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
        let noResultsRequestCount = await capture.count()
        XCTAssertEqual(noResultsRequestCount, 1)

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
          <item><title>Alias Oshi diary</title><link>\(originalURL)</link><description>daily update</description><pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate></item>
          <item><title>Alias Oshi duplicate</title><link>https://ameblo.jp/first/entry-1?utm_medium=email</link><pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate></item>
          <item><title>Unrelated</title><link>https://ameblo.jp/first/entry-2</link><pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate></item>
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

    func testAmebloDedicatedRSSSortsByPublishedDateBeforeApplyingCap() async {
        let originalBlogs = db.amebloBlogs
        defer { db.amebloBlogs = originalBlogs }
        db.amebloBlogs = [
            AmebloBlog(url: "https://ameblo.jp/older-blog", addedAt: "2026-01-01T00:00:00Z")!,
            AmebloBlog(url: "https://ameblo.jp/newer-blog", addedAt: "2026-01-01T00:00:00Z")!
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "E, dd MMM yyyy HH:mm:ss Z"
        let olderBase = Date(timeIntervalSince1970: 1_785_000_000)
        let olderItems = (0..<27).map { index in
            let date = formatter.string(from: olderBase.addingTimeInterval(TimeInterval(index * 60)))
            return """
            <item>
            <title>Ameblo Cap Oshi older \(index)</title>
            <link>https://ameblo.jp/older-blog/entry-\(index)</link>
            <pubDate>\(date)</pubDate>
            </item>
            """
        }.joined()
        let olderRSS = Data("<rss version=\"2.0\"><channel>\(olderItems)</channel></rss>".utf8)
        let newerRSS = Data("""
        <rss version="2.0"><channel><item>
        <title>Ameblo Cap Oshi newest</title>
        <link>https://ameblo.jp/newer-blog/entry-newest</link>
        <pubDate>Sun, 02 Aug 2026 09:00:00 GMT</pubDate>
        </item></channel></rss>
        """.utf8)
        let service = IngestionService(
            requestExecutor: { request in
                let path = request.url?.path ?? ""
                let data = path.contains("newer-blog") ? newerRSS : olderRSS
                return (data, try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )))
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Ameblo Cap Oshi"),
            platforms: ["ameblo"]
        )

        XCTAssertEqual(report.items.count, 25)
        XCTAssertEqual(report.items.first?.url, "https://ameblo.jp/newer-blog/entry-newest")
        XCTAssertFalse(report.items.contains { $0.url == "https://ameblo.jp/older-blog/entry-0" })
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
        let rss = Data("<rss version=\"2.0\"><channel><item><title>Oshi update</title><link>https://ameblo.jp/succeeding/entry-1</link><pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate></item></channel></rss>".utf8)
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
        let service = IngestionService(requestExecutor: { request in
            (
                Data("<rss version=\"2.0\"><channel></channel></rss>".utf8),
                try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                ))
            )
        }, retrySleeper: { _ in })
        let report = await service.ingestReport(
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
        let rss = Data("<rss version=\"2.0\"><channel><item><title>Retry Oshi</title><link>https://example.com/retry</link><pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate></item></channel></rss>".utf8)
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
        let successRSS = Data("<rss version=\"2.0\"><channel><item><title>Server Oshi</title><link>https://example.com/server</link><pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate></item></channel></rss>".utf8)
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
        let limitedURLs = await limitedCapture.urls
        XCTAssertEqual(limitedRequestCount, 4)
        XCTAssertEqual(limitedURLs.filter { $0 == "https://barks.jp/feed/" }.count, 2)
        XCTAssertEqual(limitedURLs.filter { $0.contains("news.google.com") }.count, 2)
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
        let malformedURLs = await malformedCapture.urls
        XCTAssertEqual(malformedRequestCount, 2)
        XCTAssertEqual(malformedURLs.filter { $0 == "https://barks.jp/feed/" }.count, 1)
        XCTAssertEqual(malformedURLs.filter { $0.contains("news.google.com") }.count, 1)
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
        <pubDate>Sun, 02 Aug 2026 08:00:00 GMT</pubDate>
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

    func testKeychainSaveReportsSuccessfulWrite() {
        let existing = KeychainHelper.read(.twitterBearerToken)
        defer { KeychainHelper.save(.twitterBearerToken, existing) }

        XCTAssertTrue(KeychainHelper.save(.twitterBearerToken, "test-token-\(UUID().uuidString)"))
        XCTAssertNotNil(KeychainHelper.read(.twitterBearerToken))
    }

    func testKeychainSaveReplacesExistingValue() {
        let existing = KeychainHelper.read(.twitterBearerToken)
        defer { KeychainHelper.save(.twitterBearerToken, existing) }

        XCTAssertTrue(KeychainHelper.save(.twitterBearerToken, "first-token"))
        XCTAssertEqual(KeychainHelper.read(.twitterBearerToken), "first-token")
        XCTAssertTrue(KeychainHelper.save(.twitterBearerToken, "second-token"))
        XCTAssertEqual(KeychainHelper.read(.twitterBearerToken), "second-token")
    }

    func testWatchTermDecodesLegacyBackupWithoutSourceSelection() throws {
        let legacy = #"{"id":"legacy","keyword":"Legacy Oshi","collection_mode":"all_info","is_active":true,"notify_on_new":false,"aliases":[],"created_at":"2026-01-01T00:00:00Z"}"#.data(using: .utf8)!
        let term = try JSONDecoder().decode(WatchTerm.self, from: legacy)

        XCTAssertEqual(term.source_mode, .all)
        XCTAssertEqual(term.selected_platforms, [])
    }

    func testSavedPageDecodesLegacyBookmarkWithoutSource() throws {
        let legacy = #"{"id":"legacy","url":"https://example.com/saved","title":"Saved","platform":"news","saved_at":"2026-01-01T00:00:00Z"}"#.data(using: .utf8)!
        let page = try JSONDecoder().decode(SavedPage.self, from: legacy)

        XCTAssertNil(page.source)
        XCTAssertNil(page.toFeedItem().source)
    }

    func testWatchTermDecodesMissingAndUnknownCollectionModeAsAllInfo() throws {
        let missing = #"{"id":"missing-mode","keyword":"Legacy Oshi","is_active":true,"aliases":[],"created_at":"2026-01-01T00:00:00Z"}"#.data(using: .utf8)!
        let unknown = #"{"id":"unknown-mode","keyword":"Legacy Oshi","collection_mode":"everything","is_active":true,"aliases":[],"created_at":"2026-01-01T00:00:00Z"}"#.data(using: .utf8)!

        XCTAssertEqual(try JSONDecoder().decode(WatchTerm.self, from: missing).collection_mode, WatchTerm.allInfoCollectionMode)
        XCTAssertEqual(try JSONDecoder().decode(WatchTerm.self, from: unknown).collection_mode, WatchTerm.allInfoCollectionMode)
        XCTAssertEqual(WatchTerm(keyword: "Video Oshi", collection_mode: "media_only").collection_mode, WatchTerm.mediaOnlyCollectionMode)
        XCTAssertEqual(WatchTerm(keyword: "Unknown Oshi", collection_mode: "bad").collection_mode, WatchTerm.allInfoCollectionMode)
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

    func testISO8601DateParsingCacheHandlesConcurrentCalls() {
        let values = [
            "2024-06-15T10:30:00.123456Z",
            "2024-06-15T10:30:00Z",
            "2024-06-15T19:30:00+09:00",
            "2024-06-15T10:30:00",
            "not-a-date",
            ""
        ]
        let lock = NSLock()
        var mismatches: [String] = []

        DispatchQueue.concurrentPerform(iterations: 500) { index in
            let value = values[index % values.count]
            let date = parseISO8601Date(value)
            let shouldBeNil = value.isEmpty || value == "not-a-date"
            if shouldBeNil != (date == nil) {
                lock.lock()
                mismatches.append(value)
                lock.unlock()
            }
        }

        XCTAssertTrue(mismatches.isEmpty, "Unexpected parse results for \(mismatches)")
    }

    func testCleanDisplayTextHTMLEntities() {
        XCTAssertEqual(cleanDisplayText("Fish &amp; Chips"), "Fish & Chips")
        XCTAssertEqual(cleanDisplayText("He said &quot;hello&quot;"), "He said \"hello\"")
        XCTAssertEqual(cleanDisplayText("It&#39;s &apos;OK&apos;"), "It's 'OK'")
        XCTAssertEqual(cleanDisplayText("a&nbsp;b"), "a b")
        XCTAssertEqual(cleanDisplayText("x &lt; y &gt; z"), "x < y > z")
    }

    func testCleanDisplayTextStripsHTMLTagsBeforeDecodingEntities() {
        XCTAssertEqual(cleanDisplayText("<p>Hello <b>World</b></p>"), "Hello World")
        XCTAssertEqual(cleanDisplayText("Escaped &lt;b&gt;not a tag&lt;/b&gt;"), "Escaped <b>not a tag</b>")
    }

    func testCleanDisplayTextCollapsesWhitespaceAndEmptyResults() {
        XCTAssertEqual(cleanDisplayText("too   many   spaces"), "too many spaces")
        XCTAssertNil(cleanDisplayText("   "))
        XCTAssertNil(cleanDisplayText("<br/>"))
        XCTAssertNil(cleanDisplayText(nil))
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
        XCTAssertEqual(
            IngestionService.effectivePlatforms(for: term, available: [" x ", "news:yahoo_ent", "youtube", "unknown"]),
            ["youtube"]
        )
        XCTAssertEqual(
            IngestionService.effectivePlatforms(
                for: WatchTerm(keyword: "All Source Oshi"),
                available: [" x ", "news:yahoo_ent", "unknown"]
            ),
            ["twitter", "yahoonews"]
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

    @MainActor
    func testRemovedSourceIsDroppedFromSavedSourcePreferences() throws {
        XCTAssertEqual(
            LocalDB.subscribedPlatformsForLoadedValue(["togetter", "news", "youtube"], hasSavedFile: true),
            ["news", "youtube"]
        )
        XCTAssertEqual(
            LocalDB.normalizedSourcesOrder(["custom", "togetter", "news", "youtube"]),
            ["custom", "news", "youtube"]
        )

        let term = db.saveTerm(
            keyword: "Removed Source Oshi",
            sourceMode: .selected,
            selectedPlatforms: ["togetter", "news"]
        )

        let saved = try XCTUnwrap(db.terms.first { $0.id == term.id })
        XCTAssertEqual(saved.source_mode, .selected)
        XCTAssertEqual(saved.selected_platforms, ["news"])

        db.updateTerm(id: term.id, sourceMode: .selected, selectedPlatforms: ["togetter"])
        let noLongerValid = try XCTUnwrap(db.terms.first { $0.id == term.id })
        XCTAssertEqual(noLongerValid.source_mode, .all)
        XCTAssertEqual(noLongerValid.selected_platforms, [])
    }

    func testLocalRefreshRequestNormalizesPlatformIDs() {
        XCTAssertEqual(
            LocalRefreshRequest.platform(" news:yahoo_ent ").platforms(subscribedPlatforms: ["youtube"]),
            ["yahoonews"]
        )
        XCTAssertEqual(
            LocalRefreshRequest.platform("unknown").platforms(subscribedPlatforms: ["youtube"]),
            []
        )
        XCTAssertEqual(
            LocalRefreshRequest.platform("custom").platforms(subscribedPlatforms: ["youtube", "custom"]),
            []
        )
        XCTAssertEqual(
            LocalRefreshRequest.foreground.platforms(subscribedPlatforms: ["custom", "x", "news:mdpr", "unknown", "youtube"]),
            ["twitter", "mdpr", "youtube"]
        )
        XCTAssertFalse(LocalRefreshRequest.platform("youtube").refreshesCustomURLs())
        XCTAssertTrue(LocalRefreshRequest.platform(" CUSTOM ").refreshesCustomURLs())
        XCTAssertTrue(LocalRefreshRequest.foreground.refreshesCustomURLs())
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

    func testRefreshResultKeepsSourceFailurePartialNotFailed() {
        let result = LocalRefreshResult(
            completion: .completed,
            addedCount: 0,
            sourceStatuses: [
                SourceRefreshStatus(id: "twitter", outcome: .failed(.missingCredential), itemCount: 0, queryCount: 1)
            ],
            customRefreshCompleted: true
        )

        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.hasSourceFailures)
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
        XCTAssertFalse(diagnostics.statusText.contains("0 sec"))
        XCTAssertTrue(diagnostics.statusText.contains("just now"))
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
    func testDeletingTermClearsHiddenItemsForThatKeywordOnly() throws {
        let deletedTerm = db.saveTerm(keyword: "Deleted Oshi")
        let keptTerm = db.saveTerm(keyword: "Kept Oshi")
        let separatorKeptTerm = db.saveTerm(keyword: "Prefix::Deleted Oshi")
        let nowString = ISO8601DateFormatter().string(from: Date())
        let deletedItem = FeedItem(
            id: "news:deleted-hidden",
            platform: "news",
            url: "https://example.com/deleted-hidden",
            title: "Deleted Oshi update",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "article",
            published_at: nowString,
            watch_term_keyword: deletedTerm.keyword,
            fetched_at: nowString
        )
        let keptItem = FeedItem(
            id: "news:kept-hidden",
            platform: "news",
            url: "https://example.com/kept-hidden",
            title: "Kept Oshi update",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "article",
            published_at: nowString,
            watch_term_keyword: keptTerm.keyword,
            fetched_at: nowString
        )
        let separatorKeptItem = FeedItem(
            id: "news:separator-kept-hidden",
            platform: "news",
            url: "https://example.com/separator-kept-hidden",
            title: "Prefix Deleted Oshi update",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "article",
            published_at: nowString,
            watch_term_keyword: separatorKeptTerm.keyword,
            fetched_at: nowString
        )
        db.feedItems = [deletedItem, keptItem, separatorKeptItem]

        db.deleteFeedItem(id: deletedItem.id, watchTermKeyword: deletedTerm.keyword)
        db.deleteFeedItem(id: keptItem.id, watchTermKeyword: keptTerm.keyword)
        db.deleteFeedItem(id: separatorKeptItem.id, watchTermKeyword: separatorKeptTerm.keyword)

        db.deleteTerm(id: deletedTerm.id)

        XCTAssertFalse(db.hiddenItems.contains("\(deletedItem.id)::\(deletedTerm.keyword)"))
        XCTAssertTrue(db.hiddenItems.contains("\(keptItem.id)::\(keptTerm.keyword)"))
        XCTAssertTrue(db.hiddenItems.contains("\(separatorKeptItem.id)::\(separatorKeptTerm.keyword)"))
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
                title: "Enabled first", content_text: nil, author: nil, thumbnail_url: nil,
                media_type: "video", published_at: oldString, watch_term_keyword: enabledTerm.keyword,
                fetched_at: oldString, source: "youtube_scrape"
            ),
            FeedItem(
                id: "note:enabled-2", platform: "note", url: "https://note.com/2",
                title: "Enabled second", content_text: nil, author: nil, thumbnail_url: nil,
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

        XCTAssertEqual(center.requests.count, 1)
        XCTAssertEqual(center.requests.first?.content.title, "New items for Enabled Oshi")
        XCTAssertEqual(center.requests.first?.content.body, "Enabled second\n+1 more")
        XCTAssertEqual(center.requests.first?.content.userInfo["source"] as? String, "note_rss")
        XCTAssertNil(center.requests.first?.trigger)
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
    
    // MARK: - Feature 4: Saved Bookmarks
    func testSavedBookmarks() throws {
        let item = FeedItem(
            id: "news:111", platform: "news", url: "https://url", title: "Bookmark test",
            content_text: nil, author: nil, thumbnail_url: nil, media_type: "article",
            published_at: "2026-06-02T12:00:00Z", watch_term_keyword: "", fetched_at: "",
            source: "google_news"
        )
        
        XCTAssertEqual(db.getSaved().count, 0)
        
        // Toggle saved (Add)
        let isSaved1 = db.toggleSaved(item: item)
        XCTAssertTrue(isSaved1)
        XCTAssertEqual(db.getSaved().count, 1)
        XCTAssertEqual(db.getSaved().first?.id, "news:111")
        XCTAssertEqual(db.getSaved().first?.source, "google_news")
        XCTAssertEqual(db.getSaved().first?.toFeedItem().source, "google_news")
        
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
            fetched_at: now,
            source: "google_news"
        )
        db.terms = [term]
        db.feedItems = [item]
        db.savedPages = [
            SavedPage(
                id: item.id,
                url: item.url,
                title: item.title,
                platform: item.platform,
                saved_at: now,
                source: item.source
            )
        ]
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
        XCTAssertEqual(db.savedPages.first?.source, "google_news")
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
        XCTAssertEqual(db.customUrls.map(\.id), ["custom:https://example.com/feed.xml"])
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
    func testBackupImportNormalizesCustomUrlsAndDropsInvalidEntries() throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let backup = LocalBackup(
            exportedAt: now,
            terms: [],
            feedItems: [
                FeedItem(
                    id: "legacy:bad-script",
                    platform: "custom",
                    url: "javascript://example.com/feed",
                    title: "Bad",
                    content_text: nil,
                    author: nil,
                    thumbnail_url: nil,
                    media_type: "article",
                    published_at: now,
                    watch_term_keyword: "",
                    fetched_at: now
                ),
                FeedItem(
                    id: "legacy:host-port",
                    platform: "custom",
                    url: "localhost:9090/feed",
                    title: "Local cached",
                    content_text: nil,
                    author: nil,
                    thumbnail_url: nil,
                    media_type: "article",
                    published_at: now,
                    watch_term_keyword: "",
                    fetched_at: now
                ),
                FeedItem(
                    id: "legacy:tracked-dup",
                    platform: "custom",
                    url: "https://example.com/feed?b=2&a=1",
                    title: "Duplicate cached",
                    content_text: nil,
                    author: nil,
                    thumbnail_url: nil,
                    media_type: "article",
                    published_at: now,
                    watch_term_keyword: "",
                    fetched_at: now
                )
            ],
            savedPages: [
                SavedPage(
                    id: "legacy:bad-script",
                    url: "javascript://example.com/feed",
                    title: "Bad saved",
                    platform: "custom",
                    saved_at: now
                ),
                SavedPage(
                    id: "legacy:host-port",
                    url: "localhost:9090/feed",
                    title: "Local saved",
                    platform: "CUSTOM",
                    saved_at: now
                ),
                SavedPage(
                    id: "legacy:tracked-saved",
                    url: "https://www.example.com/feed/?b=2&a=1&utm_source=saved",
                    title: "Tracked saved",
                    platform: "custom",
                    saved_at: now
                ),
                SavedPage(
                    id: "legacy:tracked-dup",
                    url: "https://example.com/feed?b=2&a=1",
                    title: "Duplicate saved",
                    platform: "custom",
                    saved_at: now
                )
            ],
            customUrls: [
                CustomUrl(id: "legacy:bad-script", url: "javascript://example.com/feed", title: "Bad", added_at: now),
                CustomUrl(id: "legacy:host-port", url: "localhost:9090/feed", title: " Local Feed ", added_at: now),
                CustomUrl(id: "legacy:tracked", url: "https://www.example.com/feed/?utm_source=backup&b=2&a=1#frag", title: " ", added_at: now),
                CustomUrl(id: "legacy:tracked-dup", url: "https://example.com/feed?b=2&a=1", title: "Duplicate", added_at: now),
            ],
            subscribedPlatforms: ["custom"],
            wallpaper: nil,
            sourcesOrder: nil,
            oshiAvatars: [:],
            compositions: [:],
            hiddenItems: [
                "legacy:bad-script::",
                "legacy:host-port::",
                "legacy:tracked-dup::",
                "youtube:v1::Aiko"
            ]
        )

        try db.importBackupData(JSONEncoder().encode(backup))

        XCTAssertEqual(db.customUrls.map(\.url), [
            "https://localhost:9090/feed",
            "https://example.com/feed?a=1&b=2",
        ])
        XCTAssertEqual(db.customUrls.map(\.title), ["Local Feed", nil])
        XCTAssertTrue(db.customUrls.allSatisfy { $0.id.hasPrefix("custom:") })
        XCTAssertEqual(Set(db.feedItems.map(\.id)), Set(db.customUrls.map(\.id)))
        XCTAssertEqual(Set(db.feedItems.map(\.url)), Set(db.customUrls.map(\.url)))
        XCTAssertEqual(db.savedPages.count, 2)
        XCTAssertEqual(Set(db.savedPages.map(\.id)), Set(db.customUrls.map(\.id)))
        XCTAssertEqual(Set(db.savedPages.map(\.url)), Set(db.customUrls.map(\.url)))
        XCTAssertEqual(db.hiddenItems, Set([
            "\(db.customUrls[0].id)::",
            "\(db.customUrls[1].id)::",
            "youtube:v1::Aiko"
        ]))
    }

    @MainActor
    func testProfileLoadNormalizesPersistedCustomUrlsAndCachedRows() throws {
        let originalProfileID = db.activeProfile.id
        let profile = try db.createProfile(name: "Legacy custom load \(UUID().uuidString)")
        defer {
            try? db.switchProfile(to: originalProfileID)
            try? db.deleteProfile(id: profile.id)
        }

        let now = ISO8601DateFormatter().string(from: Date())
        let legacyCustomUrls = [
            CustomUrl(id: "legacy:bad-script", url: "javascript://example.com/feed", title: "Bad", added_at: now),
            CustomUrl(id: "legacy:host-port", url: "localhost:9090/feed", title: " Local Feed ", added_at: now),
            CustomUrl(id: "legacy:tracked", url: "https://www.example.com/feed/?utm_source=load&b=2&a=1#frag", title: "Tracked", added_at: now),
            CustomUrl(id: "legacy:tracked-dup", url: "https://example.com/feed?b=2&a=1", title: "Duplicate", added_at: now),
        ]
        let legacyFeedItems = [
            FeedItem(
                id: "legacy:host-port",
                platform: "custom",
                url: "localhost:9090/feed",
                title: "Local cached",
                content_text: nil,
                author: nil,
                thumbnail_url: nil,
                media_type: "article",
                published_at: now,
                watch_term_keyword: "",
                fetched_at: now
            ),
            FeedItem(
                id: "legacy:tracked-raw",
                platform: "CUSTOM",
                url: "https://www.example.com/feed/?b=2&a=1&utm_source=cache",
                title: "Tracked cached",
                content_text: nil,
                author: nil,
                thumbnail_url: nil,
                media_type: "article",
                published_at: now,
                watch_term_keyword: "",
                fetched_at: now
            ),
            FeedItem(
                id: "legacy:bad-script",
                platform: "custom",
                url: "javascript://example.com/feed",
                title: "Bad cached",
                content_text: nil,
                author: nil,
                thumbnail_url: nil,
                media_type: "article",
                published_at: now,
                watch_term_keyword: "",
                fetched_at: now
            )
        ]
        let hiddenItems = [
            "legacy:bad-script::",
            "legacy:host-port::",
            "legacy:tracked-dup::",
            "youtube:v1::Aiko"
        ]
        let legacySavedPages = [
            SavedPage(
                id: "legacy:bad-script",
                url: "javascript://example.com/feed",
                title: "Bad saved",
                platform: "custom",
                saved_at: now
            ),
            SavedPage(
                id: "legacy:host-port",
                url: "localhost:9090/feed",
                title: "Local saved",
                platform: "custom",
                saved_at: now
            ),
            SavedPage(
                id: "legacy:tracked-saved",
                url: "https://www.example.com/feed/?b=2&a=1&utm_source=saved",
                title: "Tracked saved",
                platform: "CUSTOM",
                saved_at: now
            ),
            SavedPage(
                id: "legacy:tracked-dup",
                url: "https://example.com/feed?b=2&a=1",
                title: "Duplicate saved",
                platform: "custom",
                saved_at: now
            )
        ]
        let encoder = JSONEncoder()
        try encoder.encode(legacyCustomUrls).write(to: LocalProfileStore.shared.fileURL(for: "custom_urls", profileID: profile.id), options: [.atomic])
        try encoder.encode(legacyFeedItems).write(to: LocalProfileStore.shared.fileURL(for: "feed_items", profileID: profile.id), options: [.atomic])
        try encoder.encode(legacySavedPages).write(to: LocalProfileStore.shared.fileURL(for: "saved_pages", profileID: profile.id), options: [.atomic])
        try encoder.encode(hiddenItems).write(to: LocalProfileStore.shared.fileURL(for: "hidden_items", profileID: profile.id), options: [.atomic])

        try db.switchProfile(to: profile.id)

        XCTAssertEqual(db.customUrls.map(\.url), [
            "https://localhost:9090/feed",
            "https://example.com/feed?a=1&b=2",
        ])
        XCTAssertEqual(Set(db.feedItems.map(\.id)), Set(db.customUrls.map(\.id)))
        XCTAssertEqual(Set(db.feedItems.map(\.url)), Set(db.customUrls.map(\.url)))
        XCTAssertEqual(db.savedPages.count, 2)
        XCTAssertEqual(Set(db.savedPages.map(\.id)), Set(db.customUrls.map(\.id)))
        XCTAssertEqual(Set(db.savedPages.map(\.url)), Set(db.customUrls.map(\.url)))
        XCTAssertEqual(db.hiddenItems, Set([
            "\(db.customUrls[0].id)::",
            "\(db.customUrls[1].id)::",
            "youtube:v1::Aiko"
        ]))
    }

    @MainActor
    func testProfileLoadDropsHiddenItemsForPrunedLegacyYouTubeRows() throws {
        let originalProfileID = db.activeProfile.id
        let profile = try db.createProfile(name: "Legacy youtube load \(UUID().uuidString)")
        defer {
            try? db.switchProfile(to: originalProfileID)
            try? db.deleteProfile(id: profile.id)
        }

        let now = ISO8601DateFormatter().string(from: Date())
        let legacyUnmarked = FeedItem(
            id: "load-youtube:unmarked",
            platform: "youtube",
            url: "https://news.google.com/articles/load-unmarked",
            title: "Legacy unmarked",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "video",
            published_at: now,
            watch_term_keyword: "Aiko",
            fetched_at: now
        )
        let legacyGoogleNews = FeedItem(
            id: "load-youtube:google",
            platform: "youtube",
            url: "https://news.google.com/articles/load-google",
            title: "Legacy Google News",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "video",
            published_at: now,
            watch_term_keyword: "Aiko",
            fetched_at: now,
            source: "google_news"
        )
        let currentScrape = FeedItem(
            id: "load-youtube:current",
            platform: "youtube",
            url: "https://youtube.com/watch?v=current",
            title: "Current scrape",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "video",
            published_at: now,
            watch_term_keyword: "Aiko",
            fetched_at: now,
            source: "youtube_scrape"
        )
        let hiddenItems = [
            "\(legacyUnmarked.id)::\(legacyUnmarked.watch_term_keyword)",
            "\(legacyGoogleNews.id)::\(legacyGoogleNews.watch_term_keyword)",
            "\(currentScrape.id)::\(currentScrape.watch_term_keyword)"
        ]
        let encoder = JSONEncoder()
        try encoder.encode([legacyUnmarked, legacyGoogleNews, currentScrape]).write(to: LocalProfileStore.shared.fileURL(for: "feed_items", profileID: profile.id), options: [.atomic])
        try encoder.encode(hiddenItems).write(to: LocalProfileStore.shared.fileURL(for: "hidden_items", profileID: profile.id), options: [.atomic])

        try db.switchProfile(to: profile.id)

        XCTAssertEqual(db.feedItems.map(\.id), [currentScrape.id])
        XCTAssertEqual(db.hiddenItems, ["\(currentScrape.id)::\(currentScrape.watch_term_keyword)"])
    }

    @MainActor
    func testBackupImportUsesParsedDateCapAndRetainsDiscussionItems() throws {
        let formatter = ISO8601DateFormatter()
        let baseDate = Date(timeIntervalSince1970: 1_800_000_000)
        let newsItems = (0..<600).map { index in
            FeedItem(
                id: "backup-news:\(index)",
                platform: "news",
                url: "https://example.com/backup/news/\(index)",
                title: "Backup news \(index)",
                content_text: "Aiko news",
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
                id: "backup-5ch:\(index)",
                platform: "5ch",
                url: "https://example.5ch.net/test/read.cgi/thread/\(index)",
                title: "Backup thread \(index)",
                content_text: "Aiko thread",
                author: nil,
                thumbnail_url: nil,
                media_type: "article",
                published_at: formatter.string(from: baseDate.addingTimeInterval(TimeInterval(index))),
                watch_term_keyword: "Aiko",
                fetched_at: formatter.string(from: baseDate)
            )
        }
        let newerUTC = FeedItem(
            id: "backup-youtube:newer",
            platform: "youtube",
            url: "https://yt.example/backup/newer",
            title: "Backup newer",
            content_text: "Aiko",
            author: nil,
            thumbnail_url: nil,
            media_type: "video",
            published_at: "2024-06-01T03:00:00Z",
            watch_term_keyword: "Aiko",
            fetched_at: "2024-06-01T03:00:00Z",
            source: "youtube_scrape"
        )
        let olderOffset = FeedItem(
            id: "backup-youtube:older",
            platform: "youtube",
            url: "https://yt.example/backup/older",
            title: "Backup older",
            content_text: "Aiko",
            author: nil,
            thumbnail_url: nil,
            media_type: "video",
            published_at: "2024-06-01T10:00:00+09:00",
            watch_term_keyword: "Aiko",
            fetched_at: "2024-06-01T10:00:00+09:00",
            source: "youtube_scrape"
        )
        let backup = LocalBackup(
            exportedAt: formatter.string(from: Date()),
            terms: [],
            feedItems: newsItems + fiveChItems + [olderOffset, newerUTC],
            savedPages: [],
            customUrls: [],
            subscribedPlatforms: ["news", "5ch", "youtube"],
            wallpaper: nil,
            sourcesOrder: nil,
            oshiAvatars: [:],
            compositions: [:],
            hiddenItems: []
        )

        try db.importBackupData(JSONEncoder().encode(backup))

        XCTAssertEqual(db.feedItems.count, 600)
        XCTAssertEqual(db.feedItems.filter { $0.platform == "5ch" }.count, 25)
        XCTAssertLessThan(
            try XCTUnwrap(db.feedItems.firstIndex { $0.id == newerUTC.id }),
            try XCTUnwrap(db.feedItems.firstIndex { $0.id == olderOffset.id })
        )
    }

    @MainActor
    func testBackupImportPrunesLegacyYouTubeFallbackRows() throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let legacyUnmarked = FeedItem(
            id: "backup-youtube:legacy-unmarked",
            platform: "youtube",
            url: "https://youtube.com/watch?v=legacy-unmarked",
            title: "Legacy unmarked",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "video",
            published_at: now,
            watch_term_keyword: "Aiko",
            fetched_at: now
        )
        let legacyGoogleNews = FeedItem(
            id: "backup-youtube:legacy-google",
            platform: "youtube",
            url: "https://news.google.com/articles/legacy-google",
            title: "Legacy Google News",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "video",
            published_at: now,
            watch_term_keyword: "Aiko",
            fetched_at: now,
            source: "google_news"
        )
        let currentScrape = FeedItem(
            id: "backup-youtube:current",
            platform: "youtube",
            url: "https://youtube.com/watch?v=current",
            title: "Current scrape",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "video",
            published_at: now,
            watch_term_keyword: "Aiko",
            fetched_at: now,
            source: "youtube_scrape"
        )
        let backup = LocalBackup(
            exportedAt: now,
            terms: [],
            feedItems: [legacyUnmarked, legacyGoogleNews, currentScrape],
            savedPages: [],
            customUrls: [],
            subscribedPlatforms: ["youtube"],
            wallpaper: nil,
            sourcesOrder: nil,
            oshiAvatars: [:],
            compositions: [:],
            hiddenItems: [
                "\(legacyUnmarked.id)::\(legacyUnmarked.watch_term_keyword)",
                "\(legacyGoogleNews.id)::\(legacyGoogleNews.watch_term_keyword)",
                "\(currentScrape.id)::\(currentScrape.watch_term_keyword)"
            ]
        )

        try db.importBackupData(JSONEncoder().encode(backup))

        XCTAssertEqual(db.feedItems.map(\.id), [currentScrape.id])
        XCTAssertEqual(db.hiddenItems, ["\(currentScrape.id)::\(currentScrape.watch_term_keyword)"])
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
            fetched_at: "2026-07-27T00:00:00Z",
            source: "google_news"
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
            "fetched_at": item.fetched_at,
            "source": item.source as Any
        ])

        XCTAssertEqual(NotificationNavigationManager.shared.selectedItem, item)
        NotificationNavigationManager.shared.selectedItem = nil
    }

    @MainActor
    func testNotificationPayloadUsesCachedItemForMissingFields() throws {
        let cached = FeedItem(
            id: "youtube:abc123def45",
            platform: "youtube",
            url: "https://www.youtube.com/watch?v=abc123def45",
            title: "Cached title",
            content_text: "Cached description",
            author: "Cached channel",
            thumbnail_url: "https://i.ytimg.com/vi/abc123def45/hqdefault.jpg",
            media_type: "video",
            published_at: "2026-07-27T00:00:00Z",
            watch_term_keyword: "Cached Oshi",
            fetched_at: "2026-07-27T00:01:00Z",
            source: "youtube_scrape"
        )
        db.feedItems = [cached]

        NotificationNavigationManager.shared.open(userInfo: [
            "feed_item_id": cached.id,
            "url": cached.url
        ])

        XCTAssertEqual(NotificationNavigationManager.shared.selectedItem, cached)
        NotificationNavigationManager.shared.selectedItem = nil

        let twitterCached = FeedItem(
            id: "twitter:legacy-platform",
            platform: "twitter",
            url: "https://x.com/example/status/1",
            title: "Cached X title",
            content_text: nil,
            author: nil,
            thumbnail_url: nil,
            media_type: "text",
            published_at: "2026-07-27T00:00:00Z",
            watch_term_keyword: "Cached Oshi",
            fetched_at: "2026-07-27T00:01:00Z",
            source: "twitter_api"
        )
        db.feedItems = [twitterCached]

        NotificationNavigationManager.shared.open(userInfo: [
            "feed_item_id": twitterCached.id,
            "watch_term_keyword": twitterCached.watch_term_keyword,
            "platform": "x",
            "url": twitterCached.url
        ])

        XCTAssertEqual(NotificationNavigationManager.shared.selectedItem?.platform, "twitter")
        NotificationNavigationManager.shared.selectedItem = nil

        db.feedItems = []
        NotificationNavigationManager.shared.open(userInfo: [
            "feed_item_id": "x:evicted-status",
            "url": "https://x.com/example/status/2",
            "title": "Evicted X post",
            "media_type": "text",
            "published_at": "2026-07-27T00:00:00Z",
            "fetched_at": "2026-07-27T00:01:00Z"
        ])

        XCTAssertEqual(NotificationNavigationManager.shared.selectedItem?.platform, "twitter")
        NotificationNavigationManager.shared.selectedItem = nil
    }
    
    // MARK: - Feature 5: Custom tracked URLs
    @MainActor
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

        let twitterAliasMeta = manager.metadata(for: "x")
        XCTAssertEqual(twitterAliasMeta.name, "X")
        XCTAssertEqual(twitterAliasMeta.icon, "𝕏")

        let modelPressAliasMeta = manager.metadata(for: "news:mdpr")
        XCTAssertEqual(modelPressAliasMeta.name, "ModelPress")
        XCTAssertEqual(modelPressAliasMeta.icon, "💅")

        let yahooAliasMeta = manager.metadata(for: " news:yahoo_ent ")
        XCTAssertEqual(yahooAliasMeta.name, "YahooNews")
        XCTAssertEqual(yahooAliasMeta.icon, "🇯🇵")
        
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
