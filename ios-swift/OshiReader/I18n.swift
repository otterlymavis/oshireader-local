import Foundation

class I18nManager: ObservableObject {
    static let shared = I18nManager()
    private var profileID: UUID?
    
    @Published var lang: String = "ja" // Default to ja
    
    private init() {
        let activeProfileID = LocalProfileStore.shared.activeProfileID
        self.profileID = activeProfileID
        self.lang = UserDefaults.standard.string(
            forKey: LocalProfileStore.defaultsKey("selected_lang", profileID: activeProfileID)
        ) ?? "ja"
    }
    
    func setLanguage(_ language: String) {
        self.lang = language
        UserDefaults.standard.set(language, forKey: storageKey("selected_lang"))
    }

    @MainActor
    func configure(profileID: UUID) {
        self.profileID = profileID
        self.lang = UserDefaults.standard.string(forKey: storageKey("selected_lang")) ?? "ja"
    }

    private func storageKey(_ key: String) -> String {
        guard let profileID else { return key }
        return LocalProfileStore.defaultsKey(key, profileID: profileID)
    }
    
    private let translations: [String: [String: String]] = [
        "appTitle": [
            "en": "OshiReader+",
            "ja": "推しリーダー+",
            "zh-TW": "OshiReader+",
            "zh-CN": "OshiReader+"
        ],
        "tabFeed": [
            "en": "Feed",
            "ja": "フィード",
            "zh-TW": "動態",
            "zh-CN": "动态"
        ],
        "tabSaved": [
            "en": "Saved",
            "ja": "ブックマーク",
            "zh-TW": "已儲存",
            "zh-CN": "已保存"
        ],
        "tabOshi": [
            "en": "My Oshi",
            "ja": "推しリスト",
            "zh-TW": "推",
            "zh-CN": "推"
        ],
        "tabSearch": [
            "en": "Search",
            "ja": "検索",
            "zh-TW": "搜尋",
            "zh-CN": "搜索"
        ],
        "tabSettings": [
            "en": "Settings",
            "ja": "設定",
            "zh-TW": "設定",
            "zh-CN": "设置"
        ],
        "all": [
            "en": "All",
            "ja": "すべて",
            "zh-TW": "全部",
            "zh-CN": "全部"
        ],
        "filter": [
            "en": "Filter",
            "ja": "フィルター",
            "zh-TW": "篩選",
            "zh-CN": "筛选"
        ],
        "activeFiltersCount": [
            "en": "%d active",
            "ja": "有効: %d件",
            "zh-TW": "已啟用 %d 項",
            "zh-CN": "已启用 %d 项"
        ],
        "allInfo": [
            "en": "All Info",
            "ja": "全情報",
            "zh-TW": "全部資訊",
            "zh-CN": "全部信息"
        ],
        "mediaOnly": [
            "en": "Media Only",
            "ja": "メディア",
            "zh-TW": "僅媒體",
            "zh-CN": "仅媒体"
        ],
        "period": [
            "en": "Period",
            "ja": "期間",
            "zh-TW": "時間",
            "zh-CN": "时间"
        ],
        "allTime": [
            "en": "All Time",
            "ja": "全期間",
            "zh-TW": "全部",
            "zh-CN": "全部"
        ],
        "days3": [
            "en": "3 Days",
            "ja": "3日間",
            "zh-TW": "3天",
            "zh-CN": "3天"
        ],
        "month1": [
            "en": "1 Month",
            "ja": "1ヶ月",
            "zh-TW": "1個月",
            "zh-CN": "1个月"
        ],
        "months3": [
            "en": "3 Months",
            "ja": "3ヶ月",
            "zh-TW": "3個月",
            "zh-CN": "3个月"
        ],
        "months6": [
            "en": "6 Months",
            "ja": "6ヶ月",
            "zh-TW": "6個月",
            "zh-CN": "6个月"
        ],
        "keyword": [
            "en": "Keyword",
            "ja": "キーワード",
            "zh-TW": "關鍵字",
            "zh-CN": "关键字"
        ],
        "feedEmpty": [
            "en": "Feed is Empty",
            "ja": "フィードが空です",
            "zh-TW": "尚無內容",
            "zh-CN": "暂无内容"
        ],
        "feedEmptyBody": [
            "en": "Register watch keywords in Settings to track your Oshi.",
            "ja": "「設定」タブからキーワードを登録するとここに情報が表示されます",
            "zh-TW": "在「設定」中新增關鍵字以開始獲取結果。",
            "zh-CN": "在「设置」中添加关键字以开始获取结果。"
        ],
        "cancel": [
            "en": "Cancel",
            "ja": "キャンセル",
            "zh-TW": "取消",
            "zh-CN": "取消"
        ],
        "delete": [
            "en": "Delete",
            "ja": "削除",
            "zh-TW": "刪除",
            "zh-CN": "删除"
        ],
        "save": [
            "en": "Save",
            "ja": "保存",
            "zh-TW": "儲存",
            "zh-CN": "保存"
        ],
        "unsave": [
            "en": "Unsave",
            "ja": "保存解除",
            "zh-TW": "取消儲存",
            "zh-CN": "取消保存"
        ],
        "ok": [
            "en": "OK",
            "ja": "OK",
            "zh-TW": "OK",
            "zh-CN": "OK"
        ],
        "search": [
            "en": "Search",
            "ja": "検索",
            "zh-TW": "搜尋",
            "zh-CN": "搜索"
        ],
        "edit": [
            "en": "Edit",
            "ja": "編集",
            "zh-TW": "編輯",
            "zh-CN": "编辑"
        ],
        "offlineSaved": [
            "en": "Saved for Offline",
            "ja": "オフライン保存済み",
            "zh-TW": "已儲存 — 可離線閱讀",
            "zh-CN": "已保存 — 可离线阅读"
        ],
        "savedTitle": [
            "en": "Bookmarked Pages",
            "ja": "ブックマーク一覧",
            "zh-TW": "已儲存",
            "zh-CN": "已保存"
        ],
        "addAlias": [
            "en": "+ alias",
            "ja": "+ 別名",
            "zh-TW": "+ 別名",
            "zh-CN": "+ 别名"
        ],
        "aliasLimitReached": [
            "en": "You can add up to 5 aliases per keyword.",
            "ja": "キーワードごとに追加できる別名は5件までです。",
            "zh-TW": "每個關鍵字最多可新增5個別名。",
            "zh-CN": "每个关键词最多可添加5个别名。"
        ],
        "oshiEmpty": [
            "en": "Add your Oshi!",
            "ja": "推しを追加しよう！",
            "zh-TW": "新增你的推吧！",
            "zh-CN": "添加你的推吧！"
        ],
        "oshiEmptyBody": [
            "en": "Register a keyword in Settings and profile canvas will appear here.",
            "ja": "「設定」からキーワードを登録するとアバタープロフィールが表示されます",
            "zh-TW": "在「設定」中新增關鍵字以開始獲取結果。",
            "zh-CN": "在「设置」中添加关键字以开始获取结果。"
        ],
        "searchPlaceholder": [
            "en": "Search articles...",
            "ja": "記事を検索...",
            "zh-TW": "搜尋文章...",
            "zh-CN": "搜索文章..."
        ],
        "settingsTitle": [
            "en": "Settings",
            "ja": "設定",
            "zh-TW": "設定",
            "zh-CN": "设置"
        ],
        "wallpaper": [
            "en": "Wallpaper",
            "ja": "壁紙設定",
            "zh-TW": "壁紙設定",
            "zh-CN": "壁纸设置"
        ],
        "selectWallpaper": [
            "en": "Choose from stickers",
            "ja": "ステッカー画像から設定",
            "zh-TW": "從貼紙選擇",
            "zh-CN": "从贴纸选择"
        ],
        "clearWallpaper": [
            "en": "Clear Wallpaper",
            "ja": "壁紙をクリア",
            "zh-TW": "清除壁紙",
            "zh-CN": "清除壁纸"
        ],
        "language": [
            "en": "Language",
            "ja": "言語",
            "zh-TW": "語言",
            "zh-CN": "语言"
        ],
        "stats": [
            "en": "Statistics",
            "ja": "統計情報",
            "zh-TW": "儲存空間",
            "zh-CN": "存储空间"
        ],
        "watchTerms": [
            "en": "Keywords",
            "ja": "キーワード管理",
            "zh-TW": "關鍵字管理",
            "zh-CN": "关键字管理"
        ],
        "addKeyword": [
            "en": "Add Keyword",
            "ja": "キーワード追加",
            "zh-TW": "新增關鍵字",
            "zh-CN": "新增关键字"
        ],
        "inputKeyword": [
            "en": "Enter keyword...",
            "ja": "キーワードを入力...",
            "zh-TW": "關鍵字（例：偶像名稱）",
            "zh-CN": "关键字（例：偶像名字）"
        ],
        "readerModeText": [
            "en": "Reader Text Mode",
            "ja": "リーダーテキスト表示",
            "zh-TW": "閱讀器文字模式",
            "zh-CN": "阅读器文字模式"
        ],
        "readerModeWeb": [
            "en": "Original Web Mode",
            "ja": "オリジナルウェブ表示",
            "zh-TW": "原始網頁模式",
            "zh-CN": "原始网页模式"
        ],
        "invalidURL": [
            "en": "Invalid URL",
            "ja": "URLが無効です",
            "zh-TW": "網址無效",
            "zh-CN": "网址无效"
        ],
        "image": [
            "en": "Image",
            "ja": "画像",
            "zh-TW": "圖片",
            "zh-CN": "图片"
        ],
        "shareImage": [
            "en": "Share Image",
            "ja": "画像を共有",
            "zh-TW": "分享圖片",
            "zh-CN": "分享图片"
        ],
        "saveImage": [
            "en": "Save Image",
            "ja": "画像を保存",
            "zh-TW": "儲存圖片",
            "zh-CN": "保存图片"
        ],
        "openImage": [
            "en": "Open Image",
            "ja": "画像を開く",
            "zh-TW": "開啟圖片",
            "zh-CN": "打开图片"
        ],
        "imageReadFailed": [
            "en": "Could not read this image.",
            "ja": "この画像を読み込めませんでした。",
            "zh-TW": "無法讀取此圖片。",
            "zh-CN": "无法读取此图片。"
        ],
        "photosAccessRequired": [
            "en": "Photos access is required to save images.",
            "ja": "画像を保存するには写真へのアクセスが必要です。",
            "zh-TW": "需要照片權限才能儲存圖片。",
            "zh-CN": "需要照片权限才能保存图片。"
        ],
        "imageSavedToPhotos": [
            "en": "Saved to Photos.",
            "ja": "写真に保存しました。",
            "zh-TW": "已儲存到照片。",
            "zh-CN": "已保存到照片。"
        ],
        "imageSaveFailed": [
            "en": "Could not save this image.",
            "ja": "この画像を保存できませんでした。",
            "zh-TW": "無法儲存此圖片。",
            "zh-CN": "无法保存此图片。"
        ],
        "noLargeImagesFound": [
            "en": "No large images found on this page.",
            "ja": "このページに大きな画像は見つかりませんでした。",
            "zh-TW": "此頁面找不到大型圖片。",
            "zh-CN": "此页面找不到大图。"
        ],
        "oneImageSavedToPhotos": [
            "en": "Saved 1 image to Photos.",
            "ja": "画像を1件、写真に保存しました。",
            "zh-TW": "已儲存 1 張圖片到照片。",
            "zh-CN": "已保存 1 张图片到照片。"
        ],
        "imagesSavedToPhotos": [
            "en": "Saved %d images to Photos.",
            "ja": "画像を%d件、写真に保存しました。",
            "zh-TW": "已儲存 %d 張圖片到照片。",
            "zh-CN": "已保存 %d 张图片到照片。"
        ],
        "noImagesSaved": [
            "en": "No images could be saved.",
            "ja": "画像を保存できませんでした。",
            "zh-TW": "沒有圖片可儲存。",
            "zh-CN": "没有图片可保存。"
        ],
        "readerModeTextShort": [
            "en": "Text",
            "ja": "本文",
            "zh-TW": "文字",
            "zh-CN": "文字"
        ],
        "readerModeWebShort": [
            "en": "Web",
            "ja": "Web",
            "zh-TW": "網頁",
            "zh-CN": "网页"
        ],
        "readerTheme": [
            "en": "Reader Theme",
            "ja": "リーダーテーマ",
            "zh-TW": "閱讀器主題",
            "zh-CN": "阅读器主题"
        ],
        "decreaseTextSize": [
            "en": "Decrease text size",
            "ja": "文字を小さくする",
            "zh-TW": "縮小文字",
            "zh-CN": "缩小文字"
        ],
        "increaseTextSize": [
            "en": "Increase text size",
            "ja": "文字を大きくする",
            "zh-TW": "放大文字",
            "zh-CN": "放大文字"
        ],
        "avatarEditor": [
            "en": "Avatar Editor",
            "ja": "アバターエディタ",
            "zh-TW": "頭像編輯器",
            "zh-CN": "头像编辑器"
        ],
        "cropMode": [
            "en": "Crop / Move Mode",
            "ja": "切り抜き / 移動",
            "zh-TW": "裁剪 / 移動",
            "zh-CN": "裁剪 / 移动"
        ],
        "crop": [
            "en": "Crop",
            "ja": "切り抜き",
            "zh-TW": "裁剪",
            "zh-CN": "裁剪"
        ],
        "move": [
            "en": "Move",
            "ja": "移動",
            "zh-TW": "移動",
            "zh-CN": "移动"
        ],
        "zoomIn": [
            "en": "Zoom In",
            "ja": "拡大",
            "zh-TW": "放大",
            "zh-CN": "放大"
        ],
        "zoomOut": [
            "en": "Zoom Out",
            "ja": "縮小",
            "zh-TW": "縮小",
            "zh-CN": "缩小"
        ],
        "fit": [
            "en": "Fit",
            "ja": "フィット",
            "zh-TW": "適合",
            "zh-CN": "适合"
        ],
        "scaleUp": [
            "en": "Scale Up",
            "ja": "大きくする",
            "zh-TW": "放大圖層",
            "zh-CN": "放大图层"
        ],
        "scaleDown": [
            "en": "Scale Down",
            "ja": "小さくする",
            "zh-TW": "縮小圖層",
            "zh-CN": "缩小图层"
        ],
        "rotateLeft": [
            "en": "Rotate Left",
            "ja": "左に回転",
            "zh-TW": "向左旋轉",
            "zh-CN": "向左旋转"
        ],
        "rotateRight": [
            "en": "Rotate Right",
            "ja": "右に回転",
            "zh-TW": "向右旋轉",
            "zh-CN": "向右旋转"
        ],
        "popularStickers": [
            "en": "Popular ✨",
            "ja": "おすすめ ✨",
            "zh-TW": "熱門 ✨",
            "zh-CN": "热门 ✨"
        ],
        "searchStickers": [
            "en": "Search Irasutoya...",
            "ja": "いらすとやで検索...",
            "zh-TW": "搜尋貼紙...",
            "zh-CN": "搜索贴纸..."
        ],

        // MARK: - Settings section headers
        "platformSettings": [
            "en": "Source Platforms",
            "ja": "配信プラットフォーム設定",
            "zh-TW": "訂閱平台",
            "zh-CN": "订阅平台"
        ],
        "notificationsSection": [
            "en": "Notifications",
            "ja": "通知",
            "zh-TW": "通知",
            "zh-CN": "通知"
        ],
        "pushNotifications": [
            "en": "Push Notifications",
            "ja": "プッシュ通知",
            "zh-TW": "推播通知",
            "zh-CN": "推送通知"
        ],
        "enableNotifications": [
            "en": "Enable Notifications",
            "ja": "通知を有効にする",
            "zh-TW": "啟用通知",
            "zh-CN": "启用通知"
        ],
        "openIOSSettings": [
            "en": "Open iOS Settings",
            "ja": "iOS設定を開く",
            "zh-TW": "開啟 iOS 設定",
            "zh-CN": "打开 iOS 设置"
        ],
        "sendTestNotification": [
            "en": "Send Test Notification",
            "ja": "テスト通知を送信",
            "zh-TW": "傳送測試通知",
            "zh-CN": "发送测试通知"
        ],
        "notificationStatusEnabled": [
            "en": "Enabled",
            "ja": "有効",
            "zh-TW": "已啟用",
            "zh-CN": "已启用"
        ],
        "notificationStatusQuiet": [
            "en": "Quietly enabled",
            "ja": "控えめに有効",
            "zh-TW": "靜默啟用",
            "zh-CN": "静默启用"
        ],
        "notificationStatusDisabled": [
            "en": "Disabled in iOS Settings",
            "ja": "iOS設定で無効",
            "zh-TW": "已在 iOS 設定中停用",
            "zh-CN": "已在 iOS 设置中停用"
        ],
        "notificationStatusTemporary": [
            "en": "Temporarily enabled",
            "ja": "一時的に有効",
            "zh-TW": "暫時啟用",
            "zh-CN": "临时启用"
        ],
        "notificationStatusNotRequested": [
            "en": "Not requested",
            "ja": "未リクエスト",
            "zh-TW": "尚未請求",
            "zh-CN": "尚未请求"
        ],
        "notificationStatusUnknown": [
            "en": "Unknown",
            "ja": "不明",
            "zh-TW": "未知",
            "zh-CN": "未知"
        ],
        "notificationsOn": [
            "en": "Notifications On",
            "ja": "通知オン",
            "zh-TW": "通知開啟",
            "zh-CN": "通知开启"
        ],
        "notificationsOff": [
            "en": "Notifications Off",
            "ja": "通知オフ",
            "zh-TW": "通知關閉",
            "zh-CN": "通知关闭"
        ],
        "active": [
            "en": "Active",
            "ja": "有効",
            "zh-TW": "啟用",
            "zh-CN": "启用"
        ],
        "appearanceSection": [
            "en": "Theme & Appearance",
            "ja": "テーマとカスタマイズ",
            "zh-TW": "外觀設定",
            "zh-CN": "外观设置"
        ],
        "readerSection": [
            "en": "Reader",
            "ja": "リーダー",
            "zh-TW": "閱讀器",
            "zh-CN": "阅读器"
        ],
        "credentialsSection": [
            "en": "API Credentials",
            "ja": "API設定",
            "zh-TW": "API設定",
            "zh-CN": "API设置"
        ],
        "privacySection": [
            "en": "Privacy",
            "ja": "プライバシー",
            "zh-TW": "隱私",
            "zh-CN": "隐私"
        ],
        "dataSection": [
            "en": "Data",
            "ja": "データ",
            "zh-TW": "資料",
            "zh-CN": "数据"
        ],

        // MARK: - Settings controls
        "appTheme": [
            "en": "App Theme",
            "ja": "アプリテーマ",
            "zh-TW": "主題",
            "zh-CN": "主题"
        ],
        "themeLight": [
            "en": "Light",
            "ja": "ライト",
            "zh-TW": "淺色",
            "zh-CN": "浅色"
        ],
        "themeDark": [
            "en": "Dark",
            "ja": "ダーク",
            "zh-TW": "深色",
            "zh-CN": "深色"
        ],
        "themeSepia": [
            "en": "Sepia",
            "ja": "セピア",
            "zh-TW": "復古",
            "zh-CN": "复古"
        ],
        "collectionMode": [
            "en": "Collection Mode",
            "ja": "収集モード",
            "zh-TW": "收集模式",
            "zh-CN": "收集模式"
        ],
        "sourceSelection": [
            "en": "Sources",
            "ja": "ソース",
            "zh-TW": "來源",
            "zh-CN": "来源"
        ],
        "allSources": [
            "en": "All sources",
            "ja": "すべてのソース",
            "zh-TW": "所有來源",
            "zh-CN": "所有来源"
        ],
        "selectedSources": [
            "en": "Selected",
            "ja": "選択",
            "zh-TW": "選取",
            "zh-CN": "选择"
        ],
        "chooseSources": [
            "en": "Choose sources",
            "ja": "ソースを選択",
            "zh-TW": "選擇來源",
            "zh-CN": "选择来源"
        ],
        "sourcesSelectedCount": [
            "en": "%d sources selected",
            "ja": "%d件のソースを選択中",
            "zh-TW": "已選取 %d 個來源",
            "zh-CN": "已选择 %d 个来源"
        ],
        "add": [
            "en": "Add",
            "ja": "追加",
            "zh-TW": "新增",
            "zh-CN": "添加"
        ],
        "autoTranslate": [
            "en": "Auto Translate Articles",
            "ja": "記事を自動翻訳",
            "zh-TW": "自動翻譯文章",
            "zh-CN": "自动翻译文章"
        ],
        "credentialsFooter": [
            "en": "Stored only on this device (Keychain). X results require your own bearer token; without it that source is skipped.",
            "ja": "このデバイスのKeychainにのみ保存されます。Xの結果には自分のBearer Tokenが必要です。未設定の場合、そのソースはスキップされます。",
            "zh-TW": "僅儲存在此裝置的 Keychain。X 結果需要你自己的 Bearer Token；未設定時會略過該來源。",
            "zh-CN": "仅存储在此设备的 Keychain。X 结果需要你自己的 Bearer Token；未设置时会跳过该来源。"
        ],
        "style": [
            "en": "Style",
            "ja": "スタイル",
            "zh-TW": "樣式",
            "zh-CN": "样式"
        ],
        "styleColourful": [
            "en": "Colourful",
            "ja": "カラフル",
            "zh-TW": "繽紛",
            "zh-CN": "多彩"
        ],
        "styleStandard": [
            "en": "Standard",
            "ja": "標準",
            "zh-TW": "標準",
            "zh-CN": "标准"
        ],
        "font": [
            "en": "Font",
            "ja": "フォント",
            "zh-TW": "字型",
            "zh-CN": "字体"
        ],
        "fontNormal": [
            "en": "Normal",
            "ja": "標準",
            "zh-TW": "標準",
            "zh-CN": "标准"
        ],
        "fontComicSans": [
            "en": "Comic Sans",
            "ja": "Comic Sans",
            "zh-TW": "Comic Sans",
            "zh-CN": "Comic Sans"
        ],
        "fontSize": [
            "en": "Font Size",
            "ja": "文字サイズ",
            "zh-TW": "字體大小",
            "zh-CN": "字体大小"
        ],
        "fontSizeNormal": [
            "en": "Normal",
            "ja": "標準",
            "zh-TW": "標準",
            "zh-CN": "标准"
        ],
        "fontSizeLarge": [
            "en": "Large",
            "ja": "大",
            "zh-TW": "大",
            "zh-CN": "大"
        ],
        "fontSizeExtraLarge": [
            "en": "Extra Large",
            "ja": "特大",
            "zh-TW": "特大",
            "zh-CN": "特大"
        ],
        "privacyPolicy": [
            "en": "Privacy Policy",
            "ja": "プライバシーポリシー",
            "zh-TW": "隱私權政策",
            "zh-CN": "隐私政策"
        ],
        "privacyStoredTitle": [
            "en": "Data Stored on This Device",
            "ja": "このデバイスに保存されるデータ",
            "zh-TW": "儲存在此裝置的資料",
            "zh-CN": "存储在此设备的数据"
        ],
        "privacyStoredBody": [
            "en": "Oshi Reader stores watch keywords, feed items, saved pages, custom URLs, display settings, wallpaper choices, avatar compositions, and cached article HTML for offline reading, all locally on this device.",
            "ja": "推しリーダーは、キーワード、フィード項目、保存済みページ、カスタムURL、表示設定、壁紙の選択、アバター構成、オフライン閲覧用の記事HTMLキャッシュを、このデバイス内にのみ保存します。",
            "zh-TW": "Oshi Reader 會將追蹤關鍵字、動態項目、已儲存頁面、自訂網址、顯示設定、壁紙選擇、頭像組合與離線閱讀用的文章 HTML 快取，全部儲存在此裝置本機。",
            "zh-CN": "Oshi Reader 会将追踪关键字、动态项目、已保存页面、自定义网址、显示设置、壁纸选择、头像组合以及离线阅读用的文章 HTML 缓存，全部保存在此设备本机。"
        ],
        "privacySentTitle": [
            "en": "Data Sent for App Functionality",
            "ja": "機能提供のために送信されるデータ",
            "zh-TW": "為提供功能而傳送的資料",
            "zh-CN": "为提供功能而发送的数据"
        ],
        "privacySentBody": [
            "en": "When you add watch keywords, refresh feeds, search stickers, translate sticker queries, or open articles, related keywords, search text, URLs, and article requests may be sent to Google services, Irasutoya/Blogger feeds, news feeds, and the websites you choose to open.",
            "ja": "キーワードの追加、フィード更新、ステッカー検索、ステッカー検索語の翻訳、記事の表示を行うと、関連するキーワード、検索テキスト、URL、記事リクエストが、Googleサービス、いらすとや/Bloggerフィード、ニュースフィード、または開くことを選んだWebサイトへ送信される場合があります。",
            "zh-TW": "當你新增追蹤關鍵字、重新整理動態、搜尋貼紙、翻譯貼紙搜尋詞或開啟文章時，相關關鍵字、搜尋文字、網址與文章請求可能會傳送至 Google 服務、Irasutoya/Blogger feeds、新聞 feeds，以及你選擇開啟的網站。",
            "zh-CN": "当你添加追踪关键字、刷新动态、搜索贴纸、翻译贴纸搜索词或打开文章时，相关关键字、搜索文本、网址和文章请求可能会发送到 Google 服务、Irasutoya/Blogger feeds、新闻 feeds，以及你选择打开的网站。"
        ],
        "privacyTrackingTitle": [
            "en": "Tracking and Advertising",
            "ja": "トラッキングと広告",
            "zh-TW": "追蹤與廣告",
            "zh-CN": "追踪与广告"
        ],
        "privacyTrackingBody": [
            "en": "This app does not use advertising identifiers, App Tracking Transparency, third-party ad SDKs, or data broker tracking. Data is used solely to provide feed, reader, search, translation, and customization features.",
            "ja": "このアプリは、広告識別子、App Tracking Transparency、第三者広告SDK、データブローカーによるトラッキングを使用しません。データはフィード、リーダー、検索、翻訳、カスタマイズ機能の提供にのみ使用されます。",
            "zh-TW": "本 app 不使用廣告識別碼、App Tracking Transparency、第三方廣告 SDK 或資料仲介商追蹤。資料僅用於提供動態、閱讀器、搜尋、翻譯與自訂功能。",
            "zh-CN": "本 app 不使用广告标识符、App Tracking Transparency、第三方广告 SDK 或数据经纪商追踪。数据仅用于提供动态、阅读器、搜索、翻译和自定义功能。"
        ],
        "privacyPermissionsTitle": [
            "en": "Permissions",
            "ja": "権限",
            "zh-TW": "權限",
            "zh-CN": "权限"
        ],
        "privacyPermissionsBody": [
            "en": "Notifications: requested when you enable keyword alerts or send a test notification.\n\nPhoto Library: requested when you save an image from the article reader to your Photos.\n\nThis app does not request access to location, contacts, camera, microphone, Bluetooth, health data, or motion sensors.",
            "ja": "通知: キーワード通知を有効にする時、またはテスト通知を送信する時にリクエストされます。\n\n写真ライブラリ: 記事リーダーから画像を写真に保存する時にリクエストされます。\n\nこのアプリは、位置情報、連絡先、カメラ、マイク、Bluetooth、ヘルスケアデータ、モーションセンサーへのアクセスをリクエストしません。",
            "zh-TW": "通知：當你啟用關鍵字提醒或傳送測試通知時會請求此權限。\n\n照片圖庫：當你從文章閱讀器將圖片儲存到照片時會請求此權限。\n\n本 app 不會請求位置、聯絡人、相機、麥克風、Bluetooth、健康資料或動作感測器的存取權。",
            "zh-CN": "通知：当你启用关键字提醒或发送测试通知时会请求此权限。\n\n照片图库：当你从文章阅读器将图片保存到照片时会请求此权限。\n\n本 app 不会请求位置、联系人、相机、麦克风、Bluetooth、健康数据或运动传感器的访问权限。"
        ],
        "clearAllData": [
            "en": "Clear All Data",
            "ja": "すべてのデータを削除",
            "zh-TW": "清除所有資料",
            "zh-CN": "清除所有数据"
        ],
        "clearAllDataTitle": [
            "en": "Clear All Data?",
            "ja": "すべてのデータを削除しますか？",
            "zh-TW": "要清除所有資料嗎？",
            "zh-CN": "要清除所有数据吗？"
        ],
        "clearAllDataMessage": [
            "en": "This removes keywords, feed items, saved pages, custom URLs, avatars, hidden items, wallpaper, and source order from this device.",
            "ja": "このデバイスからキーワード、フィード項目、保存済みページ、カスタムURL、アバター、非表示項目、壁紙、ソース順を削除します。",
            "zh-TW": "這會從此裝置移除關鍵字、動態項目、已儲存頁面、自訂網址、頭像、隱藏項目、壁紙與來源排序。",
            "zh-CN": "这会从此设备移除关键字、动态项目、已保存页面、自定义网址、头像、隐藏项目、壁纸和来源排序。"
        ],

        // MARK: - OshiView
        "oshiListTitle": [
            "en": "My Oshi ✨",
            "ja": "推しリスト ✨",
            "zh-TW": "推清單 ✨",
            "zh-CN": "推清单 ✨"
        ],
        "myOshiTitle": [
            "en": "My Oshi",
            "ja": "推しリスト",
            "zh-TW": "推",
            "zh-CN": "推"
        ],
        "oshiTrackingCount": [
            "en": "%d tracked",
            "ja": "%d人の推しを追跡中",
            "zh-TW": "追蹤中：%d",
            "zh-CN": "追踪中：%d"
        ],
        "tapToAddToCanvas": [
            "en": "Tap an image below to add to canvas",
            "ja": "下の画像をタップしてキャンバスに追加",
            "zh-TW": "點擊下方圖片加入畫布",
            "zh-CN": "点击下方图片添加到画布"
        ],

        // MARK: - AvatarEditorView
        "saveAvatar": [
            "en": "💾 Save",
            "ja": "💾 保存",
            "zh-TW": "💾 儲存",
            "zh-CN": "💾 保存"
        ],
        "setAsWallpaper": [
            "en": "🌸 Set Wallpaper",
            "ja": "🌸 壁紙にする",
            "zh-TW": "🌸 設為壁紙",
            "zh-CN": "🌸 设为壁纸"
        ],
        "noStickersFound": [
            "en": "No stickers found",
            "ja": "イラストが見つかりません",
            "zh-TW": "找不到貼圖",
            "zh-CN": "找不到贴图"
        ],
        "layerForward": [
            "en": "↑Fwd",
            "ja": "↑前",
            "zh-TW": "↑前",
            "zh-CN": "↑前"
        ],
        "layerBack": [
            "en": "↓Back",
            "ja": "↓後",
            "zh-TW": "↓後",
            "zh-CN": "↓后"
        ],

        // MARK: - SavedView
        "savedSelectArticle": [
            "en": "Select a saved article",
            "ja": "保存した記事を選択してください",
            "zh-TW": "請選擇已儲存的文章",
            "zh-CN": "请选择已保存的文章"
        ],
        "savedEmptyTitle": [
            "en": "No Saved Articles",
            "ja": "ブックマークがありません",
            "zh-TW": "尚無儲存文章",
            "zh-CN": "暂无保存文章"
        ],
        "savedEmptyBody": [
            "en": "Save articles from your feed to read them here, even offline.",
            "ja": "フィードから気になる記事を保存すると、ここにオフラインでも読めるように表示されます。",
            "zh-TW": "從動態儲存文章，可在此離線閱讀。",
            "zh-CN": "从动态保存文章，可在此离线阅读。"
        ],

        // MARK: - FeedView / SearchView empty states
        "feedSelectArticle": [
            "en": "Select an article from your feed",
            "ja": "フィードから記事を選択してください",
            "zh-TW": "請從動態選擇文章",
            "zh-CN": "请从动态选择文章"
        ],
        "loadMoreRemaining": [
            "en": "Load more (%d remaining)",
            "ja": "さらに読み込む（残り%d件）",
            "zh-TW": "載入更多（剩餘 %d）",
            "zh-CN": "加载更多（剩余 %d）"
        ],
        "addCustomFeed": [
            "en": "Add Custom RSS/Web Feed",
            "ja": "カスタムRSS/Webフィードを追加",
            "zh-TW": "新增自訂 RSS/Web 來源",
            "zh-CN": "添加自定义 RSS/Web 来源"
        ],
        "feedTitlePlaceholder": [
            "en": "Feed/Webpage Title...",
            "ja": "フィード/Webページのタイトル...",
            "zh-TW": "來源/網頁標題...",
            "zh-CN": "来源/网页标题..."
        ],
        "reorderSources": [
            "en": "Reorder Sources",
            "ja": "ソースを並べ替え",
            "zh-TW": "重新排序來源",
            "zh-CN": "重新排序来源"
        ],
        "noCustomUrlsAdded": [
            "en": "No custom URLs added yet",
            "ja": "カスタムURLが登録されていません",
            "zh-TW": "尚未新增自訂網址",
            "zh-CN": "尚未添加自定义网址"
        ],
        "searchSelectArticle": [
            "en": "Select a search result to read",
            "ja": "検索リンクから記事を選択してください",
            "zh-TW": "請選擇搜尋結果閱讀",
            "zh-CN": "请选择搜索结果阅读"
        ],
        "savedURLs": [
            "en": "Saved URLs",
            "ja": "保存済みURL",
            "zh-TW": "已儲存網址",
            "zh-CN": "已保存网址"
        ],
        "enterKeyword": [
            "en": "Enter keyword",
            "ja": "キーワードを入力",
            "zh-TW": "輸入關鍵字",
            "zh-CN": "输入关键字"
        ],
        "addWatchKeywordsHint": [
            "en": "Add watch keywords in Settings, or type a keyword here.",
            "ja": "設定でキーワードを追加するか、ここにキーワードを入力してください。",
            "zh-TW": "請在設定中新增追蹤關鍵字，或在此輸入關鍵字。",
            "zh-CN": "请在设置中添加追踪关键字，或在此输入关键字。"
        ],
        "exportBackup": [
            "en": "Export Local Backup",
            "ja": "ローカルバックアップを書き出す",
            "zh-TW": "匯出本機備份",
            "zh-CN": "导出本地备份"
        ],
        "importBackup": [
            "en": "Import Local Backup",
            "ja": "ローカルバックアップを読み込む",
            "zh-TW": "匯入本機備份",
            "zh-CN": "导入本地备份"
        ],
        "backupImported": [
            "en": "Backup restored successfully.",
            "ja": "バックアップを復元しました。",
            "zh-TW": "備份已成功還原。",
            "zh-CN": "备份已成功恢复。"
        ],
        "backupStatus": [
            "en": "Backup",
            "ja": "バックアップ",
            "zh-TW": "備份",
            "zh-CN": "备份"
        ],
        "openNotification": [
            "en": "Open",
            "ja": "開く",
            "zh-TW": "開啟",
            "zh-CN": "打开"
        ]
    ]

    func t(_ key: String) -> String {
        guard let item = translations[key] else { return key }
        return item[lang] ?? item["en"] ?? key
    }

    func tFormat(_ key: String, _ value: Int) -> String {
        t(key).replacingOccurrences(of: "%d", with: String(value))
    }
}
