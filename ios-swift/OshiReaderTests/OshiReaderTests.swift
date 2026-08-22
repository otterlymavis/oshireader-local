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

private actor RequestPolicyCapture {
    private(set) var requests: [(url: String, timeout: TimeInterval)] = []

    func record(_ request: URLRequest) {
        requests.append((request.url?.absoluteString ?? "", request.timeoutInterval))
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

    func testBackendFeedClientDecodesHostedItemsAndQuery() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = BackendClient(session: session)
        MockURLProtocol.handler = { request in
            let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.path, "/api/feed/")
            XCTAssertEqual(components.queryItems?.first(where: { $0.name == "platform" })?.value, "youtube")
            XCTAssertEqual(components.queryItems?.first(where: { $0.name == "limit" })?.value, "25")
            XCTAssertEqual(components.queryItems?.first(where: { $0.name == "days" })?.value, "7")
            XCTAssertNotNil(request.value(forHTTPHeaderField: "X-Device-Secret"))
            let data = Data("""
            [{
              "watch_term_keyword": "Aiko",
              "matched_at": "2026-08-22T12:01:00Z",
              "item": {
                "id": "youtube:1",
                "platform": "youtube",
                "url": "https://example.com/1",
                "title": "Aiko update",
                "content_text": null,
                "author": "Channel",
                "thumbnail_url": null,
                "media_type": "video",
                "published_at": "2026-08-22T12:00:00Z",
                "source": "youtube"
              }
            }]
            """.utf8)
            return (
                data,
                try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil))
            )
        }
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        let items = try await client.fetchBackendFeed(platform: "youtube", limit: 25, days: 7)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, "youtube:1")
        XCTAssertEqual(items.first?.watch_term_keyword, "Aiko")
        XCTAssertEqual(items.first?.fetched_at, "2026-08-22T12:01:00Z")
    }

    func testBackendFeedClientSurfacesPaidAccessError() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = BackendClient(session: session)
        MockURLProtocol.handler = { request in
            let data = Data("""
            {"detail":{"code":"paid_backend_required","message":"An active purchase is required for backend feed access"}}
            """.utf8)
            return (
                data,
                try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 402, httpVersion: nil, headerFields: nil))
            )
        }
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        do {
            _ = try await client.fetchBackendFeed()
            XCTFail("Expected paid backend access to be rejected")
        } catch let BackendClientError.httpStatus(status, code, message) {
            XCTAssertEqual(status, 402)
            XCTAssertEqual(code, "paid_backend_required")
            XCTAssertEqual(message, "An active purchase is required for backend feed access")
        }
    }

    func testBackendFeedClientUsesIncrementalCursorInsteadOfDateWindow() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = BackendClient(session: session)
        MockURLProtocol.handler = { request in
            let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            XCTAssertEqual(
                components.queryItems?.first(where: { $0.name == "since" })?.value,
                "2026-08-22T12:00:00Z"
            )
            XCTAssertNil(components.queryItems?.first(where: { $0.name == "days" }))
            return (
                Data("[]".utf8),
                try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil))
            )
        }
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        let items = try await client.fetchBackendFeed(since: "2026-08-22T12:00:00Z")

        XCTAssertTrue(items.isEmpty)
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

    func testBackgroundRefreshCapsAliasesWithoutChangingForegroundSearchKeywords() {
        let term = WatchTerm(
            keyword: "Primary Oshi",
            aliases: ["Alias 1", "Alias 2", "Alias 3", "Alias 4", "Alias 5"]
        )

        XCTAssertEqual(IngestionService.searchKeywords(for: term), [
            "Primary Oshi", "Alias 1", "Alias 2", "Alias 3", "Alias 4", "Alias 5"
        ])
        XCTAssertEqual(
            IngestionService.searchKeywords(for: term, maximumAliases: LocalRefreshRequest.background.maximumAliases),
            ["Primary Oshi", "Alias 1"]
        )
    }

    func testBackgroundRefreshPlanRotatesTermsAndSourcesWithoutStarvation() {
        let first = WatchTerm(id: "first", keyword: "First")
        let second = WatchTerm(id: "second", keyword: "Second")
        let platforms = ["youtube", "news", "mdpr", "oricon", "custom"]

        let plans = (0..<3).map {
            BackgroundRefreshPlan.make(terms: [first, second], subscribedPlatforms: platforms, legacyCursor: $0)
        }

        XCTAssertEqual(plans[0].units.first, .source(term: first, platform: "mdpr"))
        XCTAssertEqual(plans[1].units.first, .source(term: second, platform: "mdpr"))
        XCTAssertEqual(plans[2].units.first, .source(term: first, platform: "news"))
        XCTAssertTrue(plans.allSatisfy { $0.totalWorkCount == 8 })
        XCTAssertEqual(Set(plans[0].units), Set([
            .source(term: first, platform: "youtube"),
            .source(term: first, platform: "news"),
            .source(term: first, platform: "mdpr"),
            .source(term: first, platform: "oricon"),
            .source(term: second, platform: "youtube"),
            .source(term: second, platform: "news"),
            .source(term: second, platform: "mdpr"),
            .source(term: second, platform: "oricon")
        ]))
    }

    func testBackgroundRefreshPlanHonorsSelectedSourcesAndSkipsCustomPlatform() {
        let selected = WatchTerm(
            id: "selected",
            keyword: "Selected",
            source_mode: .selected,
            selected_platforms: ["mdpr", "custom"]
        )

        let plan = BackgroundRefreshPlan.make(
            terms: [selected],
            subscribedPlatforms: ["youtube", "mdpr", "custom"],
            customURLs: [],
            legacyCursor: 5
        )

        XCTAssertEqual(plan.units, [.source(term: selected, platform: "mdpr")])
        XCTAssertEqual(plan.totalWorkCount, 1)
    }

    func testBackgroundRefreshPlanIncludesAndRotatesCustomURLs() {
        let term = WatchTerm(id: "term", keyword: "Term")
        let custom = CustomUrl(id: "custom", url: "https://example.com", title: nil, added_at: "2026-08-01T00:00:00Z")

        let plan = BackgroundRefreshPlan.make(
            terms: [term],
            subscribedPlatforms: ["news"],
            customURLs: [custom],
            legacyCursor: 1
        )

        XCTAssertEqual(plan.units, [
            .custom(custom),
            .source(term: term, platform: "news")
        ])
        XCTAssertEqual(plan.totalWorkCount, 2)
    }

    func testBackgroundRefreshPlanResumesAfterStableUnitWhenPriorityOrderChanges() {
        let first = WatchTerm(id: "first", keyword: "First")
        let second = WatchTerm(id: "second", keyword: "Second")
        let completed = BackgroundRefreshUnit.source(term: second, platform: "youtube")

        let plan = BackgroundRefreshPlan.make(
            terms: [second, first],
            subscribedPlatforms: ["youtube", "news"],
            lastCompletedUnitID: completed.stableID,
            legacyCursor: 99
        )

        XCTAssertEqual(plan.units.first, .source(term: first, platform: "news"))
        XCTAssertEqual(Set(plan.units).count, 4)
    }

    func testBackgroundRefreshCheckpointRejectsLateAndStaleUnits() {
        let deadline = Date()

        XCTAssertTrue(BackgroundRefreshCheckpoint.isValid(
            sourceRevision: 4,
            currentRevision: 4,
            completedAt: deadline,
            deadline: deadline
        ))
        XCTAssertFalse(BackgroundRefreshCheckpoint.isValid(
            sourceRevision: 4,
            currentRevision: 5,
            completedAt: deadline,
            deadline: deadline
        ))
        XCTAssertFalse(BackgroundRefreshCheckpoint.isValid(
            sourceRevision: 4,
            currentRevision: 4,
            completedAt: deadline.addingTimeInterval(0.001),
            deadline: deadline
        ))
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
                    "videoId":"undatedvid1"
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

    func testYouTubeEscapedFallbackDoesNotBorrowNeighboringVideosDateAcrossDoubleEscapedIDs() async throws {
        // Same regression as above, but the undated video's ID only appears in the
        // double-escaped form (\x22...\x22) that decodeJavaScriptEscapedString unwraps to a
        // single layer, not a plain quote. Boundary scoping must still recognize it as "this
        // video" rather than falling back to an unbounded search that borrows the neighbor's date.
        let capture = RequestCapture()
        let service = IngestionService(
            requestExecutor: { request in
                let url = request.url?.absoluteString ?? ""
                await capture.record(url)
                let data = url.contains("/youtubei/")
                    ? Data("{}".utf8)
                    : Data(#"""
                    \\x22videoId\\x22:\\x22undatedvid2\\x22
                    "videoRenderer":{"videoId":"freshvid003","publishedTimeText":{"simpleText":"2 days ago"}}
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

        XCTAssertEqual(report.items.map(\.id), ["youtube:freshvid003"])
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

    func testRecentLookupFallsBackToHistoricalWithoutDroppingOlderItems() async throws {
        let emptyRSS = Data("<rss version=\"2.0\"><channel></channel></rss>".utf8)
        let historicalRSS = Data("""
        <rss version="2.0"><channel><item>
        <title>Status Oshi older article - ModelPress</title>
        <link>https://mdpr.jp/news/older-status-oshi</link>
        <pubDate>Fri, 31 Jul 2026 07:00:00 GMT</pubDate>
        </item></channel></rss>
        """.utf8)
        let capture = RequestCapture()
        let referenceDate = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-12T09:00:00Z"))
        let service = IngestionService(
            requestExecutor: { request in
                let url = request.url?.absoluteString ?? ""
                await capture.record(url)
                return (
                    url.contains("when:10d") ? emptyRSS : historicalRSS,
                    try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                    ))
                )
            },
            retrySleeper: { _ in },
            classifyFreshness: true,
            now: { referenceDate }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Status Oshi"),
            platforms: ["oricon"]
        )

        XCTAssertEqual(report.items.count, 1)
        XCTAssertEqual(report.items.first?.published_at, "2026-07-31T07:00:00Z")
        XCTAssertEqual(report.sourceStatuses.first?.outcome, .stale)
        let urls = await capture.urls
        XCTAssertEqual(urls.filter { $0.contains("news.google.com") }.count, 2)
        XCTAssertTrue(urls.contains { $0.contains("when:10d") })
    }

    func testFailedRecentLookupDoesNotMisreportHistoricalItemsAsStale() async throws {
        let historicalRSS = Data("""
        <rss version="2.0"><channel><item>
        <title>Status Oshi older article</title>
        <link>https://example.com/older-status-oshi</link>
        <pubDate>Fri, 31 Jul 2026 07:00:00 GMT</pubDate>
        </item></channel></rss>
        """.utf8)
        let referenceDate = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-12T09:00:00Z"))
        let service = IngestionService(
            requestExecutor: { request in
                let isRecent = request.url?.absoluteString.contains("when:10d") == true
                return (
                    isRecent ? Data() : historicalRSS,
                    try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: isRecent ? 500 : 200, httpVersion: nil, headerFields: nil
                    ))
                )
            },
            retrySleeper: { _ in },
            classifyFreshness: true,
            now: { referenceDate }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Status Oshi"),
            platforms: ["oricon"]
        )

        XCTAssertEqual(report.items.count, 1)
        XCTAssertEqual(report.sourceStatuses.first?.outcome, .failed(.httpFailure))
    }

    func testModelPressUsesOfficialDatedSearchAndRejectsUnrelatedRows() async throws {
        let html = Data(#"""
        <ol>
          <li class="p-articleListItem">
            <a href="/news/irrelevant" class="p-articleListItem__link">
              <img src="https://img.example/irrelevant.jpg">
              <p class="p-articleListItem__title"><span>Unrelated current story</span></p>
              <time datetime="2026-08-11 14:10">2026.08.11</time>
            </a>
          </li>
          <li class="p-articleListItem">
            <a href="/news/relevant" class="p-articleListItem__link">
              <img src="https://img.example/relevant.jpg">
              <p class="p-articleListItem__title"><span>Status Oshi official update &amp; interview</span></p>
              <time datetime="2026-08-10 08:30">2026.08.10</time>
            </a>
          </li>
        </ol>
        """#.utf8)
        let capture = RequestCapture()
        let referenceDate = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-12T09:00:00Z"))
        let service = IngestionService(
            requestExecutor: { request in
                await capture.record(request.url?.absoluteString ?? "")
                return (
                    html,
                    try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                    ))
                )
            },
            retrySleeper: { _ in },
            classifyFreshness: true,
            now: { referenceDate }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Status Oshi"),
            platforms: ["mdpr"]
        )

        XCTAssertEqual(report.items.map(\.id).count, 1)
        XCTAssertEqual(report.items.first?.title, "Status Oshi official update & interview")
        XCTAssertEqual(report.items.first?.source, "modelpress_search")
        XCTAssertEqual(report.sourceStatuses.first?.outcome, .received)
        let urls = await capture.urls
        XCTAssertEqual(urls.filter { $0.contains("mdpr.jp/search") }.count, 1)
        XCTAssertFalse(urls.contains { $0.contains("news.google.com") })
    }

    func testModelPressFollowsSecondPageToPreserveOlderMatches() async throws {
        let firstPage = Data(#"""
        <ol>
          <li class="p-articleListItem">
            <a href="/news/irrelevant" class="p-articleListItem__link">
              <p class="p-articleListItem__title"><span>Unrelated story</span></p>
              <time datetime="2026-08-11 14:10">2026.08.11</time>
            </a>
          </li>
        </ol>
        <a href="/search?keyword=Status&amp;type=article&amp;page=2" class="c-pager__button c-pager__button--next">Next</a>
        """#.utf8)
        let secondPage = Data(#"""
        <ol>
          <li class="p-articleListItem">
            <a href="/news/older-relevant" class="p-articleListItem__link">
              <p class="p-articleListItem__title"><span>Status Oshi older official match</span></p>
              <time datetime="2026-07-20 08:30">2026.07.20</time>
            </a>
          </li>
        </ol>
        """#.utf8)
        let capture = RequestCapture()
        let referenceDate = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-12T09:00:00Z"))
        let service = IngestionService(
            requestExecutor: { request in
                let url = request.url?.absoluteString ?? ""
                await capture.record(url)
                return (
                    url.contains("page=2") ? secondPage : firstPage,
                    try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                    ))
                )
            },
            retrySleeper: { _ in },
            classifyFreshness: true,
            now: { referenceDate }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Status Oshi"),
            platforms: ["mdpr"]
        )

        XCTAssertEqual(report.items.map(\.title), ["Status Oshi older official match"])
        XCTAssertEqual(report.sourceStatuses.first?.outcome, .stale)
        let urls = await capture.urls
        XCTAssertEqual(urls.filter { $0.contains("mdpr.jp/search") }.count, 2)
        XCTAssertTrue(urls.contains { $0.contains("page=2") })
        XCTAssertFalse(urls.contains { $0.contains("news.google.com") })
    }

    func testRecentLookupMergesHistoricalItemsWhenCurrentItemsExist() async throws {
        let recentRSS = Data("""
        <rss version="2.0"><channel><item>
        <title>Status Oshi current article - ModelPress</title>
        <link>https://mdpr.jp/news/current-status-oshi</link>
        <pubDate>Mon, 10 Aug 2026 07:00:00 GMT</pubDate>
        </item></channel></rss>
        """.utf8)
        let historicalRSS = Data("""
        <rss version="2.0"><channel>
        <item>
        <title>Status Oshi current article - ModelPress</title>
        <link>https://mdpr.jp/news/current-status-oshi</link>
        <pubDate>Mon, 10 Aug 2026 07:00:00 GMT</pubDate>
        </item>
        <item>
        <title>Status Oshi older article - ModelPress</title>
        <link>https://mdpr.jp/news/older-status-oshi</link>
        <pubDate>Fri, 31 Jul 2026 07:00:00 GMT</pubDate>
        </item>
        </channel></rss>
        """.utf8)
        let capture = RequestCapture()
        let referenceDate = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-12T09:00:00Z"))
        let service = IngestionService(
            requestExecutor: { request in
                await capture.record(request.url?.absoluteString ?? "")
                return (
                    request.url?.absoluteString.contains("when:10d") == true ? recentRSS : historicalRSS,
                    try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                    ))
                )
            },
            retrySleeper: { _ in },
            classifyFreshness: true,
            now: { referenceDate }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Status Oshi"),
            platforms: ["oricon"]
        )

        XCTAssertEqual(report.items.count, 2)
        XCTAssertEqual(Set(report.items.map(\.url)), [
            "https://mdpr.jp/news/current-status-oshi",
            "https://mdpr.jp/news/older-status-oshi",
        ])
        XCTAssertEqual(report.sourceStatuses.first?.outcome, .received)
        let urls = await capture.urls
        XCTAssertEqual(urls.filter { $0.contains("news.google.com") }.count, 2)
        XCTAssertTrue(urls.contains { $0.contains("when:10d") })
    }

    func testRecentLookupSkipsHistoricalRequestWhenRecentResultsFillLimit() async throws {
        let items = (0..<20).map { index in
            """
            <item>
            <title>Status Oshi current article \(index)</title>
            <link>https://example.com/current-\(index)</link>
            <pubDate>Mon, 10 Aug 2026 07:00:00 GMT</pubDate>
            </item>
            """
        }.joined()
        let recentRSS = Data("<rss version=\"1.0\"><channel>\(items)</channel></rss>".utf8)
        let capture = RequestCapture()
        let referenceDate = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-12T09:00:00Z"))
        let service = IngestionService(
            requestExecutor: { request in
                await capture.record(request.url?.absoluteString ?? "")
                return (
                    recentRSS,
                    try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                    ))
                )
            },
            retrySleeper: { _ in },
            classifyFreshness: true,
            now: { referenceDate }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Status Oshi"),
            platforms: ["oricon"]
        )

        XCTAssertEqual(report.items.count, 20)
        let urls = await capture.urls
        XCTAssertEqual(urls.filter { $0.contains("news.google.com") }.count, 1)
        XCTAssertTrue(urls.first?.contains("when:10d") == true)
    }

    func testGoogleNewsQueryEscapesKeywordParameterDelimiters() async throws {
        let emptyRSS = Data("<rss version=\"2.0\"><channel></channel></rss>".utf8)
        let capture = RequestCapture()
        let service = IngestionService(
            requestExecutor: { request in
                await capture.record(request.url?.absoluteString ?? "")
                return (
                    emptyRSS,
                    try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                    ))
                )
            },
            retrySleeper: { _ in },
            classifyFreshness: true
        )

        _ = await service.ingestReport(
            term: WatchTerm(keyword: "&TEAM"),
            platforms: ["oricon"]
        )

        let urls = await capture.urls
        XCTAssertEqual(urls.count, 2)
        for rawURL in urls {
            let components = try XCTUnwrap(URLComponents(string: rawURL))
            XCTAssertEqual(
                components.queryItems?.first { $0.name == "q" }?.value?.hasPrefix("&TEAM site:oricon.co.jp"),
                true
            )
            XCTAssertFalse(rawURL.contains("?q=&TEAM"))
            XCTAssertTrue(rawURL.contains("%26TEAM"))
        }
    }

    func testTVerDoesNotInventCurrentDateForUndatedResults() async throws {
        let createResponse = Data(#"{"result":{"platform_uid":"test-uid","platform_token":"test-token"}}"#.utf8)
        let searchResponse = Data(#"""
        {"result":{"episodes":{"contents":[
          {"content":{"id":"undated","title":"TVer Oshi undated"}},
          {"content":{"id":"dated","title":"TVer Oshi dated","broadcastDate":"2026-08-11T07:00:00Z"}}
        ]}}}
        """#.utf8)
        let referenceDate = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-12T09:00:00Z"))
        let service = IngestionService(
            requestExecutor: { request in
                let data = request.url?.path.contains("/browser/create") == true ? createResponse : searchResponse
                return (
                    data,
                    try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                    ))
                )
            },
            retrySleeper: { _ in },
            classifyFreshness: true,
            now: { referenceDate }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "TVer Oshi"),
            platforms: ["tver"]
        )

        XCTAssertEqual(report.items.map(\.id), ["tver:dated"])
        XCTAssertEqual(report.sourceStatuses.first?.outcome, .received)
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

    func testBackgroundTransportPolicyUsesOneBoundedAttemptPerRequest() async {
        let capture = RequestPolicyCapture()
        let service = IngestionService(
            requestExecutor: { request in
                await capture.record(request)
                throw URLError(.timedOut)
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Bounded Oshi"),
            platforms: ["barks"],
            maximumAliases: 0,
            transportAttemptLimit: 1,
            requestTimeoutCap: 7
        )

        let requests = await capture.requests
        XCTAssertFalse(requests.isEmpty)
        XCTAssertTrue(requests.allSatisfy { $0.timeout == 7 })
        XCTAssertEqual(requests.filter { $0.url == "https://barks.jp/feed/" }.count, 1)
        XCTAssertEqual(report.sourceStatuses.first?.outcome, .failed(.timeout))
    }

    func testBackgroundAbsoluteDeadlineStopsSequentialFallbackRequests() async {
        let capture = RequestPolicyCapture()
        let service = IngestionService(
            requestExecutor: { request in
                await capture.record(request)
                try? await Task.sleep(nanoseconds: 60_000_000)
                throw URLError(.timedOut)
            },
            retrySleeper: { _ in }
        )

        let report = await service.ingestReport(
            term: WatchTerm(keyword: "Deadline Oshi"),
            platforms: ["barks"],
            maximumAliases: 0,
            transportAttemptLimit: 1,
            requestTimeoutCap: 7,
            requestDeadline: Date(timeIntervalSinceNow: 0.03)
        )

        let requests = await capture.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertLessThanOrEqual(requests[0].timeout, 0.03)
        XCTAssertEqual(report.sourceStatuses.first?.outcome, .failed(.timeout))
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

    func testMissingTwitterCredentialUsesPublicIndexFallback() async throws {
        let existing = KeychainHelper.read(.twitterBearerToken)
        KeychainHelper.save(.twitterBearerToken, nil)
        defer { KeychainHelper.save(.twitterBearerToken, existing) }

        let rss = """
        <rss version="2.0"><channel><item>
        <title>Credential Oshi posted an update - x.com</title>
        <link>https://news.google.com/rss/articles/twitter-public-result</link>
        <pubDate>Fri, 14 Aug 2026 12:00:00 GMT</pubDate>
        </item></channel></rss>
        """.data(using: .utf8)!
        let capture = RequestCapture()

        let report = await IngestionService(
            requestExecutor: { request in
                await capture.record(request.url?.absoluteString ?? "")
                return (
                    rss,
                    try XCTUnwrap(HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                    ))
                )
            },
            classifyFreshness: true,
            now: { ISO8601DateFormatter().date(from: "2026-08-15T12:00:00Z")! }
        ).ingestReport(
            term: WatchTerm(keyword: "Credential Oshi"),
            platforms: ["twitter"]
        )

        XCTAssertEqual(report.sourceStatuses.first?.outcome, .received)
        XCTAssertEqual(report.items.count, 1)
        XCTAssertEqual(report.items.first?.source, IngestionService.twitterPublicIndexSource)
        let requestedPublicIndex = await capture.contains { url in
            url.contains("news.google.com/rss/search") && url.contains("site:x.com")
        }
        XCTAssertTrue(requestedPublicIndex)
    }

    func testMissingTwitterCredentialDoesNotClaimMediaResultsFromPublicIndex() async {
        let existing = KeychainHelper.read(.twitterBearerToken)
        KeychainHelper.save(.twitterBearerToken, nil)
        defer { KeychainHelper.save(.twitterBearerToken, existing) }

        let report = await IngestionService(
            requestExecutor: { _ in
                XCTFail("Media-only X refresh must not use text-only public index results")
                throw URLError(.cancelled)
            }
        ).ingestReport(
            term: WatchTerm(keyword: "Credential Oshi", collection_mode: "media_only"),
            platforms: ["twitter"]
        )

        XCTAssertEqual(report.sourceStatuses.first?.outcome, .noResults)
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

    func testSharedRelativeTimeFormatterProducesStableOutput() {
        let reference = Date(timeIntervalSince1970: 2_000_000)
        let earlier = reference.addingTimeInterval(-120)

        let first = relativeTimeString(from: earlier, relativeTo: reference)
        let second = relativeTimeString(from: earlier, relativeTo: reference)

        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first, second)
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

    func testRefreshResultKeepsStaleSourcePartialNotFailed() {
        let result = LocalRefreshResult(
            completion: .completed,
            addedCount: 0,
            sourceStatuses: [
                SourceRefreshStatus(id: "mdpr", outcome: .stale, itemCount: 15, queryCount: 1)
            ],
            customRefreshCompleted: true
        )

        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.hasSourceFailures)
        XCTAssertTrue(result.wasPartial)
    }

    func testRefreshResultTreatsCappedBackgroundWorkAsPartialButSuccessful() {
        let result = LocalRefreshResult(
            completion: .completed,
            addedCount: 0,
            sourceStatuses: [],
            customRefreshCompleted: true,
            cappedWorkCount: 2
        )

        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.wasPartial)
    }

    @MainActor
    func testCustomURLRefreshReportsAllFailedScrapesAsSourceFailure() async {
        db.setSubscribedPlatforms(platforms: ["custom"])
        db.customUrls = [
            CustomUrl(
                id: "custom:invalid",
                url: "::::",
                title: "Broken feed",
                added_at: "2026-08-01T00:00:00Z"
            )
        ]

        let result = await LocalRefreshCoordinator.shared.refresh(.foreground)

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.sourceStatuses.first?.id, "custom")
        XCTAssertEqual(result.sourceStatuses.first?.outcome, .failed(.httpFailure))
    }

    @MainActor
    func testRefreshDiagnosticsPreservesCustomFailureWithReturnedItems() {
        let suiteName = "OshiReaderTests.custom.partial.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let diagnostics = RefreshDiagnostics(defaults: defaults)

        diagnostics.recordSourceStatuses([
            SourceRefreshStatus(id: "custom", outcome: .failed(.httpFailure), itemCount: 1, queryCount: 2)
        ])

        XCTAssertEqual(diagnostics.sourceStatuses.first?.outcome, .failed(.httpFailure))
        XCTAssertEqual(diagnostics.sourceStatuses.first?.itemCount, 1)
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
    func testBackgroundPriorityKeepsNonNotificationTermsAfterNotificationTerms() {
        let suiteName = "OshiReaderTests.background.priority.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RecentTermUsageStore(defaults: defaults)
        let first = WatchTerm(id: "first", keyword: "First", notify_on_new: false)
        let second = WatchTerm(id: "second", keyword: "Second", notify_on_new: true)
        let third = WatchTerm(id: "third", keyword: "Third", notify_on_new: false)

        store.markUsed(termID: third.id)

        XCTAssertEqual(store.priorityOrdered([first, second, third]).map(\.id), ["second", "third", "first"])
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
    func testRefreshDiagnosticsReportsAndPersistsStaleSources() {
        let suiteName = "OshiReaderTests.health.stale.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let diagnostics = RefreshDiagnostics(defaults: defaults)

        diagnostics.recordSourceStatuses([
            SourceRefreshStatus(id: "mdpr", outcome: .stale, itemCount: 12, queryCount: 1)
        ])
        diagnostics.recordCompletedSourceStatuses(diagnostics.sourceStatuses)

        XCTAssertTrue(diagnostics.hasSourceFailures)
        XCTAssertTrue(diagnostics.sourceSummaryText.contains("1 stale"))

        let reloaded = RefreshDiagnostics(defaults: defaults)
        let summary = reloaded.sourceHealthSummaries.first { $0.id == "mdpr" }
        XCTAssertEqual(summary?.staleCount, 1)
        XCTAssertEqual(summary?.currentStatus?.outcome, .stale)
        XCTAssertEqual(summary?.totalItemCount, 12)
    }

    @MainActor
    func testRefreshDiagnosticsUsesCurrentPrecedenceOverStaleAcrossTerms() {
        let suiteName = "OshiReaderTests.health.stale-precedence.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let diagnostics = RefreshDiagnostics(defaults: defaults)

        diagnostics.recordSourceStatuses([
            SourceRefreshStatus(id: "mdpr", outcome: .stale, itemCount: 2, queryCount: 1),
            SourceRefreshStatus(id: "mdpr", outcome: .received, itemCount: 1, queryCount: 1),
        ])

        let status = diagnostics.sourceStatuses.first
        XCTAssertEqual(status?.outcome, .received)
        XCTAssertEqual(status?.itemCount, 3)
        XCTAssertEqual(status?.queryCount, 2)
        XCTAssertFalse(diagnostics.sourceStatuses.hasFailures)
    }

    @MainActor
    func testRefreshDiagnosticsKeepsFailureWhenHistoricalItemsWereRetained() {
        let suiteName = "OshiReaderTests.health.items-with-failure.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let diagnostics = RefreshDiagnostics(defaults: defaults)

        diagnostics.recordSourceStatuses([
            SourceRefreshStatus(
                id: "oricon",
                outcome: .failed(.httpFailure),
                itemCount: 1,
                queryCount: 1
            )
        ])

        XCTAssertEqual(diagnostics.sourceStatuses.first?.outcome, .failed(.httpFailure))
        XCTAssertEqual(diagnostics.sourceStatuses.first?.itemCount, 1)
        XCTAssertTrue(diagnostics.hasSourceFailures)

        diagnostics.recordSourceStatuses([
            SourceRefreshStatus(id: "oricon", outcome: .received, itemCount: 2, queryCount: 1)
        ])
        XCTAssertEqual(diagnostics.sourceStatuses.first?.outcome, .received)
        XCTAssertEqual(diagnostics.sourceStatuses.first?.itemCount, 3)
        XCTAssertFalse(diagnostics.hasSourceFailures)
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
    func testSourceHealthHistoryUsesTenDayRetention() {
        let suiteName = "OshiReaderTests.health.prune.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let diagnostics = RefreshDiagnostics(defaults: defaults)
        let now = Date()
        XCTAssertEqual(RefreshDiagnostics.healthHistoryRetention, 10 * 24 * 60 * 60)

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
    func testSourceHealthHistoryReplacesProvisionalRecordsWithinOneRefresh() {
        let suiteName = "OshiReaderTests.health.provisional.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let diagnostics = RefreshDiagnostics(defaults: defaults)
        let refreshStart = Date(timeIntervalSinceNow: -60)

        diagnostics.recordCompletedSourceStatuses([
            SourceRefreshStatus(id: "barks", outcome: .noResults, itemCount: 0, queryCount: 1)
        ], completedAt: refreshStart.addingTimeInterval(-60))
        diagnostics.recordCompletedSourceStatuses([
            SourceRefreshStatus(id: "barks", outcome: .failed(.timeout), itemCount: 0, queryCount: 1)
        ], completedAt: refreshStart.addingTimeInterval(1), replacingRecordsSince: refreshStart)
        diagnostics.recordCompletedSourceStatuses([
            SourceRefreshStatus(id: "barks", outcome: .failed(.rateLimited), itemCount: 0, queryCount: 2)
        ], completedAt: refreshStart.addingTimeInterval(2), replacingRecordsSince: refreshStart)

        let summary = diagnostics.sourceHealthSummaries.first { $0.id == "barks" }
        XCTAssertEqual(summary?.emptyCount, 1)
        XCTAssertEqual(summary?.failedCount, 1)
        XCTAssertEqual(summary?.lastFailure, .rateLimited)
        XCTAssertEqual(summary?.currentStatus?.queryCount, 2)
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

    /// Times a full ingestReport fan-out (every subscribed platform, one
    /// watch term) against a mocked instant transport — isolates parsing/
    /// dedup CPU cost from real network latency, which measure() can't do
    /// for these async source fetchers. Most sources route through the
    /// generic Google News / dedicated RSS parser, so one shared RSS
    /// fixture (with the watch term's keyword in every item, satisfying
    /// strict-keyword-matching sources) exercises that shared path across
    /// all of them concurrently, same as LocalRefreshCoordinator does for
    /// one term in production. Sources needing JSON/HTML (YouTube, Twitter,
    /// TVer, niconico) will fail to parse this RSS payload and contribute
    /// no items — their cost isn't captured here.
    func testFullTermIngestionPerformanceWithMockedNetwork() async throws {
        let itemsXML = (0..<20).map { index -> String in
            """
            <item>
            <title>Perf Oshi story \(index) - Yahoo!ニュース</title>
            <link>https://example.com/perf/\(index)?utm_source=rss</link>
            <description>Perf Oshi description number \(index) with enough body text to exercise HTML-entity and whitespace cleanup.</description>
            <pubDate>Sun, 02 Aug 2026 08:0\(index % 6):00 GMT</pubDate>
            </item>
            """
        }.joined()
        let rss = Data("<rss version=\"2.0\"><channel>\(itemsXML)</channel></rss>".utf8)

        let service = IngestionService(
            requestExecutor: { request in
                (rss, try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)))
            },
            retrySleeper: { _ in }
        )
        let allPlatformIDs = Set(PlatformRegistry.all.map(\.id)).subtracting(["custom"])
        let term = WatchTerm(keyword: "Perf Oshi")

        var durationsMs: [Double] = []
        var itemCounts: [Int] = []
        for _ in 0..<5 {
            let start = CFAbsoluteTimeGetCurrent()
            let report = await service.ingestReport(term: term, platforms: allPlatformIDs)
            durationsMs.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            itemCounts.append(report.items.count)
        }
        XCTAssertTrue(itemCounts.allSatisfy { $0 > 0 }, "mocked RSS should have produced items from at least the RSS-routed sources")
        // Steady-state average (dropping the first, JIT/warmup-affected run)
        // as a loose regression guard — this call was ~30ms against a real
        // device baseline; a large multiple of that signals an accidental
        // O(n^2) regression rather than normal machine variance.
        let steadyStateAverage = durationsMs.dropFirst().reduce(0, +) / Double(durationsMs.count - 1)
        XCTAssertLessThan(steadyStateAverage, 500, "full-platform ingestion against a mocked instant transport regressed well past its ~30ms baseline")
    }

}
