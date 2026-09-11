import AppIntents

/// Which storefront/connector an item belongs to. Unknown web stores use
/// `generic`; eShop and PlayStation Store still have no dedicated connector.
enum Store: String, Codable, Sendable, CaseIterable, Identifiable {
    case appStore
    case appleStore
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
        case .appleStore: return "Apple Store"
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
        .appleStore: DisplayRepresentation(title: "Apple Store"),
        .appleBooks: DisplayRepresentation(title: "Apple Books"),
        .appleMusic: DisplayRepresentation(title: "Apple Music"),
        .amazon: DisplayRepresentation(title: "Amazon"),
        .psStore: DisplayRepresentation(title: "PlayStation Store"),
        .eshop: DisplayRepresentation(title: "Nintendo eShop"),
        .generic: DisplayRepresentation(title: "Genérico"),
    ]
}
