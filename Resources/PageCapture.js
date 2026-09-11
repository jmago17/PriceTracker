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

function capturePage() {
    const title = priceTrackerFirst([
        '[itemprop="name"]',
        'main h1',
        '[role="main"] h1',
        'h1',
        'meta[property="og:title"]',
        'meta[name="twitter:title"]'
    ]) || document.title || null;

    const description = priceTrackerFirst([
        '[itemprop="description"]',
        'meta[property="og:description"]',
        'meta[name="description"]'
    ]);

    const imageURL = priceTrackerURL(document.querySelector('[itemprop="image"]'))
        || priceTrackerURL(document.querySelector('meta[property="og:image"]'))
        || priceTrackerURL(document.querySelector('meta[name="twitter:image"]'))
        || priceTrackerLargestProductImage();

    const priceText = priceTrackerFirst([
        '[itemprop="price"]',
        'meta[property="product:price:amount"]',
        'meta[property="og:price:amount"]',
        '[data-testid*="current-price" i]',
        '[data-qa*="price"]',
        '[class*="price--current" i]',
        '[class*="current-price" i]',
        '[class*="sale-price" i]',
        'main [class*="price" i]',
        '[role="main"] [class*="price" i]'
    ]);
    const priceCents = priceTrackerPriceCents(priceText);
    const currency = priceTrackerCurrency(priceText);

    const category = priceTrackerFirst([
        'meta[property="product:category"]',
        '[itemprop="category"]'
    ]);
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
