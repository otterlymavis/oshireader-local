import SwiftUI
import UIKit
import UserNotifications

enum OshiTab: String, CaseIterable, Identifiable, Hashable {
    case feed, search, saved, oshi, settings
    var id: String { rawValue }
}

struct ContentView: View {
    @StateObject private var db = LocalDB.shared
    @StateObject private var theme = ThemeManager.shared
    @StateObject private var i18n = I18nManager.shared
    @StateObject private var appearance = AppearanceManager.shared
    @StateObject private var notificationNavigation = NotificationNavigationManager.shared
    @StateObject private var intentNavigation = AppIntentNavigationManager.shared
    
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: OshiTab = ProcessInfo.processInfo.arguments.contains("--uitesting-start-search") ? .search : .feed
    @State private var pendingShareFailure: CustomUrlAddResult?
    
    init() {
        // Initial appearance before the theme preference is read from disk.
        // The correct colors are applied in .onAppear via updateTabBarAppearance.
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        UITabBar.appearance().scrollEdgeAppearance = appearance
        UITabBar.appearance().standardAppearance = appearance
    }
    
    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
            NavigationSplitView {
                List {
                    ForEach(OshiTab.allCases) { tab in
                        Button(action: {
                            selectedTab = tab
                        }) {
                            sidebarRowContent(for: tab)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(title(for: tab))
                        .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
                        .accessibilityIdentifier("tab.\(tab.rawValue)")
                        .accessibilityAction {
                            selectedTab = tab
                        }
                        .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
                .navigationTitle(i18n.t("appTitle"))
                .listStyle(.sidebar)
            } detail: {
                switch selectedTab {
                case .feed:
                    FeedView()
                case .search:
                    SearchView()
                case .saved:
                    SavedView()
                case .oshi:
                    OshiView()
                case .settings:
                    SettingsView()
                }
            }
            .tint(theme.colors.primary)
            .preferredColorScheme(theme.mode == .dark ? .dark : .light)
            } else {
            TabView(selection: $selectedTab) {
                FeedView()
                    .tabItem {
                        Label(i18n.t("tabFeed"), systemImage: "house")
                            .accessibilityIdentifier("tab.feed")
                    }
                    .tag(OshiTab.feed)
                
                SearchView()
                    .tabItem {
                        Label(i18n.t("tabSearch"), systemImage: "magnifyingglass")
                            .accessibilityIdentifier("tab.search")
                    }
                    .tag(OshiTab.search)

                SavedView()
                    .tabItem {
                        Label(i18n.t("tabSaved"), systemImage: "bookmark")
                            .accessibilityIdentifier("tab.saved")
                    }
                    .tag(OshiTab.saved)
                
                OshiView()
                    .tabItem {
                        Label(i18n.t("tabOshi"), systemImage: "star")
                            .accessibilityIdentifier("tab.oshi")
                    }
                    .tag(OshiTab.oshi)
                
                SettingsView()
                    .tabItem {
                        Label(i18n.t("tabSettings"), systemImage: "gearshape")
                            .accessibilityIdentifier("tab.settings")
                    }
                    .tag(OshiTab.settings)
            }
            .tint(theme.colors.primary)
            // Ensure standard backgrounds
            .background(theme.colors.bg.ignoresSafeArea())
            .preferredColorScheme(theme.mode == .dark ? .dark : .light)
            }
        }
        .font(appearance.appFont)
        .ifLet(appearance.dynamicTypeSizeOverride) { view, size in
            view.environment(\.dynamicTypeSize, size)
        }
        .onAppear {
            updateTabBarAppearance(for: theme.mode)
            handlePendingShareDrain(db.processPendingShares())
        }
        .onChange(of: theme.mode) { _, newMode in
            updateTabBarAppearance(for: newMode)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                UNUserNotificationCenter.current().setBadgeCount(0)
                handlePendingShareDrain(db.processPendingShares())
            }
        }
        .alert(
            i18n.t("shareAddFailedTitle"),
            isPresented: Binding(
                get: { pendingShareFailure != nil },
                set: { if !$0 { pendingShareFailure = nil } }
            )
        ) {
            Button(i18n.t("ok"), role: .cancel) {}
        } message: {
            Text(pendingShareFailureMessage)
        }
        .onOpenURL { url in
            guard url.scheme == "oshireader", url.host == "article",
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
            var userInfo: [String: String] = [:]
            for item in components.queryItems ?? [] {
                if let value = item.value { userInfo[item.name] = value }
            }
            notificationNavigation.open(userInfo: userInfo)
        }
        .onReceive(notificationNavigation.$selectedItem) { item in
            if item != nil {
                selectedTab = .feed
            }
        }
        .onReceive(intentNavigation.$pendingSearchQuery) { query in
            if query != nil {
                selectedTab = .search
            }
        }
        .sheet(item: $notificationNavigation.selectedItem) { item in
            NavigationStack {
                ReaderView(feedItem: item)
            }
            .preferredColorScheme(theme.mode == .dark ? .dark : .light)
        }
    }

    /// Surfaces the first failure from a Share Extension drain — mirrors
    /// FeedView's in-app "Add custom feed" failure alert so a share that
    /// silently didn't make it in (duplicate, invalid, or over the custom
    /// URL limit) doesn't just vanish with no explanation.
    private func handlePendingShareDrain(_ summary: PendingShareDrainSummary) {
        pendingShareFailure = summary.failures.first
    }

    private var pendingShareFailureMessage: String {
        switch pendingShareFailure {
        case .limitReached: return i18n.t("customUrlLimitReached")
        case .duplicate: return i18n.t("customUrlDuplicate")
        case .invalidURL, .added, nil: return i18n.t("invalidUrl")
        }
    }

    /// Applies a theme-aware `UITabBarAppearance` so the tab bar background
    /// stays in sync when the user switches between light / dark / sepia modes.
    private func updateTabBarAppearance(for mode: AppThemeMode) {
        let colors = AppColors(mode: mode)
        let tbAppearance = UITabBarAppearance()
        tbAppearance.configureWithOpaqueBackground()
        tbAppearance.backgroundColor = UIColor(colors.card)
        UITabBar.appearance().scrollEdgeAppearance = tbAppearance
        UITabBar.appearance().standardAppearance = tbAppearance
    }

    private func sidebarRowContent(for tab: OshiTab) -> some View {
        let isSelected = selectedTab == tab

        return HStack {
            Image(systemName: icon(for: tab))
                .font(.title3)
                .frame(width: 28)
            Text(title(for: tab))
                .font(.body)
                .fontWeight(isSelected ? .bold : .medium)
            Spacer()
        }
        .foregroundColor(isSelected ? .white : theme.colors.text)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? theme.colors.primary : Color.clear)
        .cornerRadius(10)
        .contentShape(Rectangle())
    }
    
    private func title(for tab: OshiTab) -> String {
        switch tab {
        case .feed: return i18n.t("tabFeed")
        case .saved: return i18n.t("tabSaved")
        case .oshi: return i18n.t("tabOshi")
        case .search: return i18n.t("tabSearch")
        case .settings: return i18n.t("tabSettings")
        }
    }
    
    private func icon(for tab: OshiTab) -> String {
        switch tab {
        case .feed: return "house"
        case .saved: return "bookmark"
        case .oshi: return "star"
        case .search: return "magnifyingglass"
        case .settings: return "gearshape"
        }
    }
}

private extension View {
    @ViewBuilder
    func ifLet<T>(_ value: T?, transform: (Self, T) -> some View) -> some View {
        if let value {
            transform(self, value)
        } else {
            self
        }
    }
}

#Preview {
    ContentView()
}
