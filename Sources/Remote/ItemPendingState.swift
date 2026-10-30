import Foundation

extension Item {
    /// Added on the server but not checked yet (Amazon and blocked pages wait
    /// for the 08:00 routine): no price and no successful check.
    var isPendingFirstCheck: Bool {
        priceCurrentCents == nil && lastSuccessAt == nil
    }

    static let pendingFirstCheckText = "Pendiente de primera comprobación"
}
