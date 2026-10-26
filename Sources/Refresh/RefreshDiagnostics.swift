import Foundation

/// Closed vocabulary only: never serialize Error descriptions or request data.
enum RefreshDiagnosticCode: String, Sendable {
    case success, blocked, rateLimited, http, identity, variant, currency, conflict, conditions
    case ambiguous, missingPrice, decoding, network, cancelled, unsupported, persistence, alerts, missingItem, notFound, unknown

    var message: String {
        switch self {
        case .success: return "Precio comprobado y guardado."
        case .blocked: return "Acceso bloqueado o CAPTCHA. Abre la tienda para comprobarlo; no se evita su protección."
        case .rateLimited: return "La tienda limita solicitudes. Espera antes de reintentar."
        case .http: return "Respuesta HTTP no válida de la tienda."
        case .identity: return "No se confirma la identidad del producto guardado."
        case .variant: return "No se confirma la talla o variante guardada."
        case .currency: return "Moneda ausente, distinta o no verificable."
        case .conflict: return "Las fuentes muestran precios incompatibles; se conserva el anterior."
        case .conditions: return "Precio condicionado, cuotas o membresía; no hay un total verificable."
        case .ambiguous: return "Precio ambiguo, rango o condiciones no verificables."
        case .missingPrice: return "Sin precio verificable; puede requerir JavaScript o no estar disponible."
        case .decoding: return "La respuesta no tiene el formato esperado."
        case .network: return "Fallo de conexión con la tienda. Revisa la red y reintenta."
        case .cancelled: return "Intento cancelado; no se ha confirmado un precio nuevo."
        case .unsupported: return "Esta tienda no tiene conector de comprobación."
        case .persistence: return "No se pudo guardar la comprobación. El precio no se confirma como actualizado."
        case .alerts: return "Entrega de alertas pendiente; se reintentará por separado del precio."
        case .notFound: return "La tienda no devuelve el artículo en la región consultada."
        case .missingItem: return "El artículo ya no existe o cambió durante la comprobación."
        case .unknown: return "Error no clasificado. Comparte este informe si vuelve a ocurrir."
        }
    }
}

enum RefreshDiagnosticPhase: String, Sendable {
    case loading = "lectura", download = "descarga", extraction = "extracción"
    case validation = "validación", persistence = "persistencia", alerts = "alertas", completed = "completado"
}

struct RefreshDiagnosticFailure: Error, LocalizedError, Sendable {
    var code: RefreshDiagnosticCode
    var phase: RefreshDiagnosticPhase
    var httpStatus: Int? = nil
    var errorDescription: String? { code.message + (httpStatus.map { " HTTP \($0)." } ?? "") }

    static func classify(_ error: Error, phase: RefreshDiagnosticPhase) -> Self {
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            return Self(code: .cancelled, phase: phase)
        }
        if let refresh = error as? RefreshError, case .itemNotFound = refresh {
            return Self(code: .missingItem, phase: phase)
        }
        // Storage and delivery errors must never be relabelled as fetch errors.
        if phase == .persistence { return Self(code: .persistence, phase: phase) }
        if phase == .alerts { return Self(code: .alerts, phase: phase) }
        if let safe = error as? Self { return safe }
        if let web = error as? WebPriceError {
            switch web {
            case .blocked: return Self(code: .blocked, phase: .validation)
            case .rateLimited: return Self(code: .rateLimited, phase: .download)
            case .response(let status):
                let code: RefreshDiagnosticCode = [401, 403].contains(status) ? .blocked : ([429, 503].contains(status) ? .rateLimited : .http)
                return Self(code: code, phase: .download, httpStatus: (100...599).contains(status) ? status : nil)
            case .identity: return Self(code: .identity, phase: .validation)
            case .variant: return Self(code: .variant, phase: .validation)
            case .currency: return Self(code: .currency, phase: .validation)
            case .conflict: return Self(code: .conflict, phase: .validation)
            case .conditions: return Self(code: .conditions, phase: .validation)
            case .ambiguous: return Self(code: .ambiguous, phase: .validation)
            case .missing: return Self(code: .missingPrice, phase: .extraction)
            }
        }
        if let connector = error as? ConnectorError {
            switch connector {
            case .unrecognizedURL: return Self(code: .identity, phase: .validation)
            case .notSupported: return Self(code: .unsupported, phase: .validation)
            case .notFound: return Self(code: .notFound, phase: .extraction)
            case .decoding: return Self(code: .decoding, phase: .extraction)
            case .network: return Self(code: .network, phase: .download)
            }
        }
        if error is URLError { return Self(code: .network, phase: .download) }
        if error is DecodingError { return Self(code: .decoding, phase: .extraction) }
        return Self(code: .unknown, phase: phase)
    }
}

struct RefreshDiagnosticAttempt: Identifiable, Sendable {
    let id: UUID
    let itemID: UUID // local lookup only, deliberately omitted from exports
    let store: Store?
    let startedAt: Date
    let duration: TimeInterval
    let lastSuccessAt: Date?
    let failure: RefreshDiagnosticFailure?
    let alertFailure: RefreshDiagnosticFailure?
    var precedingFailure: RefreshDiagnosticFailure? = nil
}

/// Session-only, no files/CloudKit/telemetry. Actor isolation plus attempt IDs
/// coalesces duplicate completion callbacks, not distinct real network attempts.
actor RefreshDiagnostics {
    static let shared = RefreshDiagnostics()
    private var attempts: [RefreshDiagnosticAttempt] = []
    private let capacity: Int
    private let perItemLimit: Int
    private let ttl: TimeInterval
    init(capacity: Int = 200, perItemLimit: Int = 20, ttl: TimeInterval = 86_400) {
        self.capacity = max(1, min(200, capacity))
        self.perItemLimit = max(1, min(20, perItemLimit))
        self.ttl = max(1, min(86_400, ttl))
    }
    private func prune(now: Date) {
        attempts.removeAll { now.timeIntervalSince($0.startedAt) > ttl }
    }
    func record(_ attempt: RefreshDiagnosticAttempt, now: Date = Date()) {
        prune(now: now)
        guard !attempts.contains(where: { $0.id == attempt.id }) else { return }
        attempts.append(attempt)
        while attempts.filter({ $0.itemID == attempt.itemID }).count > perItemLimit {
            if let index = attempts.firstIndex(where: { $0.itemID == attempt.itemID }) { attempts.remove(at: index) }
        }
        if attempts.count > capacity { attempts.removeFirst(attempts.count - capacity) }
    }
    func snapshot(itemID: UUID, now: Date = Date()) -> [RefreshDiagnosticAttempt] {
        prune(now: now)
        return attempts.filter { $0.itemID == itemID }
    }
    func clear(itemID: UUID) { attempts.removeAll { $0.itemID == itemID } }

    nonisolated static func report(_ attempts: [RefreshDiagnosticAttempt]) -> String {
        let date = ISO8601DateFormatter()
        func version(_ key: String) -> String {
            guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
                  value.count <= 40, !value.isEmpty,
                  value.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) else { return "no disponible" }
            return value
        }
        var lines = ["Price Bucket · diagnóstico local v1", "Versión: \(version("CFBundleShortVersionString")) · build: \(version("CFBundleVersion"))", "Solo sesión actual: máximo 24 h, 200 intentos y 20 por artículo.",
                     "Sin títulos, URLs, precios, cuentas ni contenido de páginas. Compartir es voluntario."]
        if attempts.isEmpty { lines.append("Sin intentos registrados. Comprueba el artículo en esta sesión y vuelve a abrir el diagnóstico.") }
        for attempt in attempts {
            let failure = attempt.failure
            let duration = attempt.duration.isFinite ? min(86_400, max(0, attempt.duration)) : 0
            lines.append("\nIntento \(attempt.id.uuidString) · \(attempt.store?.displayName ?? "Tienda no disponible")")
            lines.append("Inicio: \(date.string(from: attempt.startedAt)) · duración: \(String(format: "%.2f", duration)) s")
            lines.append("Último éxito: \(attempt.lastSuccessAt.map(date.string(from:)) ?? "sin éxito registrado")")
            lines.append("\((failure?.phase ?? .completed).rawValue) · \((failure?.code ?? .success).rawValue): \(failure?.errorDescription ?? RefreshDiagnosticCode.success.message)")
            if let preceding = attempt.precedingFailure { lines.append("Causa previa · \(preceding.phase.rawValue) · \(preceding.code.rawValue): \(preceding.errorDescription ?? preceding.code.message)") }
            if let alert = attempt.alertFailure { lines.append("alertas · \(alert.code.rawValue): \(alert.code.message)") }
        }
        return lines.joined(separator: "\n")
    }
}
