import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import { init } from '../assets/embedpdf/pdfium.node.mjs';
import { PdfiumDocument, limits, rasterSize } from '../assets/embedpdf_viewer/pdfium_document.mjs';

test('final raster dimensions and product obey every budget, including extreme aspect ratios', () => {
    for (const [pageWidth, pageHeight] of [[0.001, 10000000], [10000000, 0.001], [612, 792],
    [1e308, 1e308], [Number.MIN_VALUE, 1], [1, Number.MIN_VALUE]]) {
        for (const budget of [1, 2, 17, 256, 4096, limits.rasterPixels, limits.rasterPixels * 2]) {
            const { width, height } = rasterSize(pageWidth, pageHeight, 1080, budget);
            const maximum = Math.min(budget, limits.rasterPixels);
            assert.ok(Number.isSafeInteger(width) && width > 0 && width <= maximum);
            assert.ok(Number.isSafeInteger(height) && height > 0 && height <= maximum);
            assert.ok(width * height <= maximum);
        }
    }
});

test('invalid geometry and requests are rejected without native allocation', () => {
    for (const value of [0, -1, NaN, Infinity, -Infinity, '612', null]) {
        assert.throws(() => rasterSize(value, 792, 1080), { name: 'embedpdf-fatal-page-size' });
        assert.throws(() => rasterSize(612, value, 1080), { name: 'embedpdf-fatal-page-size' });
        assert.throws(() => rasterSize(612, 792, value), { name: 'embedpdf-command-raster-range' });
        assert.throws(() => rasterSize(612, 792, 1080, value), { name: 'embedpdf-command-raster-range' });
    }
});

test('annotation limit is fatal before bitmap, form setup or click work and always closes the page', () => {
    const calls = [];
    const pdf = new PdfiumDocument({
        pdfium: {}, PDFiumExt_Init() { },
        FPDF_LoadPage: () => { calls.push('load'); return 2; },
        FPDFPage_GetAnnotCount: () => limits.annotations + 1,
        FPDF_ClosePage: () => calls.push('close'),
        FPDFBitmap_Create: () => assert.fail('must not allocate bitmap'),
        FPDFDOC_InitFormFillEnvironment: () => assert.fail('must not initialize forms'),
    });
    pdf.document = 1;
    pdf.pageCount = 1;
    for (const operation of [() => pdf.render(1, 32, 256), () => pdf.widgets(1),
    () => pdf.click(1, { pdf: true, x: 1, y: 1 })]) {
        assert.throws(operation, { name: 'embedpdf-fatal-annotation-limit' });
    }
    assert.deepEqual(calls, ['load', 'close', 'load', 'close', 'load', 'close']);
});

function syntheticPdf({ mediaBox = '0 0 612 200', annotations = 0, text = false } = {}) {
    const objects = [
        '<< /Type /Catalog /Pages 2 0 R >>',
        '<< /Type /Pages /Count 1 /Kids [3 0 R] >>',
        `<< /Type /Page /Parent 2 0 R /MediaBox [${mediaBox}] /Contents 4 0 R
            ${annotations ? `/Annots [${Array.from({ length: annotations }, (_, index) => `${index + 5} 0 R`).join(' ')}]` : ''}
            ${text ? '/Resources << /Font << /F1 5 0 R /F2 6 0 R /F3 7 0 R /F4 8 0 R >> >>' : ''} >>`,
    ];
    const content = text ? [1, 2, 3, 4].map((font, index) => `BT /F${font} 24 Tf 20 ${160 - index * 35} Td (CVL) Tj ET`).join('\n') : '';
    objects.push(`<< /Length ${Buffer.byteLength(content)} >>\nstream\n${content}\nendstream`);
    if (text) {
        for (const face of ['Helvetica', 'Helvetica-Bold', 'Helvetica-Oblique', 'Helvetica-BoldOblique']) {
            objects.push(`<< /Type /Font /Subtype /Type1 /BaseFont /${face} >>`);
        }
    }
    for (let index = 0; index < annotations; index++) {
        objects.push(`<< /Type /Annot /Subtype /Widget /FT /Btn /T (bounded-${index}) /Rect [1 1 2 2] >>`);
    }
    let pdf = '%PDF-1.7\n';
    const offsets = [0];
    objects.forEach((object, index) => {
        offsets.push(Buffer.byteLength(pdf));
        pdf += `${index + 1} 0 obj\n${object}\nendobj\n`;
    });
    const xref = Buffer.byteLength(pdf);
    pdf += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`;
    pdf += offsets.slice(1).map(offset => `${String(offset).padStart(10, '0')} 00000 n \n`).join('');
    pdf += `trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
    return Buffer.from(pdf);
}

test('outline does not inherit page one from an unrelated cover or parent', async () => {
    const pdf = new PdfiumDocument({
        pdfium: {}, PDFiumExt_Init() { },
        FPDFBookmark_GetFirstChild: (_document, bookmark) => bookmark === 0 ? 1 : bookmark === 2 ? 4 : 0,
        FPDFBookmark_GetNextSibling: (_document, bookmark) => bookmark === 1 ? 2 : bookmark === 2 ? 3 : 0,
        FPDFBookmark_GetTitle: () => 0,
        FPDFBookmark_GetAction: () => 0,
        FPDFBookmark_GetDest: (_document, bookmark) => bookmark === 1 ? 10 : bookmark === 3 ? 30 : 0,
        FPDFDest_GetDestPageIndex: (_document, destination) => destination === 10 ? 0 : 7,
    });
    pdf.document = 1;
    pdf.pageCount = 10;
    const nodes = await pdf.outline();
    assert.deepEqual(nodes.map(node => node.pageNumber), [1, null, 8]);
    assert.equal(nodes[1].destinationPath, null);
    assert.equal(nodes[1].children[0].pageNumber, null);
    assert.equal(nodes[1].children[0].destinationPath, null);
});

const wasm = await readFile(new URL('../assets/embedpdf/pdfium.wasm', import.meta.url));
async function nativeDocument(overrides = {}) {
    const api = await init({ wasmBinary: wasm, print() { }, printErr() { } });
    const wrapped = { ...api, ...Object.fromEntries(Object.entries(overrides).map(([name, wrap]) => [name, wrap(api[name])])) };
    return new PdfiumDocument(wrapped);
}

test('synthetic narrow PDF reaches native allocation only with bounded final dimensions', async () => {
    let budget = 1;
    let allocations = 0;
    const pdf = await nativeDocument({
        FPDFBitmap_Create: create => (width, height, alpha) => {
            assert.ok(width <= budget && height <= budget && width * height <= budget);
            allocations++;
            return create(width, height, alpha);
        }
    });
    try {
        assert.equal(pdf.open(syntheticPdf({ mediaBox: '0 0 .001 10000000' })), 1);
        for (budget of [1, 2, 17, 256]) {
            const bitmap = pdf.render(1, 1080, budget);
            assert.equal(bitmap.pixels.length, bitmap.width * bitmap.height * 4);
            assert.ok(bitmap.pixels.length <= 1024);
        }
        assert.equal(allocations, 4);
        assert.equal(pdf.environments, pdf.releases);
    } finally { pdf.close(); }
});

test('synthetic 4097-annotation PDF fails deterministically before native render/form/click', async () => {
    let closes = 0;
    const pdf = await nativeDocument({
        FPDFBitmap_Create: () => () => assert.fail('annotation quota precedes bitmap allocation'),
        FPDFDOC_InitFormFillEnvironment: () => () => assert.fail('annotation quota precedes form initialization'),
        FPDF_RenderPageBitmap: () => () => assert.fail('annotation quota precedes rendering'),
        FORM_OnLButtonDown: () => () => assert.fail('annotation quota precedes click'),
        FPDF_ClosePage: close => page => { closes++; close(page); },
    });
    try {
        pdf.open(syntheticPdf({ annotations: 4097 }));
        for (const operation of [() => pdf.render(1, 32, 256), () => pdf.widgets(1),
        () => pdf.click(1, { pdf: true, x: 1, y: 1 })]) {
            assert.throws(operation, { name: 'embedpdf-fatal-annotation-limit' });
        }
        assert.equal(closes, 3);
        assert.equal(pdf.environments, 0);
    } finally { pdf.close(); }
});

test('four offline fallback font styles paint and CVL search returns bounded geometry', async () => {
    const pdf = await nativeDocument();
    try {
        const fonts = await Promise.all(['Regular', 'Bold', 'Italic', 'BoldItalic'].map(async style =>
            new Uint8Array(await readFile(new URL(`../assets/embedpdf/fonts/NotoSans-${style}.ttf`, import.meta.url)))));
        assert.ok(fonts.every(font => font.length > 0 && font.length <= 1024 * 1024));
        pdf.installFonts(fonts);
        pdf.open(syntheticPdf({ text: true }));
        const bitmap = pdf.render(1, 256, 32768);
        assert.ok(bitmap.pixels.some((value, index) => index % 4 !== 3 && value < 200));
        const matches = pdf.searchPage(1, 'CVL');
        assert.equal(matches.length, 4);
        assert.ok(matches.every(match => match.pageNumber === 1 && match.rects.length > 0));
        assert.throws(() => pdf.searchPage(1, 'CVL', 3), { name: 'embedpdf-command-search-limit' });
        assert.equal(pdf.environments, pdf.releases);
    } finally { pdf.close(); }
});