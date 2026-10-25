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


function priceTrackerJSONLDProducts() {
    const products = [];
    function collect(value, depth) {
        if (!value || typeof value !== "object" || depth > 6) return;
        if (Array.isArray(value)) {
            for (const item of value) collect(item, depth + 1);
            return;
        }
        const type = [].concat(value["@type"] || []).join(" ").toLowerCase();
        if (type.includes("product")) products.push(value);
        if (value["@graph"]) collect(value["@graph"], depth + 1);
        if (value.hasVariant) collect(value.hasVariant, depth + 1);
    }
    for (const script of document.querySelectorAll('script[type="application/ld+json"]')) {
        try {
            collect(JSON.parse(script.textContent || ""), 0);
        } catch (_) {}
    }
    return products;
}

function priceTrackerCleanVariant(value) {
    if (value === null || value === undefined) return null;
    if (typeof value === "object") value = value.name || value.value || null;
    if (value === null || value === undefined) return null;
    const text = String(value).replace(/\s+/g, " ").trim();
    if (!text || text.length > 40) return null;
    if (/^(selecciona|elige|seleccione|choose|select|pick)\b/i.test(text)) return null;
    return text;
}

function priceTrackerSelectedOption(keywords) {
    const pattern = keywords.join("|");
    const regex = new RegExp(pattern, "i");
    for (const select of document.querySelectorAll("select")) {
        const name = (select.name || "") + " " + (select.id || "") + " " + (select.getAttribute("aria-label") || "");
        if (!regex.test(name)) continue;
        const option = select.selectedOptions && select.selectedOptions[0];
        const value = priceTrackerCleanVariant(option && option.textContent);
        if (value && option.value !== "") return value;
    }
    const containers = Array.from(document.querySelectorAll("[class], [id], [data-testid]")).filter(element => {
        const label = (element.className && element.className.baseVal === undefined ? element.className : "")
            + " " + (element.id || "") + " " + (element.getAttribute("data-testid") || "");
        return regex.test(label);
    }).slice(0, 40);
    for (const container of containers) {
        const chosen = container.querySelector('[aria-checked="true"], [aria-pressed="true"], [aria-selected="true"], input:checked + label, .selected, .is-selected, .active');
        const value = priceTrackerCleanVariant(chosen && (chosen.getAttribute("aria-label") || chosen.getAttribute("title") || chosen.textContent));
        if (value) return value;
    }
    return null;
}

function priceTrackerURLParameter(keys) {
    try {
        const params = new URL(location.href).searchParams;
        for (const key of keys) {
            const value = priceTrackerCleanVariant(params.get(key));
            if (value) return value;
        }
    } catch (_) {}
    return null;
}

function priceTrackerVariant(kind) {
    const isSize = kind === "size";
    const amazon = priceTrackerText(document.querySelector(isSize
        ? "#variation_size_name .selection, #inline-twister-expanded-dimension-text-size_name"
        : "#variation_color_name .selection, #inline-twister-expanded-dimension-text-color_name"));
    if (priceTrackerCleanVariant(amazon)) return priceTrackerCleanVariant(amazon);

    const itemprop = priceTrackerText(document.querySelector(isSize ? '[itemprop="size"]' : '[itemprop="color"]'));
    if (priceTrackerCleanVariant(itemprop)) return priceTrackerCleanVariant(itemprop);

    for (const product of priceTrackerJSONLDProducts()) {
        const value = priceTrackerCleanVariant(isSize ? product.size : product.color);
        if (value) return value;
    }

    return priceTrackerSelectedOption(isSize ? ["size", "talla", "taille", "groesse", "größe"] : ["colou?r", "farbe", "couleur"])
        || priceTrackerURLParameter(isSize ? ["size", "talla", "taille"] : ["color", "colour", "couleur"]);
}

function priceTrackerPageText() {
    const root = document.querySelector('#dp-container, #ppd, main, [role="main"], article') || document.body;
    if (!root) return null;
    const text = (root.innerText || root.textContent || "")
        .split("\n")
        .map(line => line.replace(/\s+/g, " ").trim())
        .filter(line => line.length > 1)
        .join("\n");
    if (!text) return null;
    return text.length > 12000 ? text.slice(0, 12000) : text;
}

function priceTrackerAmazonEvidence() {
    // Do not promote a number in JS: the same Swift validator consumes this
    // bounded pricing-only fragment for Safari, WebKit and URLSession.
    // No forms, links, scripts, cookies or full-page/account snapshots cross
    // the extension boundary. Unknown layouts deliberately save without price.
    const maxLength = 120000;
    const parts = [];
    let length = 0, visited = 0;
    function emit(value) {
        if (value.length > maxLength - length) throw new Error('pricing fragment too large');
        parts.push(value); length += value.length;
    }
    function escaped(value) {
        // Check BEFORE escaping: even one enormous text/attribute must fail
        // without constructing an enormous escaped copy. Escaping can expand
        // this bounded input; emit checks the remaining output budget as well.
        value = String(value);
        if (value.length > maxLength - length) throw new Error('pricing fragment too large');
        emit(value.replace(/&/g, '&amp;').replace(/</g, '&lt;')
            .replace(/>/g, '&gt;').replace(/"/g, '&quot;'));
    }
    function hidden(node) {
        let depth = 0;
        for (let p = node; p && p.nodeType === 1; p = p.parentElement) {
            if (++depth > 40) throw new Error('pricing ancestry too deep');
            if (p.hasAttribute('hidden') || p.getAttribute('aria-hidden') === 'true') return true;
            if (typeof getComputedStyle === 'function') {
                const style = getComputedStyle(p);
                if (style.display === 'none' || style.visibility === 'hidden') return true;
            }
        }
        return false;
    }
    function attributes(node, keys) {
        for (const key of keys) {
            if (!node.hasAttribute(key)) continue;
            emit(' ' + key + '="'); escaped(node.getAttribute(key)); emit('"');
        }
    }
    function serialize(node, depth = 0) {
        if (++visited > 6000 || depth > 40) throw new Error('pricing fragment too large');
        if (node.nodeType === 3) { escaped(node.textContent || ''); return; }
        if (node.nodeType !== 1) return;
        const tag = node.tagName.toLowerCase();
        const asinInput = tag === 'input' && (node.getAttribute('id') === 'ASIN' || node.getAttribute('name') === 'ASIN');
        if (tag === 'input' && !asinInput) return;
        // These subtrees are not visible evidence. Never flatten script/style
        // contents into price text or export non-ASIN form values.
        if (['script', 'style', 'template', 'noscript'].includes(tag)) return;
        if (!asinInput && hidden(node)) return;
        // Unknown ordinary wrappers keep ALL safe context on a neutral tag,
        // rather than silently detaching descendants from identity/conditions.
        // Interactive form/embedded payloads cannot be represented safely here.
        if (['form', 'textarea', 'select', 'iframe', 'object', 'embed'].includes(tag)) {
            throw new Error('unsupported pricing context');
        }
        const safeTag = ['div', 'span', 'p', 'b', 'strong', 'input', 'label', 'section', 'img'].includes(tag) ? tag : 'div';
        emit('<' + safeTag);
        attributes(node, ['id', 'class', 'data-asin', 'aria-label', 'title', 'alt']);
        // The sole input allowed is Amazon's selected ASIN (normally hidden).
        // name/value on ANY other wrapper are not price context.
        if (asinInput) attributes(node, ['name', 'value']);
        emit('>');
        if (!['input', 'img'].includes(safeTag)) {
            for (const child of node.childNodes || []) serialize(child, depth + 1);
            emit('</' + safeTag + '>');
        }
    }
    try {
        const selectors = ['input#ASIN', 'input[name="ASIN"]', '#productTitle',
            '#variation_size_name', '#variation_color_name', '#availability',
            '#corePriceDisplay_desktop_feature_div', '#corePrice_feature_div',
            '#apex_desktop', '#apex_mobile', '#priceblock_ourprice', '#priceblock_dealprice'];
        const roots = new Set();
        let selected = 0;
        for (const selector of selectors) {
            for (const node of document.querySelectorAll(selector)) {
                if (++selected > 6000) throw new Error('too many pricing roots');
                roots.add(node);
            }
        }
        for (const node of roots) {
            if ([...roots].some(p => p !== node && p.contains(node))) continue;
            const ancestry = [];
            let wrappers = 0;
            // Keep the existing ASIN/recommendation ancestry guard. Account
            // siblings are never serialized; every wrapper spends the budget.
            for (let p = node.parentElement; p; p = p.parentElement) {
                if (ancestry.length >= 40 || ++visited > 6000) throw new Error('pricing ancestry too deep');
                ancestry.push(p);
            }
            for (const p of ancestry.reverse()) {
                const asin = p.getAttribute('data-asin');
                const id = p.getAttribute('id') || '', className = p.getAttribute('class') || '';
                if (id.length + className.length + 1 > maxLength - length) throw new Error('pricing context too large');
                const context = id + ' ' + className;
                const related = /recommend|accessor|sponsored|frequently[-_ ]?bought|sims-|similar|bundle/i.test(context);
                if (asin || related) {
                    emit('<div');
                    if (asin) { emit(' data-asin="'); escaped(asin); emit('"'); }
                    if (related) { emit(' class="'); escaped(context); emit('"'); }
                    emit('>'); wrappers++;
                }
            }
            serialize(node);
            for (let i = 0; i < wrappers; i++) emit('</div>');
        }
        return parts.join('');
    } catch (_) { return null; }
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

    const isAmazon = /(^|\.)amazon\.[a-z.]+$/i.test(new URL(location.href).hostname);
    const result = { pageURL: location.href };
    if (isAmazon) result.amazonPriceHTML = priceTrackerAmazonEvidence();
    if (canonicalURL) result.canonicalURL = canonicalURL;
    if (title) result.title = title;
    if (description) result.description = description;
    if (imageURL) result.imageURL = imageURL;
    if (!isAmazon && priceCents !== null && currency) {
        result.priceCents = priceCents;
        result.currency = currency;
    }
    if (category) result.category = category;
    const size = priceTrackerVariant("size");
    if (size) result.size = size;
    const color = priceTrackerVariant("color");
    if (color) result.color = color;
    const pageText = priceTrackerPageText();
    if (pageText) result.pageText = pageText;
    return result;
}

class PriceTrackerExtensionPreprocessing {
    run(extensionArguments) {
        extensionArguments.completionFunction(capturePage());
    }
}

var ExtensionPreprocessingJS = new PriceTrackerExtensionPreprocessing();
