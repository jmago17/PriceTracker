import Foundation

/// The readable part of a product page, used only to feed the on-device summary.
/// It never contains prices (nothing here parses them) and the HTML is never kept.
struct PageText: Equatable, Sendable {
    var title: String?
    var description: String?
    /// Main visible text, one block per line.
    var body: String

    /// Title, description and body as one prompt-ready block, cut to `limit`.
    func combined(limit: Int = PageTextLoader.maxCharacters) -> String {
        let text = [title, description, body.trimmedNonEmpty]
            .compactMap { $0?.trimmedNonEmpty }
            .joined(separator: "\n")
        return PageTextLoader.truncate(text, to: limit)
    }
}

enum PageTextError: Error, LocalizedError, Equatable {
    case invalidURL
    case http(Int)
    case notText
    case empty

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "El enlace no es una página web."
        case .http(let code): return "La tienda respondió con el código \(code)."
        case .notText: return "La dirección no devuelve una página de texto."
        case .empty: return "La página no tiene texto legible."
        }
    }
}

/// Minimal page reader: one GET with a mobile Safari User-Agent, then title,
/// meta description and main visible text. No price parsing, no WebKit.
struct PageTextLoader: Sendable {
    static let maxCharacters = 6_000
    /// Pages are decoded up to this size; the rest cannot matter for a summary.
    static let maxBytes = 2_000_000
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    let transport: any PriceBucketTransport

    init(transport: any PriceBucketTransport = URLSessionTransport()) {
        self.transport = transport
    }

    func load(url: URL) async throws -> PageText {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw PageTextError.invalidURL
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("es-ES,es;q=0.9,en;q=0.5", forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else { throw PageTextError.http(response.statusCode) }
        if let type = response.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
           !type.contains("html"), !type.contains("text") {
            throw PageTextError.notText
        }
        let slice = data.prefix(Self.maxBytes)
        let html = String(data: slice, encoding: .utf8) ?? String(decoding: slice, as: UTF8.self)
        let page = Self.extract(html: html)
        guard page.title != nil || page.description != nil || !page.body.isEmpty else { throw PageTextError.empty }
        return page
    }

    // MARK: Extraction

    static func extract(html: String) -> PageText {
        PageText(
            title: firstMatch(#"<title\b[^>]*>(.*?)</title>"#, in: html).flatMap { decode(stripTags($0)).collapsedWhitespace },
            description: metaContent(in: html, names: ["description", "og:description"]),
            body: mainText(in: html)
        )
    }

    private static func metaContent(in html: String, names: [String]) -> String? {
        let tags = matches(#"<meta\b[^>]*>"#, in: html, group: 0)
        for name in names {
            for tag in tags {
                let key = attribute("name", in: tag) ?? attribute("property", in: tag)
                guard key?.lowercased() == name, let content = attribute("content", in: tag) else { continue }
                if let value = decode(content).collapsedWhitespace { return value }
            }
        }
        return nil
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\\b\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
        for group in 1...2 {
            if let range = Range(match.range(at: group), in: tag) { return String(tag[range]) }
        }
        return nil
    }

    private static func mainText(in html: String) -> String {
        var text = html
        text = replacing(#"<!--.*?-->"#, in: text, with: " ")
        for tag in ["script", "style", "noscript", "svg", "template", "iframe", "head", "nav", "footer", "form", "select", "button"] {
            text = replacing("<\(tag)\\b[^>]*>.*?</\(tag)\\s*>", in: text, with: " ")
        }
        // A <main> or <article> region is the product; fall back to the whole body.
        for tag in ["main", "article"] {
            if let inner = firstMatch("<\(tag)\\b[^>]*>(.*)</\(tag)\\s*>", in: text), inner.trimmedNonEmpty != nil {
                text = inner
                break
            }
        }
        text = replacing(#"</?(?:p|div|br|li|ul|ol|h[1-6]|tr|td|th|section|article|main|header|dd|dt|table|figcaption|blockquote)\b[^>]*>"#, in: text, with: "\n")
        text = decode(stripTags(text))
        return text
            .components(separatedBy: .newlines)
            .compactMap { $0.collapsedWhitespace }
            .joined(separator: "\n")
    }

    static func truncate(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let cut = String(text.prefix(limit))
        // Prefer ending on a line or word boundary rather than mid-word.
        if let boundary = cut.lastIndex(where: { $0.isWhitespace }), cut.distance(from: boundary, to: cut.endIndex) < 80 {
            return String(cut[..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cut
    }

    // MARK: Helpers

    private static func options() -> NSRegularExpression.Options { [.caseInsensitive, .dotMatchesLineSeparators] }

    private static func replacing(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options()) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        matches(pattern, in: text, group: 1).first
    }

    private static func matches(_ pattern: String, in text: String, group: Int) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options()) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: group), in: text).map { String(text[$0]) }
        }
    }

    private static func stripTags(_ text: String) -> String {
        replacing(#"<[^>]+>"#, in: text, with: " ")
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "euro": "€", "pound": "£", "copy": "©", "reg": "®", "ndash": "–", "mdash": "—",
        "hellip": "…", "laquo": "«", "raquo": "»", "middot": "·", "bull": "•",
        "aacute": "á", "eacute": "é", "iacute": "í", "oacute": "ó", "uacute": "ú", "ntilde": "ñ", "uuml": "ü",
        "Aacute": "Á", "Eacute": "É", "Iacute": "Í", "Oacute": "Ó", "Uacute": "Ú", "Ntilde": "Ñ",
    ]

    static func decode(_ text: String) -> String {
        guard text.contains("&"), let regex = try? NSRegularExpression(pattern: #"&(#x?[0-9A-Fa-f]+|[A-Za-z]+);"#) else { return text }
        var result = ""
        var last = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text), let body = Range(match.range(at: 1), in: text) else { continue }
            result += text[last..<whole.lowerBound]
            let entity = String(text[body])
            if entity.hasPrefix("#") {
                let digits = entity.dropFirst()
                let value = digits.hasPrefix("x") || digits.hasPrefix("X")
                    ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits, radix: 10)
                if let value, let scalar = Unicode.Scalar(value) { result.unicodeScalars.append(scalar) }
                else { result += text[whole] }
            } else {
                result += namedEntities[entity] ?? String(text[whole])
            }
            last = whole.upperBound
        }
        result += text[last...]
        return result
    }
}

private extension String {
    /// Runs of whitespace become one space; nil when nothing is left.
    var collapsedWhitespace: String? {
        let collapsed = split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }
}
