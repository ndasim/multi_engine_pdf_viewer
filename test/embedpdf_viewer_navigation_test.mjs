import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import vm from 'node:vm';
import { failure, limits } from '../assets/embedpdf_viewer/pdfium_document.mjs';
import { createPageScrollLimiter } from '../assets/viewer/page_scroll_limiter.mjs';

async function viewer() {
    const events = [];
    const requests = [];
    const frames = [];
    const timers = [];
    const intervals = [];
    const documentListeners = new Map();
    const windowListeners = new Map();
    let scrollX = 0;
    let scrollY = 0;
    let observed;
    const window = {
        get scrollY() { return scrollY; },
        innerWidth: 1080, innerHeight: 1400, devicePixelRatio: 1,
        PdfJsBridge: { postMessage: json => events.push(JSON.parse(json)) },
        addEventListener: (name, callback) => windowListeners.set(name, callback),
        scrollBy: ({ left = 0, top = 0 }) => {
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
            const result = type === 'open' ? { pageCount: 189, capabilities: 'test' }
                : type === 'render' ? { width: 16, height: 20, pageWidth: 612, pageHeight: 792 + payload.pageNumber * 3, pixels: new Uint8ClampedArray(1280) }
                    : type === 'outline' ? [{ children: [{}, { pageNumber: 4, children: [] }] }]
                        : type === 'click' ? { actions: ['NextPage'], targetPage: payload.pageNumber + 1 } : 'pong';
            queueMicrotask(() => this.onmessage?.({ data: { id, result } }));
        }
        terminate() { }
    }
    const context = vm.createContext({
        document, window, Worker, URL, CSS: { supports: () => true },
        ImageData: class { }, Date, Math, Map, Set, Promise,
        setInterval: callback => intervals.push(callback), clearInterval() { },
        setTimeout: callback => timers.push(callback),
        requestAnimationFrame: callback => frames.push(callback),
        IntersectionObserver: class {
            constructor(callback) { observed = callback; }
            observe() { }
            disconnect() { }
        },
    });
    const module = new vm.SourceTextModule(await readFile(new URL('../assets/embedpdf_viewer/viewer.mjs', import.meta.url), 'utf8'), {
        context, initializeImportMeta: meta => { meta.url = new URL('../assets/embedpdf_viewer/viewer.mjs', import.meta.url).href; },
    });
    await module.link(() => new vm.SyntheticModule(['limits', 'failure', 'createPageScrollLimiter'], function () {
        this.setExport('limits', limits);
        this.setExport('failure', failure);
        this.setExport('createPageScrollLimiter', createPageScrollLimiter);
    }, { context }));
    await module.evaluate();
    const settle = async () => {
        for (let turn = 0; turn < 60; turn++) {
            await Promise.resolve();
            frames.splice(0).forEach(callback => callback());
            timers.splice(0).forEach(callback => callback());
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
    await send('open', { config: { session: 'current', initialPage: 2, columns: 1, margin: 8 } });
    events.length = 0;
    return {
        root, events, requests, settle, send, observe, window,
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
    view.root.listeners.get('touchend')({});
    assert.deepEqual(view.pages(), [6]);
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