#!/usr/bin/env node
// Synthetic DOM mocks for the REAL shipped script. No npm packages, live HTML,
// account data or reimplementation of the pricing algorithm. Swift consumes the
// emitted sanitized fragment; JS must never promote an Amazon amount itself.
const fs = require('fs'), vm = require('vm'), assert = require('assert/strict');
const path = require('path');
const source = fs.readFileSync(path.join(__dirname, '../Resources/PageCapture.js'), 'utf8');
class Element {
    constructor(tag, attrs = {}, children = []) {
        this.nodeType = 1; this.tagName = tag.toUpperCase(); this.attrs = attrs;
        this.childNodes = children.map(c => typeof c === 'string' ? { nodeType: 3, textContent: c } : c);
        for (const child of this.childNodes) child.parentElement = this;
    }
    get textContent() { return this.childNodes.map(c => c.textContent).join(''); }
    get innerText() { return this.textContent; }
    getAttribute(key) { return this.attrs[key] ?? null; }
    hasAttribute(key) { return Object.hasOwn(this.attrs, key); }
    contains(other) { return this === other || this.childNodes.some(c => c.nodeType === 1 && c.contains(other)); }
}
const e = (tag, attrs, ...children) => new Element(tag, attrs, children);
const price = (text, attrs = {}) => e('span', { class: 'a-price', ...attrs }, e('span', { class: 'a-offscreen' }, text));
function capture(root, overrides = {}, url = 'https://www.amazon.es/dp/B07VLJ5JDV') {
    const all = [];
    function walk(n) { if (n.nodeType !== 1) return; all.push(n); n.childNodes.forEach(walk); } walk(root);
    function query(selector) {
        if (Object.hasOwn(overrides, selector)) return [overrides[selector]];
        // Deliberately narrow mock: supports only identifiers used by evidence
        // serialization. Generic capture selectors have explicit overrides.
        const match = selector.match(/^(input)?#([\w-]+)$/);
        if (match) return all.filter(n => n.getAttribute('id') === match[2] && (!match[1] || n.tagName === 'INPUT'));
        if (selector === 'input[name="ASIN"]') return all.filter(n => n.tagName === 'INPUT' && n.getAttribute('name') === 'ASIN');
        return [];
    }
    const document = { baseURI: url, title: 'Cámara sintética', body: root,
        querySelector: s => query(s)[0] || null, querySelectorAll: query,
        getElementById: id => query('#' + id)[0] || null };
    const context = { document, location: { href: url }, URL,
        getComputedStyle: n => ({ display: n.attrs?.style?.includes('display: none') ? 'none' : 'block', visibility: 'visible' }) };
    vm.createContext(context); vm.runInContext(source, context);
    return vm.runInContext('capturePage()', context);
}
const empty = () => e('div', {});
const scenarios = [];
function test(name, run) { run(); scenarios.push(name); }
test('historical selector mock: accessory itemprop cannot win', () => {
    const result = capture(empty(), { '[itemprop="price"]': e('span', {}, '12.39'), 'meta[itemprop="priceCurrency"]': e('meta', {content: 'EUR'}), '[class*="priceToPay" i]': e('span', {}, '1.090,99 €') });
    assert.equal(result.priceCents, undefined);
});
test('historical selector mock: monthly current-price is not a total', () => {
    assert.equal(capture(empty(), { '[class*="current-price" i]': e('span', {}, '12,39 € al mes') }).priceCents, undefined);
});
const fixture = e('div', {}, e('input', {id:'ASIN', value:'B07VLJ5JDV'}), e('span', {id:'productTitle'}, 'Cámara sintética'),
    e('div', {id:'corePrice_feature_div'}, price('1.090,99 €'), price('12,39 €', {hidden:''}), price('13,39 €', {style:'display: none'})),
    e('div', {id:'recommendations'}, price('14,39 €')), e('div', {id:'private-account'}, 'NOT-TO-CAPTURE'));
test('pricing fragment preserves identity and total but not hidden/recommended/account content', () => {
    const result = capture(fixture);
    assert.equal(result.priceCents, undefined);
    assert.match(result.amazonPriceHTML, /B07VLJ5JDV/); assert.match(result.amazonPriceHTML, /1.090,99/);
    assert.doesNotMatch(result.amazonPriceHTML, /12,39|13,39|14,39|NOT-TO-CAPTURE/);
});
test('financing annotations survive serialization for the Swift validator', () => {
    const node = e('div', {}, e('input',{id:'ASIN', value:'B07VLJ5JDV'}), e('span',{id:'productTitle'}, 'Demo'),
        e('div',{id:'corePrice_feature_div'}, e('img',{alt:'3 pagos al mes', src:'private-url'}), price('12,39 €')));
    const html = capture(node).amazonPriceHTML;
    assert.match(html, /3 pagos al mes/); assert.doesNotMatch(html, /private-url/);
});
test('other stores preserve existing permissive contract (including Apple desde)', () => {
    const result = capture(empty(), { '[itemprop="price"]': e('span', {}, 'Desde 1.299,00 €') }, 'https://www.apple.com/es/shop/buy-mac');
    assert.equal(result.priceCents, 129900); assert.equal(result.currency, 'EUR');
    assert.equal(result.amazonPriceHTML, undefined);
});
test('oversized fragments fail closed', () => {
    const node = e('div',{}, e('div',{id:'corePrice_feature_div'}, 'a'.repeat(130000)));
    assert.equal(capture(node).amazonPriceHTML, null);
});
test('ancestor ASIN and recommendation scope survive extraction', () => {
    const root = e('div', {'data-asin':'B000000001', id:'recommendations'},
        e('input',{id:'ASIN',value:'B07VLJ5JDV'}), e('span',{id:'productTitle'}, 'Demo'),
        e('div',{id:'corePrice_feature_div'}, price('12,39 €')));
    const html = capture(root).amazonPriceHTML;
    assert.match(html, /data-asin="B000000001"/); assert.match(html, /recommendations/);
});
const product = (...children) => e('div', {}, e('input', {id:'ASIN', value:'B07VLJ5JDV'}),
    e('span', {id:'productTitle'}, 'Demo'), e('div', {id:'corePrice_feature_div'}, ...children));
test('R1 button financing aria-label and title survive on a neutral wrapper', () => {
    const result = capture(product(e('button', {'aria-label':'3 pagos al mes', title:'Financiación'}, 'i'), price('12,39 €')));
    assert.match(result.amazonPriceHTML, /<div aria-label="3 pagos al mes" title="Financiación">i<\/div>/);
    assert.equal(result.priceCents, undefined);
});
test('R1 link retains conflicting ASIN and recommendation context but not URL', () => {
    const html = capture(product(e('a', {'data-asin':'B000000001', class:'recommended-accessory', href:'PRIVATE-LINK'}, price('12,39 €')))).amazonPriceHTML;
    assert.match(html, /<div class="recommended-accessory" data-asin="B000000001">/);
    assert.doesNotMatch(html, /href|PRIVATE-LINK|<a\b/);
});
test('R1 arbitrary wrappers retain identity and conditions (not a two-tag fix)', () => {
    for (const tag of ['article', 'aside', 'details', 'dl', 'x-price-context', 'svg']) {
        const html = capture(product(e(tag, {'data-asin':'B000000001', 'aria-label':'3 pagos al mes', title:'mensual', class:'accessory'}, price('12,39 €')))).amazonPriceHTML;
        assert.match(html, /data-asin="B000000001" aria-label="3 pagos al mes" title="mensual"/);
        assert.match(html, /class="accessory"/);
    }
});
test('malicious attributes and non-ASIN values never cross the boundary', () => {
    const html = capture(product(e('a', {href:'PRIVATE-HREF', action:'PRIVATE-ACTION', onclick:'PRIVATE-EVENT',
        style:'PRIVATE-STYLE', value:'PRIVATE-VALUE', name:'PRIVATE-NAME', 'data-token':'PRIVATE-TOKEN',
        title:'safe " < & >', 'aria-label':'safe label'}, price('12,39 €')),
        e('input', {name:'csrf', value:'PRIVATE-INPUT'}))).amazonPriceHTML;
    assert.doesNotMatch(html, /PRIVATE-|href=|action=|onclick=|style=|data-token=/);
    assert.match(html, /title="safe &quot; &lt; &amp; &gt;"/);
    assert.match(html, /aria-label="safe label"/);
});
test('scripts and other inert content never become text evidence', () => {
    const html = capture(product(price('12,39 €'), ...['script','style','template','noscript'].map(tag => e(tag, {}, 'PRIVATE-SCRIPT 3 pagos al mes')))).amazonPriceHTML;
    assert.doesNotMatch(html, /PRIVATE-SCRIPT|3 pagos|script|style|template/);
});
test('unknown wrappers still exclude hidden and aria duplicate prices', () => {
    const html = capture(product(price('12,39 €'), e('button', {'aria-hidden':'true'}, price('99,99 €')),
        e('article', {hidden:''}, price('88,88 €')), e('aside', {style:'display: none'}, price('77,77 €')))).amazonPriceHTML;
    assert.match(html, /12,39 €/); assert.doesNotMatch(html, /99,99|88,88|77,77/);
});
test('legitimate 12.39 total retains usable evidence without promoting a JS number', () => {
    const result = capture(product(e('article', {title:'Precio total'}, price('12,39 €'))));
    assert.match(result.amazonPriceHTML, /id="ASIN" value="B07VLJ5JDV"/);
    assert.match(result.amazonPriceHTML, /title="Precio total"/);
    assert.match(result.amazonPriceHTML, /class="a-offscreen">12,39 €/);
    assert.equal(result.priceCents, undefined);
});
test('form and embedded content fail closed, never export a partial total', () => {
    for (const tag of ['form', 'textarea', 'select', 'iframe', 'object', 'embed']) {
        const result = capture(product(price('12,39 €'), e(tag, {action:'PRIVATE'}, 'PRIVATE-CONTENT')));
        assert.equal(result.amazonPriceHTML, null); assert.equal(result.priceCents, undefined);
        assert.equal(result.pageURL, 'https://www.amazon.es/dp/B07VLJ5JDV');
        assert.equal(result.title, 'Cámara sintética');
    }
});
test('incremental budgets fail closed for text, escape expansion, attributes, nodes and depth', () => {
    let deep = price('12,39 €');
    for (let i = 0; i < 45; i++) deep = e('article', {}, deep);
    const cases = [product(price('12,39 €'), 'x'.repeat(2000000)),
        product(price('12,39 €'), '&'.repeat(25000)),
        product(e('article', {title:'x'.repeat(2000000)}, price('12,39 €'))),
        product(price('12,39 €'), ...Array.from({length:6001}, () => e('span', {}))), product(deep),
        e('div', {'data-asin':'x'.repeat(2000000)}, product(price('12,39 €')))];
    for (const node of cases) {
        const result = capture(node);
        assert.equal(result.amazonPriceHTML, null); assert.equal(result.priceCents, undefined);
        assert.equal(result.pageURL, 'https://www.amazon.es/dp/B07VLJ5JDV');
    }
});
console.log(JSON.stringify({ kind: 'SYNTHETIC_DOM_MOCK_REAL_PAGECAPTURE_JS', passed: scenarios.length, scenarios }, null, 2));
