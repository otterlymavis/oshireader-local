import SwiftUI

enum HostedSourceHealthBadgeKind: Equatable {
    case success
    case empty
    case filtered
    case failure
    case unknown
}

struct HostedSourceHealthPresentation: Equatable {
    let kind: HostedSourceHealthBadgeKind
    let labelKey: String
    let symbolName: String

    init(status: String?) {
        switch status?.lowercased() {
        case "success":
            kind = .success
            labelKey = "sourceStatusBadgeOK"
            symbolName = "checkmark.circle.fill"
        case "empty":
            kind = .empty
            labelKey = "sourceStatusBadgeEmpty"
            symbolName = "circle.dashed"
        case "filtered":
            kind = .filtered
            labelKey = "sourceStatusBadgeFiltered"
            symbolName = "line.diagonal"
        case "failure":
            kind = .failure
            labelKey = "sourceStatusBadgeFailed"
            symbolName = "exclamationmark.triangle.fill"
        default:
            kind = .unknown
            labelKey = "sourceStatusBadgeUnknown"
            symbolName = "questionmark.circle"
        }
    }
}

enum HostedSourceHealthLoadFailure: Equatable {
    case accessUnavailable
    case requestFailed
}

@MainActor
final class HostedSourceHealthViewModel: ObservableObject {
    typealias Fetch = (TimeInterval) async throws -> [HostedSourceHealthEntry]
    typealias RefreshEntitlement = () async -> Void

    @Published private(set) var entries: [HostedSourceHealthEntry] = []
    @Published private(set) var isLoading = true
    @Published private(set) var loadFailure: HostedSourceHealthLoadFailure?

    private let fetch: Fetch
    private let refreshEntitlement: RefreshEntitlement

    init(
        fetch: @escaping Fetch = { timeout in
            try await BackendClient.shared.fetchHostedSourceHealth(timeout: timeout)
        },
        refreshEntitlement: @escaping RefreshEntitlement = {
            await PlusStore.shared.refreshStatus()
        }
    ) {
        self.fetch = fetch
        self.refreshEntitlement = refreshEntitlement
    }

    func load(timeout: TimeInterval = 15) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await fetch(timeout)
            try Task.checkCancellation()
            entries = fetched
            loadFailure = nil
        } catch is CancellationError {
            return
        } catch let BackendClientError.httpStatus(_, code, _) where code == "paid_backend_required" {
            loadFailure = .accessUnavailable
            await refreshEntitlement()
        } catch {
            loadFailure = .requestFailed
        }
    }
}

@MainActor
struct HostedSourceStatusView: View {
    let theme: ThemeManager
    @StateObject private var i18n = I18nManager.shared
    @StateObject private var model: HostedSourceHealthViewModel

    init(theme: ThemeManager) {
        self.theme = theme
        _model = StateObject(wrappedValue: HostedSourceHealthViewModel())
    }

    init(theme: ThemeManager, model: HostedSourceHealthViewModel) {
        self.theme = theme
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        List {
            if model.isLoading && model.entries.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if model.entries.isEmpty {
                ContentUnavailableView(
                    emptyStateText,
                    systemImage: model.loadFailure == nil ? "server.rack" : "exclamationmark.triangle"
                )
            } else {
                if let loadFailure = model.loadFailure {
                    Text(failureText(loadFailure))
                        .font(.caption)
                        .foregroundColor(.orange)
                        .accessibilityIdentifier("settings.hostedSourceStatus.reloadError")
                }
                ForEach(model.entries) { entry in
                    row(for: entry)
                }
            }
        }
        .accessibilityIdentifier("settings.hostedSourceStatus.screen")
        .background(theme.colors.bg)
        .navigationTitle(i18n.t("hostedSourceStatus"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .refreshable { await model.load() }
    }

    private var emptyStateText: String {
        guard let loadFailure = model.loadFailure else {
            return i18n.t("hostedSourceStatusEmpty")
        }
        return failureText(loadFailure)
    }

    private func failureText(_ failure: HostedSourceHealthLoadFailure) -> String {
        switch failure {
        case .accessUnavailable:
            return i18n.t("hostedSourceStatusAccessUnavailable")
        case .requestFailed:
            return i18n.t("hostedSourceStatusLoadError")
        }
    }

    private func row(for entry: HostedSourceHealthEntry) -> some View {
        let definition = PlatformRegistry.definition(for: entry.platform)
        let presentation = HostedSourceHealthPresentation(status: entry.status)
        let statusLabel = i18n.t(presentation.labelKey)
        var accessibilityParts = [definition?.name ?? entry.platform, statusLabel]
        if let checked = checkedText(entry) { accessibilityParts.append(checked) }
        accessibilityParts.append(itemCountText(entry.last_item_count ?? 0))
        accessibilityParts.append(failureCountText(entry.consecutive_failures))
        if presentation.kind == .failure, let error = entry.last_error, !error.isEmpty {
            accessibilityParts.append(error)
        }
        if entry.jina_ok == false {
            accessibilityParts.append(jinaText(entry))
        }

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                if let icon = definition?.icon { Text(icon) }
                Text(definition?.name ?? entry.platform)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(theme.colors.text)
                Spacer()
                Label(statusLabel, systemImage: presentation.symbolName)
                    .font(.caption)
                    .foregroundColor(badgeColor(presentation.kind))
            }
            if let checked = checkedText(entry) {
                Text(checked)
                    .font(.caption)
                    .foregroundColor(theme.colors.textMuted)
            }
            HStack(spacing: 12) {
                Text(itemCountText(entry.last_item_count ?? 0))
                Text(failureCountText(entry.consecutive_failures))
            }
            .font(.caption)
            .foregroundColor(theme.colors.textMuted)
            if presentation.kind == .failure, let error = entry.last_error, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundColor(theme.colors.textMuted)
                    .lineLimit(2)
            }
            if entry.jina_ok == false {
                Text(jinaText(entry))
                    .font(.caption)
                    .foregroundColor(.orange)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityParts.joined(separator: ", "))
        .accessibilityIdentifier("settings.hostedSourceStatus.row.\(entry.platform)")
    }

    private func checkedText(_ entry: HostedSourceHealthEntry) -> String? {
        guard let raw = entry.last_checked_at, let date = parseISO8601Date(raw) else { return nil }
        return i18n.t("hostedSourceLastChecked")
            .replacingOccurrences(of: "{time}", with: relativeTimeString(from: date))
    }

    private func itemCountText(_ count: Int) -> String {
        i18n.t("hostedSourceRecentItems").replacingOccurrences(of: "{count}", with: "\(count)")
    }

    private func failureCountText(_ count: Int) -> String {
        i18n.t("hostedSourceConsecutiveFailures").replacingOccurrences(of: "{count}", with: "\(count)")
    }

    private func jinaText(_ entry: HostedSourceHealthEntry) -> String {
        let base = i18n.t("hostedSourceJinaDegraded")
        guard let error = entry.jina_error, !error.isEmpty else { return base }
        return "\(base): \(error)"
    }

    private func badgeColor(_ kind: HostedSourceHealthBadgeKind) -> Color {
        switch kind {
        case .success: return .green
        case .failure: return .red
        case .empty, .filtered, .unknown: return theme.colors.textMuted
        }
    }
}
