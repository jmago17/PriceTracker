import AppIntents

enum ItemStatus: String, Codable, Sendable, CaseIterable, Identifiable {
    case active
    case archived
    case unavailable
    case stale

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .active: return "Activo"
        case .archived: return "Archivado"
        case .unavailable: return "No disponible"
        case .stale: return "Sin comprobar"
        }
    }
}

extension ItemStatus: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Estado" }

    static let caseDisplayRepresentations: [ItemStatus: DisplayRepresentation] = [
        .active: DisplayRepresentation(title: "Activo"),
        .archived: DisplayRepresentation(title: "Archivado"),
        .unavailable: DisplayRepresentation(title: "No disponible"),
        .stale: DisplayRepresentation(title: "Sin comprobar"),
    ]
}

enum CategorySource: String, Codable, Sendable {
    case manual
    case mapped
    case none
}

enum AlertKind: String, Codable, Sendable {
    case drop
    case targetHit
    case lowRecord
    case unavailable
    case stale
}
