import XCTest
import SwiftUI
import UIKit
import UserNotifications
@testable import OshiReader

final class OPMLExportTests: XCTestCase {

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

    func testOPMLExportProducesFeedOutlinePerSubscribedGoogleNewsPlatform() throws {
        let term = WatchTerm(keyword: "Oshi", source_mode: .selected, selected_platforms: ["yahoonews", "5ch"])
        let xml = OPMLExporter.export(
            terms: [term],
            subscribedPlatforms: PlatformRegistry.all.map(\.id),
            customUrls: [],
            amebloBlogs: [],
            generatedAt: Date(timeIntervalSince1970: 1_767_225_600)
        )
        XCTAssertTrue(xml.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
        XCTAssertTrue(xml.contains("<opml version=\"2.0\">"))
        XCTAssertTrue(xml.contains("text=\"Oshi\" title=\"Oshi\""))
        // Both selected platforms have a googleNewsSite, so each should produce
        // a subscribable news.google.com/rss/search outline for this term.
        XCTAssertTrue(xml.contains("xmlUrl=\"https://news.google.com/rss/search?q=Oshi%20site:news.yahoo.co.jp"))
        XCTAssertTrue(xml.contains("xmlUrl=\"https://news.google.com/rss/search?q=Oshi%20site:5ch.net"))
        // Not subscribed to this term, so youtube (which has no googleNewsSite
        // anyway) must not appear.
        XCTAssertFalse(xml.contains("youtube"))
    }

    func testOPMLExportEscapesXMLSpecialCharactersAndSkipsInactiveTerms() throws {
        let active = WatchTerm(keyword: "A&B \"Oshi\"", is_active: true)
        let inactive = WatchTerm(keyword: "Should Not Appear", is_active: false)
        let xml = OPMLExporter.export(
            terms: [active, inactive],
            subscribedPlatforms: PlatformRegistry.all.map(\.id),
            customUrls: [],
            amebloBlogs: [],
            generatedAt: Date(timeIntervalSince1970: 1_767_225_600)
        )
        XCTAssertTrue(xml.contains("A&amp;B &quot;Oshi&quot;"))
        XCTAssertFalse(xml.contains("Should Not Appear"))
    }

    func testOPMLExportIncludesAmebloAndCustomURLFolders() throws {
        let blog = try XCTUnwrap(AmebloBlog(url: "https://ameblo.jp/testblog", title: "Test Blog"))
        let customUrl = CustomUrl(id: "custom1", url: "https://example.com/page", title: "My Page", added_at: "2026-01-01T00:00:00Z")
        let xml = OPMLExporter.export(
            terms: [],
            subscribedPlatforms: [],
            customUrls: [customUrl],
            amebloBlogs: [blog],
            generatedAt: Date(timeIntervalSince1970: 1_767_225_600)
        )
        XCTAssertTrue(xml.contains("text=\"Ameblo Blogs\""))
        XCTAssertTrue(xml.contains(blog.rssURL!.absoluteString))
        XCTAssertTrue(xml.contains("text=\"Custom URLs\""))
        XCTAssertTrue(xml.contains("type=\"link\" text=\"My Page\" title=\"My Page\" htmlUrl=\"https://example.com/page\""))
    }

    func testOPMLExportOmitsDedicatedSourcePlatformsFromPerTermFeeds() throws {
        // natalie and ameblo both have a real primary source in
        // IngestionService (a fixed dedicated RSS feed / per-blog RSS) —
        // Google News is only their fallback, so exporting it unconditionally
        // would misrepresent what the term's feed actually shows day to day.
        let term = WatchTerm(keyword: "Oshi", source_mode: .selected, selected_platforms: ["natalie", "ameblo", "yahoonews"])
        let xml = OPMLExporter.export(
            terms: [term],
            subscribedPlatforms: PlatformRegistry.all.map(\.id),
            customUrls: [],
            amebloBlogs: [],
            generatedAt: Date(timeIntervalSince1970: 1_767_225_600)
        )
        XCTAssertFalse(xml.contains("site:natalie.mu"))
        XCTAssertFalse(xml.contains("site:ameblo.jp"))
        XCTAssertTrue(xml.contains("site:news.yahoo.co.jp"))
        // No platforms left once natalie/ameblo are excluded and no other
        // term exists, so the term's own outline must not be emitted empty.
        let onlyDedicatedTerm = WatchTerm(keyword: "Solo", source_mode: .selected, selected_platforms: ["natalie"])
        let emptyXml = OPMLExporter.export(
            terms: [onlyDedicatedTerm],
            subscribedPlatforms: PlatformRegistry.all.map(\.id),
            customUrls: [],
            amebloBlogs: [],
            generatedAt: Date(timeIntervalSince1970: 1_767_225_600)
        )
        XCTAssertFalse(emptyXml.contains("text=\"Solo\""))
    }

    func testOPMLExportIncludesOneFeedPerAlias() throws {
        let term = WatchTerm(
            keyword: "Oshi",
            source_mode: .selected,
            selected_platforms: ["yahoonews"],
            aliases: ["推し"]
        )
        let xml = OPMLExporter.export(
            terms: [term],
            subscribedPlatforms: PlatformRegistry.all.map(\.id),
            customUrls: [],
            amebloBlogs: [],
            generatedAt: Date(timeIntervalSince1970: 1_767_225_600)
        )
        XCTAssertTrue(xml.contains("q=Oshi%20site:news.yahoo.co.jp"))
        XCTAssertTrue(xml.contains("q=%E6%8E%A8%E3%81%97%20site:news.yahoo.co.jp"))
        XCTAssertTrue(xml.contains("text=\"YahooNews (推し)\""))
    }

    func testOPMLExportWritesRFC822DateCreated() throws {
        let xml = OPMLExporter.export(
            terms: [],
            subscribedPlatforms: [],
            customUrls: [],
            amebloBlogs: [],
            generatedAt: Date(timeIntervalSince1970: 1_767_225_600)
        )
        XCTAssertTrue(xml.contains("<dateCreated>Thu, 01 Jan 2026 00:00:00 GMT</dateCreated>"))
    }
}
