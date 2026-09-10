import Foundation

/// Native export/import format (schema v1) — this app's own shape, round-tripped
/// through `CatalogExport`. This is NOT the format of Josu's existing Shortcuts
/// global-variable JSON; see `LegacyImport.swift` for that gap.
struct CatalogExport: Codable, Sendable {
    var schemaVersion: Int
    var exportedAt: Date
    var items: [Item]

    static let currentSchemaVersion = 1
}

enum ImportMode: Sendable, Hashable {
    case merge
    case replace
}

struct ImportSummary: Equatable, Sendable {
    var imported: Int
    var skipped: Int
}

enum ItemExporter {
    static func exportData(items: [Item]) throws -> Data {
        let export = CatalogExport(schemaVersion: CatalogExport.currentSchemaVersion, exportedAt: Date(), items: items)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(export)
    }
}

enum ImportError: Error, LocalizedError {
    case unsupportedSchemaVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            return "Versión de esquema \(version) no soportada (actual: \(CatalogExport.currentSchemaVersion))."
        }
    }
}

enum ItemImporter {
    /// Imports this app's own export format. `merge` upserts by identity key
    /// (store, store_item_id, region) so re-importing is idempotent; `replace`
    /// wipes the catalog first.
    static func importData(_ data: Data, mode: ImportMode, into store: any ItemStoring) async throws -> ImportSummary {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let export = try decoder.decode(CatalogExport.self, from: data)
        guard export.schemaVersion <= CatalogExport.currentSchemaVersion else {
            throw ImportError.unsupportedSchemaVersion(export.schemaVersion)
        }

        if mode == .replace {
            try await store.save(export.items)
            return ImportSummary(imported: export.items.count, skipped: 0)
        }

        var existing = try await store.loadAll()
        var imported = 0
        var skipped = 0
        for incoming in export.items {
            if let index = existing.firstIndex(where: { $0.identityKey == incoming.identityKey }) {
                var merged = incoming
                merged.id = existing[index].id
                existing[index] = merged
                try await store.upsert(merged)
                imported += 1
            } else if existing.contains(where: { $0.id == incoming.id }) {
                skipped += 1
            } else {
                existing.append(incoming)
                try await store.upsert(incoming)
                imported += 1
            }
        }
        return ImportSummary(imported: imported, skipped: skipped)
    }
}
