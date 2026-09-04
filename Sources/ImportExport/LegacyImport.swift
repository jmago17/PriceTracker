import Foundation

/// Migration entry point for Josu's EXISTING Shortcuts global-variable JSON.
///
/// Deliberately not implemented: the real shape of that JSON was never provided
/// (see /tmp/opus_architecture.md §0 — "el mapeo desde tu JSON actual queda
/// pendiente del export"). Guessing a schema here would silently corrupt a real
/// migration the first time the guess is wrong.
///
/// TODO(Josu): export the literal JSON (Atajo: "Obtener variable global" →
/// "Guardar en Archivos", or paste it directly) and drop a sample at
/// `Tests/PriceTrackerTests/Fixtures/legacy-export-sample.json`. Once that
/// exists, replace `LegacyImportError.notYetSpecified` below with the actual
/// field mapping to `Item`, and add a round-trip test against the fixture.
enum LegacyImportError: Error, LocalizedError {
    case notYetSpecified

    var errorDescription: String? {
        "El formato del export antiguo de Atajos aún no se ha especificado — hace falta una muestra real antes de escribir el mapeo."
    }
}

enum LegacyImporter {
    static func importLegacyShortcutsExport(_ data: Data, into store: any ItemStoring) async throws -> ImportSummary {
        throw LegacyImportError.notYetSpecified
    }
}
