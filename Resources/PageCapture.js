function priceTrackerText(element) {
    if (!element) return null;
    const value = element.getAttribute("content")
        || element.getAttribute("data-price")
        || element.getAttribute("value")
        || element.textContent;
    if (!value) return null;
    const trimmed = value.replace(/\s+/g, " ").trim();
    return trimmed.length ? trimmed : null;
}

function priceTrackerFirst(selectors) {
    for (const selector of selectors) {
        const value = priceTrackerText(document.querySelector(selector));
        if (value) return value;
    }
    return null;
}

function priceTrackerURL(element) {
    if (!element) return null;
    const value = element.getAttribute("content")
        || element.getAttribute("href")
        || element.currentSrc
        || element.getAttribute("src");
    if (!value) return null;
    try {
        return new URL(value, document.baseURI).href;
    } catch (_) {
        return null;
    }
}

function priceTrackerPriceCents(value) {
    if (!value) return null;
    const match = value.match(/\d[\d\s\u00a0'.,]*/);
    if (!match) return null;

    let number = match[0].replace(/[\s\u00a0']/g, "");
    const comma = number.lastIndexOf(",");
    const dot = number.lastIndexOf(".");
    const separator = Math.max(comma, dot);
    if (separator >= 0 && number.length - separator - 1 <= 2) {
        const integer = number.slice(0, separator).replace(/[.,]/g, "");
        const decimal = number.slice(separator + 1);
        number = integer + "." + decimal;
    } else {
        number = number.replace(/[.,]/g, "");
    }

    const parsed = Number(number);
    return Number.isFinite(parsed) ? Math.round(parsed * 100) : null;
}

function priceTrackerCurrency(priceText) {
    const explicit = priceTrackerFirst([
        'meta[itemprop="priceCurrency"]',
        '[itemprop="priceCurrency"]',
        'meta[property="product:price:currency"]',
        'meta[property="og:price:currency"]'
    ]);
    if (explicit) return explicit.toUpperCase();
    if (!priceText) return null;
    if (priceText.includes("€") || /\bEUR\b/i.test(priceText)) return "EUR";
    if (priceText.includes("£") || /\bGBP\b/i.test(priceText)) return "GBP";
    if (priceText.includes("¥") || /\bJPY\b/i.test(priceText)) return "JPY";
    if (/\bCAD\b/i.test(priceText)) return "CAD";
    if (/\bAUD\b/i.test(priceText)) return "AUD";
    if (priceText.includes("$") || /\bUSD\b/i.test(priceText)) return "USD";
    return null;
}

function priceTrackerLargestProductImage() {
    const candidates = Array.from(document.querySelectorAll(
        '[itemprop="image"], main img, [role="main"] img, article img'
    ));
    candidates.sort((left, right) => {
        const leftArea = (left.naturalWidth || left.width || 0) * (left.naturalHeight || left.height || 0);
        const rightArea = (right.naturalWidth || right.width || 0) * (right.naturalHeight || right.height || 0);
        return rightArea - leftArea;
    });
    return priceTrackerURL(candidates[0]);
}

function priceTrackerHydratedPrice(product) {
    if (!product || typeof product !== "object") return null;
    let value = product.price;
    let currency = product.currency || product.currencyCode || null;
    if (value && typeof value === "object") {
        currency = currency || value.currencyCode || value.priceCurrency || null;
        value = value.value ?? value.price ?? value.lowPrice ?? null;
    }

    let offers = product.offers;
    if (Array.isArray(offers)) offers = offers[0];
    if ((value === null || value === undefined) && offers && typeof offers === "object") {
        value = offers.price ?? offers.lowPrice ?? null;
        currency = currency || offers.priceCurrency || offers.currencyCode || null;
    }

    const cents = priceTrackerPriceCents(value === null || value === undefined ? null : String(value));
    return cents === null || !currency ? null : { cents, currency: String(currency).toUpperCase() };
}

function priceTrackerHydratedImage(value, depth = 0) {
    if (!value || depth > 5) return null;
    if (typeof value === "string") {
        try {
            return new URL(value, document.baseURI).href;
        } catch (_) {
            return null;
        }
    }
    if (Array.isArray(value)) {
        for (const item of value) {
            const result = priceTrackerHydratedImage(item, depth + 1);
            if (result) return result;
        }
        return null;
    }
    if (typeof value !== "object") return null;
    return priceTrackerHydratedImage(value.contentUrl || value.url || value.link, depth + 1)
        || priceTrackerHydratedImage(value.images, depth + 1)
        || priceTrackerHydratedImage(value.imageGroups, depth + 1);
}

function priceTrackerHydratedProduct() {
    const script = document.getElementById("__NEXT_DATA__");
    if (!script || !script.textContent) return null;

    let root;
    try {
        root = JSON.parse(script.textContent);
    } catch (_) {
        return null;
    }

    const candidates = [];
    let visited = 0;
    function collect(value, depth) {
        if (!value || typeof value !== "object" || depth > 8 || visited > 10_000) return;
        visited += 1;
        if (Array.isArray(value)) {
            for (const item of value) collect(item, depth + 1);
            return;
        }
        const name = value.name || value.title;
        const price = priceTrackerHydratedPrice(value);
        if (typeof name === "string" && name.trim() && price) {
            candidates.push({ value, price });
        }
        for (const nested of Object.values(value)) collect(nested, depth + 1);
    }
    collect(root, 0);

    candidates.sort((left, right) => {
        const score = candidate => {
            const product = candidate.value;
            const type = String(product._type || product["@type"] || "").toLowerCase();
            return (type.includes("product") ? 4 : 0)
                + (product.id || product.sku ? 2 : 0)
                + (priceTrackerHydratedImage(product.imageGroups || product.image || product.images) ? 1 : 0);
        };
        return score(right) - score(left);
    });
    return candidates[0] || null;
}

function capturePage() {
    const hydrated = priceTrackerHydratedProduct();
    const hydratedProduct = hydrated ? hydrated.value : null;
    const title = priceTrackerFirst([
        '[itemprop="name"]',
        'main h1',
        '[role="main"] h1',
        'h1',
        'meta[property="og:title"]',
        'meta[name="twitter:title"]'
    ]) || (hydratedProduct && (hydratedProduct.name || hydratedProduct.title)) || document.title || null;

    const description = priceTrackerFirst([
        '[itemprop="description"]',
        'meta[property="og:description"]',
        'meta[name="description"]'
    ]) || (hydratedProduct && (
        hydratedProduct.description
        || hydratedProduct.shortDescription
        || hydratedProduct.longDescription
    ));

    const imageURL = priceTrackerURL(document.querySelector('[itemprop="image"]'))
        || priceTrackerURL(document.querySelector('meta[property="og:image"]'))
        || priceTrackerURL(document.querySelector('meta[name="twitter:image"]'))
        || priceTrackerLargestProductImage()
        || (hydratedProduct && priceTrackerHydratedImage(
            hydratedProduct.imageGroups || hydratedProduct.image || hydratedProduct.images
        ));

    const priceText = priceTrackerFirst([
        '#corePrice_feature_div [class*="priceToPay" i]',
        '#corePriceDisplay_desktop_feature_div [class*="priceToPay" i]',
        '#apex_desktop [class*="priceToPay" i]',
        '#apex_mobile [class*="priceToPay" i]',
        '[itemprop="price"]',
        'meta[property="product:price:amount"]',
        'meta[property="og:price:amount"]',
        '[data-testid*="current-price" i]',
        '[data-qa*="price"]',
        '[class*="priceToPay" i]',
        '[class*="price-to-pay" i]',
        '[class*="price--current" i]',
        '[class*="current-price" i]',
        '[class*="sale-price" i]',
        'main [class*="price" i]',
        '[role="main"] [class*="price" i]'
    ]);
    const domPriceCents = priceTrackerPriceCents(priceText);
    const domCurrency = priceTrackerCurrency(priceText);
    const priceCents = domPriceCents !== null && domCurrency
        ? domPriceCents
        : (hydrated ? hydrated.price.cents : null);
    const currency = domPriceCents !== null && domCurrency
        ? domCurrency
        : (hydrated ? hydrated.price.currency : null);

    const category = priceTrackerFirst([
        'meta[property="product:category"]',
        '[itemprop="category"]'
    ]) || (hydratedProduct && (hydratedProduct.category || hydratedProduct.primaryCategoryId));
    const canonicalURL = priceTrackerURL(document.querySelector('link[rel="canonical"]'));

    const result = { pageURL: location.href };
    if (canonicalURL) result.canonicalURL = canonicalURL;
    if (title) result.title = title;
    if (description) result.description = description;
    if (imageURL) result.imageURL = imageURL;
    if (priceCents !== null && currency) {
        result.priceCents = priceCents;
        result.currency = currency;
    }
    if (category) result.category = category;
    return result;
}

class PriceTrackerExtensionPreprocessing {
    run(extensionArguments) {
        extensionArguments.completionFunction(capturePage());
    }
}

var ExtensionPreprocessingJS = new PriceTrackerExtensionPreprocessing();
