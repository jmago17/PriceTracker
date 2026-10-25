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
console.log(JSON.stringify({ kind: 'SYNTHETIC_DOM_MOCK_REAL_PAGECAPTURE_JS', passed: scenarios.length, scenarios }, null, 2));
