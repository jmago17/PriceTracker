# PriceTracker — estado del proyecto

## Identidad y build

- Repo: `~/Developer/PriceTracker`
- Scheme: `PriceTracker`
- Xcode usado en esta sesión: `~/Downloads/Xcode-beta.app` 27.0 (`27A5252f`), más nuevo que `/Applications/Xcode-beta.app` (`27A5194q`).
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

La Share Extension conserva solo el App Group.

## Verificación de la sesión iCloud

- Build genérico iOS sin firma: correcto con Xcode `27A5252f`.
- Tests en iPhone 17 Pro / iOS 27.0: 40 tests, 9 suites, correctos.
- Cubierto por tests: migración idempotente, JSON intacto, fallo reintentable, identidad/deduplicación, operaciones SQLite por fila, tombstones, merge concurrente por campos, victoria de tombstone y round-trip del ancestro CloudKit.
- Los `.xcent` simulados contienen CloudKit/App Group/push en la app y solo App Group en la Share Extension.
- El build firmado para dispositivo genérico se detiene antes de CodeSign: el perfil actual no incluye Push Notifications, iCloud, `iCloud.com.maromeapps.PriceTracker` ni los tres entitlements correspondientes. No es un fallo de llavero.
- La compilación firmada para dispositivo genérico llega hasta provisioning y falla porque el perfil actual no incluye Push Notifications, iCloud, `iCloud.com.maromeapps.PriceTracker` ni los entitlements asociados. No llegó a CodeSign; no es `errSecInternalComponent` ni un problema de llavero.

No verificado todavía:

- Regeneración y validación del provisioning de dispositivo físico para el nuevo container.
- Creación real de zona/registros en CloudKit Development.
- Push silencioso real.
- Sincronización entre dos dispositivos físicos.
- CloudKit Production y Xcode Cloud.

## Pasos externos pendientes

1. En Certificates, Identifiers & Profiles, habilitar iCloud/CloudKit y Push Notifications para `com.maromeapps.PriceTracker`, y asociar exactamente `iCloud.com.maromeapps.PriceTracker`.
2. Regenerar los perfiles automáticos si Apple no lo hace al primer build. Si CodeSign devuelve `errSecInternalComponent`, desbloquear con un Run manual en Xcode; no pedir la contraseña del llavero.
3. Ejecutar un build Development firmado para que CloudKit cree `PriceTrackerCatalog` y el tipo `CatalogItem` con sus campos.
4. Revisar el esquema en CloudKit Console y desplegarlo de Development a Production antes de TestFlight/App Store.
5. Confirmar que Xcode Cloud tiene acceso al container y genera un perfil con iCloud, push y App Group.
6. Probar alta, edición independiente, refresh y borrado con dos dispositivos físicos en la misma cuenta.

## Hipótesis descartadas en esta sesión

- No había ficheros `.swift` de 0 bytes.
- El repo estaba limpio y `c1dfa9a Add JSON import from clipboard` seguía como commit separado, uno por delante de `origin/main`.
- `/var/minis/shared/pricetracker/ARQUITECTURA.md` y `ESTADO.md` no estaban montados.
- `CKSyncEngine` sí es compatible con el deployment target iOS 26. Sus firmas se comprobaron contra la `.swiftinterface` y headers del SDK 27.0, no por memoria.
- Los primeros errores de macros/CoreSimulator eran del sandbox. Fuera del sandbox compilaron; el primer crash de tests era la ausencia deliberada de firma/App Group al usar `CODE_SIGNING_ALLOWED=NO`.
