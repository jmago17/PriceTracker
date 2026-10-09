import AppIntents
import Foundation
import Observation

/// The system search schema opens real in-app results. It does not promise
/// schema-based price updates or unrestricted Siri AI conversations.
@AppIntent(schema: .system.search)
struct SearchCatalogIntent: ShowInAppSearchResultsIntent {
    static let title: LocalizedStringResource = "Buscar en PriceTracker"
    static let searchScopes: [StringSearchScope] = [.general]
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Búsqueda") var criteria: StringSearchCriteria

    @MainActor
    func perform() async throws -> some IntentResult {
        CatalogSearchNavigation.shared.request(criteria.term)
        return .result()
    }
}

@MainActor @Observable
final class CatalogSearchNavigation {
    static let shared = CatalogSearchNavigation()
    struct Request: Equatable {
        let id = UUID()
        let term: String
    }
    var pending: Request?
    func request(_ term: String) { pending = Request(term: term) }
}
