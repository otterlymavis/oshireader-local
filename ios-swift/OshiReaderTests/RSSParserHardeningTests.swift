import Foundation
import XCTest
@testable import OshiReader

final class RSSParserDelegateTests: XCTestCase {
    private func parse(_ xml: String, sourceURL: URL? = nil) -> [RssItem] {
        let delegate = RSSParserDelegate(sourceURL: sourceURL)
        let parser = XMLParser(data: Data(xml.utf8))
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        parser.parse()
        return delegate.items
    }

    func testParsesBasicRssItem() {
        let xml = """
        <?xml version="1.0"?><rss version="2.0"><channel>
        <item>
            <title>Hello World</title>
            <link>https://example.com/hello</link>
            <description>A test article</description>
            <pubDate>Mon, 01 Jan 2024 12:00:00 +0000</pubDate>
        </item>
        </channel></rss>
        """
        let items = parse(xml)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "Hello World")
        XCTAssertEqual(items[0].link, "https://example.com/hello")
        XCTAssertEqual(items[0].description, "A test article")
        XCTAssertNotNil(items[0].pubDate)
    }

    func testParsesRssFieldsWrappedInCDATA() {
        let xml = """
        <?xml version="1.0"?><rss version="2.0"><channel>
        <item>
            <title><![CDATA[Aiko & Friends]]></title>
            <link><![CDATA[https://example.com/aiko?from=rss&lang=ja]]></link>
            <description><![CDATA[Concert announcement & ticket details]]></description>
            <pubDate><![CDATA[Mon, 01 Jan 2024 12:00:00 +0000]]></pubDate>
        </item>
        </channel></rss>
        """

        let items = parse(xml)

        XCTAssertEqual(items.first?.title, "Aiko & Friends")
        XCTAssertEqual(items.first?.link, "https://example.com/aiko?from=rss&lang=ja")
        XCTAssertEqual(items.first?.description, "Concert announcement & ticket details")
        XCTAssertEqual(items.first?.pubDate, "2024-01-01T12:00:00Z")
    }

    func testUsesPermalinkGuidWhenRssLinkIsMissing() {
        let xml = """
        <?xml version="1.0"?><rss version="2.0"><channel>
        <item>
            <title>GUID permalink</title>
            <guid>https://example.com/articles/guid-only</guid>
        </item>
        </channel></rss>
        """

        let items = parse(xml)

        XCTAssertEqual(items.first?.link, "https://example.com/articles/guid-only")
    }

    func testDoesNotUseNonPermalinkGuidAsRssLink() {
        let xml = """
        <?xml version="1.0"?><rss version="2.0"><channel>
        <item>
            <title>Opaque GUID</title>
            <guid isPermaLink="false">article-123</guid>
        </item>
        </channel></rss>
        """

        let items = parse(xml)

        XCTAssertEqual(items.first?.link, "")
    }

    func testParsesMediaThumbnailAttribute() {
        let xml = """
        <?xml version="1.0"?><rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/"><channel>
        <item>
            <title>Media Item</title>
            <link>https://example.com/media</link>
            <media:thumbnail url="https://example.com/thumb.jpg"/>
        </item>
        </channel></rss>
        """
        let items = parse(xml)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].thumbnailUrl, "https://example.com/thumb.jpg")
    }

    func testMediaMetadataDoesNotOverwriteCanonicalRssFields() {
        let xml = """
        <?xml version="1.0"?>
        <rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/">
          <channel><item>
            <title>Canonical title</title>
            <media:title>Media title</media:title>
            <link>https://example.com/canonical</link>
            <description>Canonical description</description>
            <media:description>Media description</media:description>
          </item></channel>
        </rss>
        """

        let items = parse(xml)

        XCTAssertEqual(items.first?.title, "Canonical title")
        XCTAssertEqual(items.first?.description, "Canonical description")
    }

    func testExplicitVideoMediaContentIsNotUsedAsThumbnail() {
        let xml = """
        <?xml version="1.0"?>
        <rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/">
          <channel><item>
            <title>Video content</title>
            <link>https://example.com/video</link>
            <media:content url="https://example.com/video.mp4" medium="video" type="video/mp4"/>
          </item></channel>
        </rss>
        """

        let items = parse(xml)

        XCTAssertNil(items.first?.thumbnailUrl)
    }

    func testImageMediaContentIsUsedAsThumbnail() {
        let xml = """
        <?xml version="1.0"?>
        <rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/">
          <channel><item>
            <title>Image content</title>
            <link>https://example.com/image</link>
            <media:content url=" https://example.com/image.jpg " medium="image" type="image/jpeg"/>
          </item></channel>
        </rss>
        """

        let items = parse(xml)

        XCTAssertEqual(items.first?.thumbnailUrl, "https://example.com/image.jpg")
    }

    func testDedicatedMediaThumbnailOverridesEarlierImageContent() {
        let xml = """
        <?xml version="1.0"?>
        <rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/">
          <channel><item>
            <title>Preferred thumbnail</title>
            <link>https://example.com/preferred-thumbnail</link>
            <media:content url="https://example.com/full-size.jpg" medium="image" type="image/jpeg"/>
            <media:thumbnail url="https://example.com/thumbnail.jpg"/>
          </item></channel>
        </rss>
        """

        let items = parse(xml)

        XCTAssertEqual(items.first?.thumbnailUrl, "https://example.com/thumbnail.jpg")
    }

    func testEarlierDedicatedThumbnailIsNotOverwrittenByImageContent() {
        let xml = """
        <?xml version="1.0"?>
        <rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/">
          <channel><item>
            <title>Stable thumbnail</title>
            <link>https://example.com/stable-thumbnail</link>
            <media:thumbnail url="https://example.com/thumbnail.jpg"/>
            <media:content url="https://example.com/full-size.jpg" medium="image" type="image/jpeg"/>
          </item></channel>
        </rss>
        """

        let items = parse(xml)

        XCTAssertEqual(items.first?.thumbnailUrl, "https://example.com/thumbnail.jpg")
    }

    func testInvalidDedicatedThumbnailDoesNotSuppressValidImageFallback() {
        let xml = """
        <?xml version="1.0"?>
        <rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/">
          <channel><item>
            <title>Invalid preferred thumbnail</title>
            <link>https://example.com/invalid-preferred-thumbnail</link>
            <media:content url="https://example.com/fallback.jpg" medium="image" type="image/jpeg"/>
            <media:thumbnail url="data:image/png;base64,AAAA"/>
          </item></channel>
        </rss>
        """

        let items = parse(xml)

        XCTAssertEqual(items.first?.thumbnailUrl, "https://example.com/fallback.jpg")
    }

    func testUnsafeAndHostlessThumbnailURLsAreRejected() {
        let xml = """
        <?xml version="1.0"?>
        <rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/">
          <channel>
            <item>
              <title>Unsafe thumbnail</title>
              <link>https://example.com/unsafe-thumbnail</link>
              <media:thumbnail url="data:image/png;base64,AAAA"/>
            </item>
            <item>
              <title>Hostless thumbnail</title>
              <link>https://example.com/hostless-thumbnail</link>
              <media:thumbnail url="/images/relative.jpg"/>
            </item>
          </channel>
        </rss>
        """

        let items = parse(xml)

        XCTAssertEqual(items.count, 2)
        XCTAssertNil(items[0].thumbnailUrl)
        XCTAssertNil(items[1].thumbnailUrl)
    }

    func testRelativeEntryAndThumbnailURLsResolveAgainstFeedURL() throws {
        let xml = """
        <?xml version="1.0"?>
        <feed xmlns="http://www.w3.org/2005/Atom" xmlns:media="http://search.yahoo.com/mrss/">
          <entry>
            <title>Relative URLs</title>
            <link href="../articles/relative"/>
            <media:thumbnail url="//cdn.example.com/images/relative.jpg"/>
          </entry>
        </feed>
        """

        let sourceURL = try XCTUnwrap(URL(string: "https://feeds.example.com/news/latest.xml"))
        let items = parse(xml, sourceURL: sourceURL)

        XCTAssertEqual(items.first?.link, "https://feeds.example.com/articles/relative")
        XCTAssertEqual(items.first?.thumbnailUrl, "https://cdn.example.com/images/relative.jpg")
    }

    func testNestedXMLBaseOverridesFeedRequestURL() throws {
        let xml = """
        <?xml version="1.0"?>
        <feed xmlns="http://www.w3.org/2005/Atom" xml:base="https://content.example.com/root/">
          <entry xml:base="articles/">
            <title>Scoped base URL</title>
            <link href="story-1"/>
            <media:thumbnail xmlns:media="http://search.yahoo.com/mrss/"
                             xml:base="../images/"
                             url="thumb.jpg"/>
            <link rel="enclosure" xml:base="https://media.example.com/" href="video.mp4"/>
          </entry>
        </feed>
        """

        let sourceURL = try XCTUnwrap(URL(string: "https://feeds.example.com/latest.xml"))
        let items = parse(xml, sourceURL: sourceURL)

        XCTAssertEqual(items.first?.link, "https://content.example.com/root/articles/story-1")
        XCTAssertEqual(items.first?.thumbnailUrl, "https://content.example.com/root/images/thumb.jpg")
    }

    func testParsesEnclosureImageAttribute() {
        let xml = """
        <?xml version="1.0"?><rss version="2.0"><channel>
        <item>
            <title>Enclosure Item</title>
            <link>https://example.com/enc</link>
            <enclosure url="https://example.com/img.png" type=" IMAGE/PNG "/>
        </item>
        </channel></rss>
        """
        let items = parse(xml)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].thumbnailUrl, "https://example.com/img.png")
    }

    func testEnclosureNonImageIgnored() {
        let xml = """
        <?xml version="1.0"?><rss version="2.0"><channel>
        <item>
            <title>Audio Item</title>
            <link>https://example.com/audio</link>
            <enclosure url="https://example.com/audio.mp3" type="audio/mpeg"/>
        </item>
        </channel></rss>
        """
        let items = parse(xml)
        XCTAssertEqual(items.count, 1)
        XCTAssertNil(items[0].thumbnailUrl)
    }

    func testParsesAtomEntryElement() {
        let xml = """
        <?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom">
        <entry>
            <title>Atom Entry</title>
            <link href="https://example.com/atom"/>
            <summary>Atom summary</summary>
            <published>2024-06-01T10:00:00Z</published>
        </entry>
        </feed>
        """
        let items = parse(xml)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "Atom Entry")
        XCTAssertEqual(items[0].link, "https://example.com/atom")
    }

    func testParsesExplicitlyPrefixedAtomFeed() {
        let xml = """
        <?xml version="1.0"?>
        <atom:feed xmlns:atom="http://www.w3.org/2005/Atom">
          <atom:entry>
            <atom:title>Prefixed Atom Entry</atom:title>
            <atom:link rel="alternate" href="https://example.com/prefixed"/>
            <atom:summary>Prefixed summary</atom:summary>
            <atom:updated>2024-06-03T12:00:00Z</atom:updated>
          </atom:entry>
        </atom:feed>
        """

        let items = parse(xml)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.title, "Prefixed Atom Entry")
        XCTAssertEqual(items.first?.link, "https://example.com/prefixed")
        XCTAssertEqual(items.first?.description, "Prefixed summary")
        XCTAssertEqual(items.first?.pubDate, "2024-06-03T12:00:00Z")
    }

    func testParsesAtomFeedWithArbitraryNamespacePrefix() {
        let xml = """
        <?xml version="1.0"?>
        <a:feed xmlns:a="http://www.w3.org/2005/Atom">
          <a:entry>
            <a:title>Aliased Atom Entry</a:title>
            <a:link href="https://example.com/aliased"/>
            <a:summary>Aliased summary</a:summary>
          </a:entry>
        </a:feed>
        """

        let items = parse(xml)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.title, "Aliased Atom Entry")
        XCTAssertEqual(items.first?.link, "https://example.com/aliased")
        XCTAssertEqual(items.first?.description, "Aliased summary")
    }

    func testParsesMediaThumbnailWithArbitraryNamespacePrefix() {
        let xml = """
        <?xml version="1.0"?>
        <rss version="2.0" xmlns:m="http://search.yahoo.com/mrss/">
          <channel><item>
            <title>Media alias</title>
            <link>https://example.com/media-alias</link>
            <m:thumbnail url="https://example.com/media-alias.jpg"/>
          </item></channel>
        </rss>
        """

        let items = parse(xml)

        XCTAssertEqual(items.first?.thumbnailUrl, "https://example.com/media-alias.jpg")
    }

    func testRecognizesRssOneRdfRootAndUsesAboutLink() {
        let xml = """
        <?xml version="1.0"?>
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns="http://purl.org/rss/1.0/">
          <item rdf:about="https://example.com/rss-one-item">
            <title>RSS 1.0 item</title>
            <description>RDF-backed article</description>
          </item>
        </rdf:RDF>
        """
        let delegate = RSSParserDelegate()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate

        XCTAssertTrue(parser.parse())
        XCTAssertTrue(delegate.recognizedFeedRoot)
        XCTAssertEqual(delegate.items.first?.link, "https://example.com/rss-one-item")
    }

    func testUsesNamespacedEncodedContentWhenDescriptionIsMissing() {
        let xml = """
        <?xml version="1.0"?>
        <rss version="2.0" xmlns:wpcontent="http://purl.org/rss/1.0/modules/content/">
          <channel><item>
            <title>WordPress article</title>
            <link>https://example.com/wordpress</link>
            <wpcontent:encoded><![CDATA[Full article body]]></wpcontent:encoded>
          </item></channel>
        </rss>
        """

        let items = parse(xml)

        XCTAssertEqual(items.first?.description, "Full article body")
    }

    func testAtomEntryPrefersAlternateLinkOverSelfLink() {
        let xml = """
        <?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom">
        <entry>
            <title>Atom Entry</title>
            <link rel="self" href="https://example.com/feed/entry/1"/>
            <link rel="alternate" href="https://example.com/articles/1"/>
        </entry>
        </feed>
        """

        let items = parse(xml)

        XCTAssertEqual(items.first?.link, "https://example.com/articles/1")
    }

    func testUnsafeAlternateLinkDoesNotSuppressValidAtomSelfLink() {
        let xml = """
        <?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom">
        <entry>
            <title>Atom Entry</title>
            <link rel="self" href="https://example.com/feed/entry/1"/>
            <link rel="alternate" href="javascript:alert(1)"/>
        </entry>
        </feed>
        """

        let items = parse(xml)

        XCTAssertEqual(items.first?.link, "https://example.com/feed/entry/1")
    }

    func testAtomEntryDoesNotUseEnclosureAsArticleLink() {
        let xml = """
        <?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom">
        <entry>
            <title>Atom Entry</title>
            <link rel="enclosure" href="https://example.com/audio.mp3"/>
        </entry>
        </feed>
        """

        let items = parse(xml)

        XCTAssertEqual(items.first?.link, "")
    }

    func testAtomContentIsUsedWhenSummaryIsAbsent() {
        let xml = """
        <?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom">
        <entry>
            <title>Atom Content</title>
            <link href="https://example.com/content"/>
            <content type="xhtml"><div><p>Full <strong>entry</strong> text</p></div></content>
        </entry>
        </feed>
        """

        let items = parse(xml)

        XCTAssertEqual(items.first?.description, "Full entry text")
    }

    func testAtomSummaryTakesPrecedenceWithoutDuplicatingContent() {
        let xml = """
        <?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom">
        <entry>
            <title>Atom Summary</title>
            <link href="https://example.com/summary"/>
            <summary>Concise summary</summary>
            <content>Concise summary followed by the full article body</content>
        </entry>
        </feed>
        """

        let items = parse(xml)

        XCTAssertEqual(items.first?.description, "Concise summary")
    }

    func testNestedAtomBodyMetadataDoesNotOverwriteEntryTitleOrLink() {
        let xml = """
        <?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom">
        <entry>
            <title>Canonical title</title>
            <link href="https://example.com/canonical"/>
            <content type="xhtml">
                <div>
                    <title>Embedded document title</title>
                    <link href="https://example.com/embedded-stylesheet"/>
                    <p>Body text</p>
                </div>
            </content>
        </entry>
        </feed>
        """

        let items = parse(xml)

        XCTAssertEqual(items.first?.title, "Canonical title")
        XCTAssertEqual(items.first?.link, "https://example.com/canonical")
        XCTAssertEqual(items.first?.description, "Embedded document title Body text")
    }

    func testNestedEntryElementDoesNotResetOrPrematurelyFinishOuterAtomEntry() {
        let xml = """
        <?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom">
        <entry>
            <title>Canonical title</title>
            <link href="https://example.com/canonical"/>
            <content type="xhtml">
                <div><entry><title>Nested title</title></entry> <p>Body tail</p></div>
            </content>
        </entry>
        </feed>
        """

        let items = parse(xml)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.title, "Canonical title")
        XCTAssertEqual(items.first?.link, "https://example.com/canonical")
        XCTAssertEqual(items.first?.description, "Nested title Body tail")
    }

    func testUndatedEntryLeavesDateNilForCallerFallback() {
        let xml = """
        <?xml version="1.0"?><rss version="2.0"><channel>
        <item><title>Undated item</title><link>https://example.com/undated</link></item>
        </channel></rss>
        """

        let items = parse(xml)

        XCTAssertNil(items.first?.pubDate)
    }

    func testInvalidEntryDateLeavesDateNilForCallerFallback() {
        let xml = """
        <?xml version="1.0"?><rss version="2.0"><channel>
        <item>
            <title>Invalid date item</title>
            <link>https://example.com/invalid-date</link>
            <pubDate>not a real date</pubDate>
        </item>
        </channel></rss>
        """

        let items = parse(xml)

        XCTAssertNil(items.first?.pubDate)
    }

    func testParsesDateOnlyDublinCoreDate() {
        let xml = """
        <?xml version="1.0"?><rss version="2.0" xmlns:dc="http://purl.org/dc/elements/1.1/"><channel>
        <item>
            <title>Date-only item</title>
            <link>https://example.com/date-only</link>
            <dc:date>2024-06-01</dc:date>
        </item>
        </channel></rss>
        """

        let items = parse(xml)

        XCTAssertEqual(items.first?.pubDate, "2024-06-01T00:00:00Z")
    }

    func testParsesRfc822DateWithoutSeconds() {
        let xml = """
        <?xml version="1.0"?><rss version="2.0"><channel>
        <item>
            <title>Minute precision</title>
            <link>https://example.com/minute</link>
            <pubDate>Mon, 01 Jan 2024 12:34 +0000</pubDate>
        </item>
        </channel></rss>
        """

        let items = parse(xml)

        XCTAssertEqual(items.first?.pubDate, "2024-01-01T12:34:00Z")
    }

    func testParsesRfc822DateWithNamedTimeZone() {
        let xml = """
        <?xml version="1.0"?><rss version="2.0"><channel>
        <item>
            <title>Named time zone</title>
            <link>https://example.com/named-zone</link>
            <pubDate>Mon, 01 Jan 2024 12:00:00 PST</pubDate>
        </item>
        </channel></rss>
        """

        let items = parse(xml)

        XCTAssertEqual(items.first?.pubDate, "2024-01-01T20:00:00Z")
    }

    func testParsesRfc822TwoDigitYearInModernWindow() {
        let xml = """
        <?xml version="1.0"?><rss version="2.0"><channel>
        <item>
            <title>Two-digit year</title>
            <link>https://example.com/two-digit-year</link>
            <pubDate>Mon, 01 Jan 24 12:00:00 +0000</pubDate>
        </item>
        </channel></rss>
        """

        let items = parse(xml)

        XCTAssertEqual(items.first?.pubDate, "2024-01-01T12:00:00Z")
    }

    func testParsesRfc822DateWithoutWeekday() {
        let xml = """
        <?xml version="1.0"?><rss version="2.0"><channel>
        <item>
            <title>No weekday</title>
            <link>https://example.com/no-weekday</link>
            <pubDate>01 Jan 2024 12:34:56 +0000</pubDate>
        </item>
        </channel></rss>
        """

        let items = parse(xml)

        XCTAssertEqual(items.first?.pubDate, "2024-01-01T12:34:56Z")
    }

    func testAtomUpdatedDateAndNestedSummaryAreParsed() {
        let xml = """
        <?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom">
        <entry>
            <title>Atom Entry</title>
            <link href="https://example.com/atom"/>
            <summary><p>Nested <strong>summary</strong> text</p></summary>
            <updated>2024-06-01T10:00:00Z</updated>
        </entry>
        </feed>
        """

        let items = parse(xml)

        XCTAssertEqual(items.first?.description, "Nested summary text")
        XCTAssertEqual(items.first?.pubDate, "2024-06-01T10:00:00Z")
    }

    func testAtomPublishedAndUpdatedDatesUseNewestValidTimestamp() {
        let xml = """
        <?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom">
        <entry>
            <title>Updated Atom Entry</title>
            <link href="https://example.com/updated-atom"/>
            <published>2024-06-01T10:00:00Z</published>
            <updated>2024-06-02T11:30:00Z</updated>
        </entry>
        </feed>
        """

        let items = parse(xml)

        XCTAssertEqual(items.first?.pubDate, "2024-06-02T11:30:00Z")
    }

    func testParsesMultipleItems() {
        let xml = """
        <?xml version="1.0"?><rss version="2.0"><channel>
        <item><title>A</title><link>https://a.com</link></item>
        <item><title>B</title><link>https://b.com</link></item>
        <item><title>C</title><link>https://c.com</link></item>
        </channel></rss>
        """
        let items = parse(xml)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items.map { $0.title }, ["A", "B", "C"])
    }

    func testEmptyFeedReturnsNoItems() {
        let xml = #"<?xml version="1.0"?><rss version="2.0"><channel></channel></rss>"#
        XCTAssertTrue(parse(xml).isEmpty)
    }
}
