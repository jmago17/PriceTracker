## Auditoría de categorías y regresiones — 2026-10-20

Base remota c5b3e75. Copia aislada fuera de iCloud; checkout histórico y cambios ajenos preservados.

Se normaliza la categoría seleccionada una sola vez y se reutilizan las claves de agrupación para evitar recorrer/normalizar dos veces el catálogo. Se conservan orden, categorías vacías y distinción de mayúsculas. Dos regresiones adicionales comprueban valores exactos en céntimos y equivalencia de todos los artículos de 10.000 entradas sintéticas con el algoritmo anterior.

Benchmark Debug (20 agrupaciones de 10.000 artículos): 0,744 → 0,450 s; repetición 0,258 → 0,138 s. Reducción local del 40–47 %, no medida de apertura de app ni de dispositivo físico.

Xcode 27.1 / iPhone 17 Pro iOS 27.0: 215 unitarias pasan. Primera batería UI: 13 correctas, 3 omitidas por tamaño/dispositivo y 3 fallos reproducidos con producción original. Se reparan selectores de esos tests sin cambiar UI: desplazar Ajustes y pulsar el switch hijo nativo (valores 0→1→0 y persistencia), leer la etiqueta accesible vigente de tarjeta y fila. Los tres pasan en repeticiones dirigidas; última ejecución: 215 unitarias + 2 UI, TEST SUCCEEDED, salida 0. No se ha repetido toda la UI en una única ejecución después de corregir selectores.

Evidencia: /tmp/PriceTracker-evidence-20261020 (regression, baseline-ui, fixed-ui y final-targeted, logs y xcresult). Respaldo de logs/parche e informe en Documents/Codex/2026-10-20/task-2/evidence.

Sin cambios de esquemas, migración, historial, cálculo monetario ni datos reales. Se mantienen JSON y adaptadores con usos activos. Pendiente: iPad/anchura estrecha de esta ronda, validación física/CloudKit ya documentada y posible consulta SQLite indexada por UUID para sustituir cargas completas; requiere trabajo separado con pruebas de migración y tombstones. Avisos del SDK/XCTest y deprecaciones preexistentes no resueltos en esta ronda.

---

## Estado vigente — revisión final 2026-10-16

Production no dispone de PriceObservation. **Transporte saliente del historial desactivado** mediante HistoryTransportPolicy.enabled = false: no se encolan nuevas muestras y se eliminan observaciones pendientes restauradas antes de construir lotes. CatalogItem sigue elegible. Los bytes, UUID y pendientes locales de observaciones se conservan en SQLite; no se despliega ni cambia el esquema.

Revisión independiente completada y bloqueo resuelto con esta protección. **28 pruebas unitarias pasan**, incluido filtrado de saves/deletes mezclados y conservación de muestras tras confirmar el catálogo y reabrir SQLite. App/extensión/tests compilados, TEST SUCCEEDED, salida 0. Evidencia `pricetracker-review-final-test.log` / `pricetracker-review-final.xcresult`. La prueba UI iPad vertical/horizontal pasó anteriormente en `pricetracker-ui-final.xcresult`; no se ha modificado UI productiva después.

Esta versión conserva historial local pero no lo envía entre dispositivos. Activar su transporte requiere autorización y despliegue del esquema, verificación posterior y pruebas CloudKit reales multidispositivo. Pendientes también perfil Time Sensitive y archive; no se cambian firma, permisos ni credenciales. La elegibilidad del catálogo se prueba localmente, no acredita una sesión real CKSyncEngine/Production. Estado operativo: Validation, no completar automáticamente. Entradas siguientes son histórico; los fallos locales están superados.

---

## Correcciones verificadas — 2026-10-16

1. applyRemoteObservation ya no trata SQLITE_ROW como error al encontrar una observación existente; mantiene la validación de identidad/contenido y los errores reales.
2. applyRemote conserva el UUID local del artículo bajo BEGIN IMMEDIATE/COMMIT/ROLLBACK. La diferencia observada era la reasignación de identidad al proyectar el historial; no se han borrado observaciones ni reescrito sus payloads. Se mantienen las expectativas de conservación y se comprueba que el precio remoto se actualiza bajo el ID local y no crea el ID remoto.
3. El fallo UI era del test: en horizontal, firstMatch encontraba la barra de la sidebar. La jerarquía real demuestra los cuatro controles en la barra del catálogo. Se selecciona esa barra por su botón de búsqueda. Además se sustituye la expectativa obsoleta «Con bajada» por el texto vigente «Menos que al añadir». No cambia código UI productivo.

**26 pruebas unitarias correctas** (HistorySyncTests, SQLiteItemStoreTests, CatalogSummaryLayoutTests, CloudRecordMergerTests) y **1 prueba UI correcta, TEST SUCCEEDED salida 0** en iPad Pro 11 M5 / iOS 27. La UI verifica controles nativos, orientación vertical/horizontal, alineación de columnas disponibles, teclado y menú. No acredita todos los tamaños de Split View ni dispositivos físicos. Compilación app/extensión/tests correcta.

Evidencia: /Users/josumartinezgonzalez/Documents/Codex/2026-10-16/task/evidence/pricetracker-final-test.log (26 unitarias; fallo UI por texto antiguo ya superado), pricetracker-ui-final-test.log y pricetracker-ui-final.xcresult (UI final correcta). Jerarquía de diagnóstico en pricetracker-fixed-test.log. git diff --check correcto.

Pendiente: validación real CloudKit multidispositivo, revisión y autorización del schema, firma/perfil con Time Sensitive y archive. No perfiles/credenciales/esquema modificados, no Cloud/TestFlight, no commit/push. Código corregido solo en la copia aislada del 14/10.

---

## Runtime comprobado — 2026-10-16

Compilación app/extensión/tests completada en Xcode 27.0, iPad Pro 11 M5 / iOS 27 exclusivo. 16 pruebas Swift Testing ejecutadas: 13 pasan y 3 fallan. HistorySyncTests falla en `offlineDevicesUnionRealSamplesAndRetriesDoNotDuplicate` y `samplesArrivingBeforeItemAndTombstonesNeverResurrectHistory` con `.execute("another row available")`. SQLiteItemStoreTests falla en `remoteUpdatesDoNotInventOrEraseLocalObservations`, línea 301, igualdad de observación. CatalogSummaryLayoutTests pasa.

La prueba UI `testIPadCatalogActionsStayInNavigationBar` también falla: no encuentra `mural-search-button` en navigationBars (ScreenshotTests.swift:49). No se acredita toolbar/alineación iPad ni sincronización real CloudKit. Evidencia: /Users/josumartinezgonzalez/Documents/Codex/2026-10-16/task/evidence/pricetracker-test.log y pricetracker.xcresult.

Sin cambios de código ni despliegue de schema. Pendiente corregir/investigar estos fallos y repetir. No commit/push. Archive/perfiles se registrarán por separado; la compilación Simulator no valida firma.

---

# PriceTracker — validación 2026-10-16

Copia aislada sobre main e4694426715779bc6530b009b5b272af1802b116, coincide con remoto verificado. UI publicada; historial iCloud sigue como borrador local, sin commit/push. HistorySyncTests se encuentra en Tests/PriceTrackerTests/SQLiteItemStoreTests.swift; CatalogSummaryLayoutTests en CatalogCardDetailsTests.swift. Runtime pendiente de la cola secuencial de Xcode. Git diff --check correcto.

Los perfiles locales existentes del bundle principal carecen de com.apple.developer.usernotifications.time-sensitive: Team Provisioning 1978ea56-b8f3-4cea-81e4-1a4a15b73e06 (expira 2027-09-10) y Team Store 01ef561c-68dc-435b-b96a-fb6c1dcdf611 (expira 2026-12-19). No se crean certificados ni permisos. La activación en Developer del traspaso no prueba que estos perfiles estén actualizados. Archive pendiente.

No desplegar schema CloudKit ni usar datos reales como fixtures. Ver Documentation/PriceHistorySync.md. Sin operaciones Cloud/TestFlight.
