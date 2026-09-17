import SwiftUI

/// Read-first ficha: the price is the dominant element, edits happen in a
/// separate sheet (see EditItemView). No invented history — Amazon/generic
/// links are captured once and not re-scraped, so "sin historial" is the
/// honest default (handoff README, "Historial ausente").
struct ItemDetailView: View {
    let item: Item
    var viewModel: ItemListViewModel

    @State private var showingEdit = false
    @State private var isRefreshing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                priceBlock
                comparisonCard
                historyCard
                if item.tags?.isEmpty == false || item.notes?.isEmpty == false {
                    tagsAndNotesCard
                }
                statusRow
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 100)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Editar", systemImage: "pencil") { showingEdit = true }
                    Button(pauseLabel, systemImage: "pause") { viewModel.togglePause(item) }
                    Button("Eliminar", systemImage: "trash", role: .destructive) { viewModel.delete(item) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            bottomBar
        }
        .sheet(isPresented: $showingEdit) {
            EditItemView(item: item, viewModel: viewModel)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            AsyncImage(url: item.imageURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 16).fill(.quaternary)
                    .overlay { Image(systemName: "photo").foregroundStyle(.tertiary) }
            }
            .frame(width: 104, height: 104)
            .clipShape(RoundedRectangle(cornerRadius: 16))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.system(.title2, weight: .bold))
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(storeAndCategoryText)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var storeAndCategoryText: String {
        if let category = item.category, !category.isEmpty {
            return "\(item.store.displayName) · \(category)"
        }
        return item.store.displayName
    }

    // MARK: Price

    private var priceBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(priceText)
                    .font(.system(size: 44, weight: .bold))
                    .monospacedDigit()
                if let percent = discountPercent {
                    Label("\(percent) %", systemImage: "arrow.down")
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(.green)
                }
            }
            if let savingsMessage {
                Text(savingsMessage)
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(.green)
            }
        }
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
        return "\(format(atAdd - current)) menos que al añadirlo"
    }

    // MARK: Comparison

    @ViewBuilder
    private var comparisonCard: some View {
        if item.priceAtAddCents != nil || item.priceLowCents != nil || item.targetPriceCents != nil {
            VStack(spacing: 0) {
                if let atAdd = item.priceAtAddCents {
                    comparisonRow(label: "Al añadirlo", value: format(atAdd))
                }
                if let low = item.priceLowCents {
                    comparisonRow(label: "Mínimo histórico", value: format(low))
                }
                if let target = item.targetPriceCents {
                    VStack(alignment: .leading, spacing: 6) {
                        comparisonRow(label: "Precio objetivo", value: format(target), showDivider: false)
                        if let current = item.priceCurrentCents {
                            // How much of the gap from "current" down to "target" is
                            // already closed — 100% only once current <= target, not
                            // whenever current is merely nonzero.
                            let progress = current > 0 ? min(1, Double(target) / Double(current)) : 1
                            ProgressView(value: max(0, min(1, progress)))
                                .tint(.orange)
                            let remaining = current - target
                            Text(remaining > 0 ? "faltan \(format(remaining))" : "objetivo alcanzado")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 12)
                }
            }
            .padding(.horizontal, 14)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    private func comparisonRow(label: String, value: String, showDivider: Bool = true) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                Spacer()
                Text(value).foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)
            if showDivider {
                Divider()
            }
        }
    }

    // MARK: History (always honest — see file header comment)

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("HISTORIAL")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Text("Todavía sin historial")
                    .font(.system(.body, weight: .bold))
                Text(historyExplanation)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if item.store == .amazon {
                    Link(destination: AmazonConnector.keepaURL(asin: item.storeItemID, region: item.region)) {
                        Label("Ver histórico en Keepa", systemImage: "arrow.up.right")
                    }
                    .font(.subheadline)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    private var historyExplanation: String {
        if item.store == .amazon {
            return "Los enlaces de Amazon se guardan con el precio del día en que los añades; no se vuelven a comprobar de forma automática."
        }
        if Store.refreshableStores.contains(item.store) {
            return "Este artículo se comprueba periódicamente, pero todavía no hay suficientes comprobaciones para mostrar una evolución."
        }
        return "Este enlace se guardó con el precio del momento y no se vuelve a comprobar automáticamente."
    }

    // MARK: Tags & notes

    private var tagsAndNotesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ETIQUETAS Y NOTAS")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                if let tags = item.tags, !tags.isEmpty {
                    HStack {
                        ForEach(tags, id: \.self) { tag in
                            Text(tag)
                                .font(.subheadline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color(.tertiarySystemFill))
                                .clipShape(Capsule())
                        }
                        Spacer()
                    }
                }
                if let notes = item.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    // MARK: Tracking status

    private var statusRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(trackingHeadline)
                        .font(.system(.body, weight: .medium))
                    Text(trackingSubline)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if Store.refreshableStores.contains(item.store) {
                    Button {
                        refresh()
                    } label: {
                        if isRefreshing {
                            ProgressView()
                        } else {
                            Label("Actualizar", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(isRefreshing)
                }
            }
            if let error = item.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Button {
                openInStore()
            } label: {
                Text("Abrir en \(item.store.displayName)")
            }
            .font(.subheadline)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var trackingHeadline: String {
        guard let checked = item.lastCheckedAt else { return "Todavía sin comprobar" }
        return "Comprobado \(checked.formatted(.relative(presentation: .named)))"
    }

    private var trackingSubline: String {
        if item.status == .archived { return "Pausado" }
        return item.lastError == nil ? "Activo · sin incidencias" : "Activo · con incidencias"
    }

    private var pauseLabel: String {
        item.status == .archived ? "Reanudar" : "Pausar"
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button {
                showingEdit = true
            } label: {
                Text("Editar")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(GhostButtonStyle(tint: .blue))

            Button {
                viewModel.togglePause(item)
            } label: {
                Text(pauseLabel)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(GhostButtonStyle(tint: .blue))

            Button(role: .destructive) {
                viewModel.delete(item)
            } label: {
                Image(systemName: "trash")
                    .frame(width: 48, height: 48)
            }
            .buttonStyle(GhostButtonStyle(tint: .red))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func refresh() {
        isRefreshing = true
        viewModel.refreshSingle(item)
        Task {
            try? await Task.sleep(for: .seconds(1))
            isRefreshing = false
        }
    }

    private func openInStore() {
        #if canImport(UIKit)
        UIApplication.shared.open(item.canonicalURL)
        #endif
    }

    private func format(_ cents: Int) -> String {
        String(format: "%.2f €", Double(cents) / 100)
    }
}

/// The 10%-tint pill used across the ficha's bottom bar: filled enough to read
/// as a button, quiet enough that the destructive action still stands apart.
private struct GhostButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, weight: .semibold))
            .foregroundStyle(tint)
            .frame(height: 48)
            .background(tint.opacity(configuration.isPressed ? 0.18 : 0.1))
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
