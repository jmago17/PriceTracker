# Catálogo: auditoría y decisiones

Base: `69ca287f5fa567726bb9e3effb6a87f08430fcf8`, verificada contra `refs/heads/main` de jmago17/PriceTracker el 5 de octubre de 2026. Original limpio; trabajo en clon independiente, rama `codex/catalog-redesign`. Bundle `com.maromeapps.PriceTracker`, scheme PriceTracker, iOS/iPadOS 26+.

## Causas verificadas

- `ItemListViewModel.isDiscounted` comparaba precio actual y precio al añadir. No identificaba promociones. La separación visual en bajadas/siguiendo daba prioridad permanente a esa comparación. Siri también la llamaba descuento.
- `CatalogView` componía dos secciones por diferencia de precio, aunque `ItemFilterEngine` ya filtraba categorías. El codec CloudKit conserva category/categorySource; no es necesario cambiar el esquema para agrupar datos que ya existen localmente. No se ha consultado el estado actual del esquema de producción.
- `PriceObservation` no tiene persistencia ni productor. La explicación anterior prometía implícitamente un gráfico al acumular comprobaciones que nunca se guardaban.

## Semántica conservadora

Precio actual registrado: última captura/comprobación, no garantía del precio en caja. Al añadir: comparación histórica preservada, aunque pasen años. Referencia capturada: metadato independiente, no prueba de promoción. Mínimo observado: mínimo conocido por este catálogo, no mínimo universal de la tienda. Promoción: requeriría evidencia explícita vigente del proveedor y persistencia de su procedencia; no se presenta ningún badge de oferta. `FetchResult.isOnSale` existe pero los conectores actuales no proporcionan un estado persistido y fiable de promoción. `onSaleUntil` o una referencia aislada tampoco prueban una oferta vigente.

No se deduce que una bajada sea temporal ni permanente según días transcurridos. No se reescriben precios históricos, categorías almacenadas, registros CloudKit ni migraciones. Las alertas siguen comparando observaciones consecutivas y deduplicando cambios reales, independientemente de esta comparación desde el alta.

## Catálogo y diseño

Se agrupa después de filtrar y ordenar; orden alfabético de categorías y orden previo dentro de ellas. Nombres nuevos se muestran sin lista cerrada. Categorías nulas/vacías se agrupan al final; espacios exteriores se normalizan solo para presentación/filtro, sin alterar datos. El filtro de comparación excluye pausados, igual que el resumen.

Dirección editorial: encabezados serif, cifras redondeadas y monoespaciadas, acento verde petróleo adaptable a modo oscuro, superficies nativas y símbolos de contenido. Dynamic Type adapta filas a vertical; filtros tienen altura mínima de 44 puntos y el botón de añadir tiene etiqueta accesible. No hay animaciones ni efectos de vidrio personalizados.

## QA aislado

`--demo-catalog`, solo en Debug, usa datos ficticios y directorio temporal separado. Omite sincronización automática, bandeja, permisos de notificaciones y actualización de shortcuts. Las llamadas de sincronización desde ajustes también se omiten. Tests unitarios se aíslan mediante XCTestConfigurationFilePath. No usar este modo como demostración de CloudKit o conectores reales.

Referencias de solo lectura: twostraws/SwiftUI-Agent-Skill `be297ff80dddec529af1f9b1f1f114aab6c9d11c`, references/design.md; AvdLee/SwiftUI-Agent-Skill `9897311e3e42cc77e87603226e74bea711092fbd`, references/accessibility-patterns.md. No se instalaron ni ejecutaron scripts externos.
