import Foundation

/// The local app's source catalog.  This is deliberately independent from
/// ThemeManager so ingestion, settings, and migrations share the same IDs.
struct PlatformDefinition: Equatable {
    enum NewsLocale: Equatable {
        case japan
        case englishUS

        var acceptLanguage: String {
            switch self {
            case .japan:
                return "ja,en;q=0.9"
            case .englishUS:
                return "en,ko;q=0.9,ja;q=0.7"
            }
        }
    }

    let id: String
    let name: String
    let icon: String
    let googleNewsSite: String?
    let newsLocale: NewsLocale
    let usesStrictKeywordMatching: Bool

    init(
        id: String,
        name: String,
        icon: String,
        googleNewsSite: String? = nil,
        newsLocale: NewsLocale = .japan,
        usesStrictKeywordMatching: Bool = false
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.googleNewsSite = googleNewsSite
        self.newsLocale = newsLocale
        self.usesStrictKeywordMatching = usesStrictKeywordMatching
    }
}

enum PlatformRegistry {
    /// Keep this order stable: it is the default order shown in Settings and
    /// becomes the fallback order when no custom source order is saved.
    static let all: [PlatformDefinition] = [
        PlatformDefinition(id: "youtube", name: "YouTube", icon: "📹"),
        PlatformDefinition(id: "niconico", name: "NicoNico", icon: "💬"),
        PlatformDefinition(id: "tver", name: "TVer", icon: "📺"),
        PlatformDefinition(id: "note", name: "Note", icon: "📝"),
        PlatformDefinition(id: "girlschannel", name: "GirlsChannel", icon: "👭", googleNewsSite: "girlschannel.net", usesStrictKeywordMatching: true),
        PlatformDefinition(id: "5ch", name: "5ch", icon: "💬", googleNewsSite: "5ch.net", usesStrictKeywordMatching: true),
        PlatformDefinition(id: "togetter", name: "Togetter", icon: "🐧", googleNewsSite: "togetter.com", usesStrictKeywordMatching: true),
        PlatformDefinition(id: "news", name: "General News", icon: "📰"),
        PlatformDefinition(id: "yahoonews", name: "YahooNews", icon: "🇯🇵", googleNewsSite: "news.yahoo.co.jp", usesStrictKeywordMatching: true),
        PlatformDefinition(id: "mdpr", name: "ModelPress", icon: "💅", googleNewsSite: "mdpr.jp", usesStrictKeywordMatching: true),
        PlatformDefinition(id: "oricon", name: "Oricon", icon: "🎤", googleNewsSite: "oricon.co.jp", usesStrictKeywordMatching: true),
        PlatformDefinition(id: "twitter", name: "X", icon: "𝕏"),

        // Additional reference sources, implemented locally through the same
        // dated Google News RSS path used by the existing source fallbacks.
        PlatformDefinition(id: "smartnews", name: "SmartNews", icon: "📰", googleNewsSite: "smartnews.com", usesStrictKeywordMatching: true),
        PlatformDefinition(id: "ameblo", name: "Ameblo", icon: "✏️", googleNewsSite: "ameblo.jp", usesStrictKeywordMatching: true),
        PlatformDefinition(id: "aera", name: "AERA dot.", icon: "📝", googleNewsSite: "dot.asahi.com", usesStrictKeywordMatching: true),
        PlatformDefinition(id: "hochi", name: "Hochi", icon: "🏅", googleNewsSite: "hochi.news", usesStrictKeywordMatching: true),
        PlatformDefinition(id: "sponichi", name: "Sponichi", icon: "⚽", googleNewsSite: "sponichi.co.jp", usesStrictKeywordMatching: true),
        PlatformDefinition(id: "livedoor", name: "Livedoor", icon: "🔴", googleNewsSite: "news.livedoor.com", usesStrictKeywordMatching: true),
        PlatformDefinition(id: "mantanweb", name: "Mantan Web", icon: "🎌", googleNewsSite: "mantan-web.jp", usesStrictKeywordMatching: true),
        PlatformDefinition(id: "realsound", name: "Real Sound", icon: "🎧", googleNewsSite: "realsound.jp", usesStrictKeywordMatching: true),
        PlatformDefinition(id: "cinemacafe", name: "CinemaCafe", icon: "🎬", googleNewsSite: "cinemacafe.net", usesStrictKeywordMatching: true),
        PlatformDefinition(id: "thetv", name: "TheTV", icon: "📺", googleNewsSite: "thetv.jp", usesStrictKeywordMatching: true),
        PlatformDefinition(id: "natalie", name: "Natalie", icon: "🎵", googleNewsSite: "natalie.mu", usesStrictKeywordMatching: true),
        PlatformDefinition(id: "billboardjapan", name: "Billboard Japan", icon: "📈", googleNewsSite: "billboard-japan.com", usesStrictKeywordMatching: true),
        PlatformDefinition(id: "soompi", name: "Soompi", icon: "🇰🇷", googleNewsSite: "soompi.com", newsLocale: .englishUS, usesStrictKeywordMatching: true),
        PlatformDefinition(id: "allkpop", name: "allkpop", icon: "🎤", googleNewsSite: "allkpop.com", newsLocale: .englishUS, usesStrictKeywordMatching: true),
        PlatformDefinition(id: "kpopofficial", name: "KpopOfficial", icon: "🗓️", googleNewsSite: "kpopofficial.com", newsLocale: .englishUS, usesStrictKeywordMatching: true),
        PlatformDefinition(id: "barks", name: "BARKS", icon: "🎸", googleNewsSite: "barks.jp", usesStrictKeywordMatching: true),
        PlatformDefinition(id: "custom", name: "Custom Feeds", icon: "🌐")
    ]

    static func definition(for id: String) -> PlatformDefinition? {
        all.first { $0.id == id }
    }

    static var googleNewsSources: [PlatformDefinition] {
        all.filter { $0.googleNewsSite != nil }
    }

    static var defaultSubscribedIDs: [String] {
        [
            "youtube", "niconico", "tver", "note",
            "girlschannel", "5ch", "togetter", "news",
            "yahoonews", "mdpr", "oricon", "twitter", "custom"
        ]
    }

    static var strictKeywordPlatformIDs: Set<String> {
        Set(all.filter(\.usesStrictKeywordMatching).map(\.id))
    }

    static func normalizeIDs(_ ids: [String]) -> [String] {
        let known = Set(all.map(\.id))
        var seen = Set<String>()
        return ids.compactMap { raw in
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard known.contains(id), seen.insert(id).inserted else { return nil }
            return id
        }
    }
}
