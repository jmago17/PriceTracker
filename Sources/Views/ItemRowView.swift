import SwiftUI

struct ItemRowView: View {
    let item: Item

    var body: some View {
        HStack(spacing: 14) {
            AsyncImage(url: item.imageURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 12).fill(.quaternary)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.tertiary)
                    }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(.body, weight: .semibold))
                    .lineLimit(1)
                Text(subtitleText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if item.lastError != nil {
                    Label("No se pudo comprobar", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(priceText)
                    .font(.system(.body, weight: .semibold))
                    .monospacedDigit()
                if let detail = priceDetail {
                    detail
                        .font(.caption)
                        .foregroundStyle(ItemListViewModel.isDiscounted(item) ? Color.green : Color.secondary)
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
            return Text(Image(systemName: "arrow.down")) + Text(" \(format(atAdd - current))")
        } else if let target = item.targetPriceCents {
            return Text("Obj. \(format(target))")
        } else if let checked = item.lastCheckedAt {
            return Text(elapsed(since: checked))
        } else {
            return nil
        }
    }

    private func format(_ cents: Int) -> String {
        String(format: "%.2f €", Double(cents) / 100)
    }

    private func elapsed(since date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }
}
