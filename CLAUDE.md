# PriceTracker — estado del proyecto

## Identidad y build

- Repo: `~/Developer/PriceTracker`
- Scheme: `PriceTracker`
- Xcode usado para la validación firmada: `/Applications/Xcode-beta.app` 27.0 (`27A5194q`).
- Deployment target: iOS 26.0.
- `project.yml` es la fuente de verdad y `PriceTracker.xcodeproj` debe quedar versionado para Xcode Cloud.
- App Group: `group.com.maromeapps.PriceTracker`.
- CloudKit container: `iCloud.com.maromeapps.PriceTracker`.

## Arquitectura vigente

### Persistencia local

- El catálogo operativo vive en `catalog.sqlite`, dentro del App Group.
- `SQLiteItemStore` usa WAL y operaciones atómicas por fila para que app y App Intents no hagan ciclos inseguros de leer/reemplazar todo el catálogo.
- La identidad lógica única es `(store, storeItemID, region)` (`Item.identityKey`).
- El nombre de `CKRecord` es determinista: prefijo `item_` más SHA-256 de la identidad lógica.
- `items.json` ya no es la fuente de verdad. Solo se conserva como origen/recuperación de la migración.
- La Share Extension no abre SQLite ni CloudKit: continúa escribiendo únicamente en `SharedURLInbox`; la app resuelve las URLs y hace el `upsert` local.
- Alertas entregadas, errores/fallos consecutivos del conector y `lastAlertedPriceCents` son locales al dispositivo.

### Migración de JSON

- `SQLiteItemStore.migrateLegacyJSONIfNeeded` es idempotente.
- No borra ni modifica `items.json`.
- Escribe por identidad, verifica que todas las identidades estén en SQLite y solo entonces guarda el marcador `items-json-migration-v1`.
- Un error de lectura/decodificación/verificación deja el marcador sin escribir para permitir reintento.

### Sincronización CloudKit

- `CloudSyncManager` usa `CKContainer(identifier:).privateCloudDatabase` y `CKSyncEngine`.
- Zona custom: `PriceTrackerCatalog`.
- El estado serializado de `CKSyncEngine` y el último registro de servidor aceptado se guardan en SQLite. El registro aceptado completo sirve de ancestro para merge de tres vías.
- Escrituras: SQLite primero; después se añade el cambio pendiente a `CKSyncEngine`. La falta de red nunca invalida la escritura local.
- Borrados: registros tombstone permanentes. No se usa el borrado físico normal de CloudKit.
- Conflictos: merge por campo con `ancestor/client/server`. Se conservan ediciones independientes; etiquetas y namespaces de IDs externos se combinan. Si ambos cambiaron otro mismo campo, gana el valor ya aceptado por el servidor. Un tombstone siempre gana. No se usa el reloj local como autoridad.
- Una eliminación física inesperada en servidor se convierte de nuevo en tombstone si el registro era conocido.
- Un cambio de Apple Account suspende la sincronización en vez de enviar el catálogo local a otra cuenta. Volver a la cuenta original permite reintentar.
- `CKSyncEngine` crea/usa su suscripción de base de datos para silent pushes. La app sincroniza también al activarse y ofrece `Sincronizar ahora`.
- La UI muestra cuenta, último sync, pendientes y último error. Cambios remotos incrementan una revisión local que recarga la lista visible.

### Campos

- Se sincronizan los campos compartidos completos de `Item`: identidad/URL, metadatos, categoría, etiquetas, notas, estado, precios, fechas y IDs externos.
- No se sincronizan `lastError`, `consecutiveFailures` ni `lastAlertedPriceCents`, porque describen ejecución/notificaciones locales.
- `PriceObservation` existe como modelo, pero antes de esta migración no tenía store ni productor y sigue sin persistirse. Por tanto no había historial real que migrar/sincronizar. Si se introduce, debe ser un tipo de registro por observación y fusionarse por ID; no debe añadirse como un blob de historial que un dispositivo pueda sobrescribir.

## Capacidades

Solo el target principal tiene:

- App Group.
- iCloud container `iCloud.com.maromeapps.PriceTracker`.
- servicio `CloudKit`.
- `aps-environment`.
- background mode `remote-notification`.

El entorno se selecciona explícitamente por configuración: `Debug` firma con
CloudKit `Development` y APNs `development`; `Release` con CloudKit
`Production` y APNs `production`. No dejar estos valores implícitos: el perfil
Development autoriza ambos entornos de CloudKit y una firma sin selección
explícita puede apuntar al servidor equivocado.

La Share Extension conserva solo el App Group.

## Verificación de la sesión iCloud

- Build genérico iOS sin firma: correcto con Xcode `27A5252f`.
- Tests en iPhone 17 Pro / iOS 27.0: 51 tests, 13 suites, correctos tras añadir precios de software, Apple Store y captura genérica de tiendas web.
- Build Release para iPhone 17 Pro Simulator / iOS 27.0: correcto con Xcode `27A5194q` después de esos cambios.
- Cubierto por tests: migración idempotente, JSON intacto, fallo reintentable, identidad/deduplicación, operaciones SQLite por fila, tombstones, merge concurrente por campos, victoria de tombstone y round-trip del ancestro CloudKit.
- Los `.xcent` simulados contienen CloudKit/App Group/push en la app y solo App Group en la Share Extension.
- Tras habilitar iCloud/CloudKit en el App ID, Xcode regeneró el perfil Development automático (`8c753b65-dda2-4b69-bd41-7c8926f21c94`) y el build genérico de dispositivo quedó firmado correctamente.
- Los entitlements efectivos de la app firmada contienen `aps-environment=development`, CloudKit, `iCloud.com.maromeapps.PriceTracker` y el App Group. La Share Extension firmada contiene únicamente el App Group, además de los identificadores normales de firma.
- El primer intento de instalación en el iPhone 17 Pro no llegó a copiar la app porque el dispositivo estaba bloqueado y CoreDevice no pudo montar la Developer Disk Image. No es un fallo de código, firma ni provisioning.
- Tras desbloquear el iPhone 17 Pro, el mismo build se instaló y arrancó correctamente. La app mostró el catálogo, dejó cero cambios pendientes en el indicador y creó/actualizó su caché privada de CloudKit, lo que confirma acceso al framework y a la cuenta iCloud desde el dispositivo.
- `cktool export-schema` no pudo usarse para inspeccionar el servidor porque no hay un CloudKit Management Token guardado. No se creó uno solo para esta comprobación.
- Después de fijar los entornos, el build Debug firmado contiene literalmente `com.apple.developer.icloud-container-environment=Development`; los 40 tests continúan pasando.
- En el iPad, una build dirigida a Production devolvió `Failed to send changes` porque Production todavía no contiene el tipo `CatalogItem`. El nombre del tipo en código es correcto; CloudKit prohíbe crear tipos o campos nuevos directamente en Production.
- Después de desplegar `CatalogItem`, Production rechazó el campo `category`. El esquema se había creado de forma just-in-time desde un registro cuyos opcionales eran `nil`, por lo que el tipo llegó a Production incompleto. No corregir los campos uno a uno: hay que completar todo `CatalogItem` en Development y volver a desplegar los cambios aditivos.
- Josu completó y desplegó el esquema aditivo de `CatalogItem` a Production. Falta verificar en dos dispositivos que el cambio pendiente del iPad se reintenta y que la sincronización bidireccional funciona.
- El conector de App Store ignoraba el campo numérico `price` que Apple devuelve para resultados `software` y, al faltar `trackPrice`, convertía incluso apps de pago en gratuitas. La corrección usa `price` primero, conserva `trackPrice`/`collectionPrice` para otros medios y considera inválida una respuesta sin ningún precio numérico.
- Apple Store tiene conector propio y refrescable. Extrae JSON-LD: una configuración concreta usa su `Offer` exacta y una familia configurable conserva `lowPrice` con la etiqueta «Precio desde».
- Cualquier otra URL web se puede guardar mediante el conector `generic`. En el alta intenta capturar nombre, descripción, imagen, URL canónica y precio desde JSON-LD/Open Graph/HTML; si la tienda bloquea la petición, conserva al menos el enlace y un título derivado de la URL. No refresca ni compara después los precios genéricos.
- La resolución prueba conectores específicos por orden y, si uno falla, continúa hasta el genérico. Una caída de la API o un HTML no reconocido reduce los metadatos disponibles, pero no impide guardar una URL web válida.
- Amazon también intenta la captura de metadatos una vez al añadir, con fallback al ASIN. Continúa sin scraping periódico y mantiene el enlace a Keepa.
- La pantalla de sincronización permite seleccionar el error de iCloud y copiarlo completo al portapapeles.

No verificado todavía:

- Creación real de zona/registros en CloudKit Development.
- Push silencioso real.
- Sincronización entre dos dispositivos físicos.
- Sincronización bidireccional real de CloudKit Production y Xcode Cloud.
- Alta desde la Share Extension del Apple Watch ya pendiente y de una tienda genérica en un dispositivo físico.

## Pasos externos pendientes

1. Exportar el esquema Development real con `cktool` y versionarlo para que futuros cambios no dependan de creación just-in-time ni de reconstrucción manual.
2. Reintentar la sincronización pendiente del iPad con el esquema Production ya desplegado.
3. Confirmar que Xcode Cloud tiene acceso al container y genera un perfil con iCloud, push y App Group.
4. Probar alta, edición independiente, refresh y borrado con dos dispositivos físicos en la misma cuenta.

## Hipótesis descartadas en esta sesión

- No había ficheros `.swift` de 0 bytes.
- El repo estaba limpio y `c1dfa9a Add JSON import from clipboard` seguía como commit separado, uno por delante de `origin/main`.
- `/var/minis/shared/pricetracker/ARQUITECTURA.md` y `ESTADO.md` no estaban montados.
- `CKSyncEngine` sí es compatible con el deployment target iOS 26. Sus firmas se comprobaron contra la `.swiftinterface` y headers del SDK 27.0, no por memoria.
- Los primeros errores de macros/CoreSimulator eran del sandbox. Fuera del sandbox compilaron; el primer crash de tests era la ausencia deliberada de firma/App Group al usar `CODE_SIGNING_ALLOWED=NO`.
- El perfil antiguo sin iCloud/push no indicaba un defecto en el proyecto: al renovar el perfil, la firma incluyó todas las capacidades esperadas.
- El primer fallo al renovar tampoco era el llavero: Xcode no tenía una sesión de cuenta válida (`missing Xcode-Username`). Tras iniciar sesión, renovación y CodeSign funcionaron.
- El error del iPad no era un fallo del ID determinista ni un typo `Catalogltem`: el servidor identificó correctamente `CatalogItem` y rechazó crearlo porque la build estaba usando el esquema Production aún sin desplegar.
- El despliegue inicial de `CatalogItem` no garantizaba que estuvieran todos sus campos: la creación just-in-time solo añadió los campos con valor presentes en el registro usado para inicializar Development; `category` y potencialmente otros opcionales quedaron fuera.
- Los precios erróneos de App Store no procedían del país ni del redondeo: respuestas reales para España devolvieron `EUR` y un `price` numérico correcto. El código no decodificaba ese campo y aplicaba un cero por defecto cuando faltaban los campos de precio de medios.
- Una página real configurada de Apple Watch publicó nombre, imagen, SKU, moneda y precio exacto mediante JSON-LD. La página de familia publicó solo un rango; por eso se diferencia «Precio desde» de una configuración exacta.
