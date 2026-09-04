import AppIntents

/// Which storefront/connector an item belongs to. `eshop`, `psstore` and `generic`
/// are modeled now (per architecture, item.store) but have no working connector yet —
/// see Connectors/ConnectorRegistry.swift.
enum Store: String, Codable, Sendable, CaseIterable, Identifiable {
    case appStore
    case appleBooks
    case appleMusic
    case amazon
    case psStore
    case eshop
    case generic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appStore: return "App Store"
        case .appleBooks: return "Apple Books"
        case .appleMusic: return "Apple Music"
        case .amazon: return "Amazon"
        case .psStore: return "PlayStation Store"
        case .eshop: return "Nintendo eShop"
        case .generic: return "Genérico"
        }
    }
}

extension Store: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Tienda" }

    static let caseDisplayRepresentations: [Store: DisplayRepresentation] = [
        .appStore: DisplayRepresentation(title: "App Store"),
        .appleBooks: DisplayRepresentation(title: "Apple Books"),
        .appleMusic: DisplayRepresentation(title: "Apple Music"),
        .amazon: DisplayRepresentation(title: "Amazon"),
        .psStore: DisplayRepresentation(title: "PlayStation Store"),
        .eshop: DisplayRepresentation(title: "Nintendo eShop"),
        .generic: DisplayRepresentation(title: "Genérico"),
    ]
}
