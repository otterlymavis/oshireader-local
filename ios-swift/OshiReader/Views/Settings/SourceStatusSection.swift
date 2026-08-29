import SwiftUI

/// Inline Settings section for local refresh diagnostics. Kept a child view (not
/// folded into `SettingsView.body`) with its own `@StateObject` so the frequent
/// `RefreshDiagnostics` publishes during a refresh re-evaluate only this section
/// — the root Form no longer observes `RefreshDiagnostics` at all.
struct SourceStatusSummarySection: View {
    @ObservedObject var theme: ThemeManager
    @ObservedObject var i18n: I18nManager
    @StateObject private var refreshDiagnostics = RefreshDiagnostics.shared
    @State private var showingDetail = false

    var body: some View {
        Section(header: Text(i18n.t("sourceStatusTitle"))) {
            HStack(spacing: 6) {
                Image(systemName: refreshDiagnostics.isRefreshing ? "arrow.triangle.2.circlepath" : "clock")
                    .font(.caption2)
                    .accessibilityHidden(true)
                Text(refreshDiagnostics.statusText)
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
            }
            .foregroundColor(theme.colors.textMuted)
            .accessibilityIdentifier("settings.refreshStatus")

            if !refreshDiagnostics.visibleSourceHealthSummaries.isEmpty || !refreshDiagnostics.sourceStatuses.isEmpty {
                Button {
                    showingDetail = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: refreshDiagnostics.hasSourceFailures ? "exclamationmark.triangle" : "chart.bar.xaxis")
                            .font(.caption2)
                            .accessibilityHidden(true)
                        Text(refreshDiagnostics.sourceSummaryText)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .accessibilityHidden(true)
                    }
                    .foregroundColor(refreshDiagnostics.hasSourceFailures ? .orange : theme.colors.textMuted)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.sourceStatus")
                // Attached to the Button (not the Section) so the presentation
                // reliably propagates through Form — a `.sheet` on a bare
                // `Section` is not a supported attachment point.
                .sheet(isPresented: $showingDetail) {
                    SourceStatusDetailSheet(
                        summaries: refreshDiagnostics.visibleSourceHealthSummaries,
                        theme: theme
                    )
                }
            }
        }
    }
}

private struct SourceStatusDetailSheet: View {
    let summaries: [SourceHealthSummary]
    let theme: ThemeManager
    @StateObject private var i18n = I18nManager.shared

    var body: some View {
        NavigationStack {
            if summaries.isEmpty {
                ContentUnavailableView(i18n.t("noSourceHistoryYet"), systemImage: "chart.bar.xaxis")
            } else {
                List(summaries) { summary in
                    SourceStatusRow(summary: summary, theme: theme)
                }
                .accessibilityIdentifier("settings.sourceStatusSheet")
            }
        }
        .navigationTitle(i18n.t("sourceStatusTitle"))
        .navigationBarTitleDisplayMode(.inline)
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("settings.sourceStatus.screen")
    }
}

private struct SourceStatusRow: View {
    let summary: SourceHealthSummary
    let theme: ThemeManager
    @StateObject private var i18n = I18nManager.shared

    var body: some View {
        HStack(spacing: 10) {
            let metadata = theme.metadata(for: summary.id)
            Text(metadata.icon)
            VStack(alignment: .leading, spacing: 3) {
                Text(metadata.name)
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("settings.sourceStatus.\(summary.id)")
                Text(summaryText)
                    .font(.caption)
                    .foregroundColor(theme.colors.textMuted)
            }
            Spacer()
            Text("\(summary.currentStatus?.itemCount ?? 0)")
                .font(.caption.monospacedDigit())
                .foregroundColor(theme.colors.textMuted)
        }
        .accessibilityIdentifier("settings.sourceStatus.row.\(summary.id)")
    }

    private var summaryText: String {
        let current = summary.currentStatus.map(statusText) ?? i18n.t("notChecked")
        let lastFailure = summary.lastFailure.map {
            i18n.t("sourceLastFailure").replacingOccurrences(of: "{failure}", with: $0.displayName)
        } ?? ""
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: localeIdentifier)
        formatter.unitsStyle = .short
        let checked = formatter.localizedString(for: summary.lastCheckedAt, relativeTo: Date())
        return i18n.t("sourceHistorySummary")
            .replacingOccurrences(of: "{current}", with: current)
            .replacingOccurrences(of: "{received}", with: "\(summary.receivedCount)")
            .replacingOccurrences(of: "{stale}", with: "\(summary.staleCount)")
            .replacingOccurrences(of: "{empty}", with: "\(summary.emptyCount)")
            .replacingOccurrences(of: "{failed}", with: "\(summary.failedCount)")
            .replacingOccurrences(of: "{total}", with: "\(summary.totalItemCount)")
            .replacingOccurrences(of: "{checked}", with: checked)
            .replacingOccurrences(of: "{lastFailure}", with: lastFailure)
    }

    private func statusText(_ status: SourceRefreshStatus) -> String {
        switch status.outcome {
        case .received:
            return i18n.t("sourceItemsQueries")
                .replacingOccurrences(of: "{items}", with: "\(status.itemCount)")
                .replacingOccurrences(of: "{queries}", with: "\(status.queryCount)")
        case .stale:
            return i18n.t("sourceStaleItemsQueries")
                .replacingOccurrences(of: "{items}", with: "\(status.itemCount)")
                .replacingOccurrences(of: "{queries}", with: "\(status.queryCount)")
        case .noResults:
            return i18n.t("sourceNoMatchingItemsQueries")
                .replacingOccurrences(of: "{queries}", with: "\(status.queryCount)")
        case .failed(let failure):
            return i18n.t("sourceFailureQueries")
                .replacingOccurrences(of: "{failure}", with: failure.displayName)
                .replacingOccurrences(of: "{queries}", with: "\(status.queryCount)")
        case .cooldown:
            return i18n.t("sourceCooldown")
        }
    }

    private var localeIdentifier: String {
        switch i18n.lang {
        case "zh-TW": return "zh_Hant_TW"
        case "zh-CN": return "zh_Hans_CN"
        case "ja": return "ja_JP"
        default: return "en_US"
        }
    }
}
