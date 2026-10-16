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

# Price history synchronization — schema review draft

Status: app and test targets compile; independent review completed. Runtime tests and real CloudKit delivery remain unverified; schema is NOT deployed.

## CloudKit schema

Existing container: `iCloud.com.maromeapps.PriceTracker`.
Existing private-database zone: `PriceTrackerCatalog`.
Add record type `PriceObservation`; leave `CatalogItem` unchanged.

| Field | CloudKit type | App contract |
| --- | --- | --- |
| `identityKey` | String | Stable store/item/region identity; required for live samples |
| `observationID` | String | Existing observation UUID; required for live samples |
| `payload` | Bytes | UTF-8 JSON for ONE immutable PriceObservation, never an array/history snapshot |
| `tombstone` | Int64 | 0 live, 1 deleted |

JSON preserves id, checkedAt (seconds since Unix epoch), priceCents (integer), currency, isOnSale, optional saleEndsAt and availability. itemID is normalized to the zero UUID on transport; the local item UUID is resolved by identityKey on read. No currency conversion, synthetic observations, or inferred historical dates.

Record names are `observation_` plus `CloudRecordIdentity.recordName(identityKey + "|" + UUID)`. The expanded name is `observation_item_<lowercase SHA-256 hex of identityKey + "|" + uppercase UUID>`. Thus the UUID of the same check is stable across devices/retries, but two independent checks remain distinct even at the same time/price.

No query indexes or CKReference/cascade rules are needed: CKSyncEngine fetches zone changes. Use the normal private-owner permissions; do not expose records publicly. CloudKit system fields are managed by CloudKit and retained locally for retry/change-tag handling.

## Compatibility and migration

The dedicated engine-state key `ck-sync-engine-state-history-v2` forces a complete first fetch on upgrade. An older/downgraded client only writes the old key, so it cannot advance this version past unknown history records. Local dirty state and server archives are preserved.

The additive SQLite table `observation_sync` stores dirty state, tombstones and server archives alongside untouched `price_observations`. Missing metadata is discovered incrementally, including rows written later by an older app/Shortcut process. Interrupted discovery is safe to repeat. Local observations are durable before network work starts.

New clients union independently uploaded samples by UUID. They accept observations before the parent catalog record arrives. Existing clients ignore the new record type and retain their local history; their CatalogItem updates cannot replace a history blob because none is added to that record.

Incoming server records are durably retained before processing; one conflict does not stop unrelated records in the batch. Failed archives are retried on manual sync.

A conflicting payload for one UUID produces an explicit error while retaining the local sample. It is not silently replaced by a last-writer-wins decision. Normal overlapping/repeated downloads are idempotent.

## Deletion

Deleting an article continues to use its CatalogItem tombstone. Retain its real observation rows; hide them for deleted articles. No automatic erasure of historical evidence. Unexpected physical deletion of an observation is represented by a permanent observation tombstone; a late offline device cannot resurrect it. An unknown deleted observation may have only a record name until its original metadata arrives.

## Production rollout gate

Before release, review this exact schema and the tests. Add the type and all four fields in Development using schema tooling, then review the additive Development-to-Production schema diff. Deploy only that schema after authorization; do not create sample production records or alter user data. No deployment has been performed by this task.

Verify schema availability before shipping the feature to Production. Missing schema must remain a visible sync error with local data and pending uploads preserved. Do not describe two-device CloudKit synchronization as verified solely because local merge/codec tests pass.

## Complete field contract

All four custom fields are scalar, not lists. Do not add `checkedAt`, `priceCents`, `currency`, `itemID`, `isOnSale`, `saleEndsAt` or `availability` as CloudKit columns: they belong inside `payload`. There are no custom indexes, references, assets or new subscriptions in this change. Existing CatalogItem schema and zone remain unchanged.

Live records require identityKey, observationID and payload at application level. Tombstones intentionally omit observationID/payload and may omit identityKey when a deletion arrives before the sample. Do not introduce a server rule requiring those fields on every record. The writer emits tombstone 0/1; the reader treats an absent tombstone as false. CloudKit record name, zone, change tag, creator/modifier and server timestamps are system metadata, not custom fields; server timestamps never replace the real checkedAt.

Payload example (illustrative only; do not upload):

```json
{"checkedAt":1700000000,"currency":"EUR","id":"11111111-1111-4111-8111-111111111111","isOnSale":false,"itemID":"00000000-0000-0000-0000-000000000000","priceCents":1299}
```

Optional saleEndsAt is another Unix timestamp and availability is a string; nil values are omitted. The code accepts nonnegative prices and nonempty currency. Same-sample comparison ignores local itemID, compares all other values, and tolerates date differences below one millisecond. Different UUIDs are distinct real observations even if all their values match.

## Development procedure — not executed

1. Open CloudKit Console with the authorized Apple team, select `iCloud.com.maromeapps.PriceTracker`, and explicitly select **Development**. Record/export the existing schema first. Do not reset the environment.
2. In Schema / Record Types, create `PriceObservation` if absent. If present, compare its exact spelling and field types; stop on a mismatch rather than rename/delete existing fields.
3. Add `identityKey: String`, `observationID: String`, `payload: Bytes`, `tombstone: Int64`. Save the schema. Leave indexes and existing security roles unchanged; this implementation uses each user's private database and `PriceTrackerCatalog` custom zone.
4. Reopen the record type and verify all four field types. Export the resulting schema and compare against the baseline: the intended difference is one record type and these fields only.
5. After simulator access and runtime testing are authorized, run HistorySyncTests first. Then use isolated Development test accounts/devices with the same iCloud account: create independent real observations on A/B offline, reconnect, repeat sync and relaunch, and confirm the union and stable UUIDs. Check history-before-parent, item deletion, tombstone, conflict retention, retry, currency/date preservation and older-client coexistence. Do not use production/user records as fixtures.

## Production procedure — blocked pending review and authorization

1. Require passing runtime tests, reviewed Development schema export, and explicit deployment authorization. Verify the chosen team/container again. Signing/profile validation remains a separate pending task.
2. Open the container's **Deploy Schema Changes** action from Development. Review the entire proposed Development-to-Production diff, including any unrelated pending CatalogItem changes. Do not assume the action deploys just the selected record type. Stop if there are unreviewed changes.
3. Only after approval of that complete diff, confirm deployment. Deploy schema only; do not create, import, edit or delete Production records.
4. Switch the console to **Production**, inspect `PriceObservation`, verify the four types and unchanged existing schema, and save the deployment result/export as evidence. Deployment does not verify device synchronization.
5. Validate an explicitly authorized signed Production configuration separately before release. This task does not trigger CI, Xcode Cloud, TestFlight or App Store delivery.

Console navigation labels above describe the expected workflow, not a captured current Console session. The official [Apple deployment documentation](https://developer.apple.com/documentation/cloudkit/deploying-an-icloud-container-s-schema) was located, but its Markdown body could not be retrieved in this environment; confirm the actual Console diff and controls before any later deployment.

## Compatibility and rollback risks

- Treat Production schema additions as permanent: rolling back the app must leave the new type/fields in place. Never plan a rollback around deleting Production schema or changing field types. Development and Production records are separate; schema deployment is not a history-data migration.
- Older clients do not display remote history. Their locally captured points become upload candidates on upgrade; first upgrade performs a fresh zone fetch and may cost network/storage proportional to existing records. This does not reconstruct observations that were never stored.
- Every successful check is retained, including unchanged prices. Storage grows with checks; no retention/compaction policy is added here. Independent samples are deliberately not deduplicated by price/date.
- Same UUID with different content is a visible retained conflict, requiring investigation; retries do not silently select a winner. A permanent observation tombstone cannot be undone by a late device. Article deletion hides retained history rather than erasing it; reusing the same item identity can expose that retained history again.
- SQLite additions preserve existing payloads and old metadata. Downgrade/upgrade behavior is covered by drafted tests but remains unexecuted. Keep the v2 cursor separate; do not copy an old engine cursor into it.
- Missing Production schema prevents successful history uploads; local samples/pending work must survive. A successful build or local SQL check cannot establish CloudKit delivery, quotas, account permissions, notification delivery or signed entitlement validity.

## Lightweight verification — 2026-10-15

Passed nine synthetic in-memory checks with SQLite 3.50.4, using the CREATE TABLE block and migration/upsert statements extracted directly from SQLiteItemStore.swift: schema creation, 1,001 rows in batches 500/500/1, idempotent rerun, untouched raw payloads, later old-writer rows, unknown tombstone preservation, UUID uniqueness, indexed named lookup and transaction rollback. Evidence: `/tmp/pricetracker-history-sql-check.json` (local, not committed).

These checks do not execute the Swift actor, codec or CKSyncEngine. HistorySyncTests and the iPad/UI runtime checks remain pending. No new build, simulator, schema deployment, profile change or production data access was performed during this static review.
