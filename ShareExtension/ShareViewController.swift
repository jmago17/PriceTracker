import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Native Share sheet endpoint. Shows a small SwiftUI form and sends the link
/// straight to the PriceBucket server; when that is impossible (no key, no
/// network) `ShareSubmission` parks it in the App Group inbox instead.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        Task { @MainActor in
            let shared = await extractSharedLink()
            let model = ShareSheetModel(url: shared.url, pageTitle: shared.title) { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            }
            embed(ShareSheetView(model: model))
        }
    }

    private func embed(_ content: ShareSheetView) {
        let host = UIHostingController(rootView: content)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
    }

    /// The first http(s) URL among the shared items (a URL attachment, or plain
    /// text that is a URL), with the page title Safari supplies when present.
    private func extractSharedLink() async -> (url: URL?, title: String?) {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else { return (nil, nil) }
        for item in items {
            let title = (item.attributedTitle?.string ?? item.attributedContentText?.string)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let value = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier),
                   let url = value as? URL, Self.isWebURL(url) {
                    return (url, title?.isEmpty == false ? title : nil)
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let value = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier),
                   let string = value as? String,
                   let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)), Self.isWebURL(url) {
                    return (url, nil)
                }
            }
        }
        return (nil, nil)
    }

    private static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && url.host != nil
    }
}
