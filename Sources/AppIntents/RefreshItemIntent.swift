import AppIntents
import Foundation

/// The `RefreshItem` half of the FindItems + "Repeat with each" pattern.
/// `supportedModes = .background` (not the deprecated `openAppWhenRun`) so an
/// unattended hourly Shortcuts automation can invoke it without launching the
/// app or requiring the device to be unlocked — verified against the iOS 27
/// AppIntents `.swiftinterface`; see /tmp/opus_architecture.md "Segunda
/// revisión" for the disassembly-backed reasoning.
///
/// Deliberately short-lived: one network round-trip per invocation, so no
/// individual call gets near the ~30s per-intent budget. The untested part is
/// the ceiling on the WHOLE automation across many invocations — see
/// /tmp/pricetracker_status.md, "riesgos".
struct RefreshItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Actualizar artículo"
    static let description = IntentDescription("Comprueba el precio actual de un artículo y guarda el resultado.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Artículo")
    var item: ItemEntity

    init() {}

    init(item: ItemEntity) {
        self.item = item
    }

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let success = try await AppEnvironment.shared.refreshCoordinator.refreshItem(id: item.id)
        return .result(value: success)
    }
}
