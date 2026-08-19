import SwiftUI

struct ShareConfirmationView: View {
    let url: String?
    let title: String?
    let onAdd: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Add this page to OshiReader?")
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
                    Text("No shareable link was found on this page.")
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
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: onAdd)
                        .disabled(url == nil)
                }
            }
        }
    }
}
