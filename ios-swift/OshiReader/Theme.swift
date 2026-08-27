import SwiftUI

enum AppThemeMode: String, Codable, CaseIterable {
    case light = "light"
    case dark = "dark"
    case sepia = "sepia"
}

enum AppColorStyle: String, CaseIterable, Identifiable {
    case colourful = "colourful"
    case standard = "standard"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .colourful: return "Colourful"
        case .standard: return "Standard"
        }
    }
}

enum AppFontChoice: String, CaseIterable, Identifiable {
    case normal = "normal"
    case playful = "comic_sans"
    case serif = "serif"

    static var comicSans: AppFontChoice { .playful }

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .normal: return "Normal"
        case .playful: return "Playful"
        case .serif: return "Serif"
        }
    }

    var cssFamily: String {
        switch self {
        case .normal:
            return "-apple-system, BlinkMacSystemFont, \"Helvetica Neue\", Arial, sans-serif"
        case .playful:
            return "\"Chalkboard SE\", \"Marker Felt\", \"Comic Sans MS\", cursive"
        case .serif:
            return "Georgia, \"Times New Roman\", serif"
        }
    }
}

enum AppFontSizeChoice: String, CaseIterable, Identifiable {
    case normal = "normal"
    case large = "large"
    case extraLarge = "extra_large"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .normal: return "Normal"
        case .large: return "Large"
        case .extraLarge: return "Extra Large"
        }
    }

    var scale: CGFloat {
        switch self {
        case .normal: return 1.0
        case .large: return 1.15
        case .extraLarge: return 1.3
        }
    }
}

struct AppColors {
    let mode: AppThemeMode
    
    var bg: Color {
        switch mode {
        case .light: return Color(red: 0.98, green: 0.98, blue: 1.0)
        case .dark:  return Color(red: 0.08, green: 0.08, blue: 0.1)
        case .sepia: return Color(red: 0.96, green: 0.93, blue: 0.86)
        }
    }
    
    var card: Color {
        switch mode {
        case .light: return Color.white
        case .dark:  return Color(red: 0.12, green: 0.12, blue: 0.15)
        case .sepia: return Color(red: 0.98, green: 0.96, blue: 0.91)
        }
    }
    
    var text: Color {
        switch mode {
        case .light: return Color(red: 0.1, green: 0.1, blue: 0.15)
        case .dark:  return Color(red: 0.95, green: 0.95, blue: 0.98)
        case .sepia: return Color(red: 0.22, green: 0.15, blue: 0.05)
        }
    }
    
    var textSub: Color {
        switch mode {
        case .light: return Color(red: 0.35, green: 0.35, blue: 0.45)
        case .dark:  return Color(red: 0.7, green: 0.7, blue: 0.78)
        case .sepia: return Color(red: 0.4, green: 0.3, blue: 0.15)
        }
    }
    
    var textMuted: Color {
        switch mode {
        case .light: return Color(red: 0.55, green: 0.55, blue: 0.65)
        case .dark:  return Color(red: 0.5, green: 0.5, blue: 0.58)
        case .sepia: return Color(red: 0.55, green: 0.48, blue: 0.38)
        }
    }
    
    var primary: Color {
        switch mode {
        case .light: return Color(red: 0.72, green: 0.52, blue: 0.65) // Opera mauve (#B784A7)
        case .dark:  return Color(red: 0.82, green: 0.64, blue: 0.76) // Light opera mauve
        case .sepia: return Color(red: 0.58, green: 0.35, blue: 0.0)  // Golden brown
        }
    }
    
    var primaryBg: Color {
        switch mode {
        case .light: return Color(red: 0.98, green: 0.93, blue: 0.96)
        case .dark:  return Color(red: 0.28, green: 0.18, blue: 0.24)
        case .sepia: return Color(red: 0.93, green: 0.88, blue: 0.78)
        }
    }
    
    var border: Color {
        switch mode {
        case .light: return Color(red: 0.9, green: 0.9, blue: 0.95)
        case .dark:  return Color(red: 0.2, green: 0.2, blue: 0.25)
        case .sepia: return Color(red: 0.88, green: 0.84, blue: 0.76)
        }
    }
    
    var divider: Color {
        switch mode {
        case .light: return Color(red: 0.93, green: 0.93, blue: 0.96)
        case .dark:  return Color(red: 0.16, green: 0.16, blue: 0.2)
        case .sepia: return Color(red: 0.9, green: 0.86, blue: 0.78)
        }
    }
    
    var accentGreen: Color {
        return Color(red: 0.13, green: 0.77, blue: 0.37) // #22C55E
    }
}

struct PlatformMetadata {
    let name: String
    let icon: String
    let accent: Color
    let bg: Color
    let fg: Color
}

class ThemeManager: ObservableObject {
    private var profileID: UUID?

    @Published var mode: AppThemeMode = .light {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: storageKey("app_theme_mode")) }
    }

    @Published var style: AppColorStyle {
        didSet { UserDefaults.standard.set(style.rawValue, forKey: storageKey("app_color_style")) }
    }
    
    static let shared = ThemeManager()

    private init() {
        let activeProfileID = LocalProfileStore.shared.activeProfileID
        self.profileID = activeProfileID
        let storedMode = UserDefaults.standard.string(forKey: LocalProfileStore.defaultsKey("app_theme_mode", profileID: activeProfileID)) ?? AppThemeMode.light.rawValue
        self.mode = AppThemeMode(rawValue: storedMode) ?? .light
        let storedStyle = UserDefaults.standard.string(forKey: LocalProfileStore.defaultsKey("app_color_style", profileID: activeProfileID)) ?? AppColorStyle.colourful.rawValue
        self.style = AppColorStyle(rawValue: storedStyle) ?? .colourful
    }

    @MainActor
    func configure(profileID: UUID) {
        self.profileID = profileID
        let storedMode = UserDefaults.standard.string(forKey: storageKey("app_theme_mode")) ?? AppThemeMode.light.rawValue
        let storedStyle = UserDefaults.standard.string(forKey: storageKey("app_color_style")) ?? AppColorStyle.colourful.rawValue
        mode = AppThemeMode(rawValue: storedMode) ?? .light
        style = AppColorStyle(rawValue: storedStyle) ?? .colourful
    }

    private func storageKey(_ key: String) -> String {
        guard let profileID else { return key }
        return LocalProfileStore.defaultsKey(key, profileID: profileID)
    }
    
    var colors: AppColors {
        return AppColors(mode: mode)
    }

    var standardBadgeBg: Color {
        switch mode {
        case .light: return Color(red: 0.95, green: 0.94, blue: 0.98)
        case .dark: return Color(red: 0.19, green: 0.18, blue: 0.24)
        case .sepia: return Color(red: 0.93, green: 0.88, blue: 0.78)
        }
    }

    var standardBadgeFg: Color {
        switch mode {
        case .light: return Color(red: 0.28, green: 0.25, blue: 0.36)
        case .dark: return Color(red: 0.83, green: 0.82, blue: 0.9)
        case .sepia: return Color(red: 0.35, green: 0.25, blue: 0.12)
        }
    }
    
    /// `metadata(for:)` is called for every visible feed / saved card and
    /// platform chip on each render. The result depends only on `(mode,
    /// normalized platform)`, so memoize it — bounded at 3 modes × the
    /// platform catalog. Unknown raw platforms produce a per-input name and
    /// are computed fresh (not cached).
    private static let metadataCacheLock = NSLock()
    private static var metadataCache: [AppThemeMode: [String: PlatformMetadata]] = [:]

    func metadata(for platform: String) -> PlatformMetadata {
        let normalizedPlatform = PlatformRegistry.normalizeID(platform)
        guard PlatformRegistry.definition(for: normalizedPlatform) != nil else {
            return uncachedMetadata(for: platform, normalizedPlatform: normalizedPlatform)
        }
        Self.metadataCacheLock.lock()
        if let cached = Self.metadataCache[mode]?[normalizedPlatform] {
            Self.metadataCacheLock.unlock()
            return cached
        }
        Self.metadataCacheLock.unlock()
        let result = uncachedMetadata(for: platform, normalizedPlatform: normalizedPlatform)
        Self.metadataCacheLock.lock()
        Self.metadataCache[mode, default: [:]][normalizedPlatform] = result
        Self.metadataCacheLock.unlock()
        return result
    }

    private func uncachedMetadata(for platform: String, normalizedPlatform: String) -> PlatformMetadata {
        switch normalizedPlatform {
        case "youtube":
            return PlatformMetadata(name: "YouTube", icon: "📹", accent: Color.red, bg: Color(red: 1.0, green: 0.9, blue: 0.9), fg: Color.red)
        case "tver":
            return PlatformMetadata(name: "TVer", icon: "📺", accent: Color.blue, bg: Color(red: 0.9, green: 0.95, blue: 1.0), fg: Color.blue)
        case "niconico":
            return PlatformMetadata(name: "NicoNico", icon: "💬", accent: Color.black, bg: Color.gray.opacity(0.2), fg: Color.primary)
        case "yahoonews":
            return PlatformMetadata(name: "YahooNews", icon: "🇯🇵", accent: Color(red: 0.86, green: 0.0, blue: 0.0), bg: Color(red: 1.0, green: 0.92, blue: 0.92), fg: Color(red: 0.86, green: 0.0, blue: 0.0))
        case "mdpr":
            return PlatformMetadata(name: "ModelPress", icon: "💅", accent: Color.pink, bg: Color(red: 1.0, green: 0.9, blue: 0.95), fg: Color.pink)
        case "oricon":
            return PlatformMetadata(name: "Oricon", icon: "🎤", accent: Color(red: 0.86, green: 0.12, blue: 0.22), bg: Color(red: 1.0, green: 0.92, blue: 0.94), fg: Color(red: 0.86, green: 0.12, blue: 0.22))
        case "twitter":
            return PlatformMetadata(name: "X", icon: "𝕏", accent: Color.black, bg: Color.gray.opacity(0.2), fg: Color.primary)
        case "5ch":
            return PlatformMetadata(name: "5ch", icon: "💬", accent: Color.orange, bg: Color(red: 1.0, green: 0.95, blue: 0.9), fg: Color.orange)
        case "girlschannel":
            return PlatformMetadata(name: "GirlsChannel", icon: "👭", accent: Color.pink, bg: Color(red: 1.0, green: 0.92, blue: 0.95), fg: Color.pink)
        case "note":
            return PlatformMetadata(name: "Note", icon: "📝", accent: Color(red: 0.1, green: 0.7, blue: 0.5), bg: Color(red: 0.9, green: 0.97, blue: 0.95), fg: Color(red: 0.1, green: 0.7, blue: 0.5))
        case "news":
            return PlatformMetadata(name: "News", icon: "📰", accent: Color.purple, bg: Color(red: 0.96, green: 0.9, blue: 1.0), fg: Color.purple)
        case "smartnews":
            return PlatformMetadata(name: "SmartNews", icon: "📰", accent: Color(red: 0.80, green: 0.00, blue: 0.00), bg: Color(red: 1.0, green: 0.92, blue: 0.92), fg: Color(red: 0.80, green: 0.00, blue: 0.00))
        case "ameblo":
            return PlatformMetadata(name: "Ameblo", icon: "✏️", accent: Color(red: 1.00, green: 0.42, blue: 0.00), bg: Color(red: 1.0, green: 0.94, blue: 0.88), fg: Color(red: 1.00, green: 0.42, blue: 0.00))
        case "aera":
            return PlatformMetadata(name: "AERA dot.", icon: "📝", accent: Color(red: 0.00, green: 0.27, blue: 0.58), bg: Color(red: 0.90, green: 0.94, blue: 1.0), fg: Color(red: 0.00, green: 0.27, blue: 0.58))
        case "hochi":
            return PlatformMetadata(name: "Hochi", icon: "🏅", accent: Color(red: 0.82, green: 0.10, blue: 0.10), bg: Color(red: 1.0, green: 0.92, blue: 0.92), fg: Color(red: 0.82, green: 0.10, blue: 0.10))
        case "sponichi":
            return PlatformMetadata(name: "Sponichi", icon: "⚽", accent: Color(red: 0.00, green: 0.27, blue: 0.60), bg: Color(red: 0.90, green: 0.94, blue: 1.0), fg: Color(red: 0.00, green: 0.27, blue: 0.60))
        case "livedoor":
            return PlatformMetadata(name: "Livedoor", icon: "🔴", accent: Color(red: 0.88, green: 0.00, blue: 0.20), bg: Color(red: 1.0, green: 0.92, blue: 0.94), fg: Color(red: 0.88, green: 0.00, blue: 0.20))
        case "mantanweb":
            return PlatformMetadata(name: "Mantan Web", icon: "🎌", accent: Color(red: 0.07, green: 0.53, blue: 0.25), bg: Color(red: 0.90, green: 1.0, blue: 0.93), fg: Color(red: 0.07, green: 0.53, blue: 0.25))
        case "realsound":
            return PlatformMetadata(name: "Real Sound", icon: "🎧", accent: Color(red: 0.18, green: 0.36, blue: 0.72), bg: Color(red: 0.91, green: 0.95, blue: 1.0), fg: Color(red: 0.18, green: 0.36, blue: 0.72))
        case "cinemacafe":
            return PlatformMetadata(name: "CinemaCafe", icon: "🎬", accent: Color(red: 0.56, green: 0.20, blue: 0.64), bg: Color(red: 0.96, green: 0.91, blue: 0.98), fg: Color(red: 0.56, green: 0.20, blue: 0.64))
        case "thetv":
            return PlatformMetadata(name: "TheTV", icon: "📺", accent: Color(red: 0.02, green: 0.36, blue: 0.78), bg: Color(red: 0.90, green: 0.95, blue: 1.0), fg: Color(red: 0.02, green: 0.36, blue: 0.78))
        case "natalie":
            return PlatformMetadata(name: "Natalie", icon: "🎵", accent: Color(red: 0.86, green: 0.14, blue: 0.22), bg: Color(red: 1.0, green: 0.92, blue: 0.94), fg: Color(red: 0.86, green: 0.14, blue: 0.22))
        case "billboardjapan":
            return PlatformMetadata(name: "Billboard Japan", icon: "📈", accent: Color(red: 0.05, green: 0.38, blue: 0.72), bg: Color(red: 0.90, green: 0.95, blue: 1.0), fg: Color(red: 0.05, green: 0.38, blue: 0.72))
        case "soompi":
            return PlatformMetadata(name: "Soompi", icon: "🇰🇷", accent: Color(red: 0.74, green: 0.16, blue: 0.30), bg: Color(red: 1.0, green: 0.92, blue: 0.95), fg: Color(red: 0.74, green: 0.16, blue: 0.30))
        case "allkpop":
            return PlatformMetadata(name: "allkpop", icon: "🎤", accent: Color(red: 0.48, green: 0.24, blue: 0.70), bg: Color(red: 0.96, green: 0.92, blue: 1.0), fg: Color(red: 0.48, green: 0.24, blue: 0.70))
        case "kpopofficial":
            return PlatformMetadata(name: "KpopOfficial", icon: "🗓️", accent: Color(red: 0.04, green: 0.52, blue: 0.54), bg: Color(red: 0.90, green: 0.98, blue: 0.98), fg: Color(red: 0.04, green: 0.52, blue: 0.54))
        case "barks":
            return PlatformMetadata(name: "BARKS", icon: "🎸", accent: Color(red: 0.13, green: 0.13, blue: 0.13), bg: Color(red: 0.93, green: 0.93, blue: 0.93), fg: Color(red: 0.13, green: 0.13, blue: 0.13))
        default:
            if let definition = PlatformRegistry.definition(for: normalizedPlatform) {
                return PlatformMetadata(name: definition.name, icon: definition.icon, accent: colors.primary, bg: colors.primaryBg, fg: colors.primary)
            }
            return PlatformMetadata(name: platform.capitalized, icon: "🌐", accent: colors.primary, bg: colors.primaryBg, fg: colors.primary)
        }
    }
}

class AppearanceManager: ObservableObject {
    static let shared = AppearanceManager()
    private var profileID: UUID?

    @Published var fontChoice: AppFontChoice {
        didSet { UserDefaults.standard.set(fontChoice.rawValue, forKey: storageKey("app_font_choice")) }
    }

    @Published var fontSizeChoice: AppFontSizeChoice {
        didSet { UserDefaults.standard.set(fontSizeChoice.rawValue, forKey: storageKey("app_font_size_choice")) }
    }

    private init() {
        let activeProfileID = LocalProfileStore.shared.activeProfileID
        self.profileID = activeProfileID
        let storedFont = UserDefaults.standard.string(forKey: LocalProfileStore.defaultsKey("app_font_choice", profileID: activeProfileID)) ?? AppFontChoice.normal.rawValue
        self.fontChoice = AppFontChoice(rawValue: storedFont) ?? .normal

        let storedSize = UserDefaults.standard.string(forKey: LocalProfileStore.defaultsKey("app_font_size_choice", profileID: activeProfileID)) ?? AppFontSizeChoice.normal.rawValue
        self.fontSizeChoice = AppFontSizeChoice(rawValue: storedSize) ?? .normal
    }

    @MainActor
    func configure(profileID: UUID) {
        self.profileID = profileID
        let storedFont = UserDefaults.standard.string(forKey: storageKey("app_font_choice")) ?? AppFontChoice.normal.rawValue
        let storedSize = UserDefaults.standard.string(forKey: storageKey("app_font_size_choice")) ?? AppFontSizeChoice.normal.rawValue
        fontChoice = AppFontChoice(rawValue: storedFont) ?? .normal
        fontSizeChoice = AppFontSizeChoice(rawValue: storedSize) ?? .normal
    }

    private func storageKey(_ key: String) -> String {
        guard let profileID else { return key }
        return LocalProfileStore.defaultsKey(key, profileID: profileID)
    }

    // Returns a DynamicTypeSize override when the user has chosen a larger-than-system
    // font size. nil for Normal — leaves the iOS accessibility setting untouched.
    var dynamicTypeSizeOverride: DynamicTypeSize? {
        switch fontSizeChoice {
        case .normal:     return nil         // respect whatever iOS has set
        case .large:      return .xLarge
        case .extraLarge: return .xxLarge
        }
    }

    // appFont is only applied to text that has no explicit .font() modifier.
    // Size scaling is handled by preferredDynamicTypeSize, so we use semantic
    // sizes here to avoid double-scaling.
    var appFont: Font {
        font(size: 17.0, relativeTo: .body)
    }

    func font(size: CGFloat, relativeTo textStyle: Font.TextStyle = .body) -> Font {
        switch fontChoice {
        case .normal:
            return .system(size: size, design: .default)
        case .playful:
            return .system(size: size, design: .rounded)
        case .serif:
            return .system(size: size, design: .serif)
        }
    }

    var readerFontSize: CGFloat {
        16.0 * fontSizeChoice.scale
    }

    var readerFontFamilyCSS: String {
        fontChoice.cssFamily
    }
}
