import SwiftUI

/// Home for the screens that used to be catalog-toolbar sheets with no other
/// entry point (handoff structural change #5). The catálogo "···" menu still
/// offers quick shortcuts to the same two screens for convenience.
struct SettingsView: View {
    var viewModel: ItemListViewModel
    var syncViewModel: RemoteSyncViewModel

    @State private var automation = DailyRefreshSettings.shared
    @State private var bridge = ShortcutBridgeSettings.shared
    @AppStorage("timeSensitivePriceDeals") private var timeSensitivePriceDeals = false
    @AppStorage("compactCatalogMuralEnabled") private var compactCatalogMuralEnabled = false

    var body: some View {
        NavigationStack {
            List {
                if syncViewModel.isAvailable {
                    serverSection
                } else {
                Section {
                    Toggle("Actualizar precios diariamente", isOn: Binding(
                        get: { automation.dailyEnabled }, set: { automation.setDailyEnabled($0) }))
                    Toggle("Notificar cambios de precio", isOn: Binding(
                        get: { automation.notificationsEnabled },
                        set: { value in Task { await automation.setNotificationsEnabled(value) } }))
                        .disabled(automation.requestingPermission)
                    Toggle(CatalogLanguage.isSpanish
                           ? "Avisos sensibles al tiempo para ofertas prioritarias"
                           : "Time Sensitive alerts for high-priority deals", isOn: $timeSensitivePriceDeals)
                    Text(CatalogLanguage.isSpanish
                         ? "Solo ofertas confirmadas con vencimiento de artículos de prioridad alta. Requiere permiso en Ajustes de notificaciones de iOS; no evita el modo silencio. Si no está permitido, se envía un aviso normal."
                         : "Only confirmed, expiring offers for high-priority items. Requires permission in iOS Notification Settings; does not override silent mode. Otherwise a normal alert is sent.")
                        .font(.caption).foregroundStyle(.secondary)
                    Link(CatalogLanguage.isSpanish ? "Ajustes de notificaciones" : "Notification Settings",
                         destination: URL(string: UIApplication.openNotificationSettingsURLString)!)
                    if let message = automation.message {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Precios y avisos")
                } footer: {
                    Text("iOS decide cuándo puede actualizar en segundo plano; no se garantiza una hora ni una ejecución diaria. Solo se comprueban tiendas compatibles. Los avisos también se aplican a las comprobaciones manuales y de Atajos.")
                }
                shortcutBridgeSection
                }
                Section("Apariencia") {
                    Toggle("Mural en iPhone", isOn: $compactCatalogMuralEnabled)
                        .accessibilityIdentifier("compact-catalog-mural-toggle")
                    Text("Catálogo gris con tarjetas en dos columnas escalonadas, adaptable a una columna con texto accesible o poco ancho. Desactivado conserva la lista habitual. En iPad a ancho completo se mantiene el mural.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Atajos y Siri") {
                    Text("En Atajos: Buscar artículos → Repetir con cada uno → Actualizar artículo. Cada resultado incluye precio en céntimos, moneda, cambio y error.")
                    Text("Con Siri puedes decir: ‘Comprueba los precios en PriceTracker’. La disponibilidad depende del sistema, idioma y configuración de Siri.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {

                    NavigationLink {
                        ImportExportView(viewModel: viewModel)
                    } label: {
                        Label("Importar / exportar", systemImage: "square.and.arrow.up.on.square")
                    }
                }

                Section {
                    LabeledContent("Versión", value: appVersion)
                }
            }
            .navigationTitle("Ajustes")
        }
    }

    private var shortcutBridgeSection: some View {
        Section {
            Toggle("Puente diario para Atajos", isOn: Binding(
                get: { bridge.enabled },
                set: { value in Task { await bridge.setEnabled(value) } }))
                .disabled(bridge.isWorking && !bridge.enabled)
            DatePicker("Hora local", selection: Binding(
                get: { bridge.time },
                set: { value in Task { await bridge.setTime(value) } }),
                displayedComponents: .hourAndMinute)
                .disabled(bridge.isWorking)
            Button("Enviar notificación de prueba") {
                Task { await bridge.test() }
            }
            .disabled(bridge.isWorking)
            if let message = bridge.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Link("Abrir ajustes de notificaciones", destination: URL(string: UIApplication.openNotificationSettingsURLString)!)
            NavigationLink("Cómo configurar la automatización") {
                List {
                    Section("Configuración manual en Atajos") {
                        Text("1. Abre Atajos → Automatización → Nueva automatización. Si tu versión ofrece el disparador Notificación, selecciónalo y elige PriceTracker.")
                        Text("2. Filtra el cuerpo por el texto exacto ‘PriceTracker refresh’. Si solo permite elegir la app, añade una condición sobre el cuerpo antes de ejecutar la acción para no reaccionar a los avisos de precios.")
                        Text("3. Añade PriceTracker → Comprobar precios (actualiza el catálogo). Elige Ejecutar inmediatamente si el sistema lo permite; si pide confirmación, tendrás que confirmarla.")
                        Text("4. Activa el puente y elige la hora. Envía una prueba y sal de PriceTracker. Verifica la recepción y la ejecución; programar una notificación no comprueba que Atajos esté configurado.")
                    }
                    Section("Si no aparece Notificación") {
                        Text("No todas las versiones de iOS ofrecen ese disparador. Usa Atajos → Automatización → Hora del día → Diariamente → PriceTracker → Comprobar precios. Desactiva este puente para evitar avisos innecesarios.")
                    }
                    Section("Límites") {
                        Text("Es una notificación local pasiva: sin sonido ni insignia, no invisible. Puede quedar en el Centro de notificaciones. No inicia Atajos por sí sola ni garantiza una actualización. La entrega, permisos, modos de concentración, confirmaciones y ejecución en segundo plano dependen de iOS.")
                        Text("El permiso es compartido con los avisos de precios, pero el puente no activa ni desactiva esos avisos. Si usas la automatización, puedes desactivar la actualización diaria de mejor esfuerzo para evitar comprobaciones duplicadas.")
                    }
                }
                .navigationTitle("Puente de Atajos")
            }
        } header: {
            Text("Automatización por notificación")
        } footer: {
            Text("Optativo. Envía ‘PriceTracker refresh’ cada día a la hora local elegida. Requiere configurar Atajos manualmente y que iOS ofrezca un disparador compatible. Silenciosa significa sin sonido, no invisible.")
        }
    }

    private var syncSubtitle: String {
        guard syncViewModel.isConfigured else { return "Sin configurar" }
        if let error = syncViewModel.lastError { return error }
        return syncViewModel.lastSyncAt.map { "Sincronizado \($0.relativeSpanish)" } ?? "Sin sincronizar"
    }

    /// Prices are checked and alerts sent by the server, so the on-device
    /// automation sections do not apply in remote mode.
    private var serverSection: some View {
        Section {
            NavigationLink {
                ServerSettingsView(viewModel: syncViewModel)
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Servidor PriceBucket")
                        Text(syncSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                } icon: {
                    Image(systemName: "server.rack")
                }
            }
            .accessibilityIdentifier("settings-sync-row")
        } header: {
            Text("Precios y avisos")
        } footer: {
            Text("El servidor comprueba los precios cada día (y en la rutina de las 08:00) y envía los avisos. La app solo muestra el catálogo y lo edita.")
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }
}
