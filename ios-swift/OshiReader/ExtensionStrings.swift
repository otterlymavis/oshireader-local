import Foundation

/// A tiny, self-contained localization table for the widget and share
/// extensions. They can't share `I18nManager` — it's tied to `LocalProfileStore`
/// and `UserDefaults.standard`, neither of which an extension process can
/// reach — so this covers just the handful of strings those two surfaces
/// actually show, keyed off `SharedAppLanguage.current`.
enum ExtensionStrings {
    private static let table: [String: [String: String]] = [
        "widgetChooseTerm": [
            "en": "Long-press to choose a watch term",
            "ja": "長押しして追跡キーワードを選択",
            "zh-TW": "長按以選擇追蹤關鍵字",
            "zh-CN": "长按以选择追踪关键字"
        ],
        "widgetNoItems": [
            "en": "No recent items",
            "ja": "最近のアイテムはありません",
            "zh-TW": "沒有最近的項目",
            "zh-CN": "没有最近的项目"
        ],
        "shareConfirmTitle": [
            "en": "Add this page to OshiReader?",
            "ja": "このページをOshiReaderに追加しますか？",
            "zh-TW": "要將此頁面新增至 OshiReader 嗎？",
            "zh-CN": "要将此页面添加到 OshiReader 吗？"
        ],
        "shareNoLinkFound": [
            "en": "No shareable link was found on this page.",
            "ja": "このページには共有可能なリンクが見つかりませんでした。",
            "zh-TW": "在此頁面上找不到可分享的連結。",
            "zh-CN": "在此页面上未找到可分享的链接。"
        ],
        "shareCancel": [
            "en": "Cancel",
            "ja": "キャンセル",
            "zh-TW": "取消",
            "zh-CN": "取消"
        ],
        "shareAdd": [
            "en": "Add",
            "ja": "追加",
            "zh-TW": "新增",
            "zh-CN": "添加"
        ]
    ]

    static func t(_ key: String) -> String {
        table[key]?[SharedAppLanguage.current] ?? table[key]?["en"] ?? key
    }
}
