import SwiftUI
import Charts

/// Shows successful check freshness separately from observed price changes.
/// History contains real recorded observations, merged across devices.
///
/// Layering follows iOS 26: content sits on grouped cards, and only the
/// controls (the system bottom bar, the toolbar) are Liquid Glass. The
/// frequent actions live in the bottom bar so they stay visible while
/// scrolling; deleting lives in its own section at the end.
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
        }
        .safeAreaInset(edge: .bottom) { actionBar }
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

    /// Frequent actions, always visible while scrolling: labelled Liquid Glass
    /// buttons grouped in one container (system toolbars render icon-only).
    private var actionBar: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Button { showingEdit = true } label: {
                    Label("Editar", systemImage: "pencil").lineLimit(1)
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("edit-item-button")
                Button { viewModel.togglePause(item) } label: {
                    Label(pauseLabel, systemImage: item.status == .archived ? "play" : "pause").lineLimit(1)
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("pause-item-button")
                Button { openInStore() } label: {
                    Label("Abrir tienda", systemImage: "arrow.up.forward.app")
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("open-in-store-button")
            }
            .font(.subheadline.weight(.semibold))
            .controlSize(.large)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
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
            headerCard(imageHeight: 220)
            historySection
            summarySection
            pricesCard
            tagsAndNotesCard
            trackingCard
            dangerZone
        }
        .frame(maxWidth: 760)
        .padding(.horizontal, 16)
    }

    /// iPad: the identity of the product on the left, the data you compare
    /// and adjust on the right.
    private var regularLayout: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 16) {
                headerCard(imageHeight: 320)
                summarySection
                tagsAndNotesCard
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 16) {
                historySection
                pricesCard
                trackingCard
                dangerZone
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: 1180)
        .padding(.horizontal, 32)
    }

    // MARK: Header

    /// One visual unit: image, identity, price and verdict. If the image is
    /// missing or fails to load, no hero is reserved: a compact tile sits
    /// beside the title instead.
    private func headerCard(imageHeight: CGFloat) -> some View {
        AsyncImage(url: item.imageURL) { phase in
            VStack(alignment: .leading, spacing: 0) {
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                        .padding(16)
                        .frame(maxWidth: .infinity)
                        .frame(height: imageHeight)
                        .background(Color(.secondarySystemFill))
                        .accessibilityHidden(true)
                    headerBody(showsTile: false)
                case .empty where item.imageURL != nil:
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .frame(height: imageHeight * 0.6)
                        .background(Color(.secondarySystemFill))
                        .accessibilityHidden(true)
                    headerBody(showsTile: false)
                default:
                    headerBody(showsTile: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    private func headerBody(showsTile: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsTile {
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                    : AnyLayout(HStackLayout(alignment: .top, spacing: 14))
                layout {
                    Image(systemName: "bag")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 56, height: 56)
                        .background(Color(.secondarySystemFill),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .accessibilityHidden(true)
                    titleBlock
                }
            } else {
                titleBlock
            }
            priceBlock
            buyMoment
        }
        .padding(16)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(storeAndCategoryText)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(item.title)
                .font(.system(.title2, design: .serif, weight: .semibold))
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

    // MARK: Buy moment

    private enum BuyVerdict {
        case goalReached, atLow, nearLow, aboveInitial, unknown

        var title: LocalizedStringKey {
            switch self {
            case .goalReached: "Objetivo alcanzado"
            case .atLow: "En su mínimo observado"
            case .nearLow: "Cerca del mínimo"
            case .aboveInitial: "Por encima del precio inicial"
            case .unknown: "Aún sin referencias para comparar"
            }
        }

        var systemImage: String {
            switch self {
            case .goalReached, .atLow: "checkmark.seal.fill"
            case .nearLow: "hand.thumbsup"
            case .aboveInitial: "arrow.up.right"
            case .unknown: "questionmark.circle"
            }
        }

        var tint: Color {
            switch self {
            case .goalReached, .atLow: .green
            case .nearLow: .orange
            case .aboveInitial, .unknown: .secondary
            }
        }
    }

    /// Read-only comparison of the current price with data already stored.
    /// It never claims that the store is running a promotion.
    private var buyVerdict: BuyVerdict? {
        guard let current = item.priceCurrentCents else { return nil }
        if let target = item.targetPriceCents, current <= target { return .goalReached }
        if let low = item.priceLowCents {
            let highestReference = [item.priceAtAddCents, item.priceReferenceCents].compactMap { $0 }.max()
            if current <= low, let highestReference, highestReference > current { return .atLow }
            if low > 0, current > low, Double(current) <= Double(low) * 1.05 { return .nearLow }
        }
        if let atAdd = item.priceAtAddCents, current > atAdd { return .aboveInitial }
        return .unknown
    }

    @ViewBuilder
    private var buyMoment: some View {
        if let verdict = buyVerdict {
            Divider()
            HStack(spacing: 12) {
                Image(systemName: verdict.systemImage)
                    .font(.title3)
                    .foregroundStyle(verdict.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("¿Buen momento para comprar?")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(verdict.title)
                        .font(.subheadline.weight(.semibold))
                }
            }
            .accessibilityElement(children: .combine)
        }
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
                    .buttonStyle(.glass)
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

    // MARK: Danger zone

    /// Deleting is destructive and rare: its own labelled section at the
    /// end of the page, confirmed before it runs.
    private var dangerZone: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Zona de peligro", systemImage: "exclamationmark.triangle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.red)
            Text("Dejarás de seguir este artículo y se borrará de tu catálogo.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button(role: .destructive) {
                showingDeleteConfirmation = true
            } label: {
                Label("Eliminar artículo", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .tint(.red)
            .controlSize(.large)
            .accessibilityIdentifier("delete-item-button")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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
        .frame(height: 200)
        .accessibilityIdentifier("price-history-chart")
    }
}
