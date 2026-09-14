import Photos
import SafariServices
import SwiftUI
import UIKit
import WebKit

enum ReaderWebLoadState {
    case loading
    case loaded
    case failed
}

struct ReaderView: View {
    let feedItem: FeedItem
    /// The ordered list `feedItem` was opened from (e.g. the current feed page).
    /// Empty means "no sibling navigation" — prev/next controls stay hidden.
    let siblingItems: [FeedItem]
    /// Lets a split-view parent keep its own selection in sync when the user
    /// moves between siblings from inside the reader instead of the list.
    var onNavigate: ((FeedItem) -> Void)? = nil

    @StateObject private var db = LocalDB.shared
    @StateObject private var theme = ThemeManager.shared
    @StateObject private var i18n = I18nManager.shared
    @StateObject private var appearance = AppearanceManager.shared

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var currentItem: FeedItem
    @State private var readerMode: Bool
    @State private var readerTheme: AppThemeMode = .light
    @State private var fontSize: CGFloat = 16.0
    /// Page zoom for Original Web Mode. Reader Mode has its own text-size
    /// control (`fontSize`) instead — resizing actual reading text serves
    /// that mode better than scaling a fixed layout would.
    @State private var webZoomScale: CGFloat = 1.0
    @State private var isTranslated = false
    @State private var saveImageStatus = ""
    @State private var showingSaveImageStatus = false
    @State private var selectImagesCounter = 0
    @State private var imageSelectionActionCounter = 0
    @State private var imageSelectionAction = ""
    @State private var saveAllImagesCounter = 0
    @State private var isSelectingImages = false
    @State private var selectedImageCount = 0
    @State private var isSavingSelectedImages = false
    @State private var webLoadState: ReaderWebLoadState = .loading
    @State private var showSignInBanner = false
    @State private var isSigningIntoX = false
    @State private var showOpenInBrowserBanner = false
    /// Whether the web view has navigated away from the article it opened
    /// (the user tapped a link inside the page) and so has somewhere to go
    /// back to. Distinct from `previousSiblingItem` — that switches between
    /// feed items; this steps back within one article's own page history.
    @State private var canGoBackInPage = false
    @State private var goBackCounter = 0

    init(feedItem: FeedItem, siblingItems: [FeedItem] = [], onNavigate: ((FeedItem) -> Void)? = nil) {
        self.feedItem = feedItem
        self.siblingItems = siblingItems
        self.onNavigate = onNavigate
        _currentItem = State(initialValue: feedItem)
        _readerMode = State(initialValue: Self.initialReaderMode(for: feedItem))
        _isTranslated = State(initialValue: UserDefaults.standard.bool(forKey: LocalProfileStore.defaultsKey("auto_translate_reader")) && !Self.usesSystemSafari(for: feedItem))
    }

    static func initialReaderMode(for feedItem: FeedItem) -> Bool {
        if usesSystemSafari(for: feedItem) {
            return false
        }
        return !feedItem.id.hasPrefix("search:")
    }

    static func usesSystemSafari(for feedItem: FeedItem) -> Bool {
        PlatformRegistry.normalizeID(feedItem.platform) == "5ch"
    }

    var originalPageUrl: URL? {
        guard let normalized = normalizedReaderUrl(currentItem.url, platform: currentItem.platform) else { return nil }
        return URL(string: normalized)
    }

    var targetUrl: URL? {
        if isSigningIntoX {
            return URL(string: "https://x.com/login")
        }
        guard let originalUrl = originalPageUrl else { return nil }
        if isTranslated, !Self.usesSystemSafari(for: currentItem) {
            let targetLang: String
            switch i18n.lang {
            case "ja": targetLang = "ja"
            case "en": targetLang = "en"
            case "zh-CN": targetLang = "zh-CN"
            case "zh-TW": targetLang = "zh-TW"
            default: targetLang = "en"
            }
            if let escapedUrl = originalUrl.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               let transUrl = URL(string: "https://translate.google.com/translate?sl=auto&tl=\(targetLang)&u=\(escapedUrl)") {
                return transUrl
            }
        }
        return originalUrl
    }

    var isSaved: Bool {
        db.savedPages.contains(where: { $0.id == currentItem.id })
    }

    var currentSiblingIndex: Int? {
        siblingItems.firstIndex(where: { $0.id == currentItem.id })
    }

    var previousSiblingItem: FeedItem? {
        guard let index = currentSiblingIndex, index > 0 else { return nil }
        return siblingItems[index - 1]
    }

    var nextSiblingItem: FeedItem? {
        guard let index = currentSiblingIndex, index + 1 < siblingItems.count else { return nil }
        return siblingItems[index + 1]
    }

    func navigate(to item: FeedItem) {
        currentItem = item
        readerMode = Self.initialReaderMode(for: item)
        isTranslated = UserDefaults.standard.bool(forKey: LocalProfileStore.defaultsKey("auto_translate_reader")) && !Self.usesSystemSafari(for: item)
        isSigningIntoX = false
        showSignInBanner = false
        showOpenInBrowserBanner = false
        canGoBackInPage = false
        webZoomScale = 1.0
        RecentTermUsageStore.shared.markUsed(keyword: item.watch_term_keyword, terms: db.terms)
        onNavigate?(item)
    }

    var body: some View {
        // Read once — usesSystemSafari (and the originalPageUrl it, the toolbar
        // ShareLink, and the load overlay all separately re-derive) is cheap on
        // its own, but body evaluates it several times per render; same
        // reasoning as the single sibling read in the toolbar below.
        let usesSafari = Self.usesSystemSafari(for: currentItem)
        let originalURL = originalPageUrl
        VStack(spacing: 0) {
            if let url = targetUrl {
                ZStack {
                    if usesSafari {
                        SafariReaderView(url: url)
                            .id(url)
                            .background(bgColor)
                            .onAppear {
                                webLoadState = .loaded
                            }
                    } else {
                        WebViewHelper(
                            url: url,
                            cacheId: currentItem.id,
                            cacheGeneration: db.contentCacheGeneration,
                            platform: currentItem.platform,
                            themeMode: readerTheme,
                            fontSize: fontSize,
                            fontFamilyCSS: appearance.readerFontFamilyCSS,
                            readerMode: readerMode,
                            zoomScale: webZoomScale,
                            selectImagesCounter: selectImagesCounter,
                            imageSelectionActionCounter: imageSelectionActionCounter,
                            imageSelectionAction: imageSelectionAction,
                            saveAllImagesCounter: saveAllImagesCounter,
                            goBackCounter: goBackCounter,
                            onNavigationHistoryChange: { canGoBack in canGoBackInPage = canGoBack },
                            onLoadStateChange: { state in
                                webLoadState = state
                                if state == .loading {
                                    isSelectingImages = false
                                    isSavingSelectedImages = false
                                    selectedImageCount = 0
                                    showSignInBanner = false
                                    showOpenInBrowserBanner = false
                                    canGoBackInPage = false
                                    webZoomScale = 1.0
                                }
                            },
                            onImageSelectionState: { selectedImageCount = $0 },
                            onImageSelectionUnavailable: {
                                isSelectingImages = false
                                isSavingSelectedImages = false
                                selectedImageCount = 0
                            },
                            onImageSelectionFailure: {
                                isSelectingImages = false
                                isSavingSelectedImages = false
                                selectedImageCount = 0
                                saveImageStatus = i18n.t("imageSelectionError")
                                showingSaveImageStatus = true
                            },
                            onSaveAllImagesUnavailable: {
                                isSavingSelectedImages = false
                                saveImageStatus = i18n.t("imageSelectionError")
                                showingSaveImageStatus = true
                            },
                            onSelectedImages: { urls in saveSelectedImages(urls) },
                            onAllImages: { urls in saveSelectedImages(urls, emptyMessageKey: "imageNoLargeImages") },
                            onContentBlocked: {
                                if PlatformRegistry.normalizeID(currentItem.platform) == "twitter" {
                                    if !isSigningIntoX { showSignInBanner = true }
                                } else {
                                    showOpenInBrowserBanner = true
                                }
                            }
                        )
                        .equatable()
                        .background(bgColor)
                    }

                    if !usesSafari, webLoadState != .loaded {
                        readerLoadStateOverlay
                            .allowsHitTesting(webLoadState == .failed)
                    }

                    VStack {
                        if isSigningIntoX {
                            signInReturnBanner
                        } else if showSignInBanner {
                            signInPromptBanner
                        } else if showOpenInBrowserBanner {
                            openInBrowserBanner
                        }
                        Spacer()
                    }
                }
            } else {
                Text(i18n.t("invalidUrl"))
                    .foregroundColor(theme.colors.textMuted)
            }

            if !usesSafari {
                readerControlBar
            }
        }
        .background(bgColor)
        .navigationTitle(currentItem.title ?? i18n.t("readerTitle"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if !usesSafari, canGoBackInPage {
                    Button {
                        goBackCounter += 1
                    } label: {
                        Image(systemName: "chevron.backward")
                    }
                    .accessibilityLabel(i18n.t("readerGoBack"))
                    .accessibilityIdentifier("reader.goBackButton")
                }
            }

            ToolbarItemGroup(placement: .navigationBarLeading) {
                if !siblingItems.isEmpty {
                    // Read each sibling once — both properties independently
                    // re-scan siblingItems via currentSiblingIndex, and this
                    // toolbar previously read each of them twice (once for
                    // the button action, once for .disabled).
                    let previous = previousSiblingItem
                    let next = nextSiblingItem

                    Button {
                        if let previous { navigate(to: previous) }
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .disabled(previous == nil)
                    .accessibilityLabel(i18n.t("readerPreviousArticle"))
                    .accessibilityIdentifier("reader.previousArticleButton")

                    Button {
                        if let next { navigate(to: next) }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .disabled(next == nil)
                    .accessibilityLabel(i18n.t("readerNextArticle"))
                    .accessibilityIdentifier("reader.nextArticleButton")
                }
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                if !usesSafari {
                    Button {
                        isTranslated.toggle()
                    } label: {
                        Image(systemName: "translate")
                            .foregroundColor(isTranslated ? theme.colors.primary : theme.colors.textMuted)
                    }
                    .accessibilityLabel(i18n.t("translate"))
                    .accessibilityValue(isTranslated ? "on" : "off")
                    .accessibilityIdentifier("reader.translateButton")
                }
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                let saved = isSaved
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    _ = db.toggleSaved(item: currentItem)
                } label: {
                    Image(systemName: saved ? "bookmark.fill" : "bookmark")
                        .foregroundColor(theme.colors.primary)
                }
                .accessibilityLabel(i18n.t("tabSaved"))
                .accessibilityValue(saved ? "on" : "off")
                .accessibilityIdentifier("reader.bookmarkButton")
            }

            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if !usesSafari {
                    if isSavingSelectedImages {
                        ProgressView().tint(theme.colors.primary)
                    } else if isSelectingImages {
                        Button(i18n.t("cancel")) {
                            imageSelectionAction = "cancel"
                            imageSelectionActionCounter += 1
                            isSelectingImages = false
                            selectedImageCount = 0
                        }
                        .accessibilityIdentifier("reader.cancelImageSelectionButton")
                        Button {
                            imageSelectionAction = "finish"
                            imageSelectionActionCounter += 1
                            isSavingSelectedImages = true
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                                .foregroundColor(theme.colors.primary)
                        }
                        .accessibilityLabel(i18n.tFormat("saveSelectedImages", selectedImageCount))
                        .disabled(selectedImageCount == 0)
                        .accessibilityIdentifier("reader.saveSelectedImagesButton")
                    } else {
                        Menu {
                            Button {
                                isSelectingImages = true
                                selectedImageCount = 0
                                selectImagesCounter += 1
                            } label: {
                                Label(i18n.t("selectMultipleImages"), systemImage: "checklist")
                            }
                            .accessibilityIdentifier("reader.selectImagesButton")

                            Button {
                                isSavingSelectedImages = true
                                saveAllImagesCounter += 1
                            } label: {
                                Label(i18n.t("saveAllImages"), systemImage: "square.and.arrow.down.on.square")
                            }
                            .accessibilityIdentifier("reader.saveAllImagesButton")
                        } label: {
                            Image(systemName: "checklist")
                                .foregroundColor(theme.colors.primary)
                        }
                        .accessibilityLabel(i18n.t("selectImages"))
                        .accessibilityIdentifier("reader.imageActionsMenuButton")
                    }
                }
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                if let url = originalURL {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundColor(theme.colors.primary)
                    }
                    .accessibilityIdentifier("reader.shareButton")
                }
            }
        }
        .alert(i18n.t("imageActions"), isPresented: $showingSaveImageStatus) {
            Button(i18n.t("ok"), role: .cancel) {}
        } message: {
            Text(saveImageStatus)
        }
        .onAppear {
            readerTheme = theme.mode
            fontSize = appearance.readerFontSize
            if UserDefaults.standard.bool(forKey: LocalProfileStore.defaultsKey("auto_translate_reader")) {
                isTranslated = true
            }
        }
        .onChange(of: appearance.fontSizeChoice) {
            fontSize = appearance.readerFontSize
        }
        .onChange(of: feedItem.id) { _, _ in
            // A parent that swaps `feedItem` without recreating this view (e.g. a
            // split-view pane whose selection changed) lands here; route it through
            // the same soft reset chevron navigation uses so font/theme choices
            // made mid-session survive instead of being torn down with a fresh view.
            if feedItem.id != currentItem.id {
                navigate(to: feedItem)
            }
        }
    }

    private var readerControlBar: some View {
        Group {
            if horizontalSizeClass == .compact {
                compactReaderControlBar
            } else {
                regularReaderControlBar
            }
        }
        .background(theme.colors.card)
        .overlay(Rectangle().frame(height: 0.5).foregroundColor(theme.colors.divider), alignment: .top)
    }

    private var regularReaderControlBar: some View {
        HStack(spacing: 12) {
            readerModeButton(showTitle: true)
            Spacer()
            centerReaderControls
            Spacer()
            themePicker(width: 112)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var compactReaderControlBar: some View {
        HStack(spacing: 8) {
            readerModeButton(showTitle: false)
            Spacer(minLength: 4)
            centerReaderControls
                .layoutPriority(1)
            Spacer(minLength: 4)
            themePicker(width: 104)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// Reader Mode gets the text-size control; Original Web Mode gets page
    /// zoom instead — the same slot in the control bar, whichever is
    /// relevant to what's currently on screen.
    @ViewBuilder
    private var centerReaderControls: some View {
        if readerMode {
            fontSizeControls
        } else {
            webZoomControls
        }
    }

    private func readerModeButton(showTitle: Bool) -> some View {
        Button(action: { readerMode.toggle() }) {
            if showTitle {
                Label(readerMode ? i18n.t("readerModeText") : i18n.t("readerModeWeb"),
                      systemImage: readerMode ? "doc.plaintext" : "globe")
            } else {
                Image(systemName: readerMode ? "doc.plaintext" : "globe")
            }
        }
        .font(.caption)
        .fontWeight(.bold)
        .frame(minWidth: showTitle ? nil : 38, minHeight: 34)
        .padding(.horizontal, showTitle ? 10 : 0)
        .padding(.vertical, showTitle ? 6 : 0)
        .background(theme.colors.divider)
        .foregroundColor(theme.colors.primary)
        .cornerRadius(8)
        .accessibilityLabel(readerMode ? i18n.t("readerModeText") : i18n.t("readerModeWeb"))
        .accessibilityValue(readerMode ? "reader" : "web")
        .accessibilityIdentifier("reader.modeToggleButton")
    }

    private var fontSizeControls: some View {
        HStack(spacing: 10) {
            Button(action: { fontSize = max(12.0, fontSize - 2.0) }) {
                Text("A-")
                    .font(.subheadline)
                    .foregroundColor(theme.colors.textSub)
            }
            .accessibilityHidden(true)

            Text("\(Int(fontSize))")
                .font(.caption)
                .foregroundColor(theme.colors.textMuted)
                .frame(minWidth: 22)
                .accessibilityHidden(true)

            Button(action: { fontSize = min(28.0, fontSize + 2.0) }) {
                Text("A+")
                    .font(.subheadline)
                    .foregroundColor(theme.colors.textSub)
            }
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(theme.colors.divider)
        .cornerRadius(8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(i18n.t("fontSize"))
        .accessibilityValue("\(Int(fontSize))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: fontSize = min(28.0, fontSize + 2.0)
            case .decrement: fontSize = max(12.0, fontSize - 2.0)
            @unknown default: break
            }
        }
    }

    private static let minWebZoomScale: CGFloat = 0.5
    private static let maxWebZoomScale: CGFloat = 3.0
    private static let webZoomStep: CGFloat = 0.25

    private var webZoomControls: some View {
        HStack(spacing: 10) {
            Button(action: { webZoomScale = max(Self.minWebZoomScale, webZoomScale - Self.webZoomStep) }) {
                Image(systemName: "minus.magnifyingglass")
                    .font(.subheadline)
                    .foregroundColor(theme.colors.textSub)
            }
            .accessibilityHidden(true)
            .accessibilityIdentifier("reader.zoomOutButton")

            Text("\(Int(webZoomScale * 100))%")
                .font(.caption)
                .foregroundColor(theme.colors.textMuted)
                .frame(minWidth: 36)
                .accessibilityHidden(true)

            Button(action: { webZoomScale = min(Self.maxWebZoomScale, webZoomScale + Self.webZoomStep) }) {
                Image(systemName: "plus.magnifyingglass")
                    .font(.subheadline)
                    .foregroundColor(theme.colors.textSub)
            }
            .accessibilityHidden(true)
            .accessibilityIdentifier("reader.zoomInButton")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(theme.colors.divider)
        .cornerRadius(8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(i18n.t("webZoom"))
        .accessibilityValue("\(Int(webZoomScale * 100))%")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: webZoomScale = min(Self.maxWebZoomScale, webZoomScale + Self.webZoomStep)
            case .decrement: webZoomScale = max(Self.minWebZoomScale, webZoomScale - Self.webZoomStep)
            @unknown default: break
            }
        }
    }

    private func themePicker(width: CGFloat) -> some View {
        Picker(i18n.t("appTheme"), selection: $readerTheme) {
            Label(i18n.t("themeLight"), systemImage: "sun.max.fill")
                .labelStyle(.iconOnly)
                .tag(AppThemeMode.light)
            Label(i18n.t("themeDark"), systemImage: "moon.fill")
                .labelStyle(.iconOnly)
                .tag(AppThemeMode.dark)
            Label(i18n.t("themeSepia"), systemImage: "doc.text.magnifyingglass")
                .labelStyle(.iconOnly)
                .tag(AppThemeMode.sepia)
        }
        .pickerStyle(.segmented)
        .frame(width: width)
    }

    private var signInPromptBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .foregroundColor(theme.colors.textSub)
                .accessibilityHidden(true)
            Text(i18n.t("readerSignInRequired"))
                .font(.caption)
                .foregroundColor(theme.colors.textSub)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button(i18n.t("readerSignInButton")) {
                showSignInBanner = false
                isSigningIntoX = true
            }
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundColor(theme.colors.primary)
            .accessibilityIdentifier("reader.signInButton")
            Button {
                showSignInBanner = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(theme.colors.textMuted)
            }
            .accessibilityLabel(i18n.t("close"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.colors.card)
        .cornerRadius(10)
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .padding(10)
    }

    private var signInReturnBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.uturn.backward.circle.fill")
                .foregroundColor(theme.colors.textSub)
                .accessibilityHidden(true)
            Text(i18n.t("readerSignInReturnMessage"))
                .font(.caption)
                .foregroundColor(theme.colors.textSub)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button(i18n.t("readerSignInReturnButton")) {
                isSigningIntoX = false
            }
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundColor(theme.colors.primary)
            .accessibilityIdentifier("reader.signInReturnButton")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.colors.card)
        .cornerRadius(10)
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .padding(10)
    }

    private var openInBrowserBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(theme.colors.textSub)
                .accessibilityHidden(true)
            Text(i18n.t("readerCouldNotDisplay"))
                .font(.caption)
                .foregroundColor(theme.colors.textSub)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button(i18n.t("readerOpenInBrowser")) {
                showOpenInBrowserBanner = false
                openInExternalBrowser()
            }
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundColor(theme.colors.primary)
            .accessibilityIdentifier("reader.openInBrowserButton")
            Button {
                showOpenInBrowserBanner = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(theme.colors.textMuted)
            }
            .accessibilityLabel(i18n.t("close"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.colors.card)
        .cornerRadius(10)
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .padding(10)
    }

    private func openInExternalBrowser() {
        guard let url = originalPageUrl else { return }
        UIApplication.shared.open(url)
    }

    private var readerLoadStateOverlay: some View {
        VStack(spacing: 12) {
            if webLoadState == .loading {
                ProgressView()
                    .tint(theme.colors.primary)
                Text(i18n.t("readerLoadingPage"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.colors.textSub)
            } else {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(theme.colors.textMuted)
                Text(i18n.t("readerLoadFailed"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.colors.textSub)
                    .multilineTextAlignment(.center)
                Button(i18n.t("readerOpenInBrowser")) {
                    openInExternalBrowser()
                }
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(theme.colors.primary)
                .foregroundColor(.white)
                .cornerRadius(8)
                .accessibilityIdentifier("reader.failedOpenInBrowserButton")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(webLoadState == .loading ? bgColor.opacity(0.82) : bgColor)
        .accessibilityIdentifier(webLoadState == .loading ? "reader.loadingState" : "reader.failedState")
    }

    private var bgColor: Color {
        switch readerTheme {
        case .light: return Color.white
        case .dark: return Color(red: 0.08, green: 0.08, blue: 0.1)
        case .sepia: return Color(red: 0.96, green: 0.93, blue: 0.86)
        }
    }

    static let bulkImageSaveLimit = 25
    static let bulkImageDownloadConcurrency = 3
    static let maximumBulkImageDownloadBytes: Int64 = 20 * 1024 * 1024

    static func cappedBulkImageURLs(_ urls: [URL]) -> [URL] {
        Array(urls.prefix(bulkImageSaveLimit))
    }

    static func acceptsBulkImageDownload(expectedContentLength: Int64, fileSize: Int64) -> Bool {
        guard fileSize >= 0, fileSize <= maximumBulkImageDownloadBytes else { return false }
        return expectedContentLength <= 0 || expectedContentLength <= maximumBulkImageDownloadBytes
    }

    private func saveSelectedImages(_ urls: [URL], emptyMessageKey: String = "imageNoSelectedImages") {
        guard !urls.isEmpty else {
            isSelectingImages = false
            isSavingSelectedImages = false
            selectedImageCount = 0
            saveImageStatus = i18n.t(emptyMessageKey)
            showingSaveImageStatus = true
            return
        }
        Task {
            let auth = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard auth == .authorized || auth == .limited else {
                await MainActor.run {
                    isSelectingImages = false
                    isSavingSelectedImages = false
                    selectedImageCount = 0
                    saveImageStatus = i18n.t("photosAccessRequired")
                    showingSaveImageStatus = true
                }
                return
            }
            var saved = 0
            let requests = Self.cappedBulkImageURLs(urls).map(imageRequest(for:))
            await withTaskGroup(of: Data?.self) { group in
                var nextRequestIndex = 0
                let initialRequestCount = min(Self.bulkImageDownloadConcurrency, requests.count)
                for _ in 0..<initialRequestCount {
                    let request = requests[nextRequestIndex]
                    nextRequestIndex += 1
                    group.addTask {
                        await Self.downloadBulkImageData(for: request)
                    }
                }
                while let data = await group.next() {
                    if !Task.isCancelled,
                       let data,
                       let image = UIImage(data: data) {
                        do {
                            try await PHPhotoLibrary.shared().performChanges {
                                PHAssetChangeRequest.creationRequestForAsset(from: image)
                            }
                            saved += 1
                        } catch {
                            // Continue saving the remaining independent images.
                        }
                    }
                    if !Task.isCancelled, nextRequestIndex < requests.count {
                        let request = requests[nextRequestIndex]
                        nextRequestIndex += 1
                        group.addTask {
                            await Self.downloadBulkImageData(for: request)
                        }
                    } else if Task.isCancelled {
                        group.cancelAll()
                    }
                }
            }
            await MainActor.run {
                isSelectingImages = false
                isSavingSelectedImages = false
                selectedImageCount = 0
                saveImageStatus = saved > 0
                    ? i18n.tFormat("savedImagesToPhotos", saved)
                    : i18n.t("imageNoneSaved")
                showingSaveImageStatus = true
            }
        }
    }

    private static func downloadBulkImageData(for request: URLRequest) async -> Data? {
        do {
            let (temporaryURL, response) = try await URLSession.shared.download(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else { return nil }
            guard let downloadedFileSize = try temporaryURL
                .resourceValues(forKeys: [.fileSizeKey])
                .fileSize else { return nil }
            let fileSize = Int64(downloadedFileSize)
            guard acceptsBulkImageDownload(
                expectedContentLength: http.expectedContentLength,
                fileSize: fileSize
            ) else { return nil }
            return try Data(contentsOf: temporaryURL, options: .mappedIfSafe)
        } catch {
            return nil
        }
    }

    private func imageRequest(for imageURL: URL) -> URLRequest {
        var request = URLRequest(url: imageURL)
        request.setValue("image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        if let pageURL = originalPageUrl {
            request.setValue(pageURL.absoluteString, forHTTPHeaderField: "Referer")
        }
        return request
    }
}

struct WebViewHelper: UIViewRepresentable, Equatable {
    static let mobileUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

    let url: URL
    let cacheId: String
    let cacheGeneration: Int
    let platform: String
    let themeMode: AppThemeMode
    let fontSize: CGFloat
    let fontFamilyCSS: String
    let readerMode: Bool
    let zoomScale: CGFloat
    let selectImagesCounter: Int
    let imageSelectionActionCounter: Int
    let imageSelectionAction: String
    let saveAllImagesCounter: Int
    let goBackCounter: Int
    let onNavigationHistoryChange: (Bool) -> Void
    let onLoadStateChange: (ReaderWebLoadState) -> Void
    let onImageSelectionState: (Int) -> Void
    let onImageSelectionUnavailable: () -> Void
    let onImageSelectionFailure: () -> Void
    let onSaveAllImagesUnavailable: () -> Void
    let onSelectedImages: ([URL]) -> Void
    let onAllImages: ([URL]) -> Void
    let onContentBlocked: () -> Void

    /// Closures are excluded — they're recreated on every `ReaderView` body
    /// re-render regardless of content changes, and comparing them would
    /// defeat the point of `.equatable()`: skipping `updateUIView` (and its
    /// reader-mode JS rescan) when none of the actual displayed content changed.
    static func == (lhs: WebViewHelper, rhs: WebViewHelper) -> Bool {
        lhs.url == rhs.url &&
            lhs.cacheId == rhs.cacheId &&
            lhs.cacheGeneration == rhs.cacheGeneration &&
            lhs.platform == rhs.platform &&
            lhs.themeMode == rhs.themeMode &&
            lhs.fontSize == rhs.fontSize &&
            lhs.fontFamilyCSS == rhs.fontFamilyCSS &&
            lhs.readerMode == rhs.readerMode &&
            lhs.zoomScale == rhs.zoomScale &&
            lhs.selectImagesCounter == rhs.selectImagesCounter &&
            lhs.imageSelectionActionCounter == rhs.imageSelectionActionCounter &&
            lhs.imageSelectionAction == rhs.imageSelectionAction &&
            lhs.saveAllImagesCounter == rhs.saveAllImagesCounter &&
            lhs.goBackCounter == rhs.goBackCounter
    }

    static func customUserAgent(for platform: String) -> String? {
        switch PlatformRegistry.normalizeID(platform) {
        case "girlschannel", "twitter":
            return mobileUserAgent
        default:
            return nil
        }
    }

    private static let uiTestImageFixtureHTML = """
    <!doctype html>
    <html><head><title>UITest image fixture</title></head>
    <body><article>
    <div class="oshi-uitest-image-row">
    <button class="oshi-uitest-image-button" aria-label="fixture image one"><img class="oshi-uitest-image" src="https://example.com/fixture-image-one.jpg" alt="fixture image one" width="400" height="300"></button>
    <button class="oshi-uitest-image-button" aria-label="fixture image two"><img class="oshi-uitest-image" src="https://example.com/fixture-image-two.jpg" alt="fixture image two" width="400" height="300"></button>
    </div>
    <a id="fixture-linked-image" href="#fixture-target" aria-label="fixture linked image"><img class="oshi-uitest-image" src="https://example.com/fixture-image-linked.jpg" alt="fixture linked image" width="400" height="300"></a>
    <p id="fixture-nav-status">not navigated</p>
    <p>This cached article contains deterministic image-selection fixtures.</p>
    </article>
    <script>
    window.addEventListener('hashchange', function() {
      document.getElementById('fixture-nav-status').textContent = 'navigated:' + location.hash;
    });
    </script>
    </body></html>
    """

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        configuration.userContentController.add(context.coordinator, name: "oshireader")
        configuration.userContentController.addUserScript(
            WKUserScript(source: viewportFixJS, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        configuration.userContentController.addUserScript(WKUserScript(source: readerInjectedJS, injectionTime: .atDocumentEnd, forMainFrameOnly: false))

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.customUserAgent = Self.customUserAgent(for: platform)
        context.coordinator.observeNavigationHistory(webView)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.parent = self
        uiView.customUserAgent = Self.customUserAgent(for: platform)
        let requestURL = url.absoluteString
        if context.coordinator.currentRequestURL != requestURL {
            context.coordinator.currentRequestURL = requestURL
            context.coordinator.beginNewRequest()
            context.coordinator.lastAppliedFontSize = fontSize
            context.coordinator.lastAppliedThemeMode = themeMode
            context.coordinator.lastAppliedReaderMode = readerMode
            context.coordinator.lastAppliedFontFamilyCSS = fontFamilyCSS
            context.coordinator.lastAppliedPlatform = platform
            // A fresh navigation already starts at the page's natural
            // (unzoomed) scale — match that baseline rather than carrying
            // over whatever zoom level the previous article was left at.
            context.coordinator.lastAppliedZoomScale = 1.0
            onLoadStateChange(.loading)
            if ProcessInfo.processInfo.arguments.contains("--uitesting-reader-images") {
                uiView.loadHTMLString(Self.uiTestImageFixtureHTML, baseURL: url)
            } else {
                let cacheId = cacheId
                // Cache-first: paint the last-known-good copy instantly (if any),
                // then always follow with a live fetch so the cache never wins
                // over fresh content — it's a placeholder, not a substitute.
                LocalDB.shared.getContentCache(id: cacheId) { [weak uiView] cachedHTML in
                    guard let uiView, context.coordinator.currentRequestURL == requestURL else { return }
                    if let cachedHTML {
                        context.coordinator.markShowingCachePlaceholder()
                        uiView.loadHTMLString(cachedHTML, baseURL: url)
                    }
                    uiView.load(URLRequest(url: url))
                }
            }
        } else {
            let styleRelevantChanged = context.coordinator.lastAppliedThemeMode != themeMode
                || context.coordinator.lastAppliedReaderMode != readerMode
                || context.coordinator.lastAppliedFontFamilyCSS != fontFamilyCSS
                || context.coordinator.lastAppliedPlatform != platform
            if styleRelevantChanged {
                context.coordinator.lastAppliedThemeMode = themeMode
                context.coordinator.lastAppliedReaderMode = readerMode
                context.coordinator.lastAppliedFontFamilyCSS = fontFamilyCSS
                context.coordinator.lastAppliedPlatform = platform
                context.coordinator.lastAppliedFontSize = fontSize
                uiView.evaluateJavaScript(styleInjectionJS(), completionHandler: nil)
            } else if context.coordinator.lastAppliedFontSize != fontSize {
                context.coordinator.lastAppliedFontSize = fontSize
                uiView.evaluateJavaScript("if (window.__oshiSetFontSize) { window.__oshiSetFontSize(\(fontSize)); }", completionHandler: nil)
            }
        }
        if context.coordinator.lastAppliedZoomScale != zoomScale {
            context.coordinator.lastAppliedZoomScale = zoomScale
            uiView.evaluateJavaScript("if (window.__oshiSetPageZoom) { window.__oshiSetPageZoom(\(zoomScale)); }", completionHandler: nil)
        }
        if selectImagesCounter != context.coordinator.lastSelectImagesCounter {
            context.coordinator.lastSelectImagesCounter = selectImagesCounter
            uiView.evaluateJavaScript("(function(){ if(!window.__oshiBeginImageSelection) return false; window.__oshiBeginImageSelection(); return true; })()") { result, _ in
                guard (result as? Bool) == true else {
                    DispatchQueue.main.async { onImageSelectionUnavailable() }
                    return
                }
            }
        }
        if imageSelectionActionCounter != context.coordinator.lastImageSelectionActionCounter {
            context.coordinator.lastImageSelectionActionCounter = imageSelectionActionCounter
            let functionName = imageSelectionAction == "finish"
                ? "__oshiFinishImageSelection"
                : "__oshiCancelImageSelection"
            uiView.evaluateJavaScript("(function(){ if(!window.\(functionName)) return false; window.\(functionName)(); return true; })()") { result, _ in
                guard (result as? Bool) == true else {
                    DispatchQueue.main.async { onImageSelectionFailure() }
                    return
                }
            }
        }
        if saveAllImagesCounter != context.coordinator.lastSaveAllImagesCounter {
            context.coordinator.lastSaveAllImagesCounter = saveAllImagesCounter
            uiView.evaluateJavaScript("(function(){ if(!window.__oshiSaveAllImages) return false; window.__oshiSaveAllImages(); return true; })()") { result, _ in
                guard (result as? Bool) == true else {
                    DispatchQueue.main.async { onSaveAllImagesUnavailable() }
                    return
                }
            }
        }
        if goBackCounter != context.coordinator.lastGoBackCounter {
            context.coordinator.lastGoBackCounter = goBackCounter
            if uiView.canGoBack {
                uiView.goBack()
            }
        }
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "oshireader")
        uiView.navigationDelegate = nil
        uiView.uiDelegate = nil
    }

    private func styleInjectionJS() -> String {
        let bgColorHex: String
        let textColorHex: String
        let linkHex: String
        let uiTestFixtureCSS = ProcessInfo.processInfo.arguments.contains("--uitesting-reader-images")
            ? """
            .oshi-uitest-image-row { display: flex !important; gap: 8px !important; }
            button.oshi-uitest-image-button { display: block !important; width: 48% !important; height: 280px !important; padding: 0 !important; border: 0 !important; background: #d8d8dc !important; }
            img.oshi-uitest-image { width: 100% !important; height: 280px !important; background: #d8d8dc !important; }
            """
            : ""

        switch themeMode {
        case .light:
            bgColorHex = "#ffffff"
            textColorHex = "#1a1a1a"
            linkHex = "#7C3AED"
        case .dark:
            bgColorHex = "#121215"
            textColorHex = "#e5e5e7"
            linkHex = "#A78BFA"
        case .sepia:
            bgColorHex = "#f5ebd6"
            textColorHex = "#38250f"
            linkHex = "#8f5a00"
        }

        let readerCSS: String
        if readerMode {
            readerCSS = """
            :root {
                --oshi-reader-font-size: \(fontSize)px;
            }
            body {
                background-color: \(bgColorHex) !important;
                color: \(textColorHex) !important;
                font-size: var(--oshi-reader-font-size) !important;
                line-height: 1.75 !important;
                padding: 16px !important;
                max-width: 760px !important;
                margin: 0 auto !important;
                word-break: break-word !important;
            }
            body, body * {
                font-family: \(fontFamilyCSS) !important;
            }
            nav, header, footer, aside, iframe, [role=navigation], [role=banner], [role=contentinfo],
            .sidebar, .ad, .ads, .adbox, .ad_box, .ad_area, .adsbygoogle, .advert, .advertisement,
            .banner, .sponsor, .sponsored, .promotion, [data-ad], [data-ad-unit], [data-google-query-id],
            [id*="ad-"], [id^="ad_"], [id*="_ad_"], [id*="ads"], [class*=" ad-"], [class^="ad-"],
            [class*=" ads"], [class*="_ad_"], [class*="advert"], [class*="banner"], [class*="sponsor"] {
                display: none !important;
                visibility: hidden !important;
                max-height: 0 !important;
                overflow: hidden !important;
            }
            img, video { max-width: 100% !important; height: auto !important; border-radius: 8px !important; }
            \(uiTestFixtureCSS)
            pre, code { white-space: pre-wrap !important; word-break: break-word !important; }
            a { color: \(linkHex) !important; }
            [data-oshireader-reader-root="true"] {
                display: block !important;
                max-width: 720px !important;
                margin: 0 auto !important;
                padding: 2px 0 28px !important;
            }
            [data-oshireader-reader-root="true"] p,
            [data-oshireader-reader-root="true"] li,
            [data-oshireader-reader-root="true"] blockquote {
                font-size: var(--oshi-reader-font-size) !important;
                line-height: 1.82 !important;
                letter-spacing: 0 !important;
            }
            [data-oshireader-reader-root="true"] h1,
            [data-oshireader-reader-root="true"] h2,
            [data-oshireader-reader-root="true"] h3 {
                color: \(textColorHex) !important;
                line-height: 1.28 !important;
                letter-spacing: 0 !important;
                margin: 1.2em 0 0.55em !important;
            }
            [data-oshireader-reader-root="true"] p {
                margin: 0 0 1.05em !important;
            }
            [data-oshireader-reader-root="true"] figure {
                margin: 1.3em 0 !important;
            }
            [data-oshireader-reader-root="true"] figcaption,
            [data-oshireader-reader-root="true"] time,
            [data-oshireader-reader-root="true"] small {
                color: \(textColorHex) !important;
                opacity: 0.72 !important;
            }
            """
        } else if PlatformRegistry.normalizeID(platform) == "twitter" {
            readerCSS = ""
        } else {
            readerCSS = """
            body {
                background-color: \(bgColorHex) !important;
                color: \(textColorHex) !important;
            }
            """
        }

        return """
        (function() {
            var style = document.getElementById('oshireader-injected-style');
            if (!style) {
                style = document.createElement('style');
                style.id = 'oshireader-injected-style';
                document.head.appendChild(style);
            }
            style.innerHTML = `\(readerCSS)`;
            if (\(readerMode ? "true" : "false")) {
                var selectors = [
                    'article',
                    'main',
                    '[role="main"]',
                    '.article',
                    '.post',
                    '.entry-content',
                    '.article-body',
                    '.story-body',
                    '.content',
                    '#content'
                ];
                function applyReaderRoot() {
                    document.querySelectorAll('[data-oshireader-reader-root="true"]').forEach(function(el) {
                        el.removeAttribute('data-oshireader-reader-root');
                    });
                    var best = null;
                    var bestScore = 0;
                    selectors.forEach(function(selector) {
                        document.querySelectorAll(selector).forEach(function(el) {
                            var text = el.innerText ? el.innerText.replace(/\\s+/g, ' ').trim() : '';
                            var paragraphs = el.querySelectorAll('p, li, blockquote').length;
                            var rect = el.getBoundingClientRect();
                            var score = text.length + (paragraphs * 80) + Math.min(rect.height || 0, 1400);
                            if (text.length >= 240 && rect.width > 0 && rect.height > 0 && score > bestScore) {
                                best = el;
                                bestScore = score;
                            }
                        });
                    });
                    if (best) best.setAttribute('data-oshireader-reader-root', 'true');
                }
                applyReaderRoot();
                if (!window.__oshiReaderRootCatchUp) {
                    var attempts = 0;
                    window.__oshiReaderRootCatchUp = setInterval(function() {
                        attempts++;
                        applyReaderRoot();
                        if (attempts >= 8) {
                            clearInterval(window.__oshiReaderRootCatchUp);
                            window.__oshiReaderRootCatchUp = null;
                        }
                    }, 750);
                }
            } else {
                if (window.__oshiReaderRootCatchUp) {
                    clearInterval(window.__oshiReaderRootCatchUp);
                    window.__oshiReaderRootCatchUp = null;
                }
                document.querySelectorAll('[data-oshireader-reader-root="true"]').forEach(function(el) {
                    el.removeAttribute('data-oshireader-reader-root');
                });
            }
        })();
        """
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var parent: WebViewHelper
        var lastSelectImagesCounter = 0
        var lastImageSelectionActionCounter = 0
        var lastSaveAllImagesCounter = 0
        var lastGoBackCounter = 0
        var currentRequestURL: String?
        /// The web view's `backForwardList.backList.count` at the point this
        /// article's own navigation started. `canGoBack` on the shared WKWebView
        /// stays true across article switches (sibling navigation reuses the
        /// same web view and just keeps appending to its history), so the
        /// "go back" button needs its own baseline: only offer to go back
        /// while the list is deeper than where *this* article began, i.e. the
        /// user actually followed a link inside the page.
        var baselineBackListCount = 0
        var pendingBaselineCapture = false
        /// Tracks which style-affecting values are already reflected in the
        /// page so `updateUIView` can tell a font-size-only change (cheap,
        /// CSS-variable update) apart from a theme/reader-mode change (needs
        /// the full reader-mode rescan in `styleInjectionJS()`).
        var lastAppliedFontSize: CGFloat?
        var lastAppliedThemeMode: AppThemeMode?
        var lastAppliedReaderMode: Bool?
        var lastAppliedFontFamilyCSS: String?
        var lastAppliedPlatform: String?
        var lastAppliedZoomScale: CGFloat = 1.0
        private var hasCommittedPage = false
        private var pendingFailure: DispatchWorkItem?
        /// True while the web view is showing an on-disk cache placeholder
        /// (either the fast-paint-on-open path or the offline fallback) —
        /// its `didFinish` shouldn't re-snapshot content that's already on disk.
        private var isShowingCachePlaceholder = false
        /// KVO on `canGoBack` rather than only `didCommit`/`didFinish`: a
        /// same-document (pushState/History API) navigation — how girlschannel's
        /// own in-page links behave — never fires the navigation delegate at
        /// all, but it does update `backForwardList`, and `canGoBack` is a
        /// KVO-observable `@objc dynamic` property that reflects that change
        /// regardless of which kind of navigation caused it.
        private var canGoBackObservation: NSKeyValueObservation?

        init(_ parent: WebViewHelper) {
            self.parent = parent
        }

        func observeNavigationHistory(_ webView: WKWebView) {
            canGoBackObservation = webView.observe(\.canGoBack, options: [.initial]) { [weak self, weak webView] _, _ in
                guard let self, let webView else { return }
                self.reportNavigationHistory(webView)
            }
        }

        func beginNewRequest() {
            hasCommittedPage = false
            isShowingCachePlaceholder = false
            pendingFailure?.cancel()
            pendingBaselineCapture = true
        }

        /// Recomputes whether the "go back" button should be offered and
        /// reports it, capturing this article's baseline history depth on
        /// its first call after `beginNewRequest()`.
        private func reportNavigationHistory(_ webView: WKWebView) {
            if pendingBaselineCapture {
                baselineBackListCount = webView.backForwardList.backList.count
                pendingBaselineCapture = false
            }
            let canGoBack = webView.backForwardList.backList.count > baselineBackListCount
            DispatchQueue.main.async { self.parent.onNavigationHistoryChange(canGoBack) }
        }

        func markShowingCachePlaceholder() {
            isShowingCachePlaceholder = true
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            pendingFailure?.cancel()
            DispatchQueue.main.async { self.parent.onImageSelectionUnavailable() }
            if !hasCommittedPage {
                DispatchQueue.main.async { self.parent.onLoadStateChange(.loading) }
            }
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            hasCommittedPage = true
            pendingFailure?.cancel()
            DispatchQueue.main.async { self.parent.onLoadStateChange(.loaded) }
            reportNavigationHistory(webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            hasCommittedPage = true
            pendingFailure?.cancel()
            DispatchQueue.main.async { self.parent.onLoadStateChange(.loaded) }
            webView.evaluateJavaScript(parent.styleInjectionJS(), completionHandler: nil)
            if isShowingCachePlaceholder {
                // This navigation just repainted content already on disk (either
                // the fast-paint-on-open placeholder or the offline fallback) —
                // re-snapshotting it would be a same-bytes write. The live fetch
                // that follows (or a future successful load) captures the fresh copy.
                isShowingCachePlaceholder = false
            } else {
                let cacheId = parent.cacheId
                let cacheGeneration = parent.cacheGeneration
                webView.evaluateJavaScript("document.documentElement.outerHTML") { result, _ in
                    guard let html = result as? String, !html.isEmpty else { return }
                    LocalDB.shared.saveContentCache(
                        id: cacheId,
                        html: html,
                        sourceGeneration: cacheGeneration
                    )
                }
            }
            checkForBlockedContent(in: webView)
            reportNavigationHistory(webView)
        }

        private func checkForBlockedContent(in webView: WKWebView) {
            let requestURLAtCheckTime = currentRequestURL
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak webView] in
                guard let self, let webView, self.currentRequestURL == requestURLAtCheckTime else { return }
                webView.evaluateJavaScript(Self.contentDisplayabilityJS) { result, _ in
                    guard let metrics = result as? [String: Any],
                          ReaderContentDisplayability.shouldShowBlockedBanner(metrics: metrics) else { return }
                    DispatchQueue.main.async { self.parent.onContentBlocked() }
                }
            }
        }

        private static let contentDisplayabilityJS = """
        (function() {
          var body = document.body;
          var doc = document.documentElement;
          var text = body && body.innerText ? body.innerText.replace(/\\s+/g, ' ').trim() : '';
          var title = document.title ? document.title.trim() : '';
          var url = location.href || '';
          var selectors = 'article, main, [role="main"], .article, .post, .entry-content, .content, #content';
          var visibleTextNodes = 0;

          if (body) {
            var candidates = body.querySelectorAll('p, h1, h2, h3, li, blockquote, pre');
            for (var i = 0; i < candidates.length; i++) {
              var rect = candidates[i].getBoundingClientRect();
              var nodeText = candidates[i].innerText ? candidates[i].innerText.trim() : '';
              if (nodeText.length >= 12 && rect.width > 0 && rect.height > 0) visibleTextNodes++;
              if (visibleTextNodes >= 3) break;
            }
          }

          return {
            textLength: text.length,
            titleLength: title.length,
            hasReaderContainer: !!(body && body.querySelector(selectors)),
            linkCount: body ? body.querySelectorAll('a[href]').length : 0,
            imageCount: body ? body.querySelectorAll('img, picture, video, iframe').length : 0,
            visibleTextNodes: visibleTextNodes,
            height: Math.max(
              body ? body.scrollHeight : 0,
              doc ? doc.scrollHeight : 0,
              body ? body.offsetHeight : 0,
              doc ? doc.offsetHeight : 0
            ),
            blockedText: /sign in|log in|enable javascript|unsupported browser|cannot display|couldn't display|not available|access denied|forbidden|attention required|cloudflare/i.test(text + ' ' + title),
            urlLooksBlank: /about:blank|\\/sorry\\/|\\/signin|\\/login/i.test(url)
          };
        })();
        """

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            handleLoadFailure(error, in: webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            handleLoadFailure(error, in: webView)
        }

        private func handleLoadFailure(_ error: Error, in webView: WKWebView) {
            let nsError = error as NSError
            AppLogger.network.warning("Reader load failed domain=\(nsError.domain, privacy: .public) code=\(nsError.code) url=\(webView.url?.absoluteString ?? self.parent.url.absoluteString, privacy: .public)")

            if isBenignNavigationFailure(error) || hasCommittedPage {
                if hasCommittedPage {
                    DispatchQueue.main.async { self.parent.onLoadStateChange(.loaded) }
                }
                return
            }

            loadCachedPage(in: webView) { [weak self, weak webView] loaded in
                guard let self, let webView, !loaded else { return }
                if PlatformRegistry.normalizeID(self.parent.platform) == "twitter" {
                    DispatchQueue.main.async { self.parent.onContentBlocked() }
                }
                self.pendingFailure?.cancel()
                let failure = DispatchWorkItem { [weak self, weak webView] in
                    guard let self, let webView, !self.hasCommittedPage else { return }
                    webView.evaluateJavaScript("document.readyState") { result, _ in
                        if self.hasCommittedPage || result is String {
                            DispatchQueue.main.async { self.parent.onLoadStateChange(.loaded) }
                        } else {
                            DispatchQueue.main.async { self.parent.onLoadStateChange(.failed) }
                        }
                    }
                }
                self.pendingFailure = failure
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: failure)
            }
        }

        private func isBenignNavigationFailure(_ error: Error) -> Bool {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                return true
            }
            if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 {
                return true
            }
            return false
        }

        private func loadCachedPage(in webView: WKWebView, completion: @escaping (Bool) -> Void) {
            let cacheId = parent.cacheId
            LocalDB.shared.getContentCache(id: cacheId) { [weak self, weak webView] html in
                guard let self, let webView else { completion(false); return }
                guard let html, self.parent.cacheId == cacheId else { completion(false); return }
                self.pendingFailure?.cancel()
                self.hasCommittedPage = false
                self.markShowingCachePlaceholder()
                self.parent.onLoadStateChange(.loading)
                webView.loadHTMLString(html, baseURL: self.parent.url)
                completion(true)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            let scheme = url.scheme?.lowercased() ?? ""
            if ["mailto", "tel", "sms", "facetime", "facetime-audio"].contains(scheme) {
                decisionHandler(.cancel)
                UIApplication.shared.open(url)
                return
            }
            if PlatformRegistry.normalizeID(parent.platform) != "5ch", shouldBlockReaderRequest(url.absoluteString) {
                decisionHandler(.cancel)
                return
            }
            let host = url.host ?? ""
            let hostRange = NSRange(host.startIndex..., in: host)
            if _ReaderRegex.fivechHost?.firstMatch(in: host, range: hostRange) != nil {
                let rewritten = normalize5chReaderUrl(url.absoluteString)
                if rewritten != url.absoluteString, let rewrittenUrl = URL(string: rewritten) {
                    decisionHandler(.cancel)
                    webView.load(URLRequest(url: rewrittenUrl))
                    return
                }
            }
            decisionHandler(.allow)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "oshireader",
                  let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }
            if type == "image-selection-state",
                      let count = body["count"] as? Int {
                DispatchQueue.main.async { self.parent.onImageSelectionState(count) }
            } else if type == "selected-images",
                      let rawUrls = body["urls"] as? [String] {
                let urls = rawUrls.compactMap { URL(string: $0) }
                DispatchQueue.main.async { self.parent.onSelectedImages(urls) }
            } else if type == "all-images",
                      let rawUrls = body["urls"] as? [String] {
                let urls = rawUrls.compactMap { URL(string: $0) }
                DispatchQueue.main.async { self.parent.onAllImages(urls) }
            }
        }
    }
}

struct SafariReaderView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.dismissButtonStyle = .close
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

enum ReaderContentDisplayability {
    static func shouldShowBlockedBanner(metrics: [String: Any]) -> Bool {
        let textLength = intMetric("textLength", in: metrics)
        let titleLength = intMetric("titleLength", in: metrics)
        let linkCount = intMetric("linkCount", in: metrics)
        let imageCount = intMetric("imageCount", in: metrics)
        let visibleTextNodes = intMetric("visibleTextNodes", in: metrics)
        let height = intMetric("height", in: metrics)
        let hasReaderContainer = metrics["hasReaderContainer"] as? Bool ?? false
        let blockedText = metrics["blockedText"] as? Bool ?? false
        let urlLooksBlank = metrics["urlLooksBlank"] as? Bool ?? false

        let hasMeaningfulStructure = hasReaderContainer
            || visibleTextNodes >= 2
            || linkCount >= 3
            || imageCount >= 2
            || height >= 900
            || titleLength >= 8

        if hasMeaningfulStructure && !blockedText && !urlLooksBlank {
            return false
        }
        return (textLength < 40 && !hasMeaningfulStructure) || (blockedText && textLength < 180) || urlLooksBlank
    }

    private static func intMetric(_ key: String, in metrics: [String: Any]) -> Int {
        if let value = metrics[key] as? Int { return value }
        if let value = metrics[key] as? Double { return Int(value) }
        if let value = metrics[key] as? NSNumber { return value.intValue }
        return 0
    }
}

private enum _ReaderRegex {
    static let schemeAllowlist = try? NSRegularExpression(
        pattern: #"^(about:|data:|blob:|file:|mailto:|tel:)"#,
        options: .caseInsensitive
    )
    static let adBlocklist = try? NSRegularExpression(
        pattern: #"(2mdn|doubleclick|googlesyndication|googleadservices|adservice\.google|googletagmanager|google-analytics|analytics\.yahoo|yjtag\.yahoo|yads\.c\.yimg|ad\.yahoo|ad-stir|ad-generation|admatrix|adingo|fam-ad|fluct|genieessp|gmossp|i-mobile|im-apps|impact-ad|microad|nend|popin|taboola|outbrain|/adserver[/.?_-]|/ads?[/.?_-]|/advert|/banner|/sponsor|/promoted)"#,
        options: .caseInsensitive
    )
    static let itestHost = try? NSRegularExpression(pattern: #"^itest\.5ch\.(net|io)$"#)
    static let fivechHost = try? NSRegularExpression(pattern: #"(^|\.)5ch\.(net|io)$"#)
    static let twochHost = try? NSRegularExpression(pattern: #"(^|\.)2ch\.sc$"#)
    static let itestPath = try? NSRegularExpression(pattern: #"^/([^/]+)/test/read\.cgi/([^/]+)/(\d{9,})"#)
    static let fivechPath = try? NSRegularExpression(pattern: #"/test/read\.cgi/([^/]+)/(\d{9,})"#)
    static let oriconArticle = try? NSRegularExpression(pattern: #"/(?:news|article)/(\d+)"#)
}

private func normalizedReaderUrl(_ rawUrl: String, platform: String) -> String? {
    let stripped = stripTrackingParams(rawUrl)
    let platformID = PlatformRegistry.normalizeID(platform)
    if platformID == "5ch" {
        return normalize5chReaderUrl(stripped)
    }
    if platformID == "oricon", let article = stripped.match(_ReaderRegex.oriconArticle) {
        return "https://www.oricon.co.jp/news/\(article)/full/"
    }
    return stripped
}

private func stripTrackingParams(_ rawUrl: String) -> String {
    guard var components = URLComponents(string: rawUrl) else { return rawUrl }
    let blockedPrefixes = ["utm_"]
    let blockedKeys = Set(["fbclid", "gclid", "yclid", "mc_cid", "mc_eid", "igshid", "ref"])
    components.queryItems = components.queryItems?.filter { item in
        let key = item.name.lowercased()
        return !blockedKeys.contains(key) && !blockedPrefixes.contains(where: { key.hasPrefix($0) })
    }
    if components.queryItems?.isEmpty == true {
        components.queryItems = nil
    }
    return components.url?.absoluteString ?? rawUrl
}

private func normalize5chReaderUrl(_ rawUrl: String) -> String {
    guard let url = URL(string: rawUrl), let host = url.host else { return rawUrl }
    let hostRange = NSRange(host.startIndex..., in: host)
    let isItest = _ReaderRegex.itestHost?.firstMatch(in: host, range: hostRange) != nil
    let isFiveCh = _ReaderRegex.fivechHost?.firstMatch(in: host, range: hostRange) != nil
    let isTwoCh = _ReaderRegex.twochHost?.firstMatch(in: host, range: hostRange) != nil
    guard isItest || isFiveCh || isTwoCh else { return rawUrl }

    if isTwoCh {
        return rawUrl
    }

    if isItest, let match = url.path.match(_ReaderRegex.itestPath) {
        let parts = match.components(separatedBy: "|")
        if parts.count == 3 {
            return "https://itest.5ch.io/\(parts[0])/test/read.cgi/\(parts[1])/\(parts[2])/"
        }
    }

    guard let match = url.path.match(_ReaderRegex.fivechPath) else { return rawUrl }
    let parts = match.components(separatedBy: "|")
    guard parts.count == 2 else { return rawUrl }
    let server = host.components(separatedBy: ".").first ?? ""
    guard !server.isEmpty, !["www", "itest", "find", "dig"].contains(server.lowercased()) else { return rawUrl }
    return "https://itest.5ch.io/\(server)/test/read.cgi/\(parts[0])/\(parts[1])/"
}

private func shouldBlockReaderRequest(_ rawUrl: String) -> Bool {
    let range = NSRange(rawUrl.startIndex..., in: rawUrl)
    if _ReaderRegex.schemeAllowlist?.firstMatch(in: rawUrl, range: range) != nil { return false }
    return _ReaderRegex.adBlocklist?.firstMatch(in: rawUrl, range: range) != nil
}

private let viewportFixJS = """
(function () {
  var desiredContent = 'width=device-width, initial-scale=1';

  function ensureMeta() {
    var meta = document.querySelector('meta[name="viewport"]');
    if (meta) return meta;
    if (!document.head) return null;
    meta = document.createElement('meta');
    meta.setAttribute('name', 'viewport');
    document.head.appendChild(meta);
    return meta;
  }

  // Legacy fixed-width layouts — old BBS/thread tables, avatar columns,
  // desktop-only sites like girlschannel.net — often still declare
  // width=device-width (or nothing at all) while their actual content is
  // hard-coded wider than the screen. A page that *declares* a viewport
  // tells WebKit to trust it, so unlike Mobile Safari's fallback for
  // truly viewport-less pages, WebKit won't auto-shrink the overflow to
  // fit; the result renders "zoomed in", showing only a slice of a
  // too-wide layout.
  //
  // The correction does NOT go through the meta tag's initial-scale —
  // WebKit only consults initial-scale to pick the page's *first* paint
  // scale. Overflow can only be measured after layout has already
  // happened, so by the time this runs, an initial-scale edit is too late
  // to visibly rescale anything (this was tried and silently did nothing).
  // Instead this reflows the page directly via WebKit's `zoom` CSS
  // property — the same mechanism the reader's manual zoom buttons use
  // (see __oshiSetPageZoom in readerInjectedJS) — which takes effect
  // immediately and can be re-applied as content changes.
  var autoZoomActive = true; // false once the observer below stops, so this
                              // hands off to the user's own zoom buttons
                              // instead of fighting a choice they've made.
  function settle() {
    var meta = ensureMeta();
    if (meta && meta.getAttribute('content') !== desiredContent) {
      meta.setAttribute('content', desiredContent);
    }
    if (!autoZoomActive) return;
    var doc = document.documentElement;
    if (!doc) return;
    var body = document.body;
    var availableWidth = doc.clientWidth || window.innerWidth || 0;
    var contentWidth = Math.max(doc.scrollWidth || 0, (body && body.scrollWidth) || 0);
    // 5% slack so ordinary rounding/scrollbar noise doesn't trigger a scale.
    var overflowing = availableWidth > 0 && contentWidth > availableWidth * 1.05;
    if (overflowing) {
      var scaleStr = String(Math.max(0.25, Math.min(1, availableWidth / contentWidth)));
      if (doc.style.zoom !== scaleStr) {
        doc.style.zoom = scaleStr;
      }
    } else if (doc.style.zoom) {
      doc.style.zoom = '';
    }
  }

  settle();
  document.addEventListener('DOMContentLoaded', settle);
  window.addEventListener('load', settle);
  var target = document.documentElement || document;
  var observer = new MutationObserver(settle);
  observer.observe(target, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ['name', 'content']
  });
  // Once the page has settled there's nothing further worth auto-correcting
  // — a full-tree observer (and further automatic zoom writes) left running
  // for the article's whole lifetime would otherwise keep paying for every
  // DOM mutation the page makes afterwards (auto-refreshing threads,
  // infinite scroll, live embeds) for no further benefit, and could fight
  // the user's own zoom buttons once they've had a chance to use them.
  function stopObserving() {
    observer.disconnect();
    autoZoomActive = false;
  }
  if (document.readyState === 'complete') {
    stopObserving();
  } else {
    window.addEventListener('load', stopObserving, { once: true });
    setTimeout(stopObserving, 8000);
  }
})();
"""

private let readerInjectedJS = """
(function () {
  if (window.__OSHIREADER_IMAGE_ACTIONS__) return true;
  window.__OSHIREADER_IMAGE_ACTIONS__ = true;
  if (window.top !== window) return true;

  function absoluteUrl(value) {
    if (!value) return '';
    try { return new URL(value, document.baseURI).toString(); } catch (e) { return String(value); }
  }
  function srcFromSrcset(value) {
    if (!value) return '';
    var parts = String(value).split(',').map(function(part) { return part.trim().split(/\\s+/)[0]; }).filter(Boolean);
    return parts.length ? parts[parts.length - 1] : '';
  }
  var imageSelectionMode = false;
  var selectedImageUrls = new Set();
  var imageSelectionStyle = null;

  function selectableImageUrl(img) {
    var placeholderPattern = /\\/(thumb(nail)?s?|icon|avatar|profile|logo|favicon|placeholder|sprite|emoji|badge|sticker|banner|ad)[_\\-./#]|[_\\-](thumb|icon|avatar|logo|small|xs|sm|tiny|mini)[._]|\\b1x1\\b|\\/1\\/1\\.|pixel|beacon/i;
    var currentUrl = absoluteUrl(img.currentSrc || '');
    var sourceUrl = absoluteUrl(img.src || img.getAttribute('src') || '');
    var naturalWidth = img.naturalWidth || 0;
    var naturalHeight = img.naturalHeight || 0;
    var hasSmallNaturalImage = naturalWidth > 0 && naturalHeight > 0 && (naturalWidth < 300 || naturalHeight < 200);
    var isUsableCandidate = function(candidate) {
      if (!/^https?:\\/\\//i.test(candidate) || placeholderPattern.test(candidate)) return false;
      if (hasSmallNaturalImage && (candidate === currentUrl || candidate === sourceUrl)) return false;
      return true;
    };
    var primaryCandidates = [
      currentUrl,
      sourceUrl,
      srcFromSrcset(img.getAttribute('srcset') || '')
    ].map(absoluteUrl).filter(Boolean);
    var lazyCandidates = [
      img.getAttribute('data-src'),
      img.getAttribute('data-original'),
      img.getAttribute('data-lazy-src'),
      srcFromSrcset(img.getAttribute('data-srcset') || '')
    ].map(absoluteUrl).filter(Boolean);
    var url = primaryCandidates.concat(lazyCandidates).find(isUsableCandidate) || '';
    if (!url || !/^https?:\\/\\//i.test(url)) return '';
    var w = naturalWidth || img.width || 0;
    var h = naturalHeight || img.height || 0;
    if (hasSmallNaturalImage && url !== currentUrl && url !== sourceUrl) {
      w = img.width || 0;
      h = img.height || 0;
    }
    if (placeholderPattern.test(img.currentSrc || img.src || '') && img.getBoundingClientRect) {
      var rect = img.getBoundingClientRect();
      w = Math.max(w, rect.width || 0);
      h = Math.max(h, rect.height || 0);
    }
    if (w > 0 && h > 0 && (w < 300 || h < 200)) return '';
    var lower = url.toLowerCase().replace(/\\?.*$/, '');
    if (placeholderPattern.test(lower)) return '';
    return url;
  }

  function postSelectionState() {
    window.webkit.messageHandlers.oshireader.postMessage({ type: 'image-selection-state', count: selectedImageUrls.size });
  }

  function updateSelectionStyle(img, selected) {
    img.setAttribute('data-oshireader-selected', selected ? 'true' : 'false');
  }

  function toggleImageSelection(img) {
    var url = selectableImageUrl(img);
    if (!url) return false;
    if (selectedImageUrls.has(url)) {
      selectedImageUrls.delete(url);
      document.querySelectorAll('img[data-oshireader-selected="true"]').forEach(function(candidate) {
        if (selectableImageUrl(candidate) === url) updateSelectionStyle(candidate, false);
      });
    } else {
      selectedImageUrls.add(url);
      updateSelectionStyle(img, true);
    }
    postSelectionState();
    return true;
  }

  window.__oshiSetFontSize = function(px) {
    document.documentElement.style.setProperty('--oshi-reader-font-size', px + 'px');
  };

  // Original Web Mode's page zoom. Setting UIScrollView.zoomScale directly
  // from the native side doesn't stick on WKWebView — WebKit's own
  // viewport-scale handling reasserts the page's declared initial-scale
  // and fights it. WebKit's (non-standard, Safari-only, but exactly what
  // we're running) `zoom` CSS property reflows the page at the given
  // factor instead, which doesn't fight that mechanism.
  window.__oshiSetPageZoom = function(scale) {
    document.documentElement.style.zoom = scale;
  };

  window.__oshiBeginImageSelection = function() {
    imageSelectionMode = true;
    selectedImageUrls = new Set();
    if (!imageSelectionStyle) {
      imageSelectionStyle = document.createElement('style');
      imageSelectionStyle.id = 'oshireader-image-selection-style';
      imageSelectionStyle.textContent = 'img[data-oshireader-selected="true"] { outline: 4px solid #7C3AED !important; outline-offset: 3px !important; opacity: .78 !important; }';
      document.head.appendChild(imageSelectionStyle);
    }
    postSelectionState();
  };

  window.__oshiCancelImageSelection = function() {
    imageSelectionMode = false;
    selectedImageUrls = new Set();
    document.querySelectorAll('img[data-oshireader-selected="true"]').forEach(function(img) { updateSelectionStyle(img, false); });
    postSelectionState();
  };

  window.__oshiFinishImageSelection = function() {
    var urls = Array.from(selectedImageUrls);
    imageSelectionMode = false;
    selectedImageUrls = new Set();
    document.querySelectorAll('img[data-oshireader-selected="true"]').forEach(function(img) { updateSelectionStyle(img, false); });
    window.webkit.messageHandlers.oshireader.postMessage({ type: 'selected-images', urls: urls });
  };

  window.__oshiSaveAllImages = function() {
    var seen = new Set();
    var urls = [];
    document.querySelectorAll('img').forEach(function(img) {
      var url = selectableImageUrl(img);
      if (url && !seen.has(url)) {
        seen.add(url);
        urls.push(url);
      }
    });
    window.webkit.messageHandlers.oshireader.postMessage({ type: 'all-images', urls: urls });
  };

  document.addEventListener('click', function(event) {
    if (!imageSelectionMode) return;
    var el = event.target;
    var depth = 0;
    while (el && el.nodeType === 1 && depth < 6) {
      var image = (el.tagName || '').toUpperCase() === 'IMG' ? el : null;
      if (!image && el.closest) {
        var control = el.closest('a,button,[role="button"]');
        image = control && control.querySelector ? control.querySelector('img') : null;
      }
      if (image) {
        toggleImageSelection(image);
        event.preventDefault();
        event.stopPropagation();
        return;
      }
      el = el.parentElement;
      depth++;
    }
  }, true);

  document.addEventListener('contextmenu', function(event) {
    if (!imageSelectionMode) return;
    if (event.target && (event.target.tagName || '').toUpperCase() === 'IMG') {
      toggleImageSelection(event.target);
    }
    event.preventDefault();
  }, true);
  return true;
})();
true;
"""

private extension String {
    func match(_ regex: NSRegularExpression?) -> String? {
        guard let regex,
              let match = regex.firstMatch(in: self, range: NSRange(startIndex..., in: self)) else {
            return nil
        }
        if match.numberOfRanges == 1 {
            return String(self[Range(match.range(at: 0), in: self)!])
        }
        var captures = [String]()
        for index in 1..<match.numberOfRanges {
            guard let range = Range(match.range(at: index), in: self) else { continue }
            captures.append(String(self[range]))
        }
        return captures.joined(separator: "|")
    }
}
