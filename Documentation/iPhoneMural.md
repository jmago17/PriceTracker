# Mural opcional de iPhone — gris masonry (11/10/2026)

Rediseño sobre `main` `58c0378`, rama `codex/iphone-gray-masonry`. Referencia leída: `photo_250FADCF.jpg` (dos columnas escalonadas, superficies claras redondeadas, texto editorial y acciones circulares). Cambio exclusivamente de UI y sus pruebas/documentación; el puente de Atajos no se modifica.

## Presentaciones y preferencia

- Ajustes → Apariencia → **Mural en iPhone**, clave `compactCatalogMuralEnabled`, sigue desactivada por defecto. Con el switch apagado se conserva la lista anterior.
- En ancho compacto, con el switch activado: masonry de **dos columnas** como máximo. Cada tarjeta se coloca en la columna más corta, según su altura medida, no en filas de una grid uniforme. La segunda columna comienza 52 pt más abajo.
- Columnas de al menos 156 pt, separación de 14 pt y márgenes laterales de 16 pt. Dos columnas requieren 326 pt de contenido útil (aproximadamente 358 pt de ventana sin otros insets). Anchos menores pasan automáticamente a una columna, sin escalón inicial.
- Todos los tamaños de Dynamic Type de accesibilidad usan una columna. Títulos, precios y metadatos no tienen truncado ni reducción de fuente; resúmenes completos en accesibilidad y hasta cinco líneas en tamaños normales.
- Ancho regular: conserva `ItemCardView`, las columnas mínimas de 220 pt, separación de 22 pt, búsqueda serif grande y controles originales de iPad, independientemente del switch. Como antes, la preferencia puede afectar a ventanas compactas de iPad.

## Diseño compacto y datos

- Fondo `systemGroupedBackground`, tarjetas `secondarySystemGroupedBackground`, borde semántico `separator` de 0,5 pt y sombra discreta. Sigue automáticamente el tema del iPhone: gris claro en light y equivalente oscuro en dark, sin `preferredColorScheme` forzado ni nueva preferencia de color. Texto/precio usan `primary`/`secondary`; controles de cristal y botón de añadir con contraste semántico. Esquinas continuas de 32 pt (imagen interior: 22 pt).
- Una sola superficie por artículo: fecha de comprobación correcta pequeña, título sans bold, **precio real visible**, tienda/variante o categoría existente, comparación histórica cuando procede, resumen y opcionalmente imagen al final. Alturas derivadas del contenido.
- La fecha usa `lastSuccessAt`, la misma fuente de frescura de la lista: evita presentar un intento fallido como comprobación correcta. Sin fecha: «Sin comprobar». No se generan fechas a partir de `createdAt`, categorías, resúmenes ni imágenes ficticias.
- Precio obtenido exclusivamente de `priceCurrentCents` y moneda mediante `MoneyFormatter`; cero es «Gratis» y ausencia de precio es «Precio sin comprobar». Una reducción se etiqueta «desde el inicio», sin afirmar una promoción comercial.
- Errores de comprobación permanecen visibles aunque exista un precio anterior. «Resumiendo…» mantiene el estado de trabajo; su pulso respeta Reduce Motion. Los colores se adaptan a light/dark mode.

## Interacciones y accesibilidad

- Cabecera reducida a búsqueda discreta de 44 pt y chips de categoría. Se elimina el resumen agregado del encabezado compacto para dar protagonismo a las tarjetas; no cambia el encabezado regular.
- Acciones inferiores, de izquierda a derecha: búsqueda, actualizar/cancelar, filtros de estado y añadir. Son controles circulares de 48 pt con etiquetas accesibles; el filtro conserva todas sus opciones y expone el estado elegido como valor accesible.
- La lupa vuelve a la cabecera con `ScrollViewReader` y enfoca la búsqueda integrada, incluso desde el final. Sin desplazamiento animado. «Listo» descarta el teclado; los controles inferiores se ocultan con foco de búsqueda.
- `safeAreaInset` reserva espacio para controles/selección y un margen de contenido inferior compacto de 80 pt permite llevar la última tarjeta por encima de la tab bar flotante. No se implementan overlays sobre la última tarjeta.
- Navegación al detalle, menú contextual, selección múltiple, compartir, filtros, alta, actualización/cancelación y progreso siguen reutilizando las acciones existentes. La tarjeta seleccionada lleva borde y símbolo; no se depende solo del color. Una tarjeta es un elemento combinado para VoiceOver; imágenes decorativas e indicador redundante se ocultan a accesibilidad.

## Archivos modificados

- `Sources/Views/CatalogView.swift`: integración masonry compacta, búsqueda discreta/flotante, fondo y acciones circulares; reserva de scroll.
- `Sources/Views/CatalogMuralComponents.swift`: parámetros opcionales del layout (defaults regulares conservados) y `CompactMuralCardView` dentro del archivo existente.
- `Sources/Views/SettingsView.swift`: texto del ajuste actualizado a dos columnas adaptables.
- `Tests/PriceTrackerUITests/ScreenshotTests.swift`: tres tests nuevos y fallback accesible añadido al test existente.
- `Documentation/iPhoneMural.md`: esta descripción.

No requiere archivos Swift nuevos ni cambios en `project.pbxproj`.

## Pruebas

Añadidas, **no ejecutadas en simulador/dispositivo en esta sesión**:

1. `testCompactMuralStaggeredColumnsAndFloatingActions`: dos columnas iguales, escalón de 52 pt, controles táctiles separados y por encima de tab bar, última tarjeta, búsqueda desde el fondo, precio/variante/frescura reales, filtro de pausados y alta.
2. `testCompactMuralDarkTwoColumns`: geometría de dos columnas, captura dark y auditoría de descripción accesible.
3. `testCompactMuralNarrowWidthFallback`: una columna normal en destino menor de 358 pt; omite la prueba en destinos anchos.
4. `testCompactMuralSearchKeyboardAndLargeText`: además comprueba ancho/posición de una columna accesible; mantiene búsqueda sin resultados, teclado y borrado.

Se conservan `testCompactMuralOptInAndNavigation`, `testCompactMuralSettingsSwitch`, las pruebas de lista con switch apagado y `testMuralLandscapeAndPortrait` de iPad.

Verificado localmente: `git diff --check` y análisis sintáctico Tree-sitter de los cuatro archivos Swift modificados, sin errores ni nodos missing. Comprobación matemática local de umbrales/colocación de columnas, incluida equivalencia de parámetros por defecto para ancho regular. **Estas comprobaciones no equivalen a compilar SwiftUI ni ejecutar XCTest.** No se ha conectado al Mac, compilado, publicado, hecho commit ni push.

## Riesgos y validación no realizada

- El masonry mide el catálogo completo, a diferencia de la anterior `LazyVStack` compacta: revisar coste con cientos de artículos y carga de imágenes.
- Revisar la geometría real de tab bar/insets, foco y scroll al aparecer el teclado en iPhone; los tests nuevos lo cubren, pero aquí no se han ejecutado.
- Revisar 320/375/390/430 pt, landscape, accesibilidad máxima, VoiceOver, Reduce Motion y iPad regular en ambas orientaciones. Los tests sintéticos de imágenes usan URLs de ejemplo: no certifican la presentación de imágenes reales.
- La sintaxis está analizada, pero el type-check de SwiftUI, el aspecto renderizado y las regresiones UI requieren Xcode/iOS; no se afirma que hayan pasado.
