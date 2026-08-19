import SwiftUI

struct ShareConfirmationView: View {
    let url: String?
    let title: String?
    let onAdd: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(ExtensionStrings.t("shareConfirmTitle"))
                    .font(.headline)
                if let title, !title.isEmpty {
                    Text(title)
                        .font(.subheadline)
                        .lineLimit(2)
                }
                if let url {
                    Text(url)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Text(ExtensionStrings.t("shareNoLinkFound"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("OshiReader")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(ExtensionStrings.t("shareCancel"), action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(ExtensionStrings.t("shareAdd"), action: onAdd)
                        .disabled(url == nil)
                }
            }
        }
    }
}
