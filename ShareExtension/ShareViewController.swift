import UIKit
import UniformTypeIdentifiers

/// Native Share sheet endpoint. It deliberately does no network work: it stores
/// the URL in the App Group inbox and lets the main app resolve it next time it
/// becomes active.
final class ShareViewController: UIViewController {
    private let inbox = SharedURLInbox()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        Task { @MainActor in
            let saved = await extractAndSaveURL()
            showResult(saved: saved)
        }
    }

    private func extractAndSaveURL() async -> Bool {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else { return false }
        for item in items {
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let value = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier),
                   let url = value as? URL {
                    inbox.enqueue(url)
                    return true
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let value = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier),
                   let string = value as? String,
                   let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
                   url.scheme != nil {
                    inbox.enqueue(url)
                    return true
                }
            }
        }
        return false
    }

    private func showResult(saved: Bool) {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textAlignment = .center
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .headline)
        label.text = saved ? "Saved to PriceTracker" : "No URL to save"
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
    }
}
