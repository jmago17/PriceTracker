import Foundation
import WebKit

enum RenderedPageCaptureError: Error, LocalizedError {
    case navigation(String)
    case timeout
    case missingCaptureScript
    case invalidResult

    var errorDescription: String? {
        switch self {
        case .navigation(let message): return "No se pudo cargar la página dinámica: \(message)"
        case .timeout: return "La página dinámica tardó demasiado en cargar."
        case .missingCaptureScript: return "Falta el extractor genérico de páginas."
        case .invalidResult: return "La página dinámica no devolvió datos utilizables."
        }
    }
}

/// Executes the same generic capture script used by the Safari Share extension.
/// It runs only when the faster URLSession/JSON-LD path lacks a price or image.
@MainActor
struct RenderedPageCaptureLoader {
    func load(_ url: URL) async throws -> SharedPageCapture {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 1024, height: 768),
            configuration: configuration
        )
        let navigation = RenderedPageNavigation()
        webView.navigationDelegate = navigation

        try await navigation.load(url, in: webView)
        try await Task.sleep(for: .milliseconds(1_200))

        let script = try Self.captureScript()
        _ = try await webView.evaluateJavaScript(script)
        guard let json = try await webView.evaluateJavaScript("JSON.stringify(capturePage())") as? String,
              let data = json.data(using: .utf8),
              let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let capture = SharedPageCapture(propertyList: dictionary) else {
            throw RenderedPageCaptureError.invalidResult
        }
        return capture
    }

    private static func captureScript() throws -> String {
        let bundles = [Bundle.main, Bundle(for: RenderedPageResourceToken.self)]
        guard let url = bundles.lazy.compactMap({ $0.url(forResource: "PageCapture", withExtension: "js") }).first else {
            throw RenderedPageCaptureError.missingCaptureScript
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

private final class RenderedPageResourceToken: NSObject {}

@MainActor
private final class RenderedPageNavigation: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, any Error>?
    private var timeoutTask: Task<Void, Never>?
    private weak var webView: WKWebView?

    func load(_ url: URL, in webView: WKWebView) async throws {
        self.webView = webView
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.load(URLRequest(url: url, timeoutInterval: 8))
            timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                self?.finish(.failure(RenderedPageCaptureError.timeout), stopLoading: true)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        finish(.success(()), stopLoading: false)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: any Error) {
        finish(.failure(RenderedPageCaptureError.navigation(error.localizedDescription)), stopLoading: true)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: any Error
    ) {
        finish(.failure(RenderedPageCaptureError.navigation(error.localizedDescription)), stopLoading: true)
    }

    private func finish(_ result: Result<Void, any Error>, stopLoading: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        if stopLoading {
            webView?.stopLoading()
        }
        continuation.resume(with: result)
    }
}
