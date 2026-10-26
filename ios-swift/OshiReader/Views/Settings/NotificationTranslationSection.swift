import SwiftUI
import Translation

/// Lets the user download the on-device language models
/// `NotificationAlertTranslator` needs. Background refreshes can only use
/// pairs that are already installed, and iOS shows its download sheet only
/// from a view's `.translationTask` — so the download has to start here.
@available(iOS 26.0, *)
struct NotificationTranslationSection: View {
    @ObservedObject var theme: ThemeManager
    @ObservedObject var i18n: I18nManager
    var headerKey = "notificationTranslationHeader"
    var footerKey = "notificationTranslationFooter"
    @Environment(\.scenePhase) private var scenePhase

    private struct LanguagePair: Identifiable {
        let source: Locale.Language
        let target: Locale.Language
        var status: LanguageAvailability.Status?
        var id: String { source.minimalIdentifier }
    }

    @State private var pairs: [LanguagePair] = []
    @State private var downloadConfiguration: TranslationSession.Configuration?

    var body: some View {
        Section {
            ForEach(pairs) { pair in
                HStack {
                    Label("\(languageName(pair.source)) → \(languageName(pair.target))", systemImage: "translate")
                    Spacer()
                    statusView(for: pair)
                }
                .accessibilityIdentifier("settings.notificationTranslation.\(pair.id)")
            }

            Text(i18n.t(footerKey))
                .font(.caption)
                .foregroundColor(theme.colors.textMuted)
        } header: {
            Text(i18n.t(headerKey))
        }
        .translationTask(downloadConfiguration) { session in
            // Shows the system download sheet when the pair isn't installed yet.
            try? await session.prepareTranslation()
            await MainActor.run {
                downloadConfiguration = nil
                NotificationAlertTranslator.shared.resetUnavailablePairs()
            }
            await refreshStatuses()
        }
        .task(id: i18n.lang) { await refreshStatuses() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await refreshStatuses() }
        }
    }

    @ViewBuilder
    private func statusView(for pair: LanguagePair) -> some View {
        switch pair.status {
        case .installed:
            Text(i18n.t("translationStatusReady"))
                .foregroundColor(theme.colors.primary)
        case .supported:
            Button(i18n.t("translationDownload")) {
                downloadConfiguration = .init(source: pair.source, target: pair.target)
            }
            .disabled(downloadConfiguration != nil)
            .foregroundColor(theme.colors.primary)
            .accessibilityIdentifier("settings.notificationTranslation.download.\(pair.id)")
        case .unsupported:
            Text(i18n.t("translationStatusUnsupported"))
                .foregroundColor(theme.colors.textMuted)
        default:
            ProgressView()
        }
    }

    @MainActor
    private func refreshStatuses() async {
        guard let target = NotificationAlertTranslator.targetLanguage(forAppLanguage: i18n.lang)?.locale else {
            pairs = []
            return
        }
        let sources = NotificationAlertTranslator.sourceLanguagesToPrepare(forAppLanguage: i18n.lang)
        if pairs.map(\.source) != sources || pairs.first?.target != target {
            pairs = sources.map { LanguagePair(source: $0, target: target, status: nil) }
        }
        let availability = LanguageAvailability()
        for index in pairs.indices {
            pairs[index].status = await availability.status(from: pairs[index].source, to: target)
        }
    }

    /// Language names follow the app language, not the device locale.
    private func languageName(_ language: Locale.Language) -> String {
        Locale(identifier: i18n.lang).localizedString(forIdentifier: language.minimalIdentifier)
            ?? language.minimalIdentifier
    }
}
