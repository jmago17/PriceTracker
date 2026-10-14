# Initial-price alerts and item priority

- A rise alert compares a successful same-currency observation with `priceAtAddCents`, never the previous observation or `priceReferenceCents`. It fires once for that initial-price generation, even across relaunches and falls/rebounds. Existing drop/target/low policy is unchanged.
- **Usar precio actual como inicial / Use current price as initial** replaces the initial comparison with a nonnegative current price, provided the item has no outstanding extraction failure. It starts a new generation and writes no price observation. It preserves creation time, real history, minimum, target and captured store reference. The action and priority editor use compare-and-commit against the latest stored row, protecting concurrent refreshes/deletion.
- Missing/negative extraction results do not produce prices, observations or alerts. Currency changes follow the existing baseline policy without an alert. Pending rise alerts for an obsolete generation and new alerts in an obsolete currency are discarded by delivery.
- Priority is low/normal/high, with normal for legacy items and unknown values. Both phone and tablet details expose the picker; non-normal priorities have a small flag on cards/list entries.

## Persistence and synchronization

App metadata is namespaced in the existing `[String: String] externalIDs` container, already encoded in SQLite, JSON export/import and CloudKit. No production CloudKit schema change is required:

- `PriceTracker.priority`: `low`, `normal`, `high`.
- `PriceTracker.initialPriceGeneration`: UUID for explicit resets/currency changes; legacy baseline uses `original`.
- `PriceTracker.alertedInitialPrice.<currency>|<cents>|<generation>`: append-only `true` marker.
- `PriceTracker.urgentOffer.<currency>|<expiry timestamp>`: append-only `true` marker.

Append-only markers survive dictionary merges and delayed devices; old markers never match a new generation. Metadata merges compare reserved keys against the ancestor, so a refresh on another device does not undo an independent priority edit. Initial amount, currency and generation are then resolved as one unit: the client wins only when it alone changed that unit; concurrent resets select the complete server reference, even if its amount is unchanged. When currencies differ, other monetary values also come from the selected currency side. Existing non-app external-ID conflict policy is retained.

Same-device app/manual/background/Shortcuts paths share `RefreshCoordinator`, atomic SQLite refresh commits and `AlertNotifier`. Markers are committed before creating the pending delivery log, consistent with existing drop dedup. A crash or log-write failure in that small window can lose an alert; no new transactional delivery outbox is introduced. Sync suppresses later repeats once the marker arrives, but simultaneously offline devices can each notify before they exchange state. Old app versions do not implement this new policy.

## Optional Time Sensitive alerts

Disabled by default under Settings. Only high-priority items with a genuine fetched `isOnSale`, an unexpired explicit `saleEndsAt`, and an actual downward price movement can create a Time Sensitive candidate. The same offer expiry is promoted once; normal drop re-arming remains unchanged. A successful fetch with `isOnSale = false` clears the item’s confirmed expiry even if it supplies the previous date. At delivery the item must still be active, healthy, at that discounted price and confirmed offer expiry; otherwise the pending drop uses normal delivery. Ordinary summaries and Time Sensitive candidates are separate, so rises/other items are never promoted accidentally.

The main app entitlement declares `com.apple.developer.usernotifications.time-sensitive` (also in `project.yml`). Delivery checks `timeSensitiveSetting == .enabled`; otherwise it uses `.active`. The app opt-in never changes system authorization. No critical entitlement, critical authorization request or critical sound is used. No account, portal or provisioning changes are made by this task; a future signed distribution build must use a profile supporting the declared capability.

Most current connectors report `isOnSale = false` and do not supply an expiry: their observed reductions stay normal notifications. A cheaper historical price is not enough to claim a temporary promotion. Physical-device Focus delivery and remote two-device CloudKit sync are not part of the local validation.

Apple sources checked 2026-10-14:
- [Time Sensitive interruption level](https://developer.apple.com/documentation/usernotifications/unnotificationinterruptionlevel/timesensitive): user-controlled interruption through Focus/summary.
- [Time Sensitive setting](https://developer.apple.com/documentation/usernotifications/unnotificationsettings/timesensitivesetting).
- [WWDC21: Send communication and Time Sensitive notifications](https://developer.apple.com/videos/play/wwdc2021/10091/): enable capability in Xcode; use only for relevant immediate attention.
- [Critical alert authorization](https://developer.apple.com/documentation/usernotifications/unauthorizationoptions/criticalalert): special Apple-issued entitlement required. Time Sensitive does not promise a silent-mode override.

## Local validation

Xcode 27.0 (27A266a), iOS 27 simulator. Generic iOS Simulator build with signing disabled succeeded. The full unit suite passed: 197 tests / 33 suites, including SQLite reopening, refresh entry points, sync codec/merge, negative extraction, initial-price reset and dedup, priority defaults, offer classification, permission fallback, mixed notification grouping, and repeated delivery. The pre-existing generic-link history test was updated to match current main's web-refresh support.

UI tests exercise the priority picker and initial-price action in Spanish and English using an isolated demo catalog. No real account data is used. The optional Mac-only harness was not used as final evidence: its existing `ephemeral` authorization case is unavailable on macOS. Simulator tests cover the production iOS targets instead.

Final follow-up: 41 tests in the three affected suites (`AutomationTests`, `PriceDropDetectorTests`, `CloudRecordMergerTests`) passed after adding the missing-current-price import case and fixing sub-microsecond `Date` precision loss on JSON round-trip. Offer expiry comparison allows less than 1 ms of serialization error, and dedup expiry keys use whole Unix seconds. UI ES/EN passed on iPhone 17 Pro and iPad Pro 13-inch; the final visible Priority label was verified on iPad. Xcode's multi-destination runner failed to launch reliably, so validation used individual destinations. All simulators created for this task were shut down.

Evidence (local, outside the repository):
- `/tmp/PriceTracker-priority-verified.xcresult`: 197 unit tests and iPhone ES/EN UI, succeeded.
- `/tmp/PriceTracker-priority-ipad.xcresult`: iPad ES/EN UI, succeeded.
- `/tmp/PriceTracker-priority-final-ipad-unit-ui.log`: final Priority label UI passed; exposed the date-precision issue subsequently fixed.
- `/tmp/PriceTracker-priority-targeted-final.xcresult`: final affected suites, 41 tests, succeeded.

Independent review follow-up: fixed mixed initial-price references in concurrent resets and stale Time Sensitive eligibility after a successful `isOnSale = false` fetch. Five regression tests cover competing resets (including unchanged server amount), independent priority edits, currency/amount coherence, persisted sale disconfirmation and actual normal-notification fallback. Rebuilt the iOS app and passed 46 tests in the three affected suites. Evidence: `/tmp/PriceTracker-review-fixes.xcresult` and `/tmp/PriceTracker-review-fixes.log`.
