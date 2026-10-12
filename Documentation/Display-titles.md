# Local display titles and adaptive mural

Catalog rows and mural cards use `CatalogItemTitle`. The visible title always
has a three-line tail limit, including accessibility text sizes and devices
without Apple Intelligence. VoiceOver and the detail view retain the original
name. Search, sharing, exports, persistence and CloudKit still use `Item.title`.

`DisplayTitleCache` requests a title from Foundation Models using only the
existing title and known size/color; there is no page fetch or cloud inference.
A request key includes the logical item identity, exact title, variant and
format/prompt version. Change the version when changing derivation policy.
Successful extractions persist atomically in Application Support, excluded
from backup. Corrupt or obsolete entries are ignored. Disk failures are benign.
The disposable cache retains at most 500 entries.

Validation requires a shorter, ordered extraction of existing words, preserves
the first three words, numbers, capitalized names and known variants present in
the original. It deliberately rejects uncertain abbreviations, including some
title-case product names; the original then receives the same three-line limit.
No model output can write to an Item. Inference is serialized and deduplicated.
Unavailable/invalid results have a five-minute, memory-only retry cooldown.
Cancelled view tasks do not publish results; shared inference may complete to
warm the cache. The view also checks the full request identity when displaying
state, preventing a previous title's result from appearing after edits.

The iPad uses the iPhone mural card surface and bottom controls. Width-driven
columns scale with Dynamic Type and collapse to one column at accessibility
sizes. iPad remains a mural in compact Split View. Navigation, selection and
context menus keep their existing wrappers; controls remain in a safe-area inset.

## Validation

Use `/Applications/Xcode.app/Contents/Developer` explicitly as `DEVELOPER_DIR`.
`DisplayTitleCacheTests` covers extraction, canonical-name preservation,
persistent/versioned caches, corrupt data, unavailable/error fallback,
deduplication, cancellation and edited titles while inference is in flight.
`CatalogTitleLayoutTests` measures long fallback titles at widths 140/240/600
and ordinary, XXXL and maximum accessibility text sizes.
`ScreenshotTests.testAdaptiveMuralLargeTextControlsAndLastCard` covers the
shared mural's large-text geometry, last card, search keyboard and real metadata.
Existing mural tests cover navigation, selection, filters and portrait/landscape.
On-device model quality still requires eligible hardware with Apple Intelligence
enabled; deterministic tests inject the generator and simulators use fallback.

### Verification on 2026-10-12

- Xcode stable 27.0 (27A266a), explicit developer directory: simulator build succeeded.
- Unit suite: 136 tests in 27 suites passed, including the eight new cache/layout tests.
- iPhone 17 Pro: four UI cases passed (adaptive large text/last card/keyboard,
  opt-in/navigation/selection, staggered layout/filters/actions, accessibility audit).
  Xcode stalled after reporting zero failures while collecting the UI results;
  its process was stopped after the cases finished. This is not a successful CLI exit.
- iPad Pro: the device booted, but the runner never started; orientation and iPad
  UI checks remain unverified. The blocked attempt was stopped and device shut down.
- Actual Split View interaction and live Foundation Models output on eligible
  hardware remain manual checks; fallback layout is covered at narrow/wide widths.
