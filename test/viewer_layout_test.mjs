import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test, { after, before } from "node:test";
import vm from "node:vm";

const assets = new URL("../assets/", import.meta.url);
const source = readFileSync(new URL("viewer/viewer.mjs", assets), "utf8");
const playwrightModule = process.env.PDFJS_PLAYWRIGHT_MODULE;
let browser;

test("bridge navigation uses anchor-aware scrolling and clamps page numbers", () => {
    const pages = [];
    const context = vm.createContext({
        PROTOCOL_VERSION: 1,
        state: {
            ready: true,
            pdfViewer: {
                pagesCount: 3,
                scrollPageIntoView: ({ pageNumber }) => pages.push(pageNumber),
                set currentPageNumber(_) {
                    assert.fail("navigation must clear the previous viewport anchor before scrolling");
                },
            },
        },
        clamp: (value, min, max) => Math.max(min, Math.min(max, value)),
    });
    vm.runInContext(shippedFunction(source, "handle"), context);
    for (const pageNumber of [3, 1, 100, -1, 1.5]) {
        context.pageNumber = pageNumber;
        vm.runInContext('handle({ v: 1, type: "goToPage", pageNumber })', context);
    }
    assert.deepEqual(pages, [3, 1, 3, 1]);
    context.state.ready = false;
    vm.runInContext('handle({ v: 1, type: "goToPage", pageNumber: 2 })', context);
    assert.deepEqual(pages, [3, 1, 3, 1]);
});

function method(text, name, className = "PDFViewer") {
    const start = text.indexOf(`  ${name}(`, text.indexOf(`class ${className}`));
    const end = text.indexOf("\n  }", start) + 4;
    assert.ok(start >= 0 && end > start, `Cannot locate PDFViewer.${name}`);
    return text.slice(start, end).replaceAll("this.#", "this.")
        .replaceAll("_ui_utils_js__WEBPACK_IMPORTED_MODULE_13__.", "");
}

function shippedFunction(text, name) {
    const start = text.indexOf(`function ${name}(`);
    const end = text.indexOf("\n}\n", start) + 2;
    assert.ok(start >= 0 && end > start, `Cannot locate ${name}`);
    return text.slice(start, end);
}

function layoutFixture(tier) {
    const engine = readFileSync(new URL(`pdfjs/${tier}/web/pdf_viewer.mjs`, assets), "utf8");
    const helpers = ["binarySearchFirstItem", "backtrackBeforeAllVisibleElements", "getVisibleElements"];
    if (engine.includes("function visibleSort(")) helpers.push("visibleSort");
    const callbacks = [];
    const listeners = new Map();
    const container = {
        clientWidth: 1200, clientHeight: 800, clientLeft: 0, clientTop: 0,
        scrollTop: 0, scrollLeft: 0, getBoundingClientRect: () => ({ top: 0, left: 0 }),
        addEventListener(type, listener) {
            const previous = listeners.get(type);
            listeners.set(type, (event) => { previous?.(event); listener(event); });
        }
    };
    const state = { columns: 3, config: { margin: 8 }, ready: true, fitScale: 1 };
    const context = vm.createContext({
        container, state, DEFAULT_CACHE_SIZE: 10,
        ScrollMode: { PAGE: 3, VERTICAL: 0, HORIZONTAL: 1, WRAPPED: 2 }, SpreadMode: { NONE: 0 },
        viewer: { classList: { toggle() { } }, style: {} }, positiveInt: (number, fallback) => number > 0 ? number : fallback,
        TAP_SLOP_PX: 12, LONG_PRESS_MS: 500, DOUBLE_TAP_MS: 300, DOUBLE_TAP_DISTANCE_PX: 40, MAX_SCALE: 6,
        clamp: (value, minimum, maximum) => Math.min(Math.max(value, minimum), maximum),
        ResizeObserver: class { observe() { } }, setTimeout, clearTimeout,
        eventBus: { dispatch(type, payload) { if (type === "pagechanging") callbacks.push(payload.pageNumber); } },
    });
    vm.runInContext(helpers.map((name) => shippedFunction(engine, name)).join("\n") + `
        class PDFViewer {
            constructor() {
                this.container = container;
                this.eventBus = eventBus;
                this._currentPageNumber = 1;
                this._spreadMode = SpreadMode.NONE;
                this._scrollMode = ScrollMode.VERTICAL;
                this._currentScale = 1;
                this.buffer = { resize() {}, *[Symbol.iterator]() {} };
                this.renderingQueue = { renderHighestPriority() {} };
                this._pages = Array.from({ length: 30 }, (_, index) => {
                    const page = { id: index + 1, width: 600, height: index === 6 ? 1800 : 800,
                        scale: 1, viewport: {}, updateVisibleArea() {} };
                    page.div = { clientLeft: 0, clientTop: 0, getBoundingClientRect: () => ({
                        left: page.div.offsetLeft - container.scrollLeft,
                        top: page.div.offsetTop - container.scrollTop,
                        width: page.div.clientWidth, height: page.div.clientHeight,
                    }) };
                    return page;
                });
                this.reflow();
            }
            get currentPageNumber() { return this._currentPageNumber; }
            set currentPageNumber(number) { this._setCurrentPageNumber(number, true); }
            get pagesCount() { return this._pages.length; }
            getPageView(index) { return this._pages[index]; }
            get currentScale() { return this._currentScale; }
            set currentScale(scale) {
                this._currentScale = scale;
                this.reflow();
                this.scrollPageIntoView({ pageNumber: this._location?.pageNumber ?? this.currentPageNumber });
                this.update();
            }
            get scrollMode() { return this._scrollMode; }
            set scrollMode(mode) {
                if (mode === this._scrollMode) return;
                this._scrollMode = mode;
                this.reflow();
                this._setCurrentPageNumber(this.currentPageNumber, true);
                this.update();
            }
            reflow() {
                const columns = this._scrollMode === ScrollMode.WRAPPED ? state.columns : 1;
                let rowTop = 8;
                for (let start = 0; start < this.pagesCount; start += columns) {
                    const row = this._pages.slice(start, start + columns);
                    const rowHeight = Math.max(...row.map((page) => page.height * this._currentScale));
                    let left = 8;
                    for (const page of row) {
                        page.scale = this._currentScale;
                        page.viewport.width = page.width * page.scale;
                        page.div.clientWidth = page.viewport.width;
                        page.div.clientHeight = page.height * page.scale;
                        page.div.offsetLeft = left;
                        page.div.offsetTop = rowTop + (rowHeight - page.div.clientHeight) / 2;
                        left += page.div.clientWidth + 8;
                    }
                    rowTop += rowHeight + 8;
                }
            }
            _setCurrentPageNumber(number, reset = false) {
                if (this._currentPageNumber !== number) {
                    this._currentPageNumber = number;
                    this.eventBus.dispatch("pagechanging", { pageNumber: number });
                }
                if (reset) container.scrollTop = this.getPageView(number - 1).div.offsetTop;
                return true;
            }
            scrollPageIntoView({ pageNumber }) { this._setCurrentPageNumber(pageNumber, true); }
            _updateLocation(first) { this._location = { pageNumber: first.id }; }
            ${method(engine, "_getVisiblePages").replace("(0,getVisibleElements)", "getVisibleElements")}
            ${method(engine, "update")}
            ${engine.includes("  #getPageAdvance(")
            ? method(engine, "#getPageAdvance").replace("  #", "  ")
            : method(engine, "_getPageAdvance")}
            ${method(engine, "nextPage")}
            ${method(engine, "previousPage")}
        }
        ${source.slice(source.indexOf("class AnchoredPDFViewer"), source.indexOf("// ---- Annotations"))}
        state.pdfViewer = new AnchoredPDFViewer();
        state.linkService = { pdfDocument: {}, pdfViewer: state.pdfViewer, eventBus,
            ${method(engine, "executeNamedAction", "PDFLinkService")}
        };
    `, context);
    vm.runInContext(source.slice(source.indexOf("const minScale ="), source.indexOf("// iOS fires its own pinch")), context);
    return {
        context, state, container, callbacks, listeners,
        run: (code) => vm.runInContext(code, context),
        anchor: () => {
            const rect = state.pdfViewer.getPageView(6).div.getBoundingClientRect();
            return rect.top / rect.height;
        }
    };
}

for (const tier of ["current", "compat", "legacy"]) {
    test(`${tier}: navigation anchors the target before PDF.js publishes its new page`, () => {
        const fixture = layoutFixture(tier);
        fixture.run(`
            PDFViewer.prototype.scrollPageIntoView = function({ pageNumber }) {
                container.scrollTop = this.getPageView(pageNumber - 1).div.offsetTop;
            };
            state.pdfViewer.currentPageNumber = 3;
            state.pdfViewer.scrollPageIntoView({ pageNumber: 1 });
        `);
        assert.equal(fixture.state.pdfViewer.viewportAnchor.pageNumber, 1);
        fixture.run("state.pdfViewer.update()");
        assert.equal(fixture.state.pdfViewer.currentPageNumber, 1);
    });

    test(`${tier}: a larger visible neighbor cannot replace a vertical navigation target`, () => {
        const fixture = layoutFixture(tier);
        fixture.run(`
            state.pdfViewer.currentPageNumber = 1;
            PDFViewer.prototype._getVisiblePages = () => ({ views: [{ id: 2 }, { id: 1 }] });
        `);
        assert.deepEqual(
            Array.from(fixture.state.pdfViewer._getVisiblePages().views, (page) => page.id),
            [1, 2],
        );
    });

    for (const phase of ["drag", "touchend", "touchcancel"]) {
        for (const direction of ["forward", "backward"]) {
            test(`${tier}: ${direction} touch scrolling beyond four pages stays native during ${phase}`, () => {
                const fixture = layoutFixture(tier);
                const initialPage = direction === "forward" ? 2 : 18;
                const targetPage = direction === "forward" ? 14 : 3;
                let prevented = false;
                fixture.run(`setColumns(1); state.pdfViewer.scrollPageIntoView({ pageNumber: ${initialPage} });`);
                fixture.listeners.get("touchstart")({
                    touches: [{ clientX: 100, clientY: 200 }], timeStamp: 0,
                    preventDefault() { prevented = true; },
                });
                fixture.listeners.get("touchmove")({
                    touches: [{ clientX: 100, clientY: direction === "forward" ? 100 : 300 }],
                    preventDefault() { prevented = true; },
                });
                if (phase !== "drag") {
                    fixture.listeners.get(phase)({ touches: [], timeStamp: 100,
                        preventDefault() { prevented = true; } });
                }
                const offset = fixture.state.pdfViewer.getPageView(targetPage - 1).div.offsetTop;
                fixture.container.scrollTop = offset;
                fixture.state.pdfViewer.update();
                assert.equal(fixture.container.scrollTop, offset);
                assert.equal(fixture.state.pdfViewer.currentPageNumber, targetPage);
                assert.equal(fixture.state.pdfViewer.viewportAnchor, null);
                assert.equal(prevented, false, "Single-touch scrolling must remain browser-owned");
            });
        }
    }

    test(`${tier}: shipped wrapped heuristic drifts without an anchor`, () => {
        const fixture = layoutFixture(tier);
        fixture.run("applyLayout(7); state.pdfViewer.viewportAnchor = null; state.pdfViewer.update();");
        assert.notEqual(fixture.state.pdfViewer.currentPageNumber, 7, "This geometry must expose the original most-visible-page drift");
    });

    test(`${tier}: async dimensions and refit preserve controller, viewport and partial-page anchor`, async () => {
        const fixture = layoutFixture(tier);
        fixture.run("applyLayout(7)");
        fixture.run("const pdfViewer = state.pdfViewer; let finishPages; pdfViewer.pagesPromise = new Promise((resolve) => { finishPages = resolve; });");
        const start = source.indexOf("    pdfViewer.pagesPromise.then(");
        const end = source.indexOf("\n    });", start) + "\n    });".length;
        assert.ok(start >= 0 && end > start, "Cannot locate the shipped full-size-page refit");
        fixture.run(source.slice(start, end).replace("pdfViewer.pagesPromise.then", "globalThis.pagesFitted = pdfViewer.pagesPromise.then"));
        const initial = fixture.anchor();
        for (const [index, width, height] of [[1, 600, 1400], [3, 1200, 2000], [4, 600, 1000]]) {
            await Promise.resolve();
            Object.assign(fixture.state.pdfViewer.getPageView(index), { width, height });
            fixture.state.pdfViewer.reflow();
            fixture.state.pdfViewer.update();
            assert.equal(fixture.state.pdfViewer.currentPageNumber, 7);
            assert.ok(Math.abs(fixture.anchor() - initial) < 0.000001);
        }
        fixture.run("finishPages()");
        await fixture.context.pagesFitted;
        fixture.container.clientWidth = 390;
        fixture.run("applyLayout()");
        assert.equal(fixture.state.pdfViewer.currentPageNumber, 7);
        assert.ok(Math.abs(fixture.anchor() - initial) < 0.000001);
        assert.deepEqual(fixture.callbacks, [7]);
        fixture.listeners.get("wheel")({});
        fixture.container.scrollTop += 30;
        fixture.run("state.pdfViewer.update(); state.pdfViewer.currentPageNumber = 7; container.scrollTop += 20; state.pdfViewer.captureViewportAnchor();");
        const partial = fixture.anchor();
        fixture.container.clientWidth = 1000;
        fixture.run("applyLayout()");
        assert.ok(Math.abs(fixture.anchor() - partial) < 0.000001);
        assert.equal(fixture.state.pdfViewer.currentPageNumber, 7);
    });

    test(`${tier}: scroll input releases the anchor and navigation replaces it`, () => {
        const fixture = layoutFixture(tier);
        fixture.run("applyLayout(7)");
        fixture.run("setColumns(1)");
        fixture.callbacks.length = 0;
        fixture.run("state.linkService.executeNamedAction('NextPage'); state.pdfViewer.update(); state.linkService.executeNamedAction('PrevPage'); state.pdfViewer.update();");
        assert.deepEqual(fixture.callbacks, [8, 7]);
        fixture.run("setColumns(3)");
        fixture.listeners.get("touchmove")({ touches: [{}, {}] });
        assert.ok(fixture.state.pdfViewer.viewportAnchor);
        fixture.listeners.get("touchmove")({ touches: [{}] });
        assert.equal(fixture.state.pdfViewer.viewportAnchor, null);
        fixture.container.scrollTop = fixture.state.pdfViewer.getPageView(12).div.offsetTop;
        fixture.state.pdfViewer.update();
        assert.notEqual(fixture.state.pdfViewer.currentPageNumber, 7);
        fixture.run("state.pdfViewer.scrollPageIntoView({ pageNumber: 13 }); state.pdfViewer.update();");
        assert.equal(fixture.state.pdfViewer.currentPageNumber, 13);
        assert.equal(fixture.state.pdfViewer.viewportAnchor.pageNumber, 13);
    });
}

before(async () => {
    if (!playwrightModule) return;
    const { chromium } = await import(playwrightModule);
    browser = await chromium.launch({
        headless: true, timeout: 10000,
        ...(process.env.PDFJS_CHROMIUM_EXECUTABLE
            ? { executablePath: process.env.PDFJS_CHROMIUM_EXECUTABLE } : {})
    });
});
after(async () => { await browser?.close(); });

for (const tier of ["current", "compat", "legacy"]) {
    test(`${tier}: page spinner follows rendering classes without image assets`,
        { skip: !playwrightModule && "Set PDFJS_PLAYWRIGHT_MODULE to test page loading styles" }, async () => {
            const page = await browser.newPage();
            try {
                await page.setContent('<div class="pdfViewer"><div class="page"></div></div>');
                await page.addStyleTag({
                    content: readFileSync(new URL(`pdfjs/${tier}/web/pdf_viewer.css`, assets), "utf8")
                });
                await page.addStyleTag({
                    content: readFileSync(new URL("viewer/viewer.css", assets), "utf8")
                });
                const indicator = (classes) => page.evaluate((classes) => {
                    const element = document.querySelector(".page");
                    element.className = `page ${classes}`;
                    const style = getComputedStyle(element, "::after");
                    return {
                        display: style.display, animation: style.animationName,
                        background: style.backgroundImage, pointerEvents: style.pointerEvents,
                        width: style.width, border: style.borderTopStyle
                    };
                }, classes);
                assert.equal((await indicator("")).display, "none");
                for (const classes of ["loadingIcon loading", "loadingIcon"]) {
                    const style = await indicator(classes);
                    assert.equal(style.display, "block");
                    assert.equal(style.animation, "pdfjs-page-loading");
                    assert.equal(style.background, "none");
                    assert.equal(style.pointerEvents, "none");
                    assert.equal(style.width, "32px");
                    assert.equal(style.border, "solid");
                }
                assert.equal((await indicator("")).display, "none");
                assert.equal((await indicator("loadingIcon loading")).display, "block",
                    "Rendering an evicted page must show the indicator again");
                await page.emulateMedia({ reducedMotion: "reduce" });
                const reduced = await indicator("loadingIcon loading");
                assert.equal(reduced.display, "block");
                assert.equal(reduced.animation, "none");
            } finally {
                await page.close();
            }
        });
}

function fixture() {
    const objects = [];
    const add = (value) => { objects.push(value); return objects.length; };
    const catalog = add("");
    const pages = add("");
    const font = add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>");
    const children = [];
    for (let number = 1; number <= 30; number++) {
        const width = number === 4 ? 1200 : 600;
        const height = number === 4 ? 2000 : number === 7 ? 1800 : 800;
        const content = `0.1 0.5 0.2 rg 40 40 200 200 re f BT /F1 40 Tf 40 300 Td (Page ${number}) Tj ET`;
        const stream = add(`<< /Length ${Buffer.byteLength(content)} >>\nstream\n${content}\nendstream`);
        children.push(add(`<< /Type /Page /Parent ${pages} 0 R /MediaBox [0 0 ${width} ${height}] /Resources << /Font << /F1 ${font} 0 R >> >> /Contents ${stream} 0 R >>`));
    }
    objects[catalog - 1] = `<< /Type /Catalog /Pages ${pages} 0 R >>`;
    objects[pages - 1] = `<< /Type /Pages /Count ${children.length} /Kids [${children.map((id) => `${id} 0 R`).join(" ")}] >>`;
    let document = "%PDF-1.7\n";
    const offsets = [0];
    for (const [index, object] of objects.entries()) {
        offsets.push(Buffer.byteLength(document));
        document += `${index + 1} 0 obj\n${object}\nendobj\n`;
    }
    const xref = Buffer.byteLength(document);
    document += `xref\n0 ${offsets.length}\n0000000000 65535 f \n`;
    document += offsets.slice(1).map((offset) => `${String(offset).padStart(10, "0")} 00000 n \n`).join("");
    document += `trailer\n<< /Size ${offsets.length} /Root ${catalog} 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
    return Buffer.from(document);
}

const pdf = fixture();
const instrumentedSource = source.replace("    pdfViewer.setDocument(pdfDocument);", `
    const getPage = pdfDocument.getPage.bind(pdfDocument);
    const releases = new Map();
    const requested = new Set();
    const gates = new Map([2, 3, 4, 5].map((number) => [number, new Promise((resolve) => releases.set(number, resolve))]));
    pdfDocument.getPage = (number) => {
        requested.add(number);
        return gates.has(number) ? gates.get(number).then(() => getPage(number)) : getPage(number);
    };
    globalThis.layoutRegression = { state, applyLayout, releases, requested };
    pdfViewer.setDocument(pdfDocument);`);
assert.notEqual(instrumentedSource, source, "Cannot instrument the shipped document boundary");

async function snapshot(page) {
    return page.evaluate(() => {
        const { pdfViewer } = layoutRegression.state;
        const rect = pdfViewer.getPageView(6).div.getBoundingClientRect();
        return {
            pageNumber: pdfViewer.currentPageNumber, top: rect.top, height: rect.height,
            left: rect.left, width: rect.width, fitScale: layoutRegression.state.fitScale,
            scale: pdfViewer.currentScale,
            viewportHeight: pdfViewer.container.clientHeight,
            scrollTop: pdfViewer.container.scrollTop,
            maxScrollTop: Math.max(0, pdfViewer.container.scrollHeight - pdfViewer.container.clientHeight),
            callbacks: events.filter((event) => event.type === "pageChanged").map((event) => event.pageNumber)
        };
    });
}

function sameAnchor(actual, expected) {
    assert.equal(actual.pageNumber, 7, "The actual PDFViewer page must stay selected");
    const targetScroll = actual.scrollTop + actual.top - expected.top / expected.height * actual.height;
    const reachableScroll = Math.min(Math.max(targetScroll, 0), actual.maxScrollTop);
    assert.ok(Math.abs(actual.scrollTop - reachableScroll) / actual.height < 0.015,
        `The page-7 document point moved: ${JSON.stringify({ actual, expected })}`);
    assert.ok(actual.top < actual.viewportHeight && actual.top + actual.height > 0, "Page 7 must remain visible");
    assert.ok(actual.callbacks.every((number) => number === 7), "Do not hide transient controller drift");
}

for (const tier of ["current", "compat", "legacy"]) {
    for (const viewport of [{ width: 1200, height: 800 }, { width: 390, height: 844 }]) {
        test(`${tier} ${viewport.width}: delayed dimensions, grid/resize anchor and real navigation`,
            { skip: !playwrightModule && "Set PDFJS_PLAYWRIGHT_MODULE to run real viewport regression tests" }, async () => {
                const context = await browser.newContext({ viewport });
                const page = await context.newPage();
                const errors = [];
                page.on("pageerror", (error) => errors.push(String(error)));
                const origin = "http://pdfjs-regression.test";
                await context.route("**/*", async (route) => {
                    const url = new URL(route.request().url());
                    assert.equal(url.origin, origin, "No external requests are allowed");
                    if (url.pathname === "/") {
                        return route.fulfill({
                            contentType: "text/html", body: `<!doctype html><html><head>
                            <link rel="stylesheet" href="/pdfjs/web/pdf_viewer.css">
                            <link rel="stylesheet" href="/viewer/viewer.css"></head><body>
                            <div id="viewerContainer"><div id="viewer" class="pdfViewer"></div></div>
                            <script type="module" src="/viewer/viewer.mjs"></script></body></html>` });
                    }
                    if (url.pathname === "/fixture.pdf") {
                        return route.fulfill({ contentType: "application/pdf", body: pdf });
                    }
                    const path = url.pathname.startsWith("/pdfjs/")
                        ? url.pathname.replace("/pdfjs/", `/pdfjs/${tier}/`) : url.pathname;
                    try {
                        const body = path === "/viewer/viewer.mjs" ? instrumentedSource : readFileSync(new URL(`.${path}`, assets));
                        return route.fulfill({
                            body, contentType: path.endsWith(".mjs") ? "text/javascript"
                                : path.endsWith(".css") ? "text/css" : "application/octet-stream"
                        });
                    } catch {
                        return route.fulfill({ status: 404, body: "Missing fixture asset" });
                    }
                });
                await page.addInitScript(() => {
                    globalThis.events = [];
                    globalThis.PdfJsBridge = { postMessage: (raw) => events.push(JSON.parse(raw)) };
                });
                try {
                    await page.goto(origin);
                    await page.waitForFunction(() => Boolean(globalThis.pdfjsBridge));
                    await page.evaluate((origin) => pdfjsBridge.receive(JSON.stringify({
                        v: 1, type: "open", config: {
                            documentUrl: `${origin}/fixture.pdf`, initialPage: 7, columns: 3, margin: 8,
                        }
                    })), origin);
                    await page.waitForFunction(() => events.some((event) => event.type === "firstPageRendered" && event.pageNumber === 7));
                    await page.waitForFunction(() => layoutRegression.requested.has(2));
                    const initial = await snapshot(page);
                    sameAnchor(initial, initial);
                    for (const number of [2, 3, 4, 5]) {
                        await page.evaluate((number) => layoutRegression.releases.get(number)(), number);
                        await page.waitForFunction((number) => Boolean(layoutRegression.state.pdfViewer.getPageView(number - 1).pdfPage), number);
                        await page.evaluate(() => layoutRegression.state.pdfViewer.update());
                        sameAnchor(await snapshot(page), initial);
                    }
                    await page.evaluate(() => layoutRegression.state.pdfViewer.pagesPromise);
                    await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
                    const fitted = await snapshot(page);
                    sameAnchor(fitted, initial);
                    assert.ok(fitted.fitScale < initial.fitScale, "The delayed landscape page must trigger refit");
                    assert.deepEqual(await page.evaluate(() => events.filter((event) => event.type === "ready" || event.type === "firstPageRendered").map((event) => event.pageNumber)), [7, 7]);
                    const nonblank = await page.evaluate(() => {
                        const canvas = layoutRegression.state.pdfViewer.getPageView(6).div.querySelector("canvas");
                        return canvas && canvas.getContext("2d").getImageData(0, 0, canvas.width, canvas.height).data.some((value, index) => index % 4 !== 3 && value < 100);
                    });
                    assert.ok(nonblank, "The anchored page must contain painted pixels");
                    await page.setViewportSize({ width: viewport.width - 40, height: viewport.height - 70 });
                    await page.waitForFunction((scale) => Math.abs(layoutRegression.state.fitScale - scale) > 0.001, fitted.fitScale);
                    sameAnchor(await snapshot(page), initial);
                    for (const columns of [1, 3]) {
                        await page.evaluate((columns) => pdfjsBridge.receive(JSON.stringify({ v: 1, type: "setLayout", columns })), columns);
                        sameAnchor(await snapshot(page), initial);
                    }
                    await page.evaluate(() => pdfjsBridge.receive(JSON.stringify({ v: 1, type: "setLayout", columns: 1 })));
                    await page.evaluate(() => {
                        events.length = 0;
                        layoutRegression.state.linkService.executeNamedAction("NextPage");
                        layoutRegression.state.linkService.executeNamedAction("PrevPage");
                        layoutRegression.state.pdfViewer.update();
                    });
                    assert.equal((await snapshot(page)).pageNumber, 7);
                    assert.deepEqual((await snapshot(page)).callbacks, [8, 7], "Named actions must use the actual page and turn exactly once");
                    await page.mouse.move(viewport.width / 2, viewport.height / 2);
                    const distance = await page.evaluate(() => {
                        const { pdfViewer } = layoutRegression.state;
                        return pdfViewer.getPageView(6).div.getBoundingClientRect().bottom + pdfViewer.container.clientHeight;
                    });
                    await page.mouse.wheel(0, distance);
                    await page.waitForFunction(() => layoutRegression.state.pdfViewer.currentPageNumber > 7);
                    assert.equal(await page.evaluate(() => layoutRegression.state.pdfViewer.viewportAnchor == null), true);
                    await page.evaluate(() => pdfjsBridge.receive(JSON.stringify({ v: 1, type: "goToPage", pageNumber: 13 })));
                    await page.evaluate(() => layoutRegression.state.pdfViewer.update());
                    assert.equal((await snapshot(page)).pageNumber, 13, "Explicit navigation must replace the old anchor");
                    assert.deepEqual(errors, []);
                } finally {
                    await context.close();
                }
            });
    }
}