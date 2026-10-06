import SwiftUI

struct ItemRowView: View {
    let item: Item
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 14))
        layout {
            AsyncImage(url: item.imageURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.10))
                    .overlay {
                        Image(systemName: item.category == "Libros" ? "book.closed" : "tag")
                            .font(.title2)
                            .foregroundStyle(Color.accentColor)
                    }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(.body, weight: .semibold))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                Text(subtitleText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                if item.lastError != nil {
                    Label("No se pudo comprobar", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(priceText)
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .monospacedDigit()
                if let detail = priceDetail {
                    detail
                        .font(.caption)
                        .foregroundStyle(ItemListViewModel.isDiscounted(item) ? Color.accentColor : Color.secondary)
                    if item.reductionSinceAddedCents != nil {
                        Text("desde el inicio")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .layoutPriority(1)
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("item-row")
    }

    private var subtitleText: String {
        if let subtitle = item.subtitle, !subtitle.isEmpty {
            return "\(subtitle) · \(item.store.displayName)"
        }
        return item.store.displayName
    }

    private var priceText: String {
        guard let cents = item.priceCurrentCents else { return "—" }
        return cents == 0 ? "Gratis" : format(cents)
    }

    private var priceDetail: Text? {
        if ItemListViewModel.isDiscounted(item), let current = item.priceCurrentCents, let atAdd = item.priceAtAddCents {
            return Text(Image(systemName: "arrow.down")) + Text(" \(format(atAdd - current)) menos")
        } else if let target = item.targetPriceCents {
            return Text("Obj. \(format(target))")
        } else if let checked = item.lastCheckedAt {
            return Text(elapsed(since: checked))
        } else {
            return nil
        }
    }

    private func format(_ cents: Int) -> String {
        MoneyFormatter.string(cents: cents, currency: item.currency)
    }

    private func elapsed(since date: Date) -> String {
        date.relativeSpanish
    }
}
