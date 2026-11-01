import SwiftUI
import Charts

/// Shows successful check freshness separately from observed price changes.
/// History contains real recorded observations, merged across devices.
///
/// Layering follows iOS 26: content sits on grouped cards, and only the
/// controls (the floating primary action, the toolbar) are Liquid Glass.
/// Sections with nothing to show collapse to one line or disappear.
struct ItemDetailView: View {
    private let initialItem: Item
    let viewModel: ItemListViewModel

    init(item: Item, viewModel: ItemListViewModel) {
        initialItem = item
        self.viewModel = viewModel
    }

    // Read the observable collection here so an open detail follows refreshes.
    private var item: Item {
        viewModel.items.first { $0.id == initialItem.id } ?? initialItem
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ScaledMetric(relativeTo: .largeTitle) private var priceSize: CGFloat = 54
    @State private var showingEdit = false
    @State private var showingDeleteConfirmation = false
    @State private var isRefreshing = false

    private var isRegularLayout: Bool {
        horizontalSizeClass == .regular && !dynamicTypeSize.isAccessibilitySize
    }

    var body: some View {
        ScrollView {
            Group {
                if isRegularLayout {
                    regularLayout
                } else {
                    compactLayout
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .background(alignment: .top) { backdrop }
        .background(Color(.systemGroupedBackground))
        .task(id: item) { await viewModel.loadHistory(for: item) }
        .navigationTitle(item.store.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(
                    item: item.canonicalURL,
                    subject: Text(item.title),
                    message: Text(ItemShareFormatter.message(for: item))
                ) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Compartir artículo")
                .accessibilityIdentifier("share-item-button")
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Editar", systemImage: "pencil") { showingEdit = true }
                    Button(pauseLabel, systemImage: item.status == .archived ? "play" : "pause") {
                        viewModel.togglePause(item)
                    }
                    Divider()
                    Button("Eliminar", systemImage: "trash", role: .destructive) {
                        showingDeleteConfirmation = true
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("Opciones del artículo")
            }
        }
        .safeAreaInset(edge: .bottom) { openInStoreBar }
        .sheet(isPresented: $showingEdit) {
            EditItemView(item: item, viewModel: viewModel)
        }
        .confirmationDialog("¿Eliminar este artículo?", isPresented: $showingDeleteConfirmation,
                            titleVisibility: .visible) {
            Button("Eliminar", role: .destructive) {
                viewModel.delete(item)
                dismiss()
            }
        } message: {
            Text("Se dejará de seguir y se borrará de tu catálogo.")
        }
    }

    /// A soft wash of the product image behind the top of the page, so the
    /// glass toolbar has something to refract. Decorative only.
    @ViewBuilder
    private var backdrop: some View {
        if let url = item.imageURL {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.clear
            }
            .frame(height: 380)
            .clipped()
            .blur(radius: 70)
            .opacity(0.35)
            .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
            .ignoresSafeArea(edges: .top)
            .accessibilityHidden(true)
        }
    }

    // MARK: Layouts

    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            priceBlock
            summarySection
            pricesCard
            historySection
            tagsAndNotesCard
            trackingCard
        }
        .frame(maxWidth: 760)
        .padding(.horizontal, 16)
    }

    /// iPad: the product image and its price history on the left, everything
    /// you read or act on in a column on the right.
    private var regularLayout: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 16) {
                if item.imageURL != nil {
                    productImage(height: 420)
                }
                historySection
                tagsAndNotesCard
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 16) {
                titleBlock(largeTitle: true)
                priceBlock
                summarySection
                pricesCard
                trackingCard
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: 1180)
        .padding(.horizontal, 32)
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        if item.imageURL != nil {
            VStack(alignment: .leading, spacing: 14) {
                productImage(height: 240)
                titleBlock(largeTitle: false)
                    .padding(.horizontal, 4)
            }
        } else {
            // No image: a compact tile beside the title instead of an empty hero.
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 14))
            layout {
                Image(systemName: "bag")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 64, height: 64)
                    .background(Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityHidden(true)
                titleBlock(largeTitle: false)
            }
            .padding(.horizontal, 4)
        }
    }

    private func productImage(height: CGFloat) -> some View {
        AsyncImage(url: item.imageURL) { image in
            image.resizable().scaledToFit().padding(20)
        } placeholder: {
            ProgressView()
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        .accessibilityHidden(true)
    }

    private func titleBlock(largeTitle: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(storeAndCategoryText)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(item.title)
                .font(.system(largeTitle ? .largeTitle : .title2, design: .serif, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle = item.subtitle, !subtitle.isEmpty, item.summary == nil {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            variantChips
        }
    }

    private var storeAndCategoryText: String {
        if let category = item.category, !category.isEmpty {
            return "\(item.store.displayName) · \(category)"
        }
        return item.store.displayName
    }

    @ViewBuilder
    private var variantChips: some View {
        if item.size?.trimmedNonEmpty != nil || item.color?.trimmedNonEmpty != nil {
            HStack(spacing: 8) {
                if let size = item.size?.trimmedNonEmpty {
                    VariantChip(label: "Talla", value: size)
                }
                if let color = item.color?.trimmedNonEmpty {
                    VariantChip(label: "Color", value: color)
                }
            }
            .padding(.top, 2)
        }
    }

    // MARK: Price

    @ViewBuilder
    private var priceBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if item.priceCurrentCents != nil {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(priceText)
                        .font(.system(size: priceSize, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    if let percent = discountPercent {
                        Label("\(percent) %", systemImage: "arrow.down")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.green.opacity(0.15), in: Capsule())
                    }
                }
                if let savingsMessage {
                    Text(savingsMessage)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    Text("Comparación histórica; no confirma una promoción de la tienda.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if item.isPendingFirstCheck {
                StatusChip(text: Item.pendingFirstCheckText, systemImage: "clock.badge", tint: .orange)
                Text("Se comprobará en la próxima pasada del servidor.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                StatusChip(text: "Sin precio comprobado", systemImage: "exclamationmark.triangle", tint: .red)
                Text("La última comprobación no devolvió un precio. Detalles más abajo.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    private var priceText: String {
        guard let cents = item.priceCurrentCents else { return "—" }
        return cents == 0 ? "Gratis" : format(cents)
    }

    private var discountPercent: Int? {
        guard ItemListViewModel.isDiscounted(item),
              let current = item.priceCurrentCents,
              let atAdd = item.priceAtAddCents,
              atAdd > 0 else { return nil }
        return Int(((Double(atAdd - current) / Double(atAdd)) * 100).rounded())
    }

    private var savingsMessage: String? {
        guard ItemListViewModel.isDiscounted(item),
              let current = item.priceCurrentCents,
              let atAdd = item.priceAtAddCents else { return nil }
        return CatalogLanguage.isSpanish
            ? "\(format(atAdd - current)) menos que el precio inicial"
            : "\(format(atAdd - current)) below the initial price"
    }

    // MARK: Summary (Apple Intelligence)

    private var isSummarizing: Bool { viewModel.summarizingIDs.contains(item.id) }

    @ViewBuilder
    private var summarySection: some View {
        let unavailableReason = ProductInsightGenerator.unavailableReason
        if isSummarizing {
            DetailCard(title: "Resumen", systemImage: "sparkles") {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Leyendo la página con Apple Intelligence…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        } else if let summary = item.summary {
            DetailCard(title: "Resumen", systemImage: "sparkles") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(summary)
                        .font(.body)
                        .textSelection(.enabled)
                    Text("Generado en el dispositivo con Apple Intelligence a partir de la página de la tienda.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if unavailableReason == nil {
                        generateSummaryButton(title: "Volver a generar")
                    } else if let unavailableReason {
                        Text(unavailableReason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else if unavailableReason == nil {
            // Nothing generated yet: one compact row, not a card of explanation.
            VStack(alignment: .leading, spacing: 4) {
                generateSummaryButton(title: "Generar resumen")
                if let error = viewModel.summaryErrors[item.id] {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private func generateSummaryButton(title: LocalizedStringKey) -> some View {
        Button(title, systemImage: "sparkles") {
            viewModel.generateSummary(for: item)
        }
        .font(.subheadline.weight(.medium))
        .accessibilityIdentifier("generate-summary-button")
    }

    // MARK: Prices

    @ViewBuilder
    private var pricesCard: some View {
        let rows = priceRows
        let showsTarget = item.targetPriceCents != nil && item.priceCurrentCents != nil
        if !rows.isEmpty || showsTarget || item.canUseCurrentPriceAsInitial {
            DetailCard(title: "Precios", systemImage: "eurosign.circle") {
                VStack(spacing: 0) {
                    ForEach(rows.indices, id: \.self) { index in
                        if index > 0 { Divider() }
                        HStack {
                            Text(rows[index].label)
                            Spacer()
                            Text(rows[index].value).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .padding(.vertical, 10)
                    }
                    if let target = item.targetPriceCents, let current = item.priceCurrentCents {
                        if !rows.isEmpty { Divider() }
                        targetProgress(target: target, current: current)
                            .padding(.vertical, 10)
                    }
                    if item.canUseCurrentPriceAsInitial {
                        if !rows.isEmpty || showsTarget { Divider() }
                        VStack(alignment: .leading, spacing: 2) {
                            Button {
                                Task { await viewModel.useCurrentPriceAsInitial(item) }
                            } label: {
                                Label(CatalogLanguage.isSpanish
                                      ? "Usar precio actual como inicial" : "Use current price as initial",
                                      systemImage: "arrow.counterclockwise")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .accessibilityIdentifier("reset-initial-price")
                            Text(CatalogLanguage.isSpanish
                                 ? "Conserva el historial y el mínimo observado."
                                 : "Keeps history and the observed low.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 10)
                    }
                }
            }
        }
    }

    private var priceRows: [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = []
        if let atAdd = item.priceAtAddCents {
            rows.append((CatalogLanguage.isSpanish ? "Precio inicial" : "Initial price", format(atAdd)))
        }
        if let reference = item.priceReferenceCents {
            rows.append(("Referencia capturada", format(reference)))
        }
        if let low = item.priceLowCents {
            rows.append(("Mínimo observado", format(low)))
        }
        if let target = item.targetPriceCents {
            rows.append(("Precio objetivo", format(target)))
        }
        return rows
    }

    @ViewBuilder
    private func targetProgress(target: Int, current: Int) -> some View {
        // How much of the gap from "current" down to "target" is already
        // closed — 100% only once current <= target.
        let progress = current > 0 ? min(1, Double(target) / Double(current)) : 1
        let remaining = current - target
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: max(0, min(1, progress)))
                .tint(remaining > 0 ? .orange : .green)
            Text(remaining > 0 ? "Faltan \(format(remaining)) para el objetivo" : "Objetivo alcanzado")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Recorded observations

    private var historySeries: PriceHistorySeries {
        PriceHistorySeries(observations: viewModel.histories[item.identityKey] ?? [], currency: item.currency)
    }

    @ViewBuilder
    private var historySection: some View {
        let loaded = viewModel.histories[item.identityKey] != nil
        let hasFailed = viewModel.historyErrors[item.identityKey] != nil
        let hasPoints = loaded && !historySeries.observations.isEmpty
        if hasPoints {
            DetailCard(title: "Evolución del precio", systemImage: "chart.xyaxis.line") {
                VStack(alignment: .leading, spacing: 8) {
                    PriceHistoryChart(series: historySeries, currency: item.currency)
                    if !historySeries.hasTimeSpan {
                        Text("Una comprobación: todavía no hay un intervalo que comparar.")
                            .font(.subheadline)
                        if let observation = historySeries.observations.first {
                            Text(observation.checkedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "es_ES"))))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if historySeries.isUnchanged {
                        Text("Mismo precio en las comprobaciones registradas.")
                            .font(.subheadline)
                    }
                    if let changed = historySeries.lastPriceChangeAt {
                        Text("Último cambio observado \(changed.relativeSpanish)")
                            .font(.subheadline)
                    }
                    Text("Comprobaciones registradas por el servidor. Los puntos son precios observados; no se reconstruyen fechas anteriores.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    keepaLink
                }
            }
        } else if hasFailed || !loaded || !item.isPendingFirstCheck || item.keepaURL != nil {
            // Compact single rows instead of a card full of explanation.
            VStack(alignment: .leading, spacing: 10) {
                if hasFailed {
                    Label("No se pudo cargar el historial. Vuelve a abrir la ficha para reintentarlo.",
                          systemImage: "exclamationmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if !loaded {
                    ProgressView("Cargando historial")
                        .font(.subheadline)
                } else if !item.isPendingFirstCheck {
                    Label("Todavía sin observaciones", systemImage: "chart.xyaxis.line")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                keepaLink
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private var keepaLink: some View {
        if let keepaURL = item.keepaURL {
            Link(destination: keepaURL) {
                Label("Ver histórico en Keepa", systemImage: "arrow.up.right")
            }
            .font(.subheadline)
        }
    }

    // MARK: Tags & notes

    @ViewBuilder
    private var tagsAndNotesCard: some View {
        let tags = item.tags ?? []
        let notes = item.notes ?? ""
        if !tags.isEmpty || !notes.isEmpty {
            DetailCard(title: "Etiquetas y notas", systemImage: "tag") {
                VStack(alignment: .leading, spacing: 10) {
                    if !tags.isEmpty {
                        TagRow(tags: tags)
                    }
                    if !notes.isEmpty {
                        Text(notes)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Tracking status

    private var trackingCard: some View {
        DetailCard(title: "Seguimiento", systemImage: "scope") {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(CatalogLanguage.isSpanish ? "Prioridad" : "Priority")
                    Spacer()
                    Picker(CatalogLanguage.isSpanish ? "Prioridad" : "Priority",
                           selection: Binding(get: { item.priority }, set: { priority in
                        Task { await viewModel.setPriority(priority, for: item) }
                    })) {
                        ForEach(ItemPriority.allCases, id: \.self) { priority in
                            Text(priority.title).tag(priority)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .accessibilityIdentifier("item-priority")
                }
                .padding(.bottom, 10)
                Divider()
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(trackingHeadline)
                            .font(.body.weight(.medium))
                        Text(trackingSubline)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        refresh()
                    } label: {
                        if isRefreshing {
                            ProgressView()
                        } else {
                            Label("Actualizar", systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .disabled(isRefreshing)
                }
                .padding(.top, 10)
                if let error = item.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .padding(.top, 8)
                }
            }
        }
    }

    private var trackingHeadline: String {
        if item.isPendingFirstCheck { return Item.pendingFirstCheckText }
        guard let checked = item.lastSuccessAt else { return "Todavía sin comprobación correcta" }
        return "Comprobado \(checked.relativeSpanish)"
    }

    private var trackingSubline: String {
        if item.status == .archived { return "Pausado" }
        if item.lastError != nil, let attempted = item.lastCheckedAt {
            return "Último intento fallido \(attempted.relativeSpanish)"
        }
        return "Activo · sin incidencias"
    }

    private var pauseLabel: String {
        item.status == .archived ? "Reanudar" : "Pausar"
    }

    // MARK: Primary action

    /// The one primary action. Edit/pause/delete live in the ··· menu only.
    private var openInStoreBar: some View {
        Button {
            openInStore()
        } label: {
            Label("Abrir en \(item.store.displayName)", systemImage: "arrow.up.forward.app")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .frame(maxWidth: 420)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private func refresh() {
        isRefreshing = true
        Task {
            defer { isRefreshing = false }
            await viewModel.refreshSingle(item)
        }
    }

    private func openInStore() {
        #if canImport(UIKit)
        UIApplication.shared.open(item.canonicalURL)
        #endif
    }

    private func format(_ cents: Int) -> String {
        MoneyFormatter.string(cents: cents, currency: item.currency)
    }
}

// MARK: - Building blocks

/// Grouped-style content card with a quiet system-font header.
private struct DetailCard<Content: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// Tinted status capsule (pending first check, no price).
private struct StatusChip: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

private struct TagRow: View {
    let tags: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tags, id: \.self) { tag in
                    Text(tag)
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
            }
        }
    }
}

private struct VariantChip: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.secondary)
            Text(value).fontWeight(.semibold)
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(.tertiarySystemFill), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

private struct PriceHistoryChart: View {
    let series: PriceHistorySeries
    let currency: String

    private var priceRange: ClosedRange<Double> {
        let prices = series.observations.map { Double($0.priceCents) / 100 }
        let low = prices.min() ?? 0
        let high = prices.max() ?? 0
        let padding = max((high - low) * 0.15, max(high * 0.03, 0.5))
        return max(0, low - padding)...(high + padding)
    }

    var body: some View {
        Chart(series.observations) { observation in
            if series.hasTimeSpan {
                LineMark(x: .value("Fecha", observation.checkedAt),
                         y: .value("Precio", Double(observation.priceCents) / 100))
            }
            PointMark(x: .value("Fecha", observation.checkedAt),
                      y: .value("Precio", Double(observation.priceCents) / 100))
                .accessibilityLabel(observation.checkedAt.formatted(date: .abbreviated, time: .shortened))
                .accessibilityValue(MoneyFormatter.string(cents: observation.priceCents, currency: currency))
        }
        .chartYScale(domain: priceRange)
        .chartYAxisLabel(currency)
        .environment(\.locale, Locale(identifier: "es_ES"))
        .frame(height: 180)
        .accessibilityIdentifier("price-history-chart")
    }
}
