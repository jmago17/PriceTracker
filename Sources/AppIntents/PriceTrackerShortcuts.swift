import AppIntents

struct PriceTrackerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ShowPriceDropsIntent(), phrases: [
            "Qué ha bajado en \(.applicationName)", "Bajadas de precio en \(.applicationName)",
            "Show price drops in \(.applicationName)"
        ], shortTitle: "Ver bajadas", systemImageName: "arrow.down.right.circle")

        AppShortcut(intent: RefreshCatalogIntent(), phrases: [
            "Comprueba los precios en \(.applicationName)", "Actualiza \(.applicationName)",
            "Check prices in \(.applicationName)"
        ], shortTitle: "Comprobar precios", systemImageName: "arrow.clockwise")

        AppShortcut(intent: GetItemPriceIntent(), phrases: [
            "Cuánto cuesta en \(.applicationName)", "Consulta un precio en \(.applicationName)",
            "Precio de \(\.$item) en \(.applicationName)"
        ], shortTitle: "Consultar precio", systemImageName: "tag")

        AppShortcut(intent: SetTargetPriceIntent(), phrases: [
            "Fija un precio objetivo en \(.applicationName)",
            "Avísame cuando baje \(\.$item) en \(.applicationName)"
        ], shortTitle: "Precio objetivo", systemImageName: "target")
    }
}
