# Actualización diaria, Atajos y Siri

## Uso

En Ajustes, activar **Actualizar precios diariamente** para solicitar una oportunidad de ejecución cada 24 horas. iOS decide si y cuándo concede tiempo; no es una alarma ni garantiza ejecución diaria. La app reprograma antes de empezar, cancela al desactivar y propaga la expiración a las descargas. Ordena el catálogo por comprobación más antigua para no relegar siempre los mismos artículos si el tiempo concedido se agota.

**Notificar cambios de precio** es independiente de la actualización diaria. Solo este interruptor solicita permiso. Se aplica también al refresco manual y a Atajos. Al activarlo se descartan avisos anteriores: no se envía de golpe el historial acumulado. Si el sistema deniega el permiso, se indica dónde habilitarlo. Se avisa de subidas y bajadas; un precio idéntico no avisa. Un cambio de moneda establece la base existente del pipeline sin comparar importes de monedas diferentes.

En Atajos:

1. Añadir la acción de búsqueda de artículos generada por `ItemQuery` (`EntityPropertyQuery`). Devuelve una lista de `ItemEntity`, no texto. Filtrar por título, tienda, categoría, estado o última comprobación; ordenar y limitar si procede. Los artículos no comprobados cuentan como los más antiguos.
2. Añadir **Repetir con cada uno** usando esa lista.
3. Dentro, **Actualizar artículo**, con el elemento de repetición como entrada.
4. Usar las propiedades del resultado: ID del artículo, precio en céntimos, moneda, ha cambiado, comprobación correcta, comprobado el y error. Los errores individuales —incluido un artículo eliminado— son resultados y permiten continuar el bucle.

Las tiendas sin conector periódico devuelven un error por artículo. La actualización completa las omite. No se añade scraping periódico de Amazon ni de tiendas genéricas. Se conserva la región y URL del artículo al invocar el conector existente.

**Notificar cambios de precio** (antes titulada «Notificar bajadas de precio», mismo identificador de intent) permite reintentar pendientes. Ya no hace falta como paso final: cada comprobación entrega mediante el mismo servicio y respeta el interruptor. El resultado cuenta artículos notificados, aunque internamente una bajada genere tanto un mínimo como un objetivo.

## Auditoría y compatibilidad

Ya existían `ItemEntity`, `ItemQuery`, `RefreshItemIntent`, `RefreshCatalogIntent`, `GetItemPriceIntent`, `SetTargetPriceIntent`, `ShowPriceDropsIntent` y `NotifyPriceDropsIntent`. La actualización individual devolvía solo `Bool`; el permiso se solicitaba al iniciar la app. El actor coordinador admitía reentrada durante los `await` y las alertas hacían read/modify/write mediante extensiones no atómicas.

Ahora las actualizaciones del singleton compartido se serializan, se vuelven a leer los datos después de la descarga, y los cambios de alertas son operaciones atómicas del actor de almacenamiento. La entrega tiene una exclusión propia y un identificador estable para reintentos. Estos servicios viven en el target principal; la Share Extension no ejecuta las actualizaciones. No se garantiza semántica exactamente-una-vez frente a una terminación del proceso entre una entrega del sistema y su confirmación persistida.

El historial sigue siendo exclusivamente observaciones reales y exitosas. Cada comprobación correcta guarda una observación aunque el precio no cambie. Errores/cancelación no fabrican observaciones. El precio de referencia de ofertas y el precio al añadir se conservan para comprobaciones en la misma moneda. El reinicio de base al cambiar moneda es el comportamiento previo del pipeline.

### Siri y Apple Intelligence

SDK comprobado: Xcode 27.0 (`27A5194q`), iPhoneOS 27.0; deployment target iOS 26.0.

- App Shortcuts: frases existentes de consulta, objetivos, bajadas y catálogo; se añade «Actualiza [artículo] en PriceTracker». El refresco individual devuelve también un diálogo con precio o error.
- `SearchCatalogIntent` adopta `@AppIntent(schema: .system.search)` / `ShowInAppSearchResultsIntent`. Abre el catálogo, elimina filtros de categoría previos y muestra la búsqueda entre artículos activos. Tiene un propósito distinto de la búsqueda de entidades que alimenta el bucle de Atajos.
- El SDK y la documentación no justifican presentar la actualización de precios como una acción de un esquema de compras ni garantizar conversación libre, razonamiento sobre precios o ejecución autónoma. La disponibilidad efectiva de Siri AI depende de versión, dispositivo, idioma y configuración.
- Los metadatos extraídos por Xcode confirman `RefreshResultEntity` como salida de `RefreshItemIntent`, `ItemEntity` como resultado de `ItemQuery`, y `system/ShowInAppSearchResultsIntent` como esquema de la búsqueda en primer plano.

Fuentes oficiales consultadas el 9 de octubre de 2026:

- [App Intents](https://developer.apple.com/documentation/appintents)
- [App Shortcuts](https://developer.apple.com/documentation/appintents/app-shortcuts)
- [Esquema system.search](https://developer.apple.com/documentation/appintents/appschema/systemintent/search)
- [Apple Intelligence Group Lab, WWDC26](https://developer.apple.com/videos/play/wwdc2026/8011/) — distinción entre esquemas Siri AI y frases App Shortcuts, especialmente 03:09–08:18.
- [BGAppRefreshTask](https://developer.apple.com/documentation/backgroundtasks/bgapprefreshtask)
- [Using background tasks to update your app](https://developer.apple.com/documentation/uikit/using-background-tasks-to-update-your-app)

## Validación local y límites

`Tools/run-core-tests.py` copia fuentes reales y pruebas seleccionadas a un paquete temporal macOS. Sustituye exclusivamente la composición que inicia iCloud; las pruebas inyectan sus almacenes y dependencias. No usa simulador ni descarga dependencias. Requiere macOS/Xcode 27 por las APIs de consultas indexadas ya existentes.

Pasaron **39 pruebas en 5 suites**. Se ejecutaron pruebas de lógica e historial originales y nuevas pruebas de IDs persistentes tras reapertura/duplicados, consultas y límites, precios iguales/subidas/bajadas, errores individuales, concurrencia, exclusión de avisos, consentimiento denegado/concedido, scheduling, cancelación y expiración. La compilación genérica iOS sin firma también pasó, incluida la extracción de metadatos App Intents. Queda un warning previo de `DateFormatting.swift` sobre `nonisolated(unsafe)` innecesario.

No se arrancaron simuladores ni se ejecutó `simctl`. Xcode emitió diagnósticos de conexión a CoreSimulator en el intento inicial bajo sandbox; no se reinició ningún servicio. No se han comprobado en dispositivo la interfaz de Atajos, el reconocimiento de frases Siri, la entrega real de avisos ni la concesión real de tiempo de fondo. Estos últimos requieren uso del sistema, no se deducen del éxito de compilación.

Base remota verificada: `15b5bc62c02ac9b5abe62d1b4d6315f9ff791617`. El repositorio original y `estado.md` permanecen intactos. No se incorpora el patch iCloud `571647b…`, no se cambian los esquemas CloudKit y no se publica ni despliega nada.
