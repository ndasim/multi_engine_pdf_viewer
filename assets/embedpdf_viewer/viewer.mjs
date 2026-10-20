import { limits, failure, rasterSize } from './pdfium_document.mjs';

const root = document.getElementById('pages');
const state = {
    config: null, worker: null, pageCount: 0, pageNumber: 1, columns: 1, zoom: 1,
    disposed: false, fatal: false, firstPaint: false, hostActive: true, active: !document.hidden,
    activeTime: 0, lastClock: Date.now(), sequence: 0, generation: 0,
    searchGeneration: 0, query: '', matches: [], currentMatch: -1,
    outline: [], rendered: new Map(), visible: new Set(), pending: new Map(),
    anchor: null,
};
let work = Promise.resolve();
let queuedJobs = 0;
let zoomTimer = 0;
function post(type, payload = {}) {
    if (state.disposed) return;
    window.PdfJsBridge?.postMessage(JSON.stringify({ v: 1, type, ...payload, session: state.config?.session }));
}
function applyPinch(point) {
    if (!pinch) return;
    pinch.lastPoint = point;
    pinch.factor = Math.max(1 / pinch.zoom, Math.min(4 / pinch.zoom, point.distance / pinch.distance));
    setZoom(pinch.zoom * pinch.factor,
        { ...pinch.anchor, clientX: point.x, clientY: point.y }, false);
}
function error(error) {
    if (state.disposed || state.fatal) return;
    const name = /^embedpdf-(fatal|command)-[a-z-]+$/.test(error?.name) ? error.name : 'embedpdf-command-operation';
    if (name.startsWith('embedpdf-fatal-')) {
        if (state.fatal || state.disposed) return;
        state.fatal = true;
        state.searchGeneration++;
        state.worker?.terminate();
        for (const request of state.pending.values()) request.reject(failure('retired'));
        state.pending.clear();
    }
    post('error', { name, message: name });
}
function clock() {
    const now = Date.now();
    if (state.active) state.activeTime += now - state.lastClock;
    state.lastClock = now;
    return state.activeTime;
}
function rpc(type, payload = {}, timeout = 15000) {
    if (state.disposed || state.fatal) return Promise.reject(failure('retired'));
    const id = ++state.sequence;
    return new Promise((resolve, reject) => {
        state.pending.set(id, { resolve, reject, deadline: clock() + timeout, type });
        state.worker.postMessage({ id, type, payload });
    });
}
function serialized(type, payload = {}, timeout) {
    if (queuedJobs >= limits.queuedJobs) return Promise.reject(failure('job-limit'));
    queuedJobs++;
    const operation = work.then(() => rpc(type, payload, timeout)).finally(() => { queuedJobs--; });
    work = operation.catch(() => { });
    return operation;
}
const watchdog = setInterval(() => {
    if (!state.active || state.disposed || state.fatal || !state.worker) return;
    const now = clock();
    for (const request of state.pending.values()) {
        if (now > request.deadline) {
            error(failure(request.type === 'open' ? 'startup-timeout' : request.type === 'render' ? 'render-timeout' : 'worker-hang', true));
            return;
        }
    }
    if (![...state.pending.values()].some(item => item.type === 'ping')) {
        rpc('ping', {}, 20000).then(() => post('heartbeat')).catch(() => { });
    }
}, 2000);
function setActive(active) {
    clock();
    state.hostActive = active;
    state.active = active && !document.hidden;
    state.lastClock = Date.now();
    if (state.active) post('heartbeat');
}
document.addEventListener('visibilitychange', () => setActive(state.hostActive));

function findState(pending) {
    post('findState', { current: state.currentMatch < 0 ? 0 : state.currentMatch + 1, total: state.matches.length, pending });
}
function highlights(pageNumber) {
    const layer = root.children[pageNumber - 1]?.querySelector('.highlights');
    if (!layer) return;
    layer.replaceChildren();
    if (!state.rendered.has(pageNumber)) return;
    state.matches.forEach((match, index) => {
        if (match.pageNumber !== pageNumber) return;
        for (const rect of match.rects) {
            const span = document.createElement('span');
            span.className = index === state.currentMatch ? 'match active' : 'match';
            span.style.left = `${rect.left * 100}%`;
            span.style.top = `${rect.top * 100}%`;
            span.style.width = `${rect.width * 100}%`;
            span.style.height = `${rect.height * 100}%`;
            layer.appendChild(span);
        }
    });
}
function clearRaster(pageNumber) {
    const canvas = root.children[pageNumber - 1]?.querySelector('canvas');
    if (canvas) { canvas.width = 0; canvas.height = 0; canvas.remove(); }
    root.children[pageNumber - 1]?.querySelector('.highlights')?.replaceChildren();
    state.rendered.delete(pageNumber);
}
function trim(keep, incomingPixels) {
    const total = () => [...state.rendered.values()].reduce((sum, size) => sum + size.width * size.height, 0);
    // Reserve space for the replacement while the old backing store is still live.
    while (state.rendered.size + 1 > limits.cachedPages || total() + incomingPixels > limits.cachedPixels) {
        const candidate = [...state.rendered.keys()].find(number =>
            number !== keep && number !== state.pageNumber && !state.visible.has(number));
        if (!candidate) return false;
        clearRaster(candidate);
    }
    return true;
}
const queued = new Set();
const renderJobs = new Map();
let rendering = false;
function render(pageNumber) {
    const existing = renderJobs.get(pageNumber);
    if (existing) return existing.then(() => render(pageNumber));
    const operation = paint(pageNumber).finally(() => renderJobs.delete(pageNumber));
    renderJobs.set(pageNumber, operation);
    return operation;
}
async function paint(pageNumber) {
    const page = root.children[pageNumber - 1];
    if (!page || pinch || state.disposed || state.fatal) return;
    const generation = state.generation;
    const config = state.config;
    const configuredPixels = state.pageCount >= config.largeDocumentPageCount ? config.largeDocumentMaxCanvasPixels : config.maxCanvasPixels;
    const pixels = Math.min(limits.rasterPixels, configuredPixels || limits.rasterPixels, state.columns > 1 ? Math.floor(limits.cachedPixels / limits.cachedPages) : limits.rasterPixels);
    const width = Math.max(32, Math.round(page.clientWidth * Math.min(2, window.devicePixelRatio || 1)));
    const cached = state.rendered.get(pageNumber);
    const target = cached ? rasterSize(cached.pageWidth, cached.pageHeight, width, pixels) : null;
    if (cached && cached.width === target.width && cached.height === target.height) return;
    if (!trim(pageNumber, target ? target.width * target.height : pixels)) return;
    const zoom = state.zoom;
    const result = await serialized('render', { pageNumber, width, pixels }, 20000);
    if (state.disposed || state.fatal) return;
    if (pinch || generation !== state.generation || zoom !== state.zoom) {
        queued.add(pageNumber);
        return;
    }
    if (!trim(pageNumber, result.width * result.height)) return;
    page.style.setProperty('--ratio', `${result.pageWidth / result.pageHeight}`);
    restoreAnchor();
    const canvas = document.createElement('canvas');
    canvas.width = result.width;
    canvas.height = result.height;
    canvas.getContext('2d').putImageData(new ImageData(result.pixels, result.width, result.height), 0, 0);
    const previous = page.querySelector('canvas');
    if (previous) {
        previous.replaceWith(canvas);
        previous.width = 0;
        previous.height = 0;
    } else page.prepend(canvas);
    state.rendered.set(pageNumber, {
        width: result.width, height: result.height,
        pageWidth: result.pageWidth, pageHeight: result.pageHeight,
    });
    highlights(pageNumber);
    await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    if (!state.firstPaint && !state.disposed && !state.fatal && generation === state.generation) {
        state.firstPaint = true;
        post('firstPageRendered', { pageNumber });
        setTimeout(() => loadOutline().catch(error), 0);
    }
}
async function drain() {
    if (rendering || pinch || zoomTimer) return;
    rendering = true;
    try {
        while (queued.size && !pinch && !zoomTimer && !state.disposed && !state.fatal) {
            const next = queued.has(state.pageNumber) ? state.pageNumber : queued.values().next().value;
            queued.delete(next);
            if (state.visible.has(next) || next === state.pageNumber) await render(next);
        }
    } catch (caught) { error(caught); }
    finally { rendering = false; }
}
function queue(pageNumber) { queued.add(pageNumber); void drain(); }
function refreshVisible() {
    for (const number of state.visible) queued.add(number);
    queued.add(state.pageNumber);
    void drain();
}
function scheduleRefresh() {
    clearTimeout(zoomTimer);
    zoomTimer = setTimeout(() => {
        zoomTimer = 0;
        refreshVisible();
    }, 150);
}
function captureAnchor(clientX = window.innerWidth / 2, clientY = 0) {
    const page = root.children[state.pageNumber - 1];
    if (!page) return null;
    const rect = page.getBoundingClientRect();
    return {
        pageNumber: state.pageNumber, x: (clientX - rect.left) / rect.width,
        y: (clientY - rect.top) / rect.height, clientX, clientY
    };
}
function restoreAnchor() {
    const anchor = state.anchor;
    if (!anchor || state.disposed || state.fatal) return;
    const rect = root.children[anchor.pageNumber - 1]?.getBoundingClientRect();
    if (!rect) return;
    window.scrollTo({
        left: window.scrollX + rect.left + anchor.x * rect.width - anchor.clientX,
        top: window.scrollY + rect.top + anchor.y * rect.height - anchor.clientY,
        behavior: 'instant'
    });
}
function releaseAnchor() { state.anchor = null; }
function currentPage() {
    if (!state.pageCount || state.disposed || state.fatal || state.anchor) return;
    const candidates = [...state.visible].map(number => ({ number, rect: root.children[number - 1].getBoundingClientRect() }))
        .filter(({ rect }) => rect.bottom > 0 && rect.top < window.innerHeight && rect.right > 0 && rect.left < window.innerWidth);
    candidates.sort((first, second) => Math.abs(first.rect.top) - Math.abs(second.rect.top) || first.rect.left - second.rect.left);
    const number = candidates[0]?.number;
    if (number && number !== state.pageNumber) { state.pageNumber = number; post('pageChanged', { pageNumber: number }); }
}
const observer = new IntersectionObserver((entries) => {
    for (const entry of entries) {
        const number = Number(entry.target.dataset.page);
        if (entry.isIntersecting) { state.visible.add(number); queue(number); }
        else state.visible.delete(number);
    }
    currentPage();
}, { rootMargin: '120px 0px' });
window.addEventListener('scroll', currentPage, { passive: true });
async function goToPage(number) {
    if (!Number.isInteger(number) || !state.pageCount) throw failure('page-range');
    number = Math.max(1, Math.min(state.pageCount, number));
    const changed = number !== state.pageNumber;
    state.pageNumber = number;
    state.anchor = captureAnchor();
    root.children[number - 1].scrollIntoView({ block: 'start', behavior: 'auto' });
    state.anchor = captureAnchor();
    if (changed) post('pageChanged', { pageNumber: number });
    await render(number);
    restoreAnchor();
}
function setLayout(columns, anchor = captureAnchor()) {
    if (!Number.isInteger(columns) || columns < 1 || columns > 6) throw failure('layout-range');
    state.anchor = anchor;
    const columnsChanged = state.columns !== columns;
    state.columns = columns;
    root.style.setProperty('--columns', columns);
    restoreAnchor();
    if (columnsChanged) {
        state.generation++;
        scheduleRefresh();
    }
}
function setZoom(zoom, anchor = captureAnchor(), refresh = true) {
    if (!Number.isFinite(zoom)) throw failure('zoom-range');
    state.anchor = anchor;
    state.zoom = Math.max(1, Math.min(4, zoom));
    root.style.width = `${state.zoom * 100}%`;
    restoreAnchor();
    if (refresh) scheduleRefresh();
}
root.addEventListener('dblclick', event => setZoom(state.zoom === 1 ? 2 : 1, captureAnchor(event.clientX, event.clientY)));
root.addEventListener('wheel', event => {
    if (!event.ctrlKey) return;
    event.preventDefault();
    setZoom(state.zoom * (event.deltaY > 0 ? 0.9 : 1.1), captureAnchor(event.clientX, event.clientY));
}, { passive: false });
window.addEventListener('wheel', event => {
    if (!event.ctrlKey) releaseAnchor();
}, { passive: true });
window.addEventListener('keydown', event => {
    if (['ArrowDown', 'ArrowUp', 'PageDown', 'PageUp', 'Home', 'End', ' '].includes(event.key)) releaseAnchor();
});
root.style.touchAction = 'pan-x pan-y';
let pinch = null;
const touchPoint = touches => ({
    x: (touches[0].clientX + touches[1].clientX) / 2,
    y: (touches[0].clientY + touches[1].clientY) / 2,
    distance: Math.hypot(touches[0].clientX - touches[1].clientX, touches[0].clientY - touches[1].clientY)
});
root.addEventListener('touchstart', event => {
    if (event.touches.length === 1) releaseAnchor();
    if (event.touches.length !== 2) return;
    event.preventDefault();
    pointer = null;
    const point = touchPoint(event.touches);
    if (point.distance <= 0) return;
    const anchor = captureAnchor(point.x, point.y);
    if (!anchor) return;
    clearTimeout(zoomTimer);
    zoomTimer = 0;
    state.anchor = anchor;
    pinch = {
        distance: point.distance,
        zoom: state.zoom,
        anchor,
        factor: 1,
        frame: 0,
        lastPoint: point,
    };
}, { passive: false });
root.addEventListener('touchmove', event => {
    if (!pinch) { releaseAnchor(); return; }
    if (event.touches.length !== 2) return;
    event.preventDefault();
    const point = touchPoint(event.touches);
    if (!pinch.anchor) return;
    pinch.lastPoint = point;
    if (!pinch.frame) {
        pinch.frame = requestAnimationFrame(() => {
            if (!pinch) return;
            pinch.frame = 0;
            applyPinch(pinch.lastPoint);
        });
    }
}, { passive: false });
function finishPinch(event) {
    if (!pinch || event.touches.length >= 2) return;
    if (pinch.frame) cancelAnimationFrame(pinch.frame);
    applyPinch(pinch.lastPoint);
    pinch = null;
    scheduleRefresh();
}
root.addEventListener('touchend', finishPinch);
root.addEventListener('touchcancel', finishPinch);
let pointer = null;
root.addEventListener('pointerdown', event => {
    if (!event.isPrimary) { pointer = null; return; }
    pointer = { x: event.clientX, y: event.clientY, time: Date.now(), id: event.pointerId };
});
root.addEventListener('pointermove', event => {
    if (!pinch && pointer && Math.hypot(event.clientX - pointer.x, event.clientY - pointer.y) > 10) releaseAnchor();
});
root.addEventListener('pointercancel', () => { pointer = null; });
root.addEventListener('pointerup', event => {
    const down = pointer;
    pointer = null;
    if (!down || down.id !== event.pointerId || Date.now() - down.time > 700 || Math.hypot(event.clientX - down.x, event.clientY - down.y) > 10) return;
    const page = event.target.closest('.page');
    const canvas = page?.querySelector('canvas');
    if (!page || !canvas) return;
    const number = Number(page.dataset.page);
    if (state.columns > 1) { post('pageTap', { pageNumber: number }); return; }
    const rect = canvas.getBoundingClientRect();
    const point = { width: canvas.width, height: canvas.height, x: (event.clientX - rect.left) * canvas.width / rect.width, y: (event.clientY - rect.top) * canvas.height / rect.height };
    serialized('click', { pageNumber: number, point }).then(async result => {
        if (result.targetPage) { await goToPage(result.targetPage); return; }
        if (result.url) { post('externalLink', { url: result.url }); return; }
        // A widget whose goto action resolved to an invalid page reports no
        // actions and no target: fall through to the link path so a /GoTo
        // link annotation stacked on the same button still navigates.
        if (result.actions.length) return;
        const link = await serialized('link', { pageNumber: number, point });
        if (link?.pageNumber) await goToPage(link.pageNumber);
        else if (link?.url) post('externalLink', { url: link.url });
        else post('pageTap', { pageNumber: number });
    }).catch(error);
});
async function loadOutline() {
    const items = await serialized('outline', {}, 30000);
    if (state.disposed || state.fatal) return;
    state.outline = items;
    post('outline', { items });
}
async function find(query) {
    const generation = ++state.searchGeneration;
    state.query = query;
    state.matches = [];
    state.currentMatch = -1;
    for (const number of state.rendered.keys()) highlights(number);
    if (!query) { findState(false); return; }
    if (typeof query !== 'string' || query.length > limits.queryLength) throw failure('query-limit');
    findState(true);
    let geometryCount = 0;
    try {
        for (let number = 1; number <= state.pageCount; number++) {
            if (generation !== state.searchGeneration || state.disposed || state.fatal) return;
            const matches = await serialized('searchPage', { pageNumber: number, query, remaining: limits.searchMatches - state.matches.length });
            if (generation !== state.searchGeneration || state.disposed || state.fatal) return;
            geometryCount += matches.reduce((sum, match) => sum + match.rects.length, 0);
            if (geometryCount > limits.searchRectangles) throw failure('search-geometry-limit');
            state.matches.push(...matches);
            if (state.currentMatch < 0 && state.matches.length) {
                state.currentMatch = 0;
                await goToPage(state.matches[0].pageNumber);
            }
            highlights(number);
            findState(true);
            await new Promise(resolve => setTimeout(resolve, 0));
        }
    } finally {
        if (generation === state.searchGeneration) findState(false);
    }
}
async function findAgain(previous) {
    if (!state.matches.length) return;
    state.currentMatch = (state.currentMatch + (previous ? -1 : 1) + state.matches.length) % state.matches.length;
    await goToPage(state.matches[state.currentMatch].pageNumber);
    for (const number of state.rendered.keys()) highlights(number);
    findState(false);
}
async function open(config) {
    if (state.config) return;
    state.config = config;
    if (!('noModule' in document.createElement('script')) || typeof Worker !== 'function' || typeof IntersectionObserver !== 'function' || !document.createElement('canvas').getContext('2d')) {
        throw failure('unsupported', true);
    }
    state.worker = new Worker(new URL('./worker.mjs', import.meta.url), { type: 'module' });
    state.worker.onerror = event => { event.preventDefault(); error(failure('worker-crash', true)); };
    state.worker.onmessageerror = () => error(failure('worker-message', true));
    state.worker.onmessage = ({ data }) => {
        const request = state.pending.get(data.id);
        if (!request || state.disposed || state.fatal) return;
        state.pending.delete(data.id);
        if (data.error) { const caught = new Error(data.error); caught.name = data.error; request.reject(caught); }
        else request.resolve(data.result);
    };
    const opened = await serialized('open', { documentUrl: config.documentUrl }, 30000);
    post('capabilities', { signature: opened.capabilities });
    state.pageCount = opened.pageCount;
    state.pageNumber = Math.max(1, Math.min(opened.pageCount, config.initialPage || 1));
    for (const name of ['backgroundColor', 'pageShadowColor', 'matchColor', 'activeMatchColor']) {
        const property = { backgroundColor: '--background', pageShadowColor: '--shadow', matchColor: '--match', activeMatchColor: '--active-match' }[name];
        if (typeof config[name] === 'string' && CSS.supports('color', config[name])) root.style.setProperty(property, config[name]);
    }
    root.style.setProperty('--margin', `${Math.max(0, Math.min(64, config.margin || 0))}px`);
    for (let number = 1; number <= opened.pageCount; number++) {
        const page = document.createElement('section');
        page.className = 'page';
        page.dataset.page = String(number);
        const layer = document.createElement('div');
        layer.className = 'highlights';
        page.appendChild(layer);
        root.appendChild(page);
    }
    state.columns = Math.max(1, Math.min(6, config.columns || 1));
    root.style.setProperty('--columns', state.columns);
    post('ready', { pageCount: opened.pageCount, pageNumber: state.pageNumber });
    await goToPage(state.pageNumber);
    for (const page of root.children) observer.observe(page);
}
function dispose() {
    if (state.disposed) return;
    state.disposed = true;
    state.anchor = null;
    state.searchGeneration++;
    clearInterval(watchdog);
    clearInterval(handshake);
    clearTimeout(zoomTimer);
    if (pinch?.frame) cancelAnimationFrame(pinch.frame);
    pinch = null;
    observer.disconnect();
    state.worker?.postMessage({ id: ++state.sequence, type: 'dispose' });
    state.worker?.terminate();
    for (const request of state.pending.values()) request.reject(failure('retired'));
    state.pending.clear();
    for (const number of [...state.rendered.keys()]) clearRaster(number);
    queued.clear();
    root.replaceChildren();
}
async function handle(message) {
    if (message?.v === 1 && message.type === 'dispose' && message.session === state.config?.session) return dispose();
    if (!message || message.v !== 1 || state.disposed || state.fatal) return;
    if (message.type !== 'open' && state.config && message.session !== state.config.session) return;
    switch (message.type) {
        case 'open': return open(message.config);
        case 'goToPage': return goToPage(message.pageNumber);
        case 'goToOutline': {
            let node;
            let items = state.outline;
            if (!Array.isArray(message.path)) throw failure('outline-path');
            for (const index of message.path) { node = Number.isInteger(index) ? items?.[index] : null; items = node?.children; }
            if (node?.pageNumber) return goToPage(node.pageNumber);
            return;
        }
        case 'setLayout': return setLayout(message.columns);
        case 'setZoom': return setZoom(message.zoom);
        case 'find': void find(message.query).catch(error); return;
        case 'findAgain': return findAgain(message.previous === true);
        case 'findClear': return find('');
        case 'setActive': return setActive(message.active === true);
        case 'dispose': return dispose();
        case 'injectFatal': throw failure('injected', true);
        case 'terminateWorker': state.worker?.terminate(); break;
        default: throw failure('unknown-command');
    }
}
window.pdfjsBridge = Object.freeze({
    receive(json) {
        try { Promise.resolve(handle(JSON.parse(json))).catch(error); } catch (caught) { error(caught); }
    }
});
window.addEventListener('pagehide', dispose);
window.addEventListener('unhandledrejection', event => { event.preventDefault(); error(failure('worker-crash', true)); });
window.addEventListener('error', () => error(failure('viewer-script', true)));
post('bridgeReady');
const handshake = setInterval(() => { if (state.config) clearInterval(handshake); else post('bridgeReady'); }, 1000);