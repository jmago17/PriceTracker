import SwiftUI

struct ItemRowView: View {
    let item: Item

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: item.imageURL) { image in
                image.resizable().aspectRatio(contentMode: .fit)
            } placeholder: {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(item.store.displayName)
                    if item.isStale {
                        Label("Sin comprobar", systemImage: "exclamationmark.triangle")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(priceText)
                    .font(.body.monospacedDigit())
                if isDiscounted {
                    Text(referenceText)
                        .font(.caption)
                        .strikethrough()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var priceText: String {
        guard let cents = item.priceCurrentCents else { return "—" }
        return format(cents)
    }

    private var referenceText: String {
        guard let cents = item.priceAtAddCents else { return "" }
        return format(cents)
    }

    private var isDiscounted: Bool {
        guard let current = item.priceCurrentCents, let atAdd = item.priceAtAddCents else { return false }
        return current < atAdd
    }

    private func format(_ cents: Int) -> String {
        String(format: "%.2f %@", Double(cents) / 100, item.currency)
    }
}
