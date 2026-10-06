import { init } from '../embedpdf/pdfium.mjs';
import { PdfiumDocument, limits, failure } from './pdfium_document.mjs';

let document = null;
let busy = false;
let disposed = false;
const local = (value) => {
    const url = new URL(value, self.location.href);
    const base = new URL(self.location.href);
    const tokenPath = `/${base.pathname.split('/')[1]}/`;
    if (url.origin !== base.origin || !url.pathname.startsWith(tokenPath)) throw failure('local-resource', true);
    return url;
};
async function bytes(url, maximum) {
    const response = await fetch(local(url), { redirect: 'error', cache: 'no-store' });
    if (!response.ok || Number(response.headers.get('Content-Length')) > maximum) throw failure('resource-load', true);
    const reader = response.body.getReader();
    const chunks = [];
    let length = 0;
    try {
        for (;;) {
            const chunk = await reader.read();
            if (chunk.done) break;
            length += chunk.value.length;
            if (length > maximum) throw failure('document-limit', true);
            chunks.push(chunk.value);
        }
    } finally { await reader.cancel(); }
    const result = new Uint8Array(length);
    let offset = 0;
    for (const chunk of chunks) { result.set(chunk, offset); offset += chunk.length; }
    return result;
}
const yieldControl = () => new Promise(resolve => setTimeout(resolve, 0));
async function execute(type, payload) {
    if (type === 'open') {
        if (document) throw failure('already-open');
        if (typeof WebAssembly !== 'object' || typeof WebAssembly.compile !== 'function') throw failure('unsupported', true);
        const wasm = await bytes('../embedpdf/pdfium.wasm', 8 * 1024 * 1024);
        try { await WebAssembly.compile(wasm); } catch { throw failure('unsupported', true); }
        const fonts = [];
        for (const style of ['Regular', 'Bold', 'Italic', 'BoldItalic']) fonts.push(await bytes(`../embedpdf/fonts/NotoSans-${style}.ttf`, 1024 * 1024));
        const api = await init({ wasmBinary: wasm, print: () => {}, printErr: () => {}, locateFile: () => local('../embedpdf/pdfium.wasm').href });
        document = new PdfiumDocument(api);
        document.installFonts(fonts);
        const content = await bytes(payload.documentUrl, limits.documentBytes);
        const pageCount = document.open(content);
        return { pageCount, capabilities: 'modules1.worker1.canvas1.wasm-compiled1.sign-extension1', limits };
    }
    if (!document) throw failure('not-ready');
    switch (type) {
        case 'render': return document.render(payload.pageNumber, payload.width, payload.pixels);
        case 'widgets': return document.widgets(payload.pageNumber);
        case 'click': return document.click(payload.pageNumber, payload.point);
        case 'link': return document.linkAt(payload.pageNumber, payload.point);
        case 'outline': return document.outline(yieldControl);
        case 'searchPage': return document.searchPage(payload.pageNumber, payload.query, payload.remaining);
        default: throw failure('unknown-operation');
    }
}
self.onmessage = async ({ data }) => {
    if (disposed || !data || !Number.isInteger(data.id)) return;
    if (data.type === 'ping') { self.postMessage({ id: data.id, result: 'pong' }); return; }
    if (data.type === 'dispose') {
        disposed = true;
        if (!busy) document?.close();
        self.close();
        return;
    }
    if (busy) { self.postMessage({ id: data.id, error: 'embedpdf-command-worker-busy' }); return; }
    busy = true;
    try {
        const result = await execute(data.type, data.payload ?? {});
        if (disposed) return;
        const transfers = result?.pixels ? [result.pixels.buffer] : [];
        self.postMessage({ id: data.id, result }, transfers);
    } catch (error) {
        const name = typeof WebAssembly !== 'undefined' && error instanceof WebAssembly.RuntimeError ? 'embedpdf-fatal-wasm-trap'
            : /^embedpdf-(fatal|command)-[a-z-]+$/.test(error?.name) ? error.name : 'embedpdf-fatal-worker-crash';
        self.postMessage({ id: data.id, error: name });
    } finally { busy = false; }
};