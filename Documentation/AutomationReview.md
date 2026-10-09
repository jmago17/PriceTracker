# Revisión final antes de publicar

Remoto consultado de nuevo el 2026-10-09: `refs/heads/main` = `15b5bc62c02ac9b5abe62d1b4d6315f9ff791617`. Es el padre exacto de `7d1d4c0fc93f561140624312d3bface5da1c56c4` y ancestro del commit de revisión posterior. No se ha publicado nada.

El primer commit modifica 25 archivos (786 inserciones, 97 eliminaciones): consultas/resultados Atajos, ajustes diarios, notificaciones, exclusión de refrescos, búsqueda Siri, pruebas y documentación. La revisión añade compare-and-commit transaccional para impedir que un refresco resucite un artículo borrado o sobrescriba una edición entre lectura y escritura. El adaptador CloudBacked delega esa operación local; no cambia el esquema ni despliega CloudKit.

## Acciones y tipos

Títulos definidos en código y confirmados en los metadatos extraídos por Xcode:

| Tipo | Título exacto | Salida |
|---|---|---|
| RefreshItemIntent | Actualizar artículo | RefreshResultEntity |
| RefreshCatalogIntent | Comprobar precios | Int (artículos con bajadas), diálogo con errores |
| GetItemPriceIntent | Consultar precio | ItemEntity |
| SetTargetPriceIntent | Fijar precio objetivo | ItemEntity |
| ShowPriceDropsIntent | Ver bajadas de precio | [ItemEntity] |
| NotifyPriceDropsIntent | Notificar cambios de precio | Int (artículos notificados) |
| SearchCatalogIntent | Buscar en PriceTracker | Abre resultados dentro de la app |

La acción **Buscar artículos** es generada por `EntityPropertyQuery`/`ItemQuery`, no por un `FindItemsIntent` con título propio. No se ha observado su etiqueta localizada exacta en la interfaz de Atajos de un dispositivo. Su tipo de entidad es `ItemEntity`, y la API de búsqueda devuelve `[ItemEntity]`, directamente utilizable en Repetir con cada uno.

Filtros registrados: **Título contiene** (sin distinguir mayúsculas), **Tienda igual a**, **Categoría igual a** (cadena exacta; vacío representa nil), **Estado igual a**, **Última comprobación anterior a** (nil como distantPast). Combinación AND/OR. Ordenación por título, última comprobación o precio actual, ascendente/descendente. Límite opcional, cero/negativo devuelve vacío. Sin filtro de estado, la consulta incluye también archivados: debe seleccionarse el estado deseado.

`RefreshResultEntity` es `TransientAppEntity`, con propiedades `@Property`: ID del artículo String; precio Int? en céntimos; moneda String?; ha cambiado Bool; comprobación correcta Bool; fecha Date?; error String?. El intent devuelve `.result` incluso ante fallo para continuar el bucle, pero **no declara éxito del refresco**: `success = outcome.error == nil`, `changed = false` en error, y diálogo explícito de fallo. Los errores de persistencia tampoco se convierten en éxito. El constructor vacío del tipo empieza con success=false.

La query rehidrata UUID persistentes y omite IDs borrados. Se verifica el ID otra vez al actualizar y al hacer commit. Se mantiene la región/URL del artículo al pasar al conector; la prueba registra literalmente `FR`, sin recurrir al storefront del Mac. No se fabrica historial ni se modifica la referencia de ofertas en comprobaciones de la misma moneda.

## Programación

`BGTaskSchedulerPermittedIdentifiers` contiene `com.maromeapps.PriceTracker.daily-prices`; `UIBackgroundModes` contiene `fetch` y conserva `remote-notification`. El mismo ID aparece en `.backgroundTask(.appRefresh(...))`, submit y cancel. `earliestBeginDate` es una oportunidad a partir de 24 horas; sucesivas entradas en background no la posponen continuamente. Antes de trabajar se programa la próxima oportunidad. Desactivar cancela solicitud y worker; la cancelación de la tarea SwiftUI por expiración se transmite al worker. Pruebas verifican ambos caminos y que no generan observaciones/errores de red falsos.

La UI dice expresamente que iOS decide cuándo ejecuta y que no garantiza hora ni ejecución diaria. El permiso de avisos se solicita solo con el interruptor, no al iniciar, programar ni desde intents.

## Cobertura y evidencia

El conjunto original de esta entrega tenía 39 tests en 5 suites: 13 de AutomationTests, 12 de PriceDropDetectorTests/PriceHistoryRefreshTests y 14 de ItemFilterEngineTests/CatalogSemanticsTests. La revisión añade una regresión de commit concurrente: **40 tests pasan**. Cubren consulta/AND/OR/límites/ordenación, UUID persistente tras reapertura/importación duplicada, errores por elemento, igual/subida/bajada/primera observación, referencia e historial, región, concurrencia de refrescos/alertas, consentimiento y ausencia de petición al programar, scheduling/fallo, disable/expiry y ruta Siri.

Evidencia local: `/tmp/PriceTracker-core-tests.log`. Ejecutable reproducible: `python3 Tools/run-core-tests.py` (ahora un único job). Compila fuentes reales, incluido SQLite y el adaptador CloudBacked, con dobles sin red para el composition root y el gestor de sincronización.

El build genérico iOS sin firma y la extracción de metadatos de `7d1d4c0` pasaron (`/tmp/PriceTracker-daily-build.log`, `/tmp/PriceTracker-daily-build/Build/Products/Debug-iphoneos/PriceTracker.app/Metadata.appintents/extract.actionsdata`). La corrección de revisión está compilada/probada en el harness macOS; por coordinación de carga no se ha repetido el build iOS. No simuladores ni simctl. Siguen pendientes voz/Atajos UI/avisos reales y concesión de background en dispositivo.
