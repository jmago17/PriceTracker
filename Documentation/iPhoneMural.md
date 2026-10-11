# Mural opcional de iPhone — 11/10/2026

Implementado sobre `main` `97b5d6d`, en rama `codex/iphone-mural-shortcut-bridge`.

- Ajustes → Apariencia → **Mural en iPhone**, `compactCatalogMuralEnabled`, desactivado por defecto. La lista anterior permanece disponible.
- Ancho compacto: una columna lazy, búsqueda serif escalada, chips de categorías, filtros de estado en menú, refrescar/cancelar y añadir. Conserva navegación, selección y compartir.
- Ancho regular: mural masonry de iPad sin depender del switch. La preferencia también afecta a ventanas compactas de iPad.
- Precio debajo de imágenes en compacto; Dynamic Type accesible sin recorte de títulos/resúmenes; controles flotantes ocultos mientras la búsqueda tiene foco; Reduce Motion respetado.
- Tres tests UI nuevos: opt-in/navegación/selección, cambio desde Ajustes y persistencia, búsqueda/teclado/texto accesible. Tests existentes fijan el switch apagado.
- Puente diario de notificación → Atajos documentado en `ShortcutBridge.md`; 11 tests unitarios nuevos, incluidos también en `Tools/run-core-tests.py`.

## Verificado aquí

`git diff --check`, sintaxis Python del runner, referencias de archivos nuevos en proyecto Xcode y análisis sintáctico Tree-sitter de los siete archivos Swift modificados/nuevos.

**No es una compilación ni una prueba ejecutada.** Mac inaccesible por SSH en esta sesión. Sin capturas reales, sin test en dispositivo y sin publicación TestFlight.

## Validación pendiente en Mac

1. Build simulador iPhone e iPad con Xcode compatible iOS 26+.
2. Suite `PriceTrackerTests`, especialmente `ShortcutBridgeTests`; runner host opcional `python3 Tools/run-core-tests.py`.
3. Tres tests `ScreenshotTests/testCompactMural*` en iPhone vertical; regresiones de lista; `testMuralLandscapeAndPortrait` en iPad.
4. Revisar capturas, barra inferior vs tab bar y última tarjeta, teclado, Dynamic Type, VoiceOver, filtros, alta y refresco/cancelación.
5. En dispositivo: activar puente y recibir prueba tras salir de app, configurar disparador compatible de Atajos y verificar acción **Comprobar precios**. No asumir disponibilidad del disparador ni ejecución automática.
6. No integrar en `main` ni distribuir hasta validar. Los pendientes previos de CloudKit Production para resumen/variantes siguen separados de este cambio.
