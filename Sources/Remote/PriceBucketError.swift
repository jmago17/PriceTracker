import Foundation

/// Typed failures of the PriceBucket backend, with messages ready for the UI.
enum PriceBucketError: Error, LocalizedError, Equatable, Sendable {
    case notConfigured
    case unauthorized
    case notFound
    case validation(String)
    case storeUnreachable(String?)
    case server(Int)
    case offline
    case invalidResponse
    case unexpectedStatus(Int)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "El servidor no está configurado. Pega tu clave en Ajustes → Servidor PriceBucket."
        case .unauthorized:
            return "El servidor ha rechazado la clave. Revísala en Ajustes → Servidor PriceBucket."
        case .notFound:
            return "El servidor no conoce este artículo. Sincroniza para actualizar el catálogo."
        case .validation(let message):
            return message
        case .storeUnreachable(let detail):
            if let detail, !detail.isEmpty { return "El servidor no pudo leer la tienda: \(detail)" }
            return "El servidor no pudo leer la tienda. Inténtalo más tarde."
        case .server(let code):
            return "El servidor ha fallado (código \(code)). Inténtalo de nuevo en unos minutos."
        case .offline:
            return "Sin conexión con el servidor. Comprueba tu conexión e inténtalo de nuevo."
        case .invalidResponse:
            return "El servidor devolvió una respuesta que la app no entiende."
        case .unexpectedStatus(let code):
            return "Respuesta inesperada del servidor (código \(code))."
        case .unsupported(let message):
            return message
        }
    }

    /// 422 on add because the link is already in the catalog. The server's exact
    /// wording is not part of the documented contract, so this matches loosely.
    var isAlreadyExists: Bool {
        guard case .validation(let message) = self else { return false }
        let lowered = message.lowercased()
        return ["ya existe", "ya está", "ya esta", "exist", "already", "duplic"].contains { lowered.contains($0) }
    }
}
