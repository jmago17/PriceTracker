import Observation
import SwiftUI

/// State of the Share sheet. The network and inbox logic lives in
/// `ShareSubmission`; this only drives the form.
@MainActor
@Observable
final class ShareSheetModel {
    enum Phase: Equatable {
        case editing
        case sending
        case done(String)
        case failed(String)
    }

    let url: URL?
    let pageTitle: String?
    var minimumPrice = ""
    var size = ""
    private(set) var phase: Phase = .editing

    private let submission: ShareSubmission
    private let close: @MainActor () -> Void

    init(url: URL?, pageTitle: String?, submission: ShareSubmission = ShareSubmission(), close: @escaping @MainActor () -> Void) {
        self.url = url
        self.pageTitle = pageTitle
        self.submission = submission
        self.close = close
    }

    var canSubmit: Bool { url != nil && phase != .sending }

    func add() async {
        guard let url, phase != .sending else { return }
        phase = .sending
        do {
            let outcome = try await submission.submit(url: url, minimumPriceText: minimumPrice, sizeText: size)
            phase = .done(outcome.message)
            try? await Task.sleep(for: .milliseconds(1_200))
            close()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func cancel() { close() }
}

struct ShareSheetView: View {
    @Bindable var model: ShareSheetModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let title = model.pageTitle {
                        Text(title).font(.headline).lineLimit(3)
                    }
                    if let url = model.url {
                        Text(url.absoluteString)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    } else {
                        Text("No hay ningún enlace que añadir.").foregroundStyle(.secondary)
                    }
                }

                Section {
                    TextField("Precio mínimo (opcional)", text: $model.minimumPrice)
                        .keyboardType(.decimalPad)
                        .accessibilityIdentifier("share-minimum-price")
                    TextField("Talla (opcional)", text: $model.size)
                        .textInputAutocapitalization(.characters)
                        .accessibilityIdentifier("share-size")
                } footer: {
                    Text("Te avisaremos cuando baje de ese precio. El importe se interpreta en la moneda del servidor.")
                }

                statusSection
            }
            .disabled(model.phase == .sending)
            .navigationTitle("Añadir a PriceTracker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { model.cancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Añadir") { Task { await model.add() } }
                        .disabled(!model.canSubmit || isFinished)
                }
            }
        }
    }

    private var isFinished: Bool {
        if case .done = model.phase { return true }
        return false
    }

    @ViewBuilder
    private var statusSection: some View {
        switch model.phase {
        case .editing:
            EmptyView()
        case .sending:
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Enviando al servidor…")
                }
            }
        case .done(let message):
            Section {
                Label(message, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        case .failed(let message):
            Section {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
    }
}
