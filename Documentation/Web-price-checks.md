# Public web price checks

Amazon, generic web items and older PlayStation/Nintendo items now use the common
refresh coordinator for manual checks, batches, background opportunities and
Shortcuts. A successful check commits the observation and `lastSuccessAt` together,
including unchanged prices. Failure records an attempt/error, preserving the last
successful price, currency and timestamp. No CloudKit schema changes are needed.

## Accepted evidence

- JSON-LD Product/Offer, including graph references and ProductGroup variants,
  bound to the saved product URL (or selected Amazon ASIN). Conflicting offers
  are rejected. Stored size/color must match; missing variant evidence fails.
- Microdata scoped to the selected Product and its Offer.
- Product Open Graph price/currency metadata with an explicit matching product URL
  and no unresolved saved variant.
- Amazon's selected ASIN and product title plus a narrowly scoped buy-box price.
  Crossed-out, related, installment and explicitly conditional prices are not used.
  This HTML fallback currently accepts EUR, GBP and USD on amazon.com; other
  currencies need structured evidence. Historical reductions remain distinct
  from claims that a store is running a promotion.

Amounts use decimal arithmetic. Currency must match the saved item's currency.
Ranges, unit prices, subscription/member conditions, expired offers, conflicting
prices, unavailable products and unverified variants fail rather than picking the
lowest value. Unsupported metadata is not equivalent to a free product.

## Network and limits

The default web session is ephemeral with no cookies, credential storage or price
cache. Requests do not use a personal browser session, external price services,
proxies or AI-generated amounts. Requests have bounded time/body size (2 MB), one
start per second per host and a 60–3600-second cooldown on HTTP 429/503 using
Retry-After. Cancellation propagates without a successful observation. Redirects
must still identify the saved product on the same host; login/CAPTCHA/access blocks
are not bypassed. These limits are per app process.

JavaScript-only pages, unsupported markup, larger responses and blocked sites may
still fail. Refresh does not launch WebKit, so it also works in background/Shortcuts
without requiring a foreground browser. Initial add-time metadata capture remains
best effort; refresh applies the stricter verification above. There is no promise
of support for every website or current Amazon page layout.

## Validation and references

Synthetic HTML fixtures cover unrelated products, multiple offers, variants,
JSON-LD graph references, microdata, page metadata, Amazon price blocks, decimal
formats, currency mismatch, blocks, redirects and ranges. URLProtocol fixtures
exercise the real connectors/coordinator, including equal price, fresh timestamp,
first observations, history, errors and rate-limit/cancellation behavior. No live
Amazon account or authenticated website was used for these tests.

- https://schema.org/Offer
- https://schema.org/AggregateOffer
- https://schema.org/priceCurrency
- https://schema.org/UnitPriceSpecification
- https://developers.google.com/search/docs/appearance/structured-data/product-variants
- https://developer.apple.com/documentation/foundation/urlsessionconfiguration/ephemeral

## Additional conservative rejection rules

Every product/OG price and currency field is compared, including against structured
prices when page metadata identifies the same product. Out-of-stock or unknown
availability metadata fails. Offer validFrom, validThrough and priceValidUntil are
all enforced using one injectable instant; a present unparseable value fails.
Date-only bounds use UTC calendar days (end dates include the entire day).
DateTime bounds require a timezone and retain fractional seconds.

Amazon rejection patterns also inspect price-area labels split across DOM nodes
and accessible annotations for installments, recurring payments and membership.
These are extra conservative rejection signals, not a universal guarantee that
unrecognized wording is unconditional; legitimate pages can be rejected if their
price area mixes a total price with financing or membership promotions. The
regressions use synthetic fixtures, not evidence of current Amazon markup.

- https://schema.org/validFrom
- https://schema.org/validThrough
- https://schema.org/priceValidUntil
