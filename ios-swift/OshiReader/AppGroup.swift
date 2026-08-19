import Foundation

/// Shared container the main app, the widget extension, and the share
/// extension all read/write into — none of them can reach another target's
/// private Documents directory.
let oshiReaderAppGroupID = "group.com.otterpia.oshireader"

/// `I18nManager`'s language selection lives in `UserDefaults.standard`,
/// which extensions can't read — each is sandboxed to its own defaults
/// suite. Mirrored into the App Group suite instead so the widget and share
/// extension's own small UI string tables can follow the user's choice.
enum SharedAppLanguage {
    private static let key = "shared_lang"

    private static var suite: UserDefaults? {
        UserDefaults(suiteName: oshiReaderAppGroupID)
    }

    /// Called from the host app whenever the active language changes.
    static func write(_ language: String) {
        suite?.set(language, forKey: key)
    }

    /// Called from an extension process. Falls back to `I18nManager`'s own
    /// default so an extension launched before the app has ever run still
    /// picks a sensible language.
    static var current: String {
        suite?.string(forKey: key) ?? "ja"
    }
}
