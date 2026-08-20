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
        SharedAppLanguage.write(lang)
    }

    func setLanguage(_ language: String) {
        self.lang = language
        UserDefaults.standard.set(language, forKey: storageKey("selected_lang"))
        SharedAppLanguage.write(language)
    }

    @MainActor
    func configure(profileID: UUID) {
        self.profileID = profileID
        self.lang = UserDefaults.standard.string(forKey: storageKey("selected_lang")) ?? "ja"
        SharedAppLanguage.write(lang)
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
        "showsAllPlatformsHint": [
            "en": "Shows all platforms",
            "ja": "すべてのプラットフォームを表示",
            "zh-TW": "顯示所有平台",
            "zh-CN": "显示所有平台"
        ],
        "deselectFilterHint": [
            "en": "Double-tap to deselect",
            "ja": "ダブルタップして選択を解除",
            "zh-TW": "點兩下以取消選取",
            "zh-CN": "双击取消选择"
        ],
        "filterByPlatformHint": [
            "en": "Double-tap to filter by %@",
            "ja": "ダブルタップして%@で絞り込む",
            "zh-TW": "點兩下以依 %@ 篩選",
            "zh-CN": "双击按 %@ 筛选"
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
        "feedFilteredEmpty": [
            "en": "No Results Match Filters",
            "ja": "条件に一致する結果がありません",
            "zh-TW": "沒有符合篩選條件的結果",
            "zh-CN": "没有符合筛选条件的结果"
        ],
        "feedFilteredEmptyBody": [
            "en": "Stored results exist, but the current keyword, source, media, or time filter is hiding them.",
            "ja": "保存済みの結果はありますが、現在のキーワード、ソース、メディア、期間フィルターで非表示になっています。",
            "zh-TW": "已有儲存結果，但目前的關鍵字、來源、媒體或時間篩選將其隱藏。",
            "zh-CN": "已有保存结果，但当前的关键字、来源、媒体或时间筛选将其隐藏。"
        ],
        "clearFilters": [
            "en": "Clear Filters",
            "ja": "フィルターを解除",
            "zh-TW": "清除篩選",
            "zh-CN": "清除筛选"
        ],
        "sourceStatusTitle": [
            "en": "Source Status",
            "ja": "ソースの状態",
            "zh-TW": "來源狀態",
            "zh-CN": "来源状态"
        ],
        "noSourceHistoryYet": [
            "en": "No source history yet",
            "ja": "ソース履歴はまだありません",
            "zh-TW": "尚無來源記錄",
            "zh-CN": "暂无来源记录"
        ],
        "sourceItemsQueries": [
            "en": "{items} current items · {queries} queries",
            "ja": "最新の項目 {items}件 · {queries}クエリ",
            "zh-TW": "{items} 個近期項目 · {queries} 次查詢",
            "zh-CN": "{items} 个近期项目 · {queries} 次查询"
        ],
        "sourceStaleItemsQueries": [
            "en": "{items} older matches · no current result · {queries} queries",
            "ja": "古い一致 {items}件 · 最新結果なし · {queries}クエリ",
            "zh-TW": "{items} 個較舊結果 · 無近期結果 · {queries} 次查詢",
            "zh-CN": "{items} 个较旧结果 · 无近期结果 · {queries} 次查询"
        ],
        "sourceNoMatchingItemsQueries": [
            "en": "No matching items · {queries} queries",
            "ja": "一致する項目なし · {queries}クエリ",
            "zh-TW": "無符合項目 · {queries} 次查詢",
            "zh-CN": "无匹配项目 · {queries} 次查询"
        ],
        "sourceFailureQueries": [
            "en": "{failure} · {queries} queries",
            "ja": "{failure} · {queries}クエリ",
            "zh-TW": "{failure} · {queries} 次查詢",
            "zh-CN": "{failure} · {queries} 次查询"
        ],
        "sourceCooldown": [
            "en": "Skipped — repeated failures, retrying later",
            "ja": "スキップ — 連続失敗のため後で再試行します",
            "zh-TW": "已略過 — 連續失敗，稍後重試",
            "zh-CN": "已跳过 — 连续失败，稍后重试"
        ],
        "notChecked": [
            "en": "Not checked",
            "ja": "未確認",
            "zh-TW": "尚未檢查",
            "zh-CN": "尚未检查"
        ],
        "sourceLastFailure": [
            "en": " · last {failure}",
            "ja": " · 前回 {failure}",
            "zh-TW": " · 上次 {failure}",
            "zh-CN": " · 上次 {failure}"
        ],
        "sourceHistorySummary": [
            "en": "{current} · 10d: {received} current, {stale} stale, {empty} empty, {failed} failed · {total} returned items · checked {checked}{lastFailure}",
            "ja": "{current} · 10日間: 最新 {received}、古い {stale}、空 {empty}、失敗 {failed} · 取得 {total}件 · 確認 {checked}{lastFailure}",
            "zh-TW": "{current} · 10 天：近期 {received}、過舊 {stale}、空白 {empty}、失敗 {failed} · 共傳回 {total} 個項目 · 檢查 {checked}{lastFailure}",
            "zh-CN": "{current} · 10 天：近期 {received}、过旧 {stale}、空白 {empty}、失败 {failed} · 共返回 {total} 个项目 · 检查 {checked}{lastFailure}"
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
        "removeNamed": [
            "en": "Remove %@",
            "ja": "%@を削除",
            "zh-TW": "移除 %@",
            "zh-CN": "移除 %@"
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
        "customUrlLimitReached": [
            "en": "You can add up to 200 custom URLs.",
            "ja": "追加できるカスタムURLは200件までです。",
            "zh-TW": "最多可新增200個自訂網址。",
            "zh-CN": "最多可添加200个自定义网址。"
        ],
        "shareAddFailedTitle": [
            "en": "Couldn't Add Shared Link",
            "ja": "共有したリンクを追加できませんでした",
            "zh-TW": "無法新增分享的連結",
            "zh-CN": "无法添加分享的链接"
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
        "clearSearch": [
            "en": "Clear search",
            "ja": "検索をクリア",
            "zh-TW": "清除搜尋",
            "zh-CN": "清除搜索"
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
        "hidePost": [
            "en": "Hide Post",
            "ja": "投稿を非表示",
            "zh-TW": "隱藏貼文",
            "zh-CN": "隐藏帖子"
        ],
        "hidePostConfirm": [
            "en": "Hide Post",
            "ja": "非表示にする",
            "zh-TW": "隱藏貼文",
            "zh-CN": "隐藏帖子"
        ],
        "hidePostTitleFmt": [
            "en": "Hide “%@”?",
            "ja": "「%@」を非表示にしますか？",
            "zh-TW": "隱藏「%@」？",
            "zh-CN": "隐藏“%@”？"
        ],
        "hidePostMessage": [
            "en": "This hides only this post from your feed. The keyword stays followed.",
            "ja": "この投稿だけをフィードから非表示にします。キーワードのフォローは継続されます。",
            "zh-TW": "這只會從動態中隱藏這篇貼文。關鍵字仍會繼續追蹤。",
            "zh-CN": "这只会从动态中隐藏这篇帖子。关键词仍会继续追踪。"
        ],
        "stopFollowing": [
            "en": "Stop Following",
            "ja": "フォロー解除",
            "zh-TW": "停止追蹤",
            "zh-CN": "停止追踪"
        ],
        "stopFollowingTitleFmt": [
            "en": "Stop following “%@”?",
            "ja": "「%@」のフォローを解除しますか？",
            "zh-TW": "停止追蹤「%@」？",
            "zh-CN": "停止追踪“%@”？"
        ],
        "stopFollowingMessage": [
            "en": "This removes the keyword and its cached posts from this device.",
            "ja": "この端末からキーワードと保存済みの投稿を削除します。",
            "zh-TW": "這會從此裝置移除該關鍵字與已快取的貼文。",
            "zh-CN": "这会从此设备移除该关键字与已缓存的帖子。"
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
        "invalidUrl": [
            "en": "Invalid URL",
            "ja": "無効なURL",
            "zh-TW": "無效的網址",
            "zh-CN": "无效的链接"
        ],
        "customUrlDuplicate": [
            "en": "This URL has already been added.",
            "ja": "このURLはすでに追加されています。",
            "zh-TW": "此網址已新增過。",
            "zh-CN": "此网址已添加过。"
        ],
        "readerLoadingPage": [
            "en": "Loading page...",
            "ja": "ページを読み込み中...",
            "zh-TW": "正在載入頁面...",
            "zh-CN": "正在加载页面..."
        ],
        "readerLoadFailed": [
            "en": "Page could not be loaded.",
            "ja": "ページを読み込めませんでした。",
            "zh-TW": "無法載入頁面。",
            "zh-CN": "无法加载页面。"
        ],
        "readerSignInRequired": [
            "en": "X requires sign-in to show this content.",
            "ja": "Xはこの内容を表示するにはログインが必要です。",
            "zh-TW": "X 需要登入才能顯示此內容。",
            "zh-CN": "X 需要登录才能显示此内容。"
        ],
        "readerSignInButton": [
            "en": "Sign in",
            "ja": "ログイン",
            "zh-TW": "登入",
            "zh-CN": "登录"
        ],
        "readerSignInReturnMessage": [
            "en": "Signed in? Go back to reload your search.",
            "ja": "ログインしましたか？戻って検索を再読み込みします。",
            "zh-TW": "已登入？返回以重新載入搜尋結果。",
            "zh-CN": "已登录？返回以重新加载搜索结果。"
        ],
        "readerSignInReturnButton": [
            "en": "Back to search",
            "ja": "検索に戻る",
            "zh-TW": "返回搜尋",
            "zh-CN": "返回搜索"
        ],
        "readerCouldNotDisplay": [
            "en": "This page couldn't be displayed in the app.",
            "ja": "このページはアプリ内で表示できませんでした。",
            "zh-TW": "此頁面無法在應用程式內顯示。",
            "zh-CN": "此页面无法在应用内显示。"
        ],
        "readerOpenInBrowser": [
            "en": "Open in Browser",
            "ja": "ブラウザで開く",
            "zh-TW": "在瀏覽器中開啟",
            "zh-CN": "在浏览器中打开"
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
        "readerPreviousArticle": [
            "en": "Previous Article",
            "ja": "前の記事",
            "zh-TW": "上一篇文章",
            "zh-CN": "上一篇文章"
        ],
        "readerNextArticle": [
            "en": "Next Article",
            "ja": "次の記事",
            "zh-TW": "下一篇文章",
            "zh-CN": "下一篇文章"
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
        "imageActions": [
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
        "share": [
            "en": "Share",
            "ja": "共有",
            "zh-TW": "分享",
            "zh-CN": "分享"
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
        "imageLoadError": [
            "en": "Could not read this image.",
            "ja": "画像を読み込めませんでした。",
            "zh-TW": "無法讀取此圖片。",
            "zh-CN": "无法读取此图片。"
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
            "zh-TW": "需要相簿存取權限才能儲存圖片。",
            "zh-CN": "需要照片访问权限才能保存图片。"
        ],
        "imageSavedToPhotos": [
            "en": "Saved to Photos.",
            "ja": "写真に保存しました。",
            "zh-TW": "已儲存到相簿。",
            "zh-CN": "已保存到照片。"
        ],
        "imageSaveError": [
            "en": "Could not save this image.",
            "ja": "画像を保存できませんでした。",
            "zh-TW": "無法儲存此圖片。",
            "zh-CN": "无法保存此图片。"
        ],
        "imageSaveFailed": [
            "en": "Could not save this image.",
            "ja": "この画像を保存できませんでした。",
            "zh-TW": "無法儲存此圖片。",
            "zh-CN": "无法保存此图片。"
        ],
        "readerTitle": [
            "en": "Reader",
            "ja": "リーダー",
            "zh-TW": "閱讀器",
            "zh-CN": "阅读器"
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
        "saveSelectedImages": [
            "en": "Save (%d)",
            "ja": "保存（%d）",
            "zh-TW": "儲存（%d）",
            "zh-CN": "保存（%d）"
        ],
        "imageNoSelectedImages": [
            "en": "No images selected.",
            "ja": "画像が選択されていません。",
            "zh-TW": "未選取圖片。",
            "zh-CN": "未选择图片。"
        ],
        "imageSelectionError": [
            "en": "Image selection is unavailable. Please try again.",
            "ja": "画像選択を利用できません。もう一度お試しください。",
            "zh-TW": "無法使用圖片選取功能，請再試一次。",
            "zh-CN": "无法使用图片选择功能，请重试。"
        ],
        "savedImagesToPhotos": [
            "en": "Saved %d image(s) to Photos.",
            "ja": "%d 枚の画像を保存しました。",
            "zh-TW": "已儲存 %d 張圖片到相簿。",
            "zh-CN": "已保存 %d 张图片到照片。"
        ],
        "imageNoneSaved": [
            "en": "No images could be saved.",
            "ja": "画像を保存できませんでした。",
            "zh-TW": "沒有圖片可以儲存。",
            "zh-CN": "没有图片可以保存。"
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
        "editAvatarFor": [
            "en": "Edit avatar for %@",
            "ja": "%@のアバターを編集",
            "zh-TW": "編輯 %@ 的頭像",
            "zh-CN": "编辑 %@ 的头像"
        ],
        "openAvatarEditorHint": [
            "en": "Double-tap to open the avatar editor",
            "ja": "ダブルタップしてアバターエディタを開く",
            "zh-TW": "點兩下以開啟頭像編輯器",
            "zh-CN": "双击打开头像编辑器"
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
            "en": "Zoom +",
            "ja": "拡大",
            "zh-TW": "放大",
            "zh-CN": "放大"
        ],
        "zoomOut": [
            "en": "Zoom -",
            "ja": "縮小",
            "zh-TW": "縮小",
            "zh-CN": "缩小"
        ],
        "cropModeBtn": [
            "en": "Crop",
            "ja": "切り取り",
            "zh-TW": "裁切",
            "zh-CN": "裁剪"
        ],
        "moveModeBtn": [
            "en": "Move",
            "ja": "移動",
            "zh-TW": "移動",
            "zh-CN": "移动"
        ],
        "fitToCanvas": [
            "en": "Fit",
            "ja": "合わせる",
            "zh-TW": "符合",
            "zh-CN": "适应"
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
        "selectAll": [
            "en": "Select All",
            "ja": "すべて選択",
            "zh-TW": "全選",
            "zh-CN": "全选"
        ],
        "deselectAll": [
            "en": "Deselect All",
            "ja": "選択解除",
            "zh-TW": "取消全選",
            "zh-CN": "取消全选"
        ],
        "notificationsSection": [
            "en": "Notifications",
            "ja": "通知",
            "zh-TW": "通知",
            "zh-CN": "通知"
        ],
        "localAlertsSection": [
            "en": "Local Alerts",
            "ja": "ローカル通知",
            "zh-TW": "本機提醒",
            "zh-CN": "本地提醒"
        ],
        "localAlertsFooter": [
            "en": "OshiReader checks for new items on this device and shows local digest alerts. iOS controls when background refresh runs, so alerts are best-effort and not instant push notifications.",
            "ja": "OshiReaderはこのデバイス上で新着を確認し、ローカルのまとめ通知を表示します。バックグラウンド更新のタイミングはiOSが制御するため、通知はベストエフォートで、即時のプッシュ通知ではありません。",
            "zh-TW": "OshiReader 會在此裝置上檢查新項目，並顯示本機摘要提醒。背景重新整理時間由 iOS 控制，因此提醒是盡力提供，不是即時推播通知。",
            "zh-CN": "OshiReader 会在此设备上检查新内容，并显示本地摘要提醒。后台刷新时间由 iOS 控制，因此提醒是尽力提供，不是即时推送通知。"
        ],
        "localAlertPermission": [
            "en": "Local Alert Permission",
            "ja": "ローカル通知の許可",
            "zh-TW": "本機提醒權限",
            "zh-CN": "本地提醒权限"
        ],
        "localAlertBackgroundRefresh": [
            "en": "Background Refresh",
            "ja": "バックグラウンド更新",
            "zh-TW": "背景重新整理",
            "zh-CN": "后台刷新"
        ],
        "backgroundRefreshAvailable": [
            "en": "Available",
            "ja": "利用可能",
            "zh-TW": "可用",
            "zh-CN": "可用"
        ],
        "backgroundRefreshDenied": [
            "en": "Off in iOS Settings",
            "ja": "iOS設定でオフ",
            "zh-TW": "已在 iOS 設定中關閉",
            "zh-CN": "已在 iOS 设置中关闭"
        ],
        "backgroundRefreshRestricted": [
            "en": "Restricted by iOS",
            "ja": "iOSにより制限中",
            "zh-TW": "受 iOS 限制",
            "zh-CN": "受 iOS 限制"
        ],
        "pushNotifications": [
            "en": "Push Notifications",
            "ja": "プッシュ通知",
            "zh-TW": "推播通知",
            "zh-CN": "推送通知"
        ],
        "notificationSetupHint": [
            "en": "Allow notifications to receive alerts for new matches.",
            "ja": "新しい一致の通知を受け取るには、通知を許可してください。",
            "zh-TW": "允許通知即可接收新相符項目的提醒。",
            "zh-CN": "允许通知即可接收新匹配项目的提醒。"
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
        "notifLocalSending": [
            "en": "Sending local test…",
            "ja": "ローカルテストを送信中…",
            "zh-TW": "正在傳送本機測試…",
            "zh-CN": "正在发送本地测试…"
        ],
        "notifLocalTestSent": [
            "en": "Local test notification sent.",
            "ja": "ローカルテスト通知を送信しました。",
            "zh-TW": "已傳送本機測試通知。",
            "zh-CN": "已发送本地测试通知。"
        ],
        "notifLocalTestFailed": [
            "en": "Local notification test failed. Check iOS notification settings.",
            "ja": "ローカル通知テストに失敗しました。iOSの通知設定を確認してください。",
            "zh-TW": "本機通知測試失敗，請檢查 iOS 通知設定。",
            "zh-CN": "本地通知测试失败，请检查 iOS 通知设置。"
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
        "notificationDigestTitle": [
            "en": "New Items Overnight",
            "ja": "夜間に新着アイテム",
            "zh-TW": "夜間新項目",
            "zh-CN": "夜间新项目"
        ],
        "notificationDigestBodyFmt": [
            "en": "%d new item(s) while you were in quiet hours.",
            "ja": "サイレント時間中に%d件の新着アイテムがありました。",
            "zh-TW": "在安靜時段中有 %d 則新項目。",
            "zh-CN": "在安静时段中有 %d 条新项目。"
        ],
        "quietHoursToggle": [
            "en": "Quiet Hours",
            "ja": "サイレント時間",
            "zh-TW": "安靜時段",
            "zh-CN": "安静时段"
        ],
        "quietHoursFooter": [
            "en": "During this window, new-item alerts are held and delivered as a single summary when it ends, instead of one per match.",
            "ja": "この時間帯は新着通知を保留し、終了時に1件のまとめ通知としてお届けします。",
            "zh-TW": "在此時段內，新項目通知會被保留，並在結束時以單一摘要通知送出，而非逐一發送。",
            "zh-CN": "在此时段内，新项目通知会被保留，并在结束时以单条摘要通知发送，而非逐一发送。"
        ],
        "quietHoursStart": [
            "en": "Starts",
            "ja": "開始",
            "zh-TW": "開始時間",
            "zh-CN": "开始时间"
        ],
        "quietHoursEnd": [
            "en": "Ends",
            "ja": "終了",
            "zh-TW": "結束時間",
            "zh-CN": "结束时间"
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
        "iCloudSyncSection": [
            "en": "iCloud Sync",
            "ja": "iCloud同期",
            "zh-TW": "iCloud 同步",
            "zh-CN": "iCloud 同步"
        ],
        "iCloudSyncToggle": [
            "en": "Sync with iCloud",
            "ja": "iCloudと同期する",
            "zh-TW": "與 iCloud 同步",
            "zh-CN": "与 iCloud 同步"
        ],
        "iCloudSyncStatusLabel": [
            "en": "Status",
            "ja": "状態",
            "zh-TW": "狀態",
            "zh-CN": "状态"
        ],
        "iCloudSyncNow": [
            "en": "Sync Now",
            "ja": "今すぐ同期",
            "zh-TW": "立即同步",
            "zh-CN": "立即同步"
        ],
        "iCloudSyncNeverSynced": [
            "en": "Not synced yet",
            "ja": "まだ同期していません",
            "zh-TW": "尚未同步",
            "zh-CN": "尚未同步"
        ],
        "iCloudSyncSyncing": [
            "en": "Syncing…",
            "ja": "同期中…",
            "zh-TW": "同步中…",
            "zh-CN": "同步中…"
        ],
        "iCloudSyncFooter": [
            "en": "Syncs your terms, saved pages, custom URLs, and settings across your devices via your private iCloud account. Whichever device saves last wins if the same data changes on two devices at once.",
            "ja": "キーワード、保存したページ、カスタムURL、設定を、あなたのiCloudアカウント経由でデバイス間で同期します。同じデータが2台のデバイスで同時に変更された場合は、最後に保存した方が優先されます。",
            "zh-TW": "透過你的私人 iCloud 帳號，在裝置之間同步追蹤關鍵字、已儲存頁面、自訂網址與設定。若同一份資料在兩台裝置上同時變更，以最後儲存的為準。",
            "zh-CN": "通过你的私人 iCloud 账号，在设备之间同步追踪关键字、已保存页面、自定义网址与设置。若同一份数据在两台设备上同时更改，以最后保存的为准。"
        ],
        "iCloudSyncMultiProfileUnavailable": [
            "en": "iCloud Sync is only available with a single local profile — it isn't supported across multiple profiles yet.",
            "ja": "iCloud同期はローカルプロフィールが1つの場合のみ利用できます。複数プロフィールにはまだ対応していません。",
            "zh-TW": "iCloud 同步僅適用於單一本機個人檔案，目前尚不支援多個個人檔案。",
            "zh-CN": "iCloud 同步仅适用于单个本地个人资料，目前尚不支持多个个人资料。"
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
        "twitterBearerTokenPlaceholder": [
            "en": "X Bearer Token",
            "ja": "X Bearer Token",
            "zh-TW": "X Bearer Token",
            "zh-CN": "X Bearer Token"
        ],
        "twitterTokenMissingHint": [
            "en": "X results are limited to a public search and won't trigger notifications until you add a bearer token below.",
            "ja": "Bearer Tokenを下に設定するまで、Xの結果は公開検索のみに限定され、通知も届きません。",
            "zh-TW": "在下方設定 Bearer Token 之前，X 的結果僅限公開搜尋，也不會觸發通知。",
            "zh-CN": "在下方设置 Bearer Token 之前，X 的结果仅限公开搜索，也不会触发通知。"
        ],
        "themeStyle": [
            "en": "Style",
            "ja": "スタイル",
            "zh-TW": "樣式",
            "zh-CN": "样式"
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
        "profiles": [
            "en": "Profiles",
            "ja": "プロフィール",
            "zh-TW": "個人檔案",
            "zh-CN": "个人档案"
        ],
        "profilesFooter": [
            "en": "Profiles stay on this device. Imported profile packages create a new profile.",
            "ja": "プロフィールはこのデバイス内に保存されます。読み込んだプロフィールパッケージは新しいプロフィールとして作成されます。",
            "zh-TW": "個人檔案會保留在此裝置上。匯入的個人檔案套件會建立新的個人檔案。",
            "zh-CN": "个人档案会保留在此设备上。导入的个人档案包会创建新的个人档案。"
        ],
        "addProfile": [
            "en": "Add profile",
            "ja": "プロフィールを追加",
            "zh-TW": "新增個人檔案",
            "zh-CN": "添加个人档案"
        ],
        "renameProfile": [
            "en": "Rename profile",
            "ja": "プロフィール名を変更",
            "zh-TW": "重新命名個人檔案",
            "zh-CN": "重命名个人档案"
        ],
        "exportProfile": [
            "en": "Export profile",
            "ja": "プロフィールを書き出す",
            "zh-TW": "匯出個人檔案",
            "zh-CN": "导出个人档案"
        ],
        "importProfile": [
            "en": "Import profile",
            "ja": "プロフィールを読み込む",
            "zh-TW": "匯入個人檔案",
            "zh-CN": "导入个人档案"
        ],
        "profileName": [
            "en": "Profile name",
            "ja": "プロフィール名",
            "zh-TW": "個人檔案名稱",
            "zh-CN": "个人档案名称"
        ],
        "profileStatus": [
            "en": "Profile status",
            "ja": "プロフィールの状態",
            "zh-TW": "個人檔案狀態",
            "zh-CN": "个人档案状态"
        ],
        "profileImported": [
            "en": "Imported profile %@.",
            "ja": "プロフィール「%@」を読み込みました。",
            "zh-TW": "已匯入個人檔案「%@」。",
            "zh-CN": "已导入个人档案“%@”。"
        ],
        "profileInvalidName": [
            "en": "Profile names must not be empty.",
            "ja": "プロフィール名は空にできません。",
            "zh-TW": "個人檔案名稱不可空白。",
            "zh-CN": "个人档案名称不能为空。"
        ],
        "profileDuplicateName": [
            "en": "A profile with that name already exists.",
            "ja": "同じ名前のプロフィールがすでに存在します。",
            "zh-TW": "已有相同名稱的個人檔案。",
            "zh-CN": "已存在同名个人档案。"
        ],
        "profileNotFound": [
            "en": "The selected profile is no longer available.",
            "ja": "選択したプロフィールは利用できません。",
            "zh-TW": "選取的個人檔案已無法使用。",
            "zh-CN": "所选个人档案已不可用。"
        ],
        "cannotDeleteLastProfile": [
            "en": "The final profile cannot be deleted.",
            "ja": "最後のプロフィールは削除できません。",
            "zh-TW": "無法刪除最後一個個人檔案。",
            "zh-CN": "无法删除最后一个个人档案。"
        ],
        "invalidProfilePackage": [
            "en": "The profile package is invalid or incomplete.",
            "ja": "プロフィールパッケージが無効または不完全です。",
            "zh-TW": "個人檔案套件無效或不完整。",
            "zh-CN": "个人档案包无效或不完整。"
        ],
        "unsupportedProfilePackageVersion": [
            "en": "This profile package version is not supported.",
            "ja": "このプロフィールパッケージのバージョンには対応していません。",
            "zh-TW": "不支援此個人檔案套件版本。",
            "zh-CN": "不支持此个人档案包版本。"
        ],
        "profilePackageTooLarge": [
            "en": "The profile package is too large.",
            "ja": "プロフィールパッケージが大きすぎます。",
            "zh-TW": "個人檔案套件太大。",
            "zh-CN": "个人档案包太大。"
        ],
        "amebloBlogs": [
            "en": "Ameblo blogs",
            "ja": "Amebloブログ",
            "zh-TW": "Ameblo 部落格",
            "zh-CN": "Ameblo 博客"
        ],
        "amebloBlogsFooter": [
            "en": "Add Ameba blog URLs to search their RSS feeds for every active watch term. Up to 20 blogs.",
            "ja": "AmebaブログのURLを追加すると、すべての有効なキーワードでRSSフィードを検索します。最大20件まで追加できます。",
            "zh-TW": "新增 Ameba 部落格網址後，會針對每個啟用的追蹤關鍵字搜尋其 RSS feed。最多 20 個部落格。",
            "zh-CN": "添加 Ameba 博客网址后，会针对每个启用的追踪关键字搜索其 RSS feed。最多 20 个博客。"
        ],
        "blogTitleOptional": [
            "en": "Blog title (optional)",
            "ja": "ブログタイトル（任意）",
            "zh-TW": "部落格標題（選填）",
            "zh-CN": "博客标题（可选）"
        ],
        "amebloInvalidURL": [
            "en": "Enter an Ameblo blog URL such as https://ameblo.jp/blog-id.",
            "ja": "https://ameblo.jp/blog-id のようなAmebloブログURLを入力してください。",
            "zh-TW": "請輸入 Ameblo 部落格網址，例如 https://ameblo.jp/blog-id。",
            "zh-CN": "请输入 Ameblo 博客网址，例如 https://ameblo.jp/blog-id。"
        ],
        "amebloDuplicate": [
            "en": "This Ameblo blog is already configured.",
            "ja": "このAmebloブログはすでに設定されています。",
            "zh-TW": "此 Ameblo 部落格已設定。",
            "zh-CN": "此 Ameblo 博客已配置。"
        ],
        "amebloLimitReached": [
            "en": "You can configure up to 20 Ameblo blogs.",
            "ja": "Amebloブログは最大20件まで設定できます。",
            "zh-TW": "最多可設定 20 個 Ameblo 部落格。",
            "zh-CN": "最多可配置 20 个 Ameblo 博客。"
        ],
        "addAmebloBlog": [
            "en": "Add Ameblo blog",
            "ja": "Amebloブログを追加",
            "zh-TW": "新增 Ameblo 部落格",
            "zh-CN": "添加 Ameblo 博客"
        ],
        "amebloEnabled": [
            "en": "Ameblo is enabled",
            "ja": "Amebloは有効です",
            "zh-TW": "Ameblo 已啟用",
            "zh-CN": "Ameblo 已启用"
        ],
        "clearAllData": [
            "en": "Clear All Data",
            "ja": "データをすべて削除",
            "zh-TW": "清除所有資料",
            "zh-CN": "清除所有数据"
        ],
        "clearAllDataAlert": [
            "en": "Clear All Data?",
            "ja": "データをすべて削除しますか？",
            "zh-TW": "清除所有資料？",
            "zh-CN": "清除所有数据？"
        ],
        "clearAllDataTitle": [
            "en": "Clear All Data?",
            "ja": "すべてのデータを削除しますか？",
            "zh-TW": "要清除所有資料嗎？",
            "zh-CN": "要清除所有数据吗？"
        ],
        "clearAllDataMessage": [
            "en": "This removes keywords, feed items, saved pages, custom URLs, avatars, hidden items, wallpaper, and source order from this device.",
            "ja": "キーワード、フィードアイテム、保存ページ、カスタムURL、アバター、非表示アイテム、壁紙、ソース順序がこのデバイスから削除されます。",
            "zh-TW": "將從此裝置移除關鍵字、動態項目、已儲存頁面、自訂URL、頭貼、隱藏項目、壁紙及來源順序。",
            "zh-CN": "将从此设备移除关键词、动态项目、已保存页面、自定义URL、头像、隐藏项目、壁纸及来源顺序。"
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
        "feedLoadMoreFmt": [
            "en": "Load more (%d remaining)",
            "ja": "もっと見る（残り%d件）",
            "zh-TW": "載入更多（剩餘%d則）",
            "zh-CN": "加载更多（剩余%d条）"
        ],
        "addCustomFeed": [
            "en": "Add Custom RSS/Web Feed",
            "ja": "カスタムRSS/Webフィードを追加",
            "zh-TW": "新增自訂RSS/網頁來源",
            "zh-CN": "添加自定义RSS/网页来源"
        ],
        "feedTitlePlaceholder": [
            "en": "Feed/Webpage Title…",
            "ja": "フィード/ページタイトル…",
            "zh-TW": "來源/網頁標題…",
            "zh-CN": "来源/网页标题…"
        ],
        "urlPlaceholder": [
            "en": "https://…",
            "ja": "https://…",
            "zh-TW": "https://…",
            "zh-CN": "https://…"
        ],
        "reorderSources": [
            "en": "Reorder Sources",
            "ja": "ソースを並び替え",
            "zh-TW": "重新排列來源",
            "zh-CN": "重新排列来源"
        ],
        "refresh": [
            "en": "Refresh",
            "ja": "更新",
            "zh-TW": "重新整理",
            "zh-CN": "刷新"
        ],
        "close": [
            "en": "Close",
            "ja": "閉じる",
            "zh-TW": "關閉",
            "zh-CN": "关闭"
        ],
        "translate": [
            "en": "Translate",
            "ja": "翻訳",
            "zh-TW": "翻譯",
            "zh-CN": "翻译"
        ],
        "selectImages": [
            "en": "Select Images",
            "ja": "画像を選択",
            "zh-TW": "選取圖片",
            "zh-CN": "选择图片"
        ],
        "saveAllImages": [
            "en": "Save All Images",
            "ja": "すべての画像を保存",
            "zh-TW": "儲存所有圖片",
            "zh-CN": "保存所有图片"
        ],
        "back": [
            "en": "Back",
            "ja": "戻る",
            "zh-TW": "返回",
            "zh-CN": "返回"
        ],
        "deleteProfile": [
            "en": "Delete Profile",
            "ja": "プロフィールを削除",
            "zh-TW": "刪除個人檔案",
            "zh-CN": "删除个人资料"
        ],
        "removeAliasFmt": [
            "en": "Remove alias %@",
            "ja": "別名「%@」を削除",
            "zh-TW": "移除別名「%@」",
            "zh-CN": "移除别名「%@」"
        ],
        "notifyOnNewToggle": [
            "en": "Notify on New Items",
            "ja": "新着通知",
            "zh-TW": "新項目通知",
            "zh-CN": "新项目通知"
        ],
        "editAvatarFmt": [
            "en": "Edit Avatar for %@",
            "ja": "%@のアバターを編集",
            "zh-TW": "編輯 %@ 的頭像",
            "zh-CN": "编辑 %@ 的头像"
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
        "exportDiagnostics": [
            "en": "Export Diagnostics",
            "ja": "診断データを書き出す",
            "zh-TW": "匯出診斷資料",
            "zh-CN": "导出诊断数据"
        ],
        "exportOPML": [
            "en": "Export as OPML",
            "ja": "OPMLとして書き出す",
            "zh-TW": "匯出為 OPML",
            "zh-CN": "导出为 OPML"
        ],
        "importBackup": [
            "en": "Import Local Backup",
            "ja": "ローカルバックアップを読み込む",
            "zh-TW": "匯入本機備份",
            "zh-CN": "导入本地备份"
        ],
        "exportEncryptedBackup": [
            "en": "Export Encrypted Backup",
            "ja": "暗号化バックアップを書き出す",
            "zh-TW": "匯出加密備份",
            "zh-CN": "导出加密备份"
        ],
        "importEncryptedBackup": [
            "en": "Import Encrypted Backup",
            "ja": "暗号化バックアップを読み込む",
            "zh-TW": "匯入加密備份",
            "zh-CN": "导入加密备份"
        ],
        "encryptedBackupTitle": [
            "en": "Encrypted Backup",
            "ja": "暗号化バックアップ",
            "zh-TW": "加密備份",
            "zh-CN": "加密备份"
        ],
        "unlockBackup": [
            "en": "Unlock Backup",
            "ja": "バックアップのロックを解除",
            "zh-TW": "解鎖備份",
            "zh-CN": "解锁备份"
        ],
        "password": [
            "en": "Password",
            "ja": "パスワード",
            "zh-TW": "密碼",
            "zh-CN": "密码"
        ],
        "confirmPassword": [
            "en": "Confirm password",
            "ja": "パスワードを確認",
            "zh-TW": "確認密碼",
            "zh-CN": "确认密码"
        ],
        "encryptedBackupExportPasswordHint": [
            "en": "Use at least 12 characters. The password is never stored.",
            "ja": "12文字以上を使用してください。パスワードは保存されません。",
            "zh-TW": "請使用至少 12 個字元。密碼永遠不會被儲存。",
            "zh-CN": "请使用至少 12 个字符。密码永远不会被保存。"
        ],
        "encryptedBackupImportPasswordHint": [
            "en": "Enter the password used when this encrypted backup was exported.",
            "ja": "この暗号化バックアップを書き出したときに使用したパスワードを入力してください。",
            "zh-TW": "請輸入匯出此加密備份時使用的密碼。",
            "zh-CN": "请输入导出此加密备份时使用的密码。"
        ],
        "passwordsDoNotMatch": [
            "en": "Passwords do not match.",
            "ja": "パスワードが一致しません。",
            "zh-TW": "密碼不一致。",
            "zh-CN": "密码不一致。"
        ],
        "encryptedBackupInvalidPassword": [
            "en": "Password must be between 12 and 256 characters.",
            "ja": "パスワードは12文字以上256文字以下にしてください。",
            "zh-TW": "密碼長度必須介於 12 到 256 個字元。",
            "zh-CN": "密码长度必须介于 12 到 256 个字符。"
        ],
        "encryptedBackupInvalidEnvelope": [
            "en": "This is not a valid OshiReader encrypted backup.",
            "ja": "有効なOshiReader暗号化バックアップではありません。",
            "zh-TW": "這不是有效的 OshiReader 加密備份。",
            "zh-CN": "这不是有效的 OshiReader 加密备份。"
        ],
        "encryptedBackupUnsupportedVersion": [
            "en": "This encrypted backup version is not supported.",
            "ja": "この暗号化バックアップのバージョンには対応していません。",
            "zh-TW": "不支援此加密備份版本。",
            "zh-CN": "不支持此加密备份版本。"
        ],
        "encryptedBackupAuthenticationFailed": [
            "en": "The password is incorrect or the backup was corrupted.",
            "ja": "パスワードが正しくないか、バックアップが破損しています。",
            "zh-TW": "密碼不正確，或備份已損毀。",
            "zh-CN": "密码不正确，或备份已损坏。"
        ],
        "encryptedBackupKeyDerivationFailed": [
            "en": "The encrypted backup key could not be derived.",
            "ja": "暗号化バックアップキーを生成できませんでした。",
            "zh-TW": "無法衍生加密備份金鑰。",
            "zh-CN": "无法派生加密备份密钥。"
        ],
        "encryptedBackupPayloadTooLarge": [
            "en": "The encrypted backup file is too large.",
            "ja": "暗号化バックアップファイルが大きすぎます。",
            "zh-TW": "加密備份檔案太大。",
            "zh-CN": "加密备份文件太大。"
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
        "backupFileTooLarge": [
            "en": "Backup file is too large.",
            "ja": "バックアップファイルが大きすぎます。",
            "zh-TW": "備份檔案太大。",
            "zh-CN": "备份文件太大。"
        ],
        "diagnosticsExportFailed": [
            "en": "Couldn't export diagnostics.",
            "ja": "診断データを書き出せませんでした。",
            "zh-TW": "無法匯出診斷資料。",
            "zh-CN": "无法导出诊断数据。"
        ],
        "backupTooManyPlatforms": [
            "en": "Backup contains too many platforms.",
            "ja": "バックアップ内のプラットフォーム数が多すぎます。",
            "zh-TW": "備份包含太多平台。",
            "zh-CN": "备份包含太多平台。"
        ],
        "backupTooMuchData": [
            "en": "Backup contains too much data.",
            "ja": "バックアップ内のデータ量が多すぎます。",
            "zh-TW": "備份包含太多資料。",
            "zh-CN": "备份包含太多数据。"
        ],
        "backupInvalidRestoreManifest": [
            "en": "Invalid restore manifest.",
            "ja": "復元マニフェストが無効です。",
            "zh-TW": "還原清單無效。",
            "zh-CN": "恢复清单无效。"
        ],
        "backupInvalidRestoreStagingPath": [
            "en": "Invalid restore staging path.",
            "ja": "復元用ステージングパスが無効です。",
            "zh-TW": "還原暫存路徑無效。",
            "zh-CN": "恢复暂存路径无效。"
        ],
        "backupRestoreStagingIncomplete": [
            "en": "Restore staging data is incomplete.",
            "ja": "復元用ステージングデータが不完全です。",
            "zh-TW": "還原暫存資料不完整。",
            "zh-CN": "恢复暂存数据不完整。"
        ],
        "searchGroupNews": [
            "en": "News",
            "ja": "ニュース",
            "zh-TW": "新聞",
            "zh-CN": "新闻"
        ],
        "searchGroupEntertainment": [
            "en": "Entertainment",
            "ja": "エンタメ",
            "zh-TW": "娛樂",
            "zh-CN": "娱乐"
        ],
        "searchGroupMagazines": [
            "en": "Magazines",
            "ja": "雑誌",
            "zh-TW": "雜誌",
            "zh-CN": "杂志"
        ],
        "searchGroupVideo": [
            "en": "Video",
            "ja": "動画",
            "zh-TW": "影片",
            "zh-CN": "视频"
        ],
        "searchGroupWriting": [
            "en": "Writing",
            "ja": "ライター",
            "zh-TW": "寫作",
            "zh-CN": "写作"
        ],
        "searchGroupSocial": [
            "en": "Social",
            "ja": "SNS",
            "zh-TW": "社群",
            "zh-CN": "社交"
        ],
        "searchGroupCommunity": [
            "en": "Community",
            "ja": "コミュニティ",
            "zh-TW": "社區",
            "zh-CN": "社区"
        ],
        "searchGroupWeb": [
            "en": "Web",
            "ja": "ウェブ",
            "zh-TW": "網頁",
            "zh-CN": "网页"
        ],
        "searchGroupShopping": [
            "en": "Shopping",
            "ja": "ショッピング",
            "zh-TW": "購物",
            "zh-CN": "购物"
        ],
        "searchGroupCustom": [
            "en": "Custom",
            "ja": "カスタム",
            "zh-TW": "自訂",
            "zh-CN": "自定义"
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

    func tFormat(_ key: String, _ value: String) -> String {
        t(key).replacingOccurrences(of: "%@", with: value)
    }

    func tSearchGroup(_ group: String) -> String {
        let key = "searchGroup\(group)"
        let result = t(key)
        return result == key ? group : result
    }
}
