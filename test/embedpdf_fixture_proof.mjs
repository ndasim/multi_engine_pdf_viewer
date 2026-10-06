import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { init } from '../assets/embedpdf/pdfium.node.mjs';
import { PdfiumDocument, limits } from '../assets/embedpdf_viewer/pdfium_document.mjs';

const fixture = process.argv[2] ?? fileURLToPath(new URL('../../../assets/pdf_harness/6474643.pdf', import.meta.url));
const bytes = await readFile(fixture);
const wasm = await readFile(new URL('../assets/embedpdf/pdfium.wasm', import.meta.url));
const sha256 = (value) => createHash('sha256').update(value).digest('hex');
const api = await init({ wasmBinary: wasm, print: () => {}, printErr: () => {} });
const document = new PdfiumDocument(api);
const outcomes = [];
const bitmapHashes = new Map();
let result;
try {
    const fonts = await Promise.all(['Regular', 'Bold', 'Italic', 'BoldItalic'].map(async style => new Uint8Array(await readFile(new URL(`../assets/embedpdf/fonts/NotoSans-${style}.ttf`, import.meta.url)))));
    document.installFonts(fonts);
    assert.equal(document.open(bytes), 189);
    const paint = (pageNumber) => {
        if (!bitmapHashes.has(pageNumber)) {
            const bitmap = document.render(pageNumber, 320);
            assert.ok(bitmap.pixels.some((value, index) => index % 4 !== 3 && value < 240), 'actual nonblank raster required');
            assert.ok(bitmap.width * bitmap.height <= limits.rasterPixels);
            bitmapHashes.set(pageNumber, { width: bitmap.width, height: bitmap.height, sha256: sha256(bitmap.pixels) });
        }
        return bitmapHashes.get(pageNumber);
    };
    for (let sourcePage = 2; sourcePage <= 4; sourcePage++) {
        const source = paint(sourcePage);
        for (const widget of document.widgets(sourcePage)) {
            const rect = widget.rect;
            const point = { width: source.width, height: source.height, x: (rect.left + rect.width / 2) * source.width, y: (rect.top + rect.height / 2) * source.height };
            const first = document.click(sourcePage, point);
            if (!['NextPage', 'PrevPage'].includes(first.actions[0])) continue;
            assert.equal(first.actions.length, 1);
            assert.equal(Math.abs(first.targetPage - sourcePage), 1);
            for (let repeat = 0; repeat < 10; repeat++) assert.deepEqual(document.click(sourcePage, point), first);
            const target = paint(first.targetPage);
            assert.notEqual(source.sha256, target.sha256);
            outcomes.push({ sourcePage, annotation: widget.index, pdfRect: widget.pdfRect, normalizedRect: rect, point,
                callbackActions: first.actions, navigationCount: 1, targetPage: first.targetPage,
                repeatedClicks: 11, sourceBitmapSha256: source.sha256, targetBitmapSha256: target.sha256 });
        }
    }
    assert.ok(outcomes.some(item => item.callbackActions[0] === 'NextPage'));
    assert.ok(outcomes.some(item => item.callbackActions[0] === 'PrevPage'));
    const outline = await document.outline();
    const flatten = (nodes) => nodes.flatMap(node => [node, ...flatten(node.children)]);
    const nodes = flatten(outline);
    assert.ok(nodes.length > 0);
    assert.ok(nodes.every(node => !node.pageNumber || (node.pageNumber >= 1 && node.pageNumber <= document.pageCount)));
    const query = 'a';
    const matches = document.searchPage(2, query);
    assert.ok(matches.length > 0);
    assert.ok(matches.every(match => match.rects.length > 0));
    assert.equal(document.environments, document.releases, 'all Release callbacks precede pointer removal');
    result = { version: '2.15.1', runtime: 'Node WASM fixture proof, not a mobile/WebView benchmark',
        fixtureSha256: sha256(bytes), fixtureBytes: bytes.length, wasmSha256: sha256(wasm), pageCount: document.pageCount,
        ownership: 'raw published PDFium, one fresh environment per operation; no stock engines environment',
        javascriptPlatform: false, environmentCount: document.environments, synchronousReleases: document.releases,
        outlineNodes: nodes.length, search: { pageNumber: 2, query, matches: matches.length }, outcomes };
} finally { document.close(); }
if (process.argv[3]) await writeFile(process.argv[3], `${JSON.stringify(result, null, 2)}\n`);
console.log(JSON.stringify(result, null, 2));