# Catalog price-check timestamp

The list and mural header show “Último precio comprobado” with an absolute date
and time, or “sin datos” when no successful check is stored. The caption wraps
at larger text sizes rather than truncating the date.

The value is the maximum `Item.lastSuccessAt` across the items currently in the
catalog, including paused items and independently of search/category/status
filters. It is the latest successful individual price check, **not** confirmation
that an entire refresh batch succeeded. A partial run can advance it; a failed
attempt cannot. A successful check advances it even if the amount is unchanged.
Opening the view, editing metadata, syncing or changing filters does not fabricate
a new timestamp. Removing an item can reveal an older remaining check.

Manual, background and Shortcuts checks use the existing RefreshCoordinator and
persist the same field. Its completion callback now advances the existing local
catalog revision signal, which RootView already observes; foreground activation
and ordinary reloads also read persisted values. No new CloudKit field, database
column or global “last updated” setting is introduced.

Date.FormatStyle uses the view's locale, calendar and time zone, including the
local 12/24-hour convention. The field is recomputed from the current environment,
not cached in a fixed timezone or formatted from the view-opening time.

Validation: `python3 Tools/test-display-titles-host.py` runs 15 host tests, including
five timestamp tests (no success, unchanged price, failure/partial refresh,
persistent reload/paused items, locale/timezone crossing midnight). These and the
generic iOS build passed with Xcode stable 27.0. No simulator was started.
