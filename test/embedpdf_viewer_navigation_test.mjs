import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import vm from 'node:vm';
import { failure, limits, rasterSize } from '../assets/embedpdf_viewer/pdfium_document.mjs';

async function viewer({ pageCount = 189, config = {} } = {}) {
    const events = [];
    const requests = [];
    const scrolls = [];
    const frames = new Map();
    const timers = new Map();
    const intervals = [];
    const documentListeners = new Map();
    const windowListeners = new Map();
    let scrollX = 0;
    let scrollY = 0;
    let observed;
    let sequence = 0;
    let now = 0;
    let holdRenders = false;
    const heldRenders = [];
    const window = {
        get scrollX() { return scrollX; },
        get scrollY() { return scrollY; },
        innerWidth: 1080, innerHeight: 1400, devicePixelRatio: 1,
        PdfJsBridge: { postMessage: json => events.push(JSON.parse(json)) },
        addEventListener: (name, callback) => windowListeners.set(name, callback),
        scrollTo: ({ left = scrollX, top = scrollY }) => window.scrollBy({ left: left - scrollX, top: top - scrollY }),
        scrollBy: ({ left = 0, top = 0 }) => {
            scrolls.push({ left, top });
            const maximumX = Math.max(0, 1080 * Number.parseFloat(root.style.width ?? '100%') / 100 - window.innerWidth);
            scrollX = Math.max(0, Math.min(maximumX, scrollX + left));
            scrollY = Math.max(0, scrollY + top);
            windowListeners.get('scroll')?.();
        },
    };
    class Element {
        constructor(tag) {
            this.tag = tag;
            this.children = [];
            this.dataset = {};
            this.listeners = new Map();
            this.values = {};
            this.style = { setProperty: (name, value) => { this.values[name] = value; } };
        }
        appendChild(child) { child.parent = this; this.children.push(child); }
        prepend(child) { child.parent = this; this.children.unshift(child); }
        replaceWith(child) {
            const index = this.parent.children.indexOf(this);
            child.parent = this.parent;
            this.parent.children[index] = child;
        }
        replaceChildren() { this.children = []; }
        remove() { this.parent.children = this.parent.children.filter(child => child !== this); }
        querySelector(selector) { return this.children.find(child => selector === 'canvas' ? child.tag === 'canvas' : child.className === selector.slice(1)); }
        closest(selector) { return selector === '.page' && this.className === 'page' ? this : this.parent?.closest(selector); }
        addEventListener(name, callback) { this.listeners.set(name, callback); }
        getContext() { return { putImageData() { } }; }
        get clientWidth() { return this.getBoundingClientRect().width; }
        getBoundingClientRect() {
            if (this.tag === 'canvas') return this.parent.getBoundingClientRect();
            const columns = Number(root.values['--columns'] ?? 1);
            const rootWidth = 1080 * Number.parseFloat(root.style.width ?? '100%') / 100;
            const gap = Number.parseFloat(root.values['--margin'] ?? '8');
            const width = (rootWidth - gap * (columns + 1)) / columns;
            const index = Number(this.dataset.page) - 1;
            const height = width / Number(this.values['--ratio'] ?? 0.773);
            let top = gap;
            for (let row = 0; row < Math.floor(index / columns); row++) {
                const heights = root.children.slice(row * columns, (row + 1) * columns)
                    .map(page => width / Number(page.values['--ratio'] ?? 0.773));
                top += Math.max(...heights) + gap;
            }
            const left = gap + (index % columns) * (width + gap) - scrollX;
            top -= scrollY;
            return { top, left, width, height, right: left + width, bottom: top + height };
        }
        scrollIntoView() { const rect = this.getBoundingClientRect(); window.scrollBy({ top: rect.top }); }
    }
    const root = new Element('main');
    const document = {
        hidden: false, getElementById: () => root,
        addEventListener: (name, callback) => documentListeners.set(name, callback),
        createElement: tag => tag === 'script' ? { noModule: false } : new Element(tag)
    };
    class Worker {
        postMessage({ id, type, payload }) {
            requests.push({ type, payload });
            const pageHeight = 792 + (payload?.pageNumber ?? 1) * 3;
            const result = type === 'open' ? { pageCount, capabilities: 'test' }
                : type === 'render' ? { ...rasterSize(612, pageHeight, payload.width, payload.pixels), pageWidth: 612, pageHeight, pixels: new Uint8ClampedArray(4) }
                    : type === 'outline' ? [{ children: [{}, { pageNumber: 4, children: [] }] }]
                        : type === 'click' ? { actions: ['NextPage'], targetPage: payload.pageNumber + 1 } : 'pong';
            const reply = () => this.onmessage?.({ data: { id, result } });
            if (type === 'render' && holdRenders) heldRenders.push(reply);
            else queueMicrotask(reply);
        }
        terminate() { }
    }
    const context = vm.createContext({
        document, window, Worker, URL, CSS: { supports: () => true },
        ImageData: class { }, Date: { now: () => now }, Math, Map, Set, Promise,
        setInterval: callback => intervals.push(callback), clearInterval() { },
        setTimeout: callback => { const id = ++sequence; timers.set(id, callback); return id; },
        clearTimeout: id => timers.delete(id),
        requestAnimationFrame: callback => { const id = ++sequence; frames.set(id, callback); return id; },
        cancelAnimationFrame: id => frames.delete(id),
        IntersectionObserver: class {
            constructor(callback) { observed = callback; }
            observe() { }
            disconnect() { }
        },
    });
    const module = new vm.SourceTextModule(await readFile(new URL('../assets/embedpdf_viewer/viewer.mjs', import.meta.url), 'utf8'), {
        context, initializeImportMeta: meta => { meta.url = new URL('../assets/embedpdf_viewer/viewer.mjs', import.meta.url).href; },
    });
    await module.link(() => new vm.SyntheticModule(['limits', 'failure', 'rasterSize'], function () {
        this.setExport('limits', limits);
        this.setExport('failure', failure);
        this.setExport('rasterSize', rasterSize);
    }, { context }));
    await module.evaluate();
    const settle = async () => {
        for (let turn = 0; turn < 60; turn++) {
            await Promise.resolve();
            const callbacks = [...frames.values(), ...timers.values()];
            frames.clear();
            timers.clear();
            callbacks.forEach(callback => callback());
        }
    };
    const send = async (type, payload = {}) => {
        window.pdfjsBridge.receive(JSON.stringify({ v: 1, type, session: 'current', ...payload }));
        await settle();
    };
    const observe = numbers => {
        observed(root.children.map(page => ({ target: page, isIntersecting: numbers.includes(Number(page.dataset.page)) })));
        windowListeners.get('scroll')?.();
    };
    await send('open', { config: { session: 'current', initialPage: 2, columns: 1, margin: 8, ...config } });
    events.length = 0;
    return {
        root, events, requests, scrolls, settle, send, observe, window,
        holdRenders: () => { holdRenders = true; },
        releaseRenders: async () => {
            holdRenders = false;
            heldRenders.splice(0).forEach(reply => reply());
            await settle();
        },
        advance: milliseconds => { now += milliseconds; },
        tick: async () => { intervals.forEach(callback => callback()); await settle(); },
        visibility: async hidden => {
            document.hidden = hidden;
            documentListeners.get('visibilitychange')?.();
            await settle();
        },
        pages: () => events.filter(event => event.type === 'pageChanged').map(event => event.pageNumber),
        point: (number, x, y) => {
            const rect = root.children[number - 1].getBoundingClientRect();
            return { x: (x - rect.left) / rect.width, y: (y - rect.top) / rect.height };
        }
    };
}

test('WebView visibility never overrides an inactive Flutter route', async () => {
    const view = await viewer();
    await view.send('setActive', { active: false });
    await view.visibility(true);
    await view.visibility(false);
    await view.tick();
    assert.equal(view.requests.filter(request => request.type === 'ping').length, 0);
    assert.equal(view.events.filter(event => event.type === 'heartbeat').length, 0);
    await view.visibility(true);
    await view.send('setActive', { active: true });
    await view.tick();
    assert.equal(view.requests.filter(request => request.type === 'ping').length, 0);
    await view.visibility(false);
    await view.tick();
    assert.equal(view.requests.filter(request => request.type === 'ping').length, 1);
    assert.ok(view.events.some(event => event.type === 'heartbeat'));
});

function samePoint(actual, expected) {
    assert.ok(Math.abs(actual.x - expected.x) < 1e-9, `horizontal anchor: ${actual.x} != ${expected.x}`);
    assert.ok(Math.abs(actual.y - expected.y) < 1e-9, `vertical anchor: ${actual.y} != ${expected.y}`);
}

test('grid 2 -> 6 and inherited outline -> 4 never publish transient page 3', async () => {
    const view = await viewer();
    await view.send('setLayout', { columns: 3 });
    view.observe([2, 4, 5, 6]);
    await view.settle();
    await view.send('goToPage', { pageNumber: 6 });
    await view.send('setLayout', { columns: 1 });
    view.observe([3, 6]);
    await view.settle();
    assert.deepEqual(view.pages(), [6]);
    await view.send('goToOutline', { path: [0, 1] });
    view.observe([3, 4]);
    await view.settle();
    assert.deepEqual(view.pages(), [6, 4]);
    assert.equal(view.events.filter(event => event.type === 'error').length, 0);
});

test('double-tap and repeated zoom/relayout preserve page 6 and its tapped document point', async () => {
    const view = await viewer();
    await view.send('goToPage', { pageNumber: 6 });
    view.observe([6]);
    await view.settle();
    const point = view.point(6, 540, 700);
    for (let repeat = 0; repeat < 8; repeat++) {
        view.root.listeners.get('dblclick')({ clientX: 540, clientY: 700 });
        view.observe([3, 6]);
        await view.settle();
        samePoint(view.point(6, 540, 700), point);
    }
    for (const columns of [3, 1, 2, 1, 4, 1]) {
        const topPoint = view.point(6, 540, 0);
        await view.send('setLayout', { columns });
        view.observe([3, 6]);
        await view.settle();
        assert.ok(Math.abs(view.point(6, 540, 0).y - topPoint.y) < 1e-9);
    }
    assert.deepEqual(view.pages(), [6]);
});

test('pinch follows a moving midpoint without changing the logical page', async () => {
    const view = await viewer();
    await view.send('goToPage', { pageNumber: 6 });
    const point = view.point(6, 540, 700);
    const event = (distance, x = 540, y = 700) => ({
        preventDefault() { }, touches: [
            { clientX: x - distance / 2, clientY: y }, { clientX: x + distance / 2, clientY: y },
        ]
    });
    view.root.listeners.get('touchstart')(event(200));
    for (const distance of [300, 400, 350, 200]) {
        const clientX = distance === 200 ? 540 : 560;
        const clientY = distance === 200 ? 700 : 710;
        view.root.listeners.get('touchmove')(event(distance, clientX, clientY));
        view.observe([3, 6]);
        await view.settle();
        samePoint(view.point(6, clientX, clientY), point);
    }
    view.root.listeners.get('touchend')({ touches: [] });
    assert.deepEqual(view.pages(), [6]);
});

const pinchEvent = (distance, x = 540, y = 700) => ({
    preventDefault() { },
    touches: [
        { clientX: x - distance / 2, clientY: y },
        { clientX: x + distance / 2, clientY: y },
    ],
});

for (const finish of ['touchend', 'touchcancel']) {
    test(`pinch ${finish} keeps the last displayed geometry and canvas without a commit frame`, async () => {
        const view = await viewer();
        await view.send('goToPage', { pageNumber: 6 });
        view.observe([6]);
        await view.settle();
        const page = view.root.children[5];
        const canvas = page.querySelector('canvas');
        const renders = view.requests.filter(request => request.type === 'render').length;
        const point = view.point(6, 540, 700);
        view.root.listeners.get('touchstart')(pinchEvent(200));
        view.root.listeners.get('touchmove')(pinchEvent(300, 560, 710));
        await view.settle();
        assert.equal(view.root.style.width, '150%');
        assert.ok(!view.root.style.transform, 'the full document must not become a scaled compositor layer');
        samePoint(view.point(6, 560, 710), point);
        assert.equal(view.requests.filter(request => request.type === 'render').length, renders);
        const rect = page.getBoundingClientRect();
        view.root.listeners.get(finish)({ touches: [] });
        assert.deepEqual(page.getBoundingClientRect(), rect);
        assert.equal(page.querySelector('canvas'), canvas);
        await view.settle();
        assert.deepEqual(page.getBoundingClientRect(), rect);
        assert.equal(page.children.filter(child => child.tag === 'canvas').length, 1);
        assert.notEqual(page.querySelector('canvas'), canvas, 'refresh only after the gesture');
        assert.equal(canvas.width, 0, 'release the replaced backing store');
        assert.deepEqual(view.pages(), [6]);
    });
}

test('zoom refresh keeps the old raster until its replacement arrives and respects the pixel cap', async () => {
    const view = await viewer();
    view.observe([2]);
    await view.settle();
    const page = view.root.children[1];
    const canvas = page.querySelector('canvas');
    view.holdRenders();
    await view.send('setZoom', { zoom: 2 });
    assert.equal(page.querySelector('canvas'), canvas);
    await view.releaseRenders();
    const replacement = page.querySelector('canvas');
    assert.notEqual(replacement, canvas);
    assert.equal(page.children.filter(child => child.tag === 'canvas').length, 1);
    assert.ok(replacement.width * replacement.height <= limits.rasterPixels);
    const count = view.requests.filter(request => request.type === 'render').length;
    await view.send('setZoom', { zoom: 4 });
    assert.equal(view.requests.filter(request => request.type === 'render').length, count,
        'do not rasterize again when the resolution is already pixel-capped');
    assert.equal(view.events.filter(event => event.type === 'error').length, 0);
});

test('a relayout keeps painted pages until new rasters are ready', async () => {
    const view = await viewer();
    view.observe([2]);
    await view.settle();
    const canvas = view.root.children[1].querySelector('canvas');
    view.holdRenders();
    await view.send('setLayout', { columns: 3 });
    assert.equal(view.root.children[1].querySelector('canvas'), canvas);
    await view.releaseRenders();
    assert.notEqual(view.root.children[1].querySelector('canvas'), canvas);
    assert.equal(canvas.width, 0);
});

test('repeated navigation and zoom stay within the raster cache budget', async () => {
    const view = await viewer();
    for (let number = 3; number <= 45; number++) {
        view.observe([number]);
        await view.send('goToPage', { pageNumber: number });
        await view.send('setZoom', { zoom: number % 2 ? 2 : 1 });
        const canvases = view.root.children.flatMap(page => page.children.filter(child => child.tag === 'canvas'));
        assert.ok(canvases.length <= limits.cachedPages);
        assert.ok(canvases.reduce((sum, canvas) => sum + canvas.width * canvas.height, 0) <= limits.cachedPixels);
        assert.ok(view.root.children[number - 1].querySelector('canvas'));
    }
    assert.equal(view.events.filter(event => event.type === 'error').length, 0);
});

test('overlapping navigation cannot overcommit the cache when worker results arrive', async () => {
    const view = await viewer();
    view.holdRenders();
    for (let number = 3; number <= 12; number++) {
        await view.send('goToPage', { pageNumber: number });
    }
    await view.releaseRenders();
    await view.settle();
    const canvases = view.root.children.flatMap(page => page.children.filter(child => child.tag === 'canvas'));
    assert.ok(canvases.reduce((sum, canvas) => sum + canvas.width * canvas.height, 0) <= limits.cachedPixels);
    assert.ok(view.root.children[11].querySelector('canvas'));
    assert.equal(view.events.filter(event => event.type === 'error').length, 0);
});

test('large-document raster limits also apply to zoom replacements', async () => {
    const view = await viewer({ config: {
        largeDocumentPageCount: 100, largeDocumentMaxCanvasPixels: 4096,
    } });
    view.observe([2]);
    await view.send('setZoom', { zoom: 4 });
    const canvas = view.root.children[1].querySelector('canvas');
    assert.ok(canvas.width * canvas.height <= 4096);
    assert.ok(view.requests.filter(request => request.type === 'render').every(request => request.payload.pixels === 4096));
});

test('zoom changes during an in-flight render never install the obsolete resolution', async () => {
    const view = await viewer();
    view.observe([2]);
    await view.settle();
    const page = view.root.children[1];
    const canvas = page.querySelector('canvas');
    view.holdRenders();
    await view.send('setZoom', { zoom: 2 });
    await view.send('setZoom', { zoom: 1 });
    await view.releaseRenders();
    assert.equal(page.querySelector('canvas'), canvas);
    assert.equal(view.events.filter(event => event.type === 'error').length, 0);
});

test('an unresponsive render still produces fatal fallback while inactive time is excluded', async () => {
    const view = await viewer();
    view.holdRenders();
    view.observe([6]);
    await view.settle();
    await view.send('setActive', { active: false });
    view.advance(60000);
    await view.tick();
    assert.equal(view.events.filter(event => event.type === 'error').length, 0);
    await view.send('setActive', { active: true });
    view.advance(21000);
    await view.tick();
    assert.ok(view.events.some(event => event.name === 'embedpdf-fatal-render-timeout'));
});

test('a named action emits exactly one navigation; manual scrolling releases the anchor', async () => {
    const view = await viewer();
    const page = view.root.children[1];
    const pointer = { isPrimary: true, pointerId: 1, clientX: 540, clientY: 700, target: page };
    view.root.listeners.get('pointerdown')(pointer);
    view.root.listeners.get('pointerup')(pointer);
    await view.settle();
    view.observe([2, 3]);
    await view.settle();
    assert.deepEqual(view.pages(), [3]);
    assert.equal(view.requests.filter(request => request.type === 'click').length, 1);
    await view.send('goToPage', { pageNumber: 6 });
    view.root.listeners.get('pointerdown')(pointer);
    view.root.listeners.get('pointermove')({ clientX: 540, clientY: 740 });
    view.root.children[2].scrollIntoView();
    view.observe([3]);
    await view.settle();
    assert.deepEqual(view.pages(), [3, 6, 3]);
});

for (const [start, target] of [[2, 7], [10, 3]]) {
    for (const finish of [null, 'touchend', 'touchcancel']) {
        test(`native touch scroll ${start} -> ${target} is not clamped ${finish ?? 'during drag'}`, async () => {
            const view = await viewer();
            await view.send('goToPage', { pageNumber: start });
            view.observe([start]);
            await view.settle();
            view.events.length = 0;
            let prevented = false;
            const touch = {
                touches: [{ clientX: 540, clientY: 700 }],
                preventDefault() { prevented = true; },
            };
            view.root.listeners.get('touchstart')(touch);
            view.root.listeners.get('touchmove')(touch);
            if (finish) view.root.listeners.get(finish)({ touches: [] });

            const offset = view.window.scrollY + view.root.children[target - 1].getBoundingClientRect().top;
            view.scrolls.length = 0;
            view.observe([target]);
            view.window.scrollBy({ top: offset - view.window.scrollY });
            assert.equal(view.window.scrollY, offset);
            await view.settle();

            assert.equal(prevented, false);
            assert.equal(view.window.scrollY, offset);
            assert.equal(view.scrolls.length, 1);
            assert.deepEqual(view.pages(), [target]);
            assert.equal(view.events.filter(event => event.type === 'error').length, 0);
        });
    }
}