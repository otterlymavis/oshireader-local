import SwiftUI
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        extractSharedURL { [weak self] url, title in
            DispatchQueue.main.async {
                self?.presentShareView(url: url, title: title)
            }
        }
    }

    private func presentShareView(url: String?, title: String?) {
        let view = ShareConfirmationView(
            url: url,
            title: title,
            onAdd: { [weak self] in
                if let url {
                    PendingShareStore.enqueue(url: url, title: title)
                }
                self?.extensionContext?.completeRequest(returningItems: nil)
            },
            onCancel: { [weak self] in
                self?.extensionContext?.cancelRequest(
                    withError: NSError(domain: "com.otterpia.oshireader.share", code: 0)
                )
            }
        )
        let hosting = UIHostingController(rootView: view)
        addChild(hosting)
        hosting.view.frame = self.view.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.view.addSubview(hosting.view)
        hosting.didMove(toParent: self)
    }

    /// Safari hands over a `public.url` attachment (and sometimes an
    /// `NSExtensionItem.attributedContentText` carrying the page title);
    /// other apps sharing plain text links land on the `public.plain-text`
    /// branch instead.
    private func extractSharedURL(completion: @escaping (String?, String?) -> Void) {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let provider = item.attachments?.first else {
            completion(nil, nil)
            return
        }
        let suggestedTitle = item.attributedContentText?.string

        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier) { data, _ in
                let url = (data as? URL)?.absoluteString
                completion(url, suggestedTitle)
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { data, _ in
                completion(data as? String, suggestedTitle)
            }
        } else {
            completion(nil, suggestedTitle)
        }
    }
}
