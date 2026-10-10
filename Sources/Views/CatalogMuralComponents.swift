import SwiftUI

// MARK: - Masonry

/// Pinterest/mymind-style columns: each subview goes to the currently
/// shortest column. Column count follows the available width, so the same
/// mural works in Split View, Stage Manager and both orientations.
struct MasonryLayout: Layout {
    var minColumnWidth: CGFloat = 220
    var spacing: CGFloat = 22

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 900
        let frames = arrange(width: width, subviews: subviews)
        let height = frames.map(\.maxY).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(width: bounds.width, subviews: subviews)
        for (subview, frame) in zip(subviews, frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [CGRect] {
        let columns = max(1, Int((width + spacing) / (minColumnWidth + spacing)))
        let columnWidth = (width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        var heights = Array(repeating: CGFloat.zero, count: columns)
        return subviews.map { subview in
            let column = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            let size = subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil))
            let frame = CGRect(
                x: CGFloat(column) * (columnWidth + spacing),
                y: heights[column],
                width: columnWidth,
                height: size.height
            )
            heights[column] += size.height + spacing
            return frame
        }
    }
}

// MARK: - Card

/// One tile of the iPad mural. Items with an image show it on a light tile
/// with the price as a badge; items without one become a typographic card.
struct ItemCardView: View {
    let item: Item
    var isSelecting = false
    var isSelected = false
    var isSummarizing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if item.imageURL != nil {
                imageTile
            } else {
                textTile
            }
            caption
        }
        .opacity(isSelecting && !isSelected ? 0.55 : 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("item-card")
    }

    /// Stable per item (not `hashValue`, which changes every launch), so the
    /// mural does not reshuffle between launches.
    private var aspectRatio: CGFloat {
        let ratios: [CGFloat] = [1.0, 0.8, 1.15, 0.9]
        return ratios[Int(item.id.uuid.0) % ratios.count]
    }

    private var imageTile: some View {
        // Plain white blended into the page background (also white) and left
        // the tile invisible outside the context menu's own preview shadow —
        // confirmed on a real mural screenshot. secondarySystemBackground plus
        // a soft shadow keeps it visible in both light and dark mode.
        Color(.secondarySystemBackground)
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay {
                AsyncImage(url: item.imageURL) { image in
                    image.resizable().scaledToFit().padding(14)
                } placeholder: {
                    Image(systemName: "photo")
                        .font(.title)
                        .foregroundStyle(.tertiary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
            .overlay(alignment: .topTrailing) {
                PriceBadge(text: priceText)
                    .padding(10)
            }
            .overlay(alignment: .topLeading) { leadingBadge.padding(10) }
            .overlay { selectionOutline }
    }

    private var textTile: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(item.store.displayName.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                leadingBadge
            }
            Text(item.title)
                .font(.system(.title2, design: .serif))
                .lineLimit(4)
            if let summary = item.summary {
                Text(summary)
                    .font(.system(.callout, design: .serif))
                    .foregroundStyle(.secondary)
                    .lineLimit(5)
            }
            Text(priceText)
                .font(.system(.title3, design: .rounded, weight: .bold))
                .monospacedDigit()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { selectionOutline }
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 2) {
            if item.imageURL != nil {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
            }
            Text(metaText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if isSummarizing {
                Label("Resumiendo…", systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .symbolEffect(.pulse)
            } else if item.imageURL != nil, let summary = item.summary {
                Text(summary)
                    .font(.system(.footnote, design: .serif))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .padding(.top, 2)
            }
            if item.lastError != nil {
                Label("No se pudo comprobar", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var leadingBadge: some View {
        if isSelecting {
            ZStack {
                Circle()
                    .fill(isSelected ? Color.accentColor : Color.black.opacity(0.3))
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(.white)
                } else {
                    Circle().strokeBorder(.white, lineWidth: 2)
                }
            }
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)
        } else if let percent = discountPercent {
            Text("↓ \(percent) %")
                .font(.caption.weight(.bold))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .foregroundStyle(Color(.systemBackground))
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    @ViewBuilder
    private var selectionOutline: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 3)
        }
    }

    private var metaText: String {
        if let variant = item.variantDescription {
            return "\(item.store.displayName) · \(variant)"
        }
        if let category = item.category, !category.isEmpty {
            return "\(item.store.displayName) · \(category)"
        }
        return item.store.displayName
    }

    private var priceText: String {
        guard let cents = item.priceCurrentCents else { return "—" }
        return cents == 0 ? "Gratis" : MoneyFormatter.string(cents: cents, currency: item.currency)
    }

    private var discountPercent: Int? {
        guard let reduction = item.reductionSinceAddedCents,
              let atAdd = item.priceAtAddCents, atAdd > 0 else { return nil }
        return Int((Double(reduction) / Double(atAdd) * 100).rounded())
    }
}

private struct PriceBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

// MARK: - Multi-selection share bar

/// Floating bar shown while selecting. Shares a bulleted plain-text list:
/// name, size/color when known, and link — see `ItemShareFormatter`.
struct SelectionShareBar: View {
    let items: [Item]

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(headline)
                    .font(.subheadline.weight(.semibold))
                if let first = items.first {
                    Text(ItemShareFormatter.line(for: first))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if items.count > 1 {
                        Text("y \(items.count - 1) más")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ShareLink(
                item: ItemShareFormatter.text(for: items),
                subject: Text(items.count == 1 ? items[0].title : "Artículos de PriceTracker")
            ) {
                Label("Compartir", systemImage: "square.and.arrow.up")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 18)
                    .frame(height: 46)
                    .foregroundStyle(Color(.systemBackground))
                    .background(Color.accentColor, in: Capsule())
            }
            .disabled(items.isEmpty)
            .opacity(items.isEmpty ? 0.5 : 1)
            .accessibilityIdentifier("share-selection-button")
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .frame(maxWidth: 720)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var headline: String {
        switch items.count {
        case 0: return "Toca los artículos que quieras compartir"
        case 1: return "1 seleccionado"
        default: return "\(items.count) seleccionados"
        }
    }
}

// MARK: - Shared item actions

/// Context-menu actions shared by the iPhone list and the iPad mural.
struct ItemContextMenu: View {
    let item: Item
    let viewModel: ItemListViewModel
    var onSelect: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        ShareLink(
            item: item.canonicalURL,
            subject: Text(item.title),
            message: Text(ItemShareFormatter.message(for: item))
        ) {
            Label("Compartir", systemImage: "square.and.arrow.up")
        }
        Button("Seleccionar", systemImage: "checkmark.circle", action: onSelect)
        Button("Abrir en \(item.store.displayName)", systemImage: "safari") {
            openURL(item.canonicalURL)
        }
        Button(
            item.status == .archived ? "Reanudar" : "Pausar",
            systemImage: item.status == .archived ? "play" : "pause"
        ) {
            viewModel.togglePause(item)
        }
        Divider()
        Button("Eliminar", systemImage: "trash", role: .destructive) {
            viewModel.delete(item)
        }
    }
}
