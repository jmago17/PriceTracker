import Foundation
import Testing
import SwiftUI
import UIKit
@testable import PriceTracker

struct DisplayTitleCacheTests {
    private let original = "Fullmosa correa compatible 42 mm negro de silicona suave para uso diario resistente al agua y cómoda"
    private let shortened = "Fullmosa correa compatible 42 mm negro"

    private func item(title: String? = nil) -> Item {
        Item(store: .generic, storeItemID: "strap", canonicalURL: URL(string: "https://example.com/strap")!,
             title: title ?? original, size: "42 mm", color: "negro")
    }

    @Test func validatesExtractionAndPreservesIdentity() {
        let request = DisplayTitleRequest(item: item())
        #expect(DisplayTitleGenerator.validated(shortened, for: request) == shortened)
        for invalid in ["Otra correa compatible 42 mm negro", "Fullmosa correa compatible negro", "Fullmosa correa compatible 42 mm", "Fullmosa compatible correa 42 mm negro", "", original] {
            #expect(DisplayTitleGenerator.validated(invalid, for: request) == nil)
        }
        let model = DisplayTitleRequest(item: item(title: "Marca auriculares inalámbricos ModeloPro 256 GB Azul con sonido estupendo para toda la familia"))
        #expect(DisplayTitleGenerator.validated("Marca auriculares inalámbricos 256 GB Azul", for: model) == nil)
    }

    @Test func fullmosaScreenshotTitleCanOmitCompatibilityListsWithoutInventingAVariant() {
        let title = "Fullmosa Correa Magnética Para Apple Watch 44mm 46mm 45mm 49mm,Negro Milanesa Pulsera de Repuesto Acero Inoxidable Loop para Ultra3/2/1 Series 11 10 9 8 7 6 5 4 3 2 1 SE3/2/1 para Mujer Hombre"
        let source = Item(store: .generic, storeItemID: "fullmosa", canonicalURL: URL(string: "https://example.com/fullmosa")!, title: title)
        let request = DisplayTitleRequest(item: source)
        let short = "Fullmosa Correa Magnética Para Apple Watch Negro"
        #expect(title.count > 160)
        #expect(DisplayTitleGenerator.validated(short, for: request) == short)
        #expect(request.version == 2)
        for invalid in [
            "Fullmosa Correa Magnética Para Apple Watch Blanco",
            "Fullmosa Correa Magnética Para Apple Watch",
            "Fullmosa Correa Magnética Para Apple Watch 49mm Negro",
            "Fullmosa Correa Magnética Para Apple Watch Negro Series 11",
            "Fullmosa Correa Magnética Para Apple Watch Negro Series 12",
            "Fullmosa Correa Magnética Para Apple Watch Negro Ultra3",
            "Fullmosa Correa Magnética Negro"
        ] {
            #expect(DisplayTitleGenerator.validated(invalid, for: request) == nil)
        }
        var selected = source
        selected.size = "44 mm"
        let selectedRequest = DisplayTitleRequest(item: selected)
        let selectedShort = "Fullmosa Correa Magnética Para Apple Watch 44mm Negro"
        #expect(DisplayTitleGenerator.validated(selectedShort, for: selectedRequest) == selectedShort)
        #expect(DisplayTitleGenerator.validated(short, for: selectedRequest) == nil)
        #expect(source.title == title)
    }

    @Test func soleCompatibilitySizeIsPreservedWithoutStructuredVariant() {
        let title = "Fullmosa Correa Magnética Para Apple Watch 49mm Negro Milanesa Pulsera de Repuesto Acero Inoxidable"
        let source = Item(store: .generic, storeItemID: "single-size", canonicalURL: URL(string: "https://example.com/single")!, title: title)
        let request = DisplayTitleRequest(item: source)
        let short = "Fullmosa Correa Magnética Para Apple Watch 49mm Negro"
        #expect(DisplayTitleGenerator.validated(short, for: request) == short)
        #expect(DisplayTitleGenerator.validated("Fullmosa Correa Magnética Para Apple Watch Negro", for: request) == nil)
    }

    @Test func actualWatchAndHeadphoneModelsAreNotCompatibilityAlternatives() {
        for (title, invalid) in [
            ("Apple Watch Ultra 3 49mm Negro con Acabado Premium y Excelente Calidad para Uso Diario", "Apple Watch Ultra 49mm Negro"),
            ("Sony Auriculares Inalámbricos WH-1000XM5 Negro con Cancelación de Ruido Premium", "Sony Auriculares Inalámbricos Negro"),
            ("Marca Auriculares Inalámbricos modelo Momentum Negro con Sonido Premium", "Marca Auriculares Inalámbricos Negro"),
            ("Marca Tablet Profesional 256 GB Azul marino con Pantalla de Alta Calidad", "Marca Tablet Profesional 256 GB Azul")
        ] {
            let request = DisplayTitleRequest(item: item(title: title))
            #expect(DisplayTitleGenerator.validated(invalid, for: request) == nil)
        }
    }

    @Test func persistsWithoutChangingCanonicalTitle() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "titles.json")
        let source = item()
        let request = DisplayTitleRequest(item: source)
        let value = shortened
        let cache = DisplayTitleCache(fileURL: file) { _ in value }
        #expect(await cache.title(for: request) == shortened)
        let restored = DisplayTitleCache(fileURL: file) { _ in Issue.record("Must use persistent cache"); return nil }
        #expect(await restored.title(for: request) == shortened)
        #expect(source.title == original)
        #expect(ItemShareFormatter.message(for: source).contains(original))
    }

    @Test func deduplicatesAndDoesNotReuseOldTitleOrVariant() async {
        let calls = Calls()
        let value = shortened
        let cache = DisplayTitleCache(fileURL: nil) { request in
            await calls.increment()
            try await Task.sleep(for: .milliseconds(30))
            return request.title.contains("azul") ? nil : value
        }
        let request = DisplayTitleRequest(item: item())
        async let first = cache.title(for: request)
        async let second = cache.title(for: request)
        #expect(await first == shortened)
        #expect(await second == shortened)
        #expect(await calls.count == 1)
        let changed = DisplayTitleRequest(item: item(title: original.replacingOccurrences(of: "negro", with: "azul")))
        #expect(await cache.title(for: changed) == nil)
        var variant = item()
        variant.size = "44 mm"
        #expect(DisplayTitleRequest(item: variant) != request)
        #expect(await calls.count == 2)
    }

    @Test func unavailableFailureAndCorruptCacheFallBack() async throws {
        let file = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("corrupt".utf8).write(to: file)
        let calls = Calls()
        let cache = DisplayTitleCache(fileURL: file) { _ in await calls.increment(); return nil }
        let request = DisplayTitleRequest(item: item())
        #expect(await cache.title(for: request) == nil)
        #expect(await cache.title(for: request) == nil)
        #expect(await calls.count == 1)
        let failing = DisplayTitleCache(fileURL: nil) { _ in throw CancellationError() }
        #expect(await failing.title(for: request) == nil)
    }

    @Test func cancelledWaiterCannotPublishSharedResult() async {
        let gate = Gate()
        let value = shortened
        let cache = DisplayTitleCache(fileURL: nil) { _ in await gate.wait(); return value }
        let request = DisplayTitleRequest(item: item())
        let waiter = Task { await cache.title(for: request) }
        await gate.started()
        waiter.cancel()
        await gate.release()
        #expect(await waiter.value == nil)
        #expect(await cache.title(for: request) == shortened)
    }

    @Test func oldInFlightResultCannotSatisfyEditedTitle() async {
        let old = DisplayTitleRequest(item: item())
        let updated = DisplayTitleRequest(item: item(title: original.replacingOccurrences(of: "negro", with: "azul")))
        let gate = Gate()
        let value = shortened
        let cache = DisplayTitleCache(fileURL: nil) { request in
            if request == old { await gate.wait() }
            return request == old ? value : value.replacingOccurrences(of: "negro", with: "azul")
        }
        let oldTask = Task { await cache.title(for: old) }
        await gate.started()
        let updatedTask = Task { await cache.title(for: updated) }
        await gate.release()
        #expect(await oldTask.value == shortened)
        #expect(await updatedTask.value == shortened.replacingOccurrences(of: "negro", with: "azul"))
        #expect(old != updated)
        let other = Item(store: .generic, storeItemID: "other", canonicalURL: URL(string: "https://example.com/other")!, title: original)
        #expect(old != DisplayTitleRequest(item: other))
    }

    @Test func ignoresOldCacheVersions() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "titles.json")
        let request = DisplayTitleRequest(item: item())
        let value = shortened
        let writer = DisplayTitleCache(fileURL: file) { _ in value }
        #expect(await writer.title(for: request) == value)
        let data = try Data(contentsOf: file)
        let outdated = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"version\":2", with: "\"version\":1")
        try Data(outdated.utf8).write(to: file)
        let reader = DisplayTitleCache(fileURL: file) { _ in nil }
        #expect(await reader.title(for: request) == nil)
    }

}

private actor Calls {
    var count = 0
    func increment() { count += 1 }
}

private actor Gate {
    var continuation: CheckedContinuation<Void, Never>?
    var start: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation = $0; start?.resume(); start = nil }
    }
    func started() async {
        if continuation != nil { return }
        await withCheckedContinuation { start = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
struct CatalogTitleLayoutTests {
    @Test func longFallbackIsThreeLinesAtEverySupportedTextSize() {
        let title = "Fullmosa correa compatible 42 mm negro " + String(repeating: "para relojes con ajuste cómodo y material resistente ", count: 12)
        let item = Item(store: .generic, storeItemID: "long", canonicalURL: URL(string: "https://example.com/long")!, title: title)
        let sizes: [(DynamicTypeSize, UIContentSizeCategory)] = [
            (.large, .large), (.xxxLarge, .extraExtraExtraLarge), (.accessibility5, .accessibilityExtraExtraExtraLarge)
        ]
        for (size, category) in sizes {
            for width in [CGFloat(140), 240, 600] {
                let controller = UIHostingController(rootView: CatalogItemTitle(item: item).font(.title3).environment(\.dynamicTypeSize, size))
                let measured = controller.sizeThatFits(in: CGSize(width: width, height: 10_000))
                let font = UIFont.preferredFont(forTextStyle: .title3, compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
                #expect(measured.height <= ceil(font.lineHeight * 3) + 3)
                #expect(measured.height > font.lineHeight)
                #expect(item.title == title)
            }
        }
    }
}
