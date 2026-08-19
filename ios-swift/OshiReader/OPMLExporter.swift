import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Builds a portable OPML export of what's being tracked, so it's not
/// locked into OshiReader's own backup format. Watch terms become folders of
/// real, subscribable Google News search-RSS feeds (the same URLs
/// `IngestionService` itself fetches) for every Google-News-backed platform
/// the term is actually scoped to; Ameblo blogs and custom URLs get their
/// own folders since they aren't per-term.
enum OPMLExporter {
    static func export(
        terms: [WatchTerm],
        subscribedPlatforms: [String],
        customUrls: [CustomUrl],
        amebloBlogs: [AmebloBlog],
        generatedAt: String
    ) -> String {
        var body = ""
        let availablePlatforms = Set(subscribedPlatforms)

        for term in terms.filter(\.is_active).sorted(by: { $0.keyword < $1.keyword }) {
            let effective = IngestionService.effectivePlatforms(for: term, available: availablePlatforms)
            let sources = PlatformRegistry.googleNewsSources
                .filter { effective.contains($0.id) }
                .sorted { $0.name < $1.name }
            guard !sources.isEmpty else { continue }

            body += "    <outline text=\"\(xmlEscape(term.keyword))\" title=\"\(xmlEscape(term.keyword))\">\n"
            for source in sources {
                guard let site = source.googleNewsSite,
                      let url = IngestionService.googleNewsURL("\(term.keyword) site:\(site)", locale: source.newsLocale) else { continue }
                body += feedOutline(text: source.name, xmlUrl: url.absoluteString, indent: "      ")
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
            <dateCreated>\(xmlEscape(generatedAt))</dateCreated>
          </head>
          <body>
        \(body)  </body>
        </opml>
        """
    }

    private static func feedOutline(text: String, xmlUrl: String, indent: String) -> String {
        "\(indent)<outline type=\"rss\" text=\"\(xmlEscape(text))\" title=\"\(xmlEscape(text))\" xmlUrl=\"\(xmlEscape(xmlUrl))\"/>\n"
    }

    private static func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
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
