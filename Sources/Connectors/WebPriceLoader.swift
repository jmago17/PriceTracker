import Foundation

/// Public, stateless requests: no personal cookies, credentials or cached prices.
enum PublicWebSession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()
}

enum WebPriceError: Error, LocalizedError {
    case blocked, identity, variant, ambiguous, conflict, conditions, missing, noOffer, currency, response(Int), rateLimited
    var errorDescription: String? {
        switch self {
        case .blocked: return "La tienda solicita acceso, inicio de sesión o CAPTCHA. No se ha comprobado el precio."
        case .identity: return "La página no identifica inequívocamente el producto guardado o redirige a otro producto."
        case .variant: return "No se puede confirmar el precio de la talla o variante guardada."
        case .ambiguous: return "La página muestra varios precios, un rango, cuotas o condiciones de compra sin un precio único del producto."
        case .conflict: return "Las fuentes de la página muestran precios incompatibles. Se conserva el precio anterior."
        case .conditions: return "El precio tiene cuotas o condiciones de compra y no es un total verificable."
        case .missing: return "No se encontró un precio verificable en la página."
        case .noOffer: return "Sin oferta destacada: la tienda no muestra un precio principal ahora mismo. Se conserva el último precio."
        case .currency: return "La moneda del precio no coincide con la guardada o no se puede verificar."
        case .response(let code): return "La tienda respondió con HTTP \(code). No se ha comprobado el precio."
        case .rateLimited: return "La tienda ha limitado las solicitudes. Espera antes de volver a comprobar; se conserva el último precio."
        }
    }
}

/// Shared across manual, background and Shortcuts requests in this process.
actor WebPriceThrottle {
    static let shared = WebPriceThrottle()
    private var nextRequest: [String: Date] = [:]
    private var blockedUntil: [String: Date] = [:]
    private let interval: TimeInterval
    init(interval: TimeInterval = 1) { self.interval = interval }

    func acquire(host: String) async throws {
        try Task.checkCancellation()
        let now = Date()
        if let until = blockedUntil[host], until > now { throw WebPriceError.rateLimited }
        let start = max(now, nextRequest[host] ?? now)
        nextRequest[host] = start.addingTimeInterval(interval)
        let delay = start.timeIntervalSince(now)
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        try Task.checkCancellation()
        if let until = blockedUntil[host], until > Date() { throw WebPriceError.rateLimited }
    }

    func limit(host: String, retryAfter: String?) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        let delay = retryAfter.flatMap(TimeInterval.init)
            ?? retryAfter.flatMap(formatter.date(from:))?.timeIntervalSinceNow ?? 60
        blockedUntil[host] = Date().addingTimeInterval(min(3600, max(60, delay)))
    }
}

struct WebPriceLoader: Sendable {
    let session: URLSession
    var throttle: WebPriceThrottle = .shared

    func fetch(_ item: Item) async throws -> FetchResult {
        let url = item.canonicalURL
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(), url.user == nil, url.password == nil else {
            throw WebPriceError.identity
        }
        try await throttle.acquire(host: host)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpShouldHandleCookies = false
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue(item.region == "ES" ? "es-ES,es;q=0.9" : "en", forHTTPHeaderField: "Accept-Language")
        let (bytes, response) = try await session.bytes(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw WebPriceError.missing }
        if http.statusCode == 429 || http.statusCode == 503 {
            await throttle.limit(host: host, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
            throw WebPriceError.response(http.statusCode)
        }
        if http.statusCode == 401 || http.statusCode == 403 { throw WebPriceError.response(http.statusCode) }
        guard (200...299).contains(http.statusCode) else { throw WebPriceError.response(http.statusCode) }
        guard http.expectedContentLength <= 2_000_000 else { throw WebPriceError.missing }
        if let mime = http.mimeType, !["text/html", "application/xhtml+xml"].contains(mime) { throw WebPriceError.missing }
        var data = Data()
        for try await byte in bytes {
            if data.count >= 2_000_000 { throw WebPriceError.missing }
            data.append(byte)
            if data.count.isMultiple(of: 4096) { try Task.checkCancellation() }
        }
        try Task.checkCancellation()
        return try WebPriceParser.parse(data: data, finalURL: response.url ?? url, item: item)
    }
}
