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
        LocalProfileStore.scopedDefaultsKey(key, profileID: profileID)
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

    /// Per-source accent / background / foreground tints, keyed by canonical
    /// platform id. Names and icons are **not** here — they come from
    /// `PlatformRegistry` (the single source of truth) via `metadata(for:)`.
    /// A platform absent from this table falls back to the app's primary tint.
    private static let platformTints: [String: (accent: Color, bg: Color, fg: Color)] = [
        "youtube": (Color.red, Color(red: 1.0, green: 0.9, blue: 0.9), Color.red),
        "tver": (Color.blue, Color(red: 0.9, green: 0.95, blue: 1.0), Color.blue),
        "niconico": (Color.black, Color.gray.opacity(0.2), Color.primary),
        "yahoonews": (Color(red: 0.86, green: 0.0, blue: 0.0), Color(red: 1.0, green: 0.92, blue: 0.92), Color(red: 0.86, green: 0.0, blue: 0.0)),
        "mdpr": (Color.pink, Color(red: 1.0, green: 0.9, blue: 0.95), Color.pink),
        "oricon": (Color(red: 0.86, green: 0.12, blue: 0.22), Color(red: 1.0, green: 0.92, blue: 0.94), Color(red: 0.86, green: 0.12, blue: 0.22)),
        "twitter": (Color.black, Color.gray.opacity(0.2), Color.primary),
        "5ch": (Color.orange, Color(red: 1.0, green: 0.95, blue: 0.9), Color.orange),
        "girlschannel": (Color.pink, Color(red: 1.0, green: 0.92, blue: 0.95), Color.pink),
        "note": (Color(red: 0.1, green: 0.7, blue: 0.5), Color(red: 0.9, green: 0.97, blue: 0.95), Color(red: 0.1, green: 0.7, blue: 0.5)),
        "news": (Color.purple, Color(red: 0.96, green: 0.9, blue: 1.0), Color.purple),
        "smartnews": (Color(red: 0.80, green: 0.00, blue: 0.00), Color(red: 1.0, green: 0.92, blue: 0.92), Color(red: 0.80, green: 0.00, blue: 0.00)),
        "ameblo": (Color(red: 1.00, green: 0.42, blue: 0.00), Color(red: 1.0, green: 0.94, blue: 0.88), Color(red: 1.00, green: 0.42, blue: 0.00)),
        "aera": (Color(red: 0.00, green: 0.27, blue: 0.58), Color(red: 0.90, green: 0.94, blue: 1.0), Color(red: 0.00, green: 0.27, blue: 0.58)),
        "hochi": (Color(red: 0.82, green: 0.10, blue: 0.10), Color(red: 1.0, green: 0.92, blue: 0.92), Color(red: 0.82, green: 0.10, blue: 0.10)),
        "sponichi": (Color(red: 0.00, green: 0.27, blue: 0.60), Color(red: 0.90, green: 0.94, blue: 1.0), Color(red: 0.00, green: 0.27, blue: 0.60)),
        "livedoor": (Color(red: 0.88, green: 0.00, blue: 0.20), Color(red: 1.0, green: 0.92, blue: 0.94), Color(red: 0.88, green: 0.00, blue: 0.20)),
        "mantanweb": (Color(red: 0.07, green: 0.53, blue: 0.25), Color(red: 0.90, green: 1.0, blue: 0.93), Color(red: 0.07, green: 0.53, blue: 0.25)),
        "realsound": (Color(red: 0.18, green: 0.36, blue: 0.72), Color(red: 0.91, green: 0.95, blue: 1.0), Color(red: 0.18, green: 0.36, blue: 0.72)),
        "cinemacafe": (Color(red: 0.56, green: 0.20, blue: 0.64), Color(red: 0.96, green: 0.91, blue: 0.98), Color(red: 0.56, green: 0.20, blue: 0.64)),
        "thetv": (Color(red: 0.02, green: 0.36, blue: 0.78), Color(red: 0.90, green: 0.95, blue: 1.0), Color(red: 0.02, green: 0.36, blue: 0.78)),
        "natalie": (Color(red: 0.86, green: 0.14, blue: 0.22), Color(red: 1.0, green: 0.92, blue: 0.94), Color(red: 0.86, green: 0.14, blue: 0.22)),
        "billboardjapan": (Color(red: 0.05, green: 0.38, blue: 0.72), Color(red: 0.90, green: 0.95, blue: 1.0), Color(red: 0.05, green: 0.38, blue: 0.72)),
        "soompi": (Color(red: 0.74, green: 0.16, blue: 0.30), Color(red: 1.0, green: 0.92, blue: 0.95), Color(red: 0.74, green: 0.16, blue: 0.30)),
        "allkpop": (Color(red: 0.48, green: 0.24, blue: 0.70), Color(red: 0.96, green: 0.92, blue: 1.0), Color(red: 0.48, green: 0.24, blue: 0.70)),
        "kpopofficial": (Color(red: 0.04, green: 0.52, blue: 0.54), Color(red: 0.90, green: 0.98, blue: 0.98), Color(red: 0.04, green: 0.52, blue: 0.54)),
        "barks": (Color(red: 0.13, green: 0.13, blue: 0.13), Color(red: 0.93, green: 0.93, blue: 0.93), Color(red: 0.13, green: 0.13, blue: 0.13)),
    ]

    private func uncachedMetadata(for platform: String, normalizedPlatform: String) -> PlatformMetadata {
        guard let definition = PlatformRegistry.definition(for: normalizedPlatform) else {
            return PlatformMetadata(name: platform.capitalized, icon: "🌐", accent: colors.primary, bg: colors.primaryBg, fg: colors.primary)
        }
        let tint = Self.platformTints[normalizedPlatform]
        return PlatformMetadata(
            name: definition.name,
            icon: definition.icon,
            accent: tint?.accent ?? colors.primary,
            bg: tint?.bg ?? colors.primaryBg,
            fg: tint?.fg ?? colors.primary
        )
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
        LocalProfileStore.scopedDefaultsKey(key, profileID: profileID)
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
