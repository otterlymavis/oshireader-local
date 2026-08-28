import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Builds a portable OPML export of what's being tracked, so it's not
/// locked into OshiReader's own backup format. Watch terms become folders of
/// real, subscribable Google News search-RSS feeds (the same URLs
/// `IngestionService` itself fetches, including one per alias) for every
/// platform the term is scoped to whose *primary* source is that same
/// keyword-scoped Google News search; Ameblo blogs and custom URLs get
/// their own folders since they aren't per-term.
enum OPMLExporter {
    /// Platforms whose primary source in `IngestionService` isn't the
    /// keyword-scoped Google News search this exporter otherwise mirrors —
    /// a dedicated RSS feed or per-blog RSS, with Google News used only as
    /// a fallback when that dedicated source fails outright. Exporting the
    /// Google News URL for these unconditionally would misrepresent what
    /// the app actually shows for the term day to day.
    private static let dedicatedSourcePlatformIDs: Set<String> = [
        "ameblo", "natalie", "barks", "aera", "hochi",
        "realsound", "cinemacafe", "billboardjapan", "kpopofficial"
    ]

    static func export(
        terms: [WatchTerm],
        subscribedPlatforms: [String],
        customUrls: [CustomUrl],
        amebloBlogs: [AmebloBlog],
        generatedAt: Date
    ) -> String {
        var body = ""
        let availablePlatforms = Set(subscribedPlatforms)

        for term in terms.filter(\.is_active).sorted(by: { $0.keyword < $1.keyword }) {
            let effective = IngestionService.effectivePlatforms(for: term, available: availablePlatforms)
            let sources = PlatformRegistry.googleNewsSources
                .filter { effective.contains($0.id) && !dedicatedSourcePlatformIDs.contains($0.id) }
                .sorted { $0.name < $1.name }
            guard !sources.isEmpty else { continue }

            // Same keyword + alias set real ingestion searches (see
            // IngestionService.ingestReport), so the exported feeds cover
            // exactly what the live app matches for this term.
            let keywords = IngestionService.searchKeywords(for: term)

            body += "    <outline text=\"\(xmlEscape(term.keyword))\" title=\"\(xmlEscape(term.keyword))\">\n"
            for source in sources {
                guard let site = source.googleNewsSite else { continue }
                for keyword in keywords {
                    guard let url = IngestionService.googleNewsURL("\(keyword) site:\(site)", locale: source.newsLocale) else { continue }
                    let label = keyword == term.keyword ? source.name : "\(source.name) (\(keyword))"
                    body += feedOutline(text: label, xmlUrl: url.absoluteString, indent: "      ")
                }
            }
            body += "    </outline>\n"
        }

        if !amebloBlogs.isEmpty {
            body += "    <outline text=\"Ameblo Blogs\" title=\"Ameblo Blogs\">\n"
            for blog in amebloBlogs.sorted(by: { ($0.title ?? $0.amebaID) < ($1.title ?? $1.amebaID) }) {
                guard let url = blog.rssURL else { continue }
                let label = (blog.title?.isEmpty == false ? blog.title : nil) ?? blog.amebaID
                body += feedOutline(text: label, xmlUrl: url.absoluteString, indent: "      ")
            }
            body += "    </outline>\n"
        }

        if !customUrls.isEmpty {
            body += "    <outline text=\"Custom URLs\" title=\"Custom URLs\">\n"
            for entry in customUrls.sorted(by: { $0.added_at < $1.added_at }) {
                let label = (entry.title?.isEmpty == false ? entry.title : nil) ?? entry.url
                body += "      <outline type=\"link\" text=\"\(xmlEscape(label))\" title=\"\(xmlEscape(label))\" htmlUrl=\"\(xmlEscape(entry.url))\"/>\n"
            }
            body += "    </outline>\n"
        }

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <head>
            <title>OshiReader Export</title>
            <dateCreated>\(xmlEscape(rfc822DateFormatter.string(from: generatedAt)))</dateCreated>
          </head>
          <body>
        \(body)  </body>
        </opml>
        """
    }

    private static func feedOutline(text: String, xmlUrl: String, indent: String) -> String {
        "\(indent)<outline type=\"rss\" text=\"\(xmlEscape(text))\" title=\"\(xmlEscape(text))\" xmlUrl=\"\(xmlEscape(xmlUrl))\"/>\n"
    }

    /// OPML 2.0's `<dateCreated>` requires RFC 822 (the same format RSS
    /// `pubDate` uses) — a plain ISO 8601 string is a spec deviation that
    /// strict readers can fail to parse.
    private static let rfc822DateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()

    private static func xmlEscape(_ value: String) -> String {
        let entitiesEscaped = value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
        // Drop characters XML 1.0 forbids even as entities — C0 controls other
        // than tab / LF / CR. A keyword or custom-URL title carrying one would
        // otherwise produce an OPML file strict parsers reject outright.
        return String(entitiesEscaped.unicodeScalars.filter { scalar in
            scalar == "\t" || scalar == "\n" || scalar == "\r" || scalar.value >= 0x20
        })
    }
}

extension UTType {
    static var opml: UTType {
        UTType(filenameExtension: "opml", conformingTo: .xml) ?? .xml
    }
}

struct OPMLDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.opml, .xml] }
    static var writableContentTypes: [UTType] { [.opml] }

    var text: String

    init(text: String = "") {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
