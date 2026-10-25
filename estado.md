## Validación final Mac completada — 2026-10-25, 20:51 CET

**Validación automatizada verde del código R1; pendiente revisión/integración por el padre.** Misma rama `fix/amazon-validation-20261025`, worktree `/root/repos/pricetracker-amazon-validation-20261025`, base remota `ea3c23d4fdafa6e2f8e7568756a10b00704c59e6`. Snapshot compilado y ejecutado: **`260ac3072cf2cf081685e01ce50bceeae275a635`**, 129 archivos versionados y todos los SHA-256 de `manifest-r1.json` coincidentes. Esta sesión NO cambia implementación ni tests: únicamente añade esta sección de estado; el HEAD documental final y situación de push constan en `manifest-final.json`/`final-validation.md` externos. Los informes anteriores se conservan históricos y no describen los resultados nuevos.

- Acceso: Tailscale falló en un intento; LAN `192.168.31.104` funcionó, sin necesitar puente HA. Sin instalaciones/configuración/permisos/credenciales nuevas. Inspección previa: ningún Booted ni build/test Apple activo. Xcode **27.1 (27A9275)** en `/Applications/Xcode.app`, SDK Simulator **27.1**, runtime **iOS 27.0 (24A5423a)**. Espacio Data: **72 GiB antes / 70 GiB después**; no limpieza adicional.
- Copia aislada exacta: `~/MinisValidation/pricetracker-amazon-20261025/source-final-260ac30`, dentro de la misma carpeta de validación. No se toca `~/Developer/PriceTracker`. Manifiesto completo de 129 archivos comprobado tras transferir; sin archivos extra. Recursos `PageCapture.js` de app, extensión embebida y producto de extensión coinciden con SHA-256 **5855fec5c2315d9d0596045ce1cd24e4116c00884a9f6d66aac2436dccbd2440**.
- Node final: sintaxis del recurso/helper correcta; **16/16** escenarios sintéticos con recurso real, salida 0.
- Build genérico Simulator de app/extensión y `build-for-testing`: **salida 0 ambos**, sin boot para compilar, `CODE_SIGNING_ALLOWED=NO`.
- Host ampliado `PRICETRACKER_EXTENDED_TESTS=1`: **159 pasadas + 1 opt-in omitida = 160, 24 suites**, salida 0. Incluye delta de ancestros, subida inicial y RefreshFeedback. ShortcutBridge permanece excluida del host por API iOS `.ephemeral`; sí cubierta en suite iOS, sin relajar aserciones.
- Recuperación durable: **dos procesos separados / dos fases pasadas**, salida 0, con fixture nuevo bajo `core-final-260ac30`. Verifica append confirmado sin ack, UUID/sentAt y reintento con precio igual; no kill aleatorio ni exactly-once físico.
- Suite iOS final `PriceTrackerTests`: **229 pasadas, 0 fallos, 1 opt-in omitida = 230, 39 suites**, salida efectiva **0**, `TEST EXECUTE SUCCEEDED`. Resumen xcresult por declaraciones; el nivel dispositivo cuenta 236 ejecuciones pasadas por parámetros dinámicos, no 236 tests distintos. La omitida `processBoundaryFixture` se ejecutó expresamente en las dos fases host. R1 `amazonWrapperContextSurvivesJavaScriptThroughOfflineResolveAndItem` pasó (9 fixtures y alta manual offline), `amazonDOMCaptureAndSwiftValidationShareTheSameContract`, subida inicial y RefreshFeedback también. WebKit real → JS bundle → SharedPageCapture → AmazonConnector offline → Item queda probado con fixtures, NO Safari Share UI real.
- Único simulador usado: iPhone 17 Pro **7E9CE89C-D06B-4AE5-B8EA-32595595E31F**, existente; ningún dispositivo creado. Runner **3663**, xcodebuild **3843** iniciado **20:49:46 CET**; un worker, sin clones/paralelismo de tests. Boot/bootstatus/tests/shutdown con deadlines y `finally`; shutdown salida 0. Verificación: **Shutdown, 0 procesos propios rastreados restantes y 0 runtime/worker nuevos propios**, runners terminados. iPad y dispositivos Kaffa conservados apagados; sesiones `shellfish-1`/`txio-design-now` preservadas. La carga media aún elevada tras compilar/simular se documenta, no se declara normalizada.
- Evidencia completa copiada local: `/var/minis/shared/PriceTracker/fix-20261025/final-evidence/evidence-final/` (logs, exits, PID/identidades, recursos/procesos, integridad, `native-final.xcresult`, `native-summary.json`, `cleanup-verification.json`). Scripts de arnés preservados en `final-evidence/`. En Mac: `~/MinisValidation/pricetracker-amazon-20261025/evidence-final/`.
- **Límites pendientes:** no recorrido manual de alta/Safari Share real; esta interfaz SSH no ofrece interacción manual con Safari/Share y no se añaden permisos ni arneses UI nuevos para fingir E2E. No Amazon histórico/real, entrega física de notificaciones, cuenta/sync CloudKit multidispositivo ni reparación del artículo 12,39 €. No datos reales ni iPhone personal, publicación o integración main. Siguiente: padre revisa informe/manifiesto y decide integración; las pruebas automatizadas pendientes del lote ya están completadas.

---

## Seguimiento R1 del Revisor — 2026-10-25

**Mismo lote y misma rama `fix/amazon-validation-20261025`; NO integrar todavía.** Partida limpia revalidada en `e1a05118750909596522d64f22478fef85a12a54` (implementación previa `9ef4ad9`, base `ea3c23d`). Commit incremental R1 identificado con HEAD/SHA-256 en `/var/minis/shared/PriceTracker/fix-20261025/manifest-r1.json`; informe completo: `r1-followup.md` en ese directorio. Se preserva debajo el histórico, cuyas referencias a «FINAL» corresponden al snapshot anterior, no al nuevo HEAD.

- `Resources/PageCapture.js`: los envoltorios ordinarios desconocidos ya no se aplanan; se convierten a `div` con `id/class/data-asin/aria-label/title/alt` escapados. Solo el input ASIN conserva `name/value`. No se exportan href/action/event handlers/otros atributos, scripts/estilos/inertes ni inputs ajenos. Formularios/controles embebidos no representables hacen fallar el fragmento completo sin precio. Se conservan filtros de ocultos/aria y guard de ancestros ASIN/recomendaciones.
- Presupuesto incremental solo del saneador: texto/atributos se comprueban antes del escape, cada escritura consume el límite de 120000 caracteres, nodos/raíces limitados a 6000 y profundidad/ascendencia a 40. Sobrepasarlo devuelve null, nunca un total parcial. Esto NO acredita un límite global de memoria de capturePage ni rendimiento medido.
- JS real en Node: **16/16 escenarios**, sintaxis del recurso y helper correctas, `git diff --check` correcto. Incluye button/cuota, a con otro ASIN, seis etiquetas arbitrarias, title/aria, atributos maliciosos, script sin texto exportado, ocultos/duplicados, total legítimo 12,39 y Apple Store «desde», límites y conservación de enlace/metadatos. La nueva regresión falla contra JS de e1a0511 (salida 1 esperada: desaparecía aria/title de button); evidencia separada `r1-baseline-regression.log`. Salidas actuales: `r1-javascript-results.json` y `r1-checks.log`. No se repitió SQL: R1 no cambia F3/esquema.
- Nuevo test `amazonWrapperContextSurvivesJavaScriptThroughOfflineResolveAndItem` en `RenderedPageCaptureLoaderTests.swift`: recurso JS real en WKWebView → SharedPageCapture → AmazonConnector con URLProtocol offline → Item; nueve fixtures comparan HTML original/fragmento, campos nil y metadatos, más alta manual offline. **Añadido, NO compilado ni ejecutado**. Sin estado global mutable nuevo ni tráfico público requerido.
- Ningún Mac/SSH, build, simulador, dependencia, push/main, catálogo/datos reales, reparación del precio histórico ni cambio F3 en esta ronda. No hay procesos propios persistentes nuevos.
- Último snapshot Mac verde sigue siendo el PREVIO a `last-green-to-final.patch`: genérico/build-for-testing `generic-final.log`; host `core-final-exact.log` con **158 pasadas + 1 omitida**; reinicio en dos procesos verde anterior. No hay hash Git íntegro verde atribuible a este snapshot mixto. Primera suite nativa sigue **224 pasadas, 2 fallos, 1 omitida**, NO verde; el comando salió -15 tras diagnósticos/cierre. Siguen pendientes delta Swift de ancestros y test de subida inicial, nuevo R1, WebKit integrado final y repetición iOS final. Disco/red Mac no se reintentaron; resolverlos es trabajo separado.
- Siguiente paso: segunda revisión de `git diff e1a0511..HEAD` y del manifiesto R1, sin integración; el padre decidirá por separado recuperación Mac/espacio y validación final.

---

## Correcciones Amazon y outbox de alertas — 2026-10-25

**Rama de revisión, NO integrar todavía.** Base remota verificada mediante fetch: `ea3c23d4fdafa6e2f8e7568756a10b00704c59e6`. Implementación: `9ef4ad97ec2989dcec44dd902813e593dab89018`, rama `fix/amazon-validation-20261025`, worktree `/root/repos/pricetracker-amazon-validation-20261025`. Principal `/root/repos/PriceTracker` sigue en main `6794765`, limpio; no reset/checkout/merge/push. El checkout ajeno del Mac `~/Developer/PriceTracker` no se tocó.

### Cambios aplicados

- F1: Amazon no promueve `priceCents` de PageCapture ni de capturas antiguas. JavaScript emite un fragmento acotado de evidencia del área de precio, conserva el ASIN oculto legítimo y el contexto de ancestros, excluye precios ocultos/duplicados aria y valores de formularios ajenos. Alta URLSession y Compartir/WebKit usan `WebPriceParser` para verificar identidad/variante, total, moneda y acuerdo de candidatos. Se conserva el enlace/metadatos sin precio si no es fiable. No cambia el contrato de Apple Store «desde» ni el de otras tiendas.
- F2: el parser contrasta evidencia visible Amazon reconocible antes de devolver JSON-LD/microdata. Contradicción, financiación y ASIN/variante incompatibles fallan de forma conservadora. Un canal válido puede bastar cuando falta legítimamente el otro.
- F3: `alert_outbox` local en la misma transacción SQLite que precio, observación y dedupe. UUID estable, append JSON idempotente con bloqueo entre instancias/procesos y ack posterior. Reintento al refrescar, arrancar/reactivar y notificar; conserva `sentAt`. `notificationError` separado del precio persistido. SQLite y CloudBacked implementan el contrato durable; el fallback antiguo queda limitado a fakes/legacy en memoria. La tabla no se sincroniza ni cambia el payload/esquema CloudKit. No migración destructiva ni JSON antes del commit.

### Validación medida y límites

- JavaScript FINAL real: **7/7** mocks/fixtures sintéticos con Node, sintaxis correcta. Helper FINAL ejecutado sobre DOM WebKit real sintético: ASIN `input[type=hidden]`, total visible, exclusión de CSS oculto/duplicado aria/recomendaciones y conservación de cuota/ancestro ASIN. No es una respuesta pública de Amazon ni una ejecución completa de Safari Share.
- Mac aislado: `~/MinisValidation/pricetracker-amazon-20261025/source`, Xcode 27.1 (`/Applications/Xcode.app`), SDK Simulator 27.1. Build genérico y build-for-testing de app/extensión/tests pasaron. Último verde: `evidence/generic-final.log` (anterior al delta de ancestros y nuevo test de subida inicial).
- Último host verde: `evidence/core-final-exact.log`, **158 pruebas pasadas + 1 opt-in omitida** en 24 suites (Swift Testing informa 159). La opt-in de reinicio pasó además en **dos procesos separados**, antes y después del checkpoint append-sin-ack; log `evidence/outbox-process-restart-final.log`. La suite ShortcutBridge se excluye del host porque `.ephemeral` no existe en macOS; no se reescriben sus aserciones ni la API productiva iOS. Apple Store «desde», parser Amazon, SQLite/historial, concurrencia de alertas y RefreshFeedback están incluidos.
- Primera ejecución iOS: **224 pasadas, 2 fallos de callbacks de refresco, 1 omitida** (227 casos), no suite verde. Se corrigieron los callbacks espurios de cola vacía y RefreshFeedback pasó en host; NO se ha repetido la suite iOS final. El nuevo test WebKit app+JS+Swift quedó compilado, no ejecutado.
- Después del último verde se añadieron controles de ASIN/contexto en ancestros y sus regresiones, y el test específico de recuperación de la alerta de subida inicial. JavaScript final sí está probado; este delta Swift final sigue **pendiente de compilar/ejecutar en Mac**. Delta preciso: `/var/minis/shared/PriceTracker/fix-20261025/last-green-to-final.patch`.
- Bloqueo real: disco del Mac cayó a 125 MiB; no se borraron datos, dispositivos, runtimes ni DerivedData. Después se midieron 141 y 485 MiB. Finalmente SSH dejó de responder tanto por Tailscale como por LAN `192.168.31.104` (8 s cada uno); la transferencia/build del último delta no llegó a ejecutarse. No afirmar validación completa del commit final.

### Simulación y cierre

Una sola tarea/dispositivo propio: `PriceTracker-AmazonFix-20261025`, iPhone 17 Pro/iOS 27.0, UUID `7E9CE89C-D06B-4AE5-B8EA-32595595E31F`. Runner PID 93832, xcodebuild PID 94046 (inicio 12:04:31 CET). Terminados los tests, Xcode quedó recogiendo diagnósticos; con disco crítico se envió TERM solo al grupo propio tras revalidar PID/PPID/inicio/comando. Su finally apagó el UUID. Se verificaron Shutdown, ausencia de workers propios y **0/151 procesos runtime propios restantes por identidad/descendencia**. Sin nuevas simulaciones, sin `shutdown all`, erase/delete ni procesos ajenos detenidos. El comando de esa primera ronda salió -15, no TEST SUCCEEDED. Evidencia resumida: `fix-20261025/simulator-closure.json`.

### Pendiente antes de integrar

1. Revisor independiente: revisar `git diff ea3c23d..fix/amazon-validation-20261025` y el delta posterior al último verde.
2. Recuperar acceso y margen de disco con autorización separada para cualquier limpieza; copiar solo fuentes de esta rama a la copia aislada, nunca al checkout ajeno. Repetir build-for-testing genérico, `Tools/run-core-tests.py` con `PRICETRACKER_EXTENDED_TESTS=1`, `Tools/test-outbox-process-recovery.py` y la suite nativa `PriceTrackerTests` con inspección, UUID único y cierre finally verificado. No repetir simulación mientras el cierre/recursos no permitan hacerlo.
3. Comprobar nuevo test WebKit y entrada manual/Safari Share integrada en app. No se ha hecho reparación automática de 12,39, pruebas de cuenta/CloudKit multidispositivo ni notificaciones físicas. El origen histórico de 12,39 sigue sin acreditarse.

Informe, patch, fixtures y logs locales: `/var/minis/shared/PriceTracker/fix-20261025/`. Evidencia remota completa: `~/MinisValidation/pricetracker-amazon-20261025/evidence/` (parcialmente respaldada; Mac inaccesible al cerrar). Sin publicación, TestFlight, cambios de permisos/configuración, compras, datos reales ni Brrr.

---

## Cierre adicional de UI — 2026-10-20 (UTC)

Código verificado: 9a65935, sin cambios de Sources/Tests en esta ronda. Pasada coherente de iPhone 17 Pro: **16 tests UI, 0 fallos, 0 omitidos**, salida 0. Después, en serie, iPad dedicado: **2 tests UI, 0 fallos, 0 omitidos**, salida 0 (toolbar/acciones y mural vertical-horizontal). Evidencia: /tmp/PriceTracker-evidence-20261020/coherent-iphone-ui.xcresult y final-ipad-ui.xcresult, logs y resúmenes JSON; respaldo en Documents/Codex/2026-10-20/task-2/evidence.

**Cobertura UI final: 18/19, no suite completa.** El caso testCompactMuralNarrowWidthFallback exige viewport <358 pt. Intentar crear iPhone SE 1st generation de 320 pt con el único runtime instalado (iOS 27.0) falla: CoreSimulator.SimError 403, Incompatible device, salida 147. No se creó el destino. No se modificó el umbral ni se eliminó la aserción para obtener un aprobado; este caso permanece bloqueado por destino incompatible.

Revisión de selectores: se conservan las aserciones de céntimos/precio, color, frescura, gráfico, navegación y persistencia tras relanzar. Settings pulsa el switch nativo observado dentro del contenedor y añade comprobaciones 0→1→0. Las etiquetas de tarjeta/fila se comprueban con el texto accesible vigente. Sin relajación de tolerancias ni cambios de UI productiva. Se ejecutó un solo destino de PriceTracker cada vez; los simuladores de otros proyectos no se tocaron. Sin procesos de test pendientes.

---

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
