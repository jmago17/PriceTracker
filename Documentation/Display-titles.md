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

Validation requires a shorter, ordered extraction of existing lexical tokens,
preserving the first three identity words, model identifiers, capacities/units,
explicit variants and color words. Capitalization alone does not make promotional
words mandatory. For recognized watch accessories, Apple Watch remains required,
while bounded lists of compatible sizes/generations may be omitted as a whole.
Partial selection from a list is rejected unless Item explicitly supplies that
variant. A sole size is preserved when structured variant data is absent.
Punctuation may be cleaned without changing tokens (e.g. `49mm,Negro` permits
extracting `Negro`). Unknown compatibility grammar retains numeric identifiers.
Policy/cache version 2 invalidates entries from the original capitalization rule.
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

### Verification on 2026-10-12 (initial v1 implementation)

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

### Capitalized Fullmosa regression (v2)

`Tools/test-display-titles-host.py` runs the production cache and its unit tests
on macOS with Xcode stable, without booting a simulator. It copies the real
production value types and cache into a temporary Swift package; it does not
stub the generator. The UIKit layout test stays in the iOS test target.
The exact screenshot title is covered, including `49mm,Negro` and the Ultra/Series/
SE compatibility lists. The accepted extraction is `Fullmosa Correa Magnética
Para Apple Watch Negro`; tests reject invented models/colors, partial list
selection, omission of an explicit selected size and removal of a sole size.

Validation: all 10 host cache tests passed; generic iOS build succeeded with
Xcode stable 27.0. No simulator was started for this correction.
