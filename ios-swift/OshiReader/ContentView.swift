import SwiftUI
import UIKit

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
    
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedTab: OshiTab = .feed
    
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
                        .accessibilityIdentifier("tab.\(tab.rawValue)")
                        .accessibilityAction {
                            selectedTab = tab
                        }
                        .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: selectedTab)
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
                    }
                    .tag(OshiTab.feed)
                    .accessibilityIdentifier("tab.feed")
                
                SearchView()
                    .tabItem {
                        Label(i18n.t("tabSearch"), systemImage: "magnifyingglass")
                    }
                    .tag(OshiTab.search)
                    .accessibilityIdentifier("tab.search")

                SavedView()
                    .tabItem {
                        Label(i18n.t("tabSaved"), systemImage: "bookmark")
                    }
                    .tag(OshiTab.saved)
                    .accessibilityIdentifier("tab.saved")
                
                OshiView()
                    .tabItem {
                        Label(i18n.t("tabOshi"), systemImage: "star")
                    }
                    .tag(OshiTab.oshi)
                    .accessibilityIdentifier("tab.oshi")
                
                SettingsView()
                    .tabItem {
                        Label(i18n.t("tabSettings"), systemImage: "gearshape")
                    }
                    .tag(OshiTab.settings)
                    .accessibilityIdentifier("tab.settings")
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
        }
        .onChange(of: theme.mode) { _, newMode in
            updateTabBarAppearance(for: newMode)
        }
        .sheet(item: $notificationNavigation.selectedItem) { item in
            NavigationStack {
                ReaderView(feedItem: item)
            }
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
