// Host page for the Flutter PDF.js viewer. Talks to Dart over a versioned JSON bridge.
//
// ENGINE FLOOR: Chrome 85 / Safari 14.
//
// This file must stay at or below the floor of the OLDEST bundle it can be
// loaded with, or the `legacy` tier is dead on engines that could otherwise run
// it. That floor is not a guess: grepping the vendored pdfjs-dist 4.1.392 build
// shows it already requires logical assignment (`||=`, Chrome 85 / Safari 14),
// class private instance methods (Chrome 84 / Safari 15) and optional chaining
// (Chrome 80 / Safari 13.1); the runtime APIs it uses above that line are
// core-js polyfilled inside the bundle, so they do not raise it.
//
// This file is NOT polyfilled, so both syntax and runtime APIs count here.
// test/viewer_asset_syntax_test.dart holds this upper bound even if a refactor
// removes a feature that once required the floor; that is why there
// is no transpile step and no second host page.
//
// Chrome 66 — Android 9's stock System WebView — is far below this floor and
// below the floor of every vendored bundle, so nothing in this file can make
// that engine work. See docs/implementation/evidence/android9_stock_webview.md.
import * as pdfjsLib from "../pdfjs/build/pdf.min.mjs";
import {
    EventBus,
    FindState,
    LinkTarget,
    PDFFindController,
    PDFLinkService,
    PDFViewer,
    ScrollMode,
} from "../pdfjs/web/pdf_viewer.mjs";

// WebKit has no ReadableStream async iteration, which PDF.js text extraction (search) iterates.
if (typeof ReadableStream !== "undefined" && !ReadableStream.prototype[Symbol.asyncIterator]) {
    ReadableStream.prototype.values = async function* (options) {
        const reader = this.getReader();
        let finished = false;
        try {
            for (;;) {
                const { done, value } = await reader.read();
                if (done) {
                    finished = true;
                    return;
                }
                yield value;
            }
        } finally {
            if (!finished && !options?.preventCancel) await reader.cancel().catch(() => {});
            reader.releaseLock();
        }
    };
    ReadableStream.prototype[Symbol.asyncIterator] = ReadableStream.prototype.values;
}

const PROTOCOL_VERSION = 1;
const DOUBLE_TAP_MS = 300;
const LONG_PRESS_MS = 500;
const TAP_SLOP_PX = 12;
const DOUBLE_TAP_DISTANCE_PX = 40;
const RESIZE_DEBOUNCE_MS = 200;
// PDF.js CSS scale; about pdfrx's default max scale of 8 in PDF points.
const MAX_SCALE = 6;

const container = document.getElementById("viewerContainer");
const viewer = document.getElementById("viewer");

const state = {
    config: null,
    pdfDocument: null,
    pdfViewer: null,
    eventBus: null,
    linkService: null,
    outline: [],
    columns: 1,
    fitScale: 1,
    ready: false,
    lastQuery: "",
};

function post(type, payload = {}) {
    const channel = globalThis.PdfJsBridge;
    if (channel) {
        channel.postMessage(JSON.stringify({ v: PROTOCOL_VERSION, type, ...payload }));
    }
}

function assetUrl(path) {
    return new URL(path, import.meta.url).href;
}

function clamp(value, min, max) {
    return Math.min(Math.max(value, min), max);
}

function positiveInt(value, fallback) {
    return Number.isInteger(value) && value > 0 ? value : fallback;
}

function applyTheme(config) {
    const root = document.documentElement.style;
    root.setProperty("--viewer-margin", `${Number(config.margin) || 0}px`);
    for (const [name, key] of [
        ["--viewer-background", "backgroundColor"],
        ["--viewer-page-shadow", "pageShadowColor"],
        ["--viewer-match", "matchColor"],
        ["--viewer-active-match", "activeMatchColor"],
    ]) {
        if (typeof config[key] === "string" && CSS.supports("color", config[key])) {
            root.setProperty(name, config[key]);
        }
    }
}

async function open(config) {
    state.config = config;
    state.columns = positiveInt(config.columns, 1);
    applyTheme(config);

    pdfjsLib.GlobalWorkerOptions.workerSrc = assetUrl("../pdfjs/build/pdf.worker.min.mjs");

    const documentOptions = {
        url: config.documentUrl,
        cMapUrl: assetUrl("../pdfjs/cmaps/"),
        cMapPacked: true,
        standardFontDataUrl: assetUrl("../pdfjs/standard_fonts/"),
        // CVE-2024-4367: never compile font paths with `new Function`.
        isEvalSupported: false,
        enableXfa: false,
    };
    // Canvas backing store. PDF.js 6 threads this down to every page's 2D
    // context as `getContext("2d", {alpha: false, willReadFrequently:
    // !enableHWA})`, and its own default is `false` — so an unset option asks
    // for a software backing store on every page. The option exists in the
    // `compat` and `current` bundles only; `legacy` 4.1.392 calls
    // `getContext("2d")` with no options anywhere and has no such option.
    //
    // Dart sends the key only for the tiers that implement it (`_sendOpen` in
    // pdfjs_viewer.dart), and only when it has been configured, so this stays
    // absent — not `undefined` — otherwise. The `typeof` guard keeps a
    // malformed config from turning into `enableHWA: "true"`, which PDF.js
    // would read as truthy.
    if (typeof config.enableHwa === "boolean") {
        documentOptions.enableHWA = config.enableHwa;
    }

    let pdfDocument;
    try {
        pdfDocument = await pdfjsLib.getDocument(documentOptions).promise;
    } catch (error) {
        post("error", { name: error?.name ?? "Error", message: String(error?.message ?? error) });
        return;
    }

    const largeDocument = pdfDocument.numPages >= positiveInt(config.largeDocumentPageCount, Infinity);
    const eventBus = new EventBus();
    const linkService = new PDFLinkService({
        eventBus,
        externalLinkTarget: LinkTarget.NONE,
        externalLinkRel: "noopener noreferrer nofollow",
        ignoreDestinationZoom: true,
    });
    const findController = new PDFFindController({
        eventBus,
        linkService,
        updateMatchesCountOnProgress: true,
    });
    const pdfViewer = new AnchoredPDFViewer({
        container,
        viewer,
        eventBus,
        linkService,
        findController,
        annotationMode: pdfjsLib.AnnotationMode.ENABLE,
        imageResourcesPath: assetUrl("../pdfjs/web/images/"),
        maxCanvasPixels: largeDocument
            ? positiveInt(config.largeDocumentMaxCanvasPixels, undefined)
            : positiveInt(config.maxCanvasPixels, undefined),
    });
    linkService.setViewer(pdfViewer);
    let reportedFirstPagePaint = false;

    Object.assign(state, { pdfDocument, pdfViewer, eventBus, linkService });
    const resolvePageNumber = createPageResolver(pdfDocument);

    eventBus.on("pagesinit", () => {
        applyLayout(clamp(positiveInt(config.initialPage, 1), 1, pdfDocument.numPages));
        state.ready = true;
        post("ready", { pageCount: pdfDocument.numPages, pageNumber: pdfViewer.currentPageNumber });
    });
    eventBus.on("pagechanging", ({ pageNumber }) => {
        if (state.ready) post("pageChanged", { pageNumber });
    });
    eventBus.on("pagerendered", ({ pageNumber }) => {
        if (!reportedFirstPagePaint && pageNumber === pdfViewer.currentPageNumber) {
            reportedFirstPagePaint = true;
            post("firstPageRendered", { pageNumber });
        }
    });
    eventBus.on("annotationlayerrendered", ({ source }) => {
        void letInertAnnotationsFallThrough(source, resolvePageNumber);
    });
    eventBus.on("updatefindmatchescount", ({ matchesCount }) => postFindState(matchesCount, false));
    eventBus.on("updatefindcontrolstate", ({ state: findState, matchesCount }) =>
        postFindState(matchesCount, findState === FindState.PENDING)
    );

    pdfViewer.setDocument(pdfDocument);
    linkService.setDocument(pdfDocument, null);
    // The outline is chrome, not content. Building it walks the whole outline
    // tree on the worker, which on a large document delays the first page by
    // seconds, so wait until something is on screen.
    afterFirstPaint(() => loadOutline(pdfDocument, resolvePageNumber));

    // Until PDF.js has fetched every page, all page views carry the first
    // page's size. Refit once the real sizes are known; if the user has
    // zoomed in the meantime only the zoom floor moves.
    pdfViewer.pagesPromise.then(() => {
        if (!state.ready || state.pdfViewer !== pdfViewer) return;
        const zoomed = Math.abs(pdfViewer.currentScale - state.fitScale) > 0.001;
        if (!zoomed) {
            applyLayout();
            return;
        }
        const scale = computeFitScale();
        if (Number.isFinite(scale) && scale > 0) state.fitScale = scale;
    });
}

// ---- Layout -------------------------------------------------------------

class AnchoredPDFViewer extends PDFViewer {
    captureViewportAnchor() {
        const pageView = this.getPageView(this.currentPageNumber - 1);
        if (!pageView) return;
        const rect = pageView.div.getBoundingClientRect();
        const bounds = this.container.getBoundingClientRect();
        if (!rect.width || !rect.height) return;
        this.viewportAnchor = {
            pageNumber: this.currentPageNumber,
            fx: (bounds.left + this.container.clientLeft - rect.left) / rect.width,
            fy: (bounds.top + this.container.clientTop - rect.top) / rect.height,
        };
    }

    restoreViewportAnchor() {
        const anchor = this.viewportAnchor;
        if (!anchor) return;
        const rect = this.getPageView(anchor.pageNumber - 1).div.getBoundingClientRect();
        const bounds = this.container.getBoundingClientRect();
        this.container.scrollLeft += rect.left + anchor.fx * rect.width - bounds.left - this.container.clientLeft;
        this.container.scrollTop += rect.top + anchor.fy * rect.height - bounds.top - this.container.clientTop;
    }

    _getVisiblePages() {
        this.restoreViewportAnchor();
        const visible = super._getVisiblePages();
        if (this.viewportAnchor && this.scrollMode === ScrollMode.WRAPPED) {
            const index = visible.views.findIndex((page) => page.id === this.viewportAnchor.pageNumber);
            if (index > 0) visible.views.unshift(...visible.views.splice(index, 1));
        }
        return visible;
    }

    _setCurrentPageNumber(pageNumber, resetCurrentPageView = false) {
        if (resetCurrentPageView && !this.preservingAnchor) this.viewportAnchor = null;
        const result = super._setCurrentPageNumber(pageNumber, resetCurrentPageView);
        if (result && resetCurrentPageView && !this.preservingAnchor) this.captureViewportAnchor();
        return result;
    }

    scrollPageIntoView(options) {
        if (this.preservingAnchor && this.viewportAnchor) {
            super.scrollPageIntoView({ pageNumber: this.viewportAnchor.pageNumber });
            this.restoreViewportAnchor();
            return;
        }
        this.viewportAnchor = null;
        super.scrollPageIntoView(options);
        this.captureViewportAnchor();
    }
}

function pageWidthAtScaleOne(pageView) {
    return pageView.viewport.width / pageView.scale;
}

// Fits the widest page. PDF.js applies one scale to the whole document, so a
// per-page fit is not possible and fitting any narrower page would let wider
// (landscape) pages overflow horizontally.
function computeFitScale() {
    const { pdfViewer } = state;
    const width = container.clientWidth;
    const margin = Number(state.config.margin) || 0;
    let maxPageWidth = 0;
    for (let i = 0; i < pdfViewer.pagesCount; i++) {
        maxPageWidth = Math.max(maxPageWidth, pageWidthAtScaleOne(pdfViewer.getPageView(i)));
    }
    if (maxPageWidth <= 0) return null;
    if (state.columns <= 1) return (width - 2 * margin) / maxPageWidth;
    // One spare pixel keeps rounding from pushing the last page to the next row.
    return (width - (state.columns + 1) * margin - 1) / (state.columns * maxPageWidth);
}

function applyLayout(initialPage = null) {
    const { pdfViewer } = state;
    if (!pdfViewer || pdfViewer.pagesCount === 0) return;

    if (!pdfViewer.viewportAnchor) pdfViewer.captureViewportAnchor();
    pdfViewer.preservingAnchor = true;
    try {
        viewer.classList.toggle("grid", state.columns > 1);
        pdfViewer.scrollMode = state.columns > 1 ? ScrollMode.WRAPPED : ScrollMode.VERTICAL;

        const scale = computeFitScale();
        if (!Number.isFinite(scale) || scale <= 0) return;
        state.fitScale = scale;
        pdfViewer.currentScale = scale;
    } finally {
        pdfViewer.preservingAnchor = false;
    }
    if (initialPage !== null) pdfViewer.scrollPageIntoView({ pageNumber: initialPage });
    pdfViewer.restoreViewportAnchor();
    pdfViewer.update();
}

function setColumns(columns) {
    state.columns = positiveInt(columns, 1);
    if (state.ready) applyLayout();
}

let resizeTimer = null;
new ResizeObserver(() => {
    if (!state.ready) return;
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(() => applyLayout(), RESIZE_DEBOUNCE_MS);
}).observe(container);

for (const type of ["wheel", "touchmove", "pointerdown", "keydown"]) {
    container.addEventListener(type, (event) => {
        if (type === "touchmove" && event.touches.length !== 1) return;
        if (type === "pointerdown" && event.target !== container) return;
        if (type === "keydown" && !["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "PageUp", "PageDown", "Home", "End", " "].includes(event.key)) return;
        if (state.pdfViewer) state.pdfViewer.viewportAnchor = null;
    }, { passive: true });
}

// ---- Annotations --------------------------------------------------------

// PDF.js hands a click to the topmost annotation. A link or push button whose
// destination cannot be resolved would swallow taps meant for a working link
// beneath it (the crew PDFs stack such a button on their home icon), so those
// stop receiving pointer events and the click reaches the link underneath.
// Which annotations are inert never changes for a page, but PDF.js rebuilds the
// annotation layer on every zoom and whenever a page re-enters the visible
// range. `open` handles a single document, so the answer can be cached for the
// lifetime of the page.
const inertAnnotationIds = new Map();

async function findInertAnnotations(pdfPage, resolvePageNumber) {
    // getAnnotations() is not cached on this side of the bridge: every call is a
    // worker round trip plus a structured clone of every annotation on the page.
    const annotations = await pdfPage.getAnnotations();
    const candidates = annotations.filter((annotation) => {
        const isLink = annotation.subtype === "Link";
        const isPushButton = annotation.subtype === "Widget" && annotation.pushButton === true;
        if (!isLink && !isPushButton) return false;
        if (annotation.url || annotation.action || annotation.actions) return false;
        return !(annotation.attachment || annotation.setOCGState || annotation.resetForm);
    });
    // Awaiting per annotation serialises one round trip each; resolve the whole
    // page in a single batch instead.
    const targets = await Promise.all(candidates.map((annotation) => resolvePageNumber(annotation.dest)));
    return candidates.filter((_, index) => !targets[index]).map((annotation) => annotation.id);
}

async function letInertAnnotationsFallThrough(pageView, resolvePageNumber) {
    const { pdfPage, div, id } = pageView;
    let ids = inertAnnotationIds.get(id);
    if (ids === undefined) {
        try {
            ids = await findInertAnnotations(pdfPage, resolvePageNumber);
        } catch {
            return;
        }
        inertAnnotationIds.set(id, ids);
    }
    for (const annotationId of ids) {
        const section = div.querySelector(`section[data-annotation-id="${CSS.escape(annotationId)}"]`);
        if (section) section.style.pointerEvents = "none";
    }
}

// ---- Zoom and taps ------------------------------------------------------

const minScale = () => state.fitScale;
const maxScale = () => Math.max(state.fitScale * 2, MAX_SCALE);

function pageAnchorAt(point) {
    const page = document.elementFromPoint(point.x, point.y)?.closest(".page");
    if (!page) return null;
    const rect = page.getBoundingClientRect();
    return { page, fx: (point.x - rect.left) / rect.width, fy: (point.y - rect.top) / rect.height };
}

function zoomTo(scale, point) {
    const { pdfViewer } = state;
    const target = clamp(scale, minScale(), maxScale());
    if (Math.abs(target - pdfViewer.currentScale) < 0.001) return;

    const anchor = pageAnchorAt(point);
    pdfViewer.currentScale = target;
    if (!anchor) return;
    // Keep the document point under the finger in place.
    const rect = anchor.page.getBoundingClientRect();
    container.scrollLeft += rect.left + anchor.fx * rect.width - point.x;
    container.scrollTop += rect.top + anchor.fy * rect.height - point.y;
    pdfViewer.viewportAnchor = null;
}

let lastDoubleTapZoomAt = -Infinity;

// Cycles fit width, 2x and 4x around the tapped point, like pdfrx's zoom loop.
function zoomOnDoubleTap(point) {
    lastDoubleTapZoomAt = performance.now();
    const current = state.pdfViewer.currentScale;
    const steps = [minScale() * 2, minScale() * 4].filter((scale) => scale <= maxScale());
    const next = steps.find((scale) => scale > current + 0.001) ?? minScale();
    zoomTo(next, point);
}

function pageNumberAt(target) {
    const page = target instanceof Element ? target.closest(".page") : null;
    return page ? positiveInt(Number(page.dataset.pageNumber), null) : null;
}

const touchDistance = (touches) =>
    Math.hypot(touches[0].clientX - touches[1].clientX, touches[0].clientY - touches[1].clientY);
const touchMidpoint = (touches) => ({
    x: (touches[0].clientX + touches[1].clientX) / 2,
    y: (touches[0].clientY + touches[1].clientY) / 2,
});

let pinch = null;
let tapStart = null;
let lastTap = null;

container.addEventListener(
    "touchstart",
    (event) => {
        if (!state.ready) return;
        if (event.touches.length === 2) {
            event.preventDefault();
            tapStart = null;
            const origin = touchMidpoint(event.touches);
            const rect = viewer.getBoundingClientRect();
            pinch = {
                startDistance: touchDistance(event.touches),
                startScale: state.pdfViewer.currentScale,
                factor: 1,
                origin,
            };
            viewer.style.transformOrigin = `${origin.x - rect.left}px ${origin.y - rect.top}px`;
        } else if (event.touches.length === 1) {
            const touch = event.touches[0];
            tapStart = { x: touch.clientX, y: touch.clientY, time: event.timeStamp };
        }
    },
    { passive: false }
);

container.addEventListener(
    "touchmove",
    (event) => {
        if (pinch && event.touches.length === 2) {
            event.preventDefault();
            pinch.factor = clamp(
                touchDistance(event.touches) / pinch.startDistance,
                minScale() / pinch.startScale,
                maxScale() / pinch.startScale
            );
            viewer.style.transform = `scale(${pinch.factor})`;
        } else if (tapStart && event.touches.length === 1) {
            const touch = event.touches[0];
            if (Math.hypot(touch.clientX - tapStart.x, touch.clientY - tapStart.y) > TAP_SLOP_PX) {
                tapStart = null;
            }
        }
    },
    { passive: false }
);

function annotationLinkAt(target) {
    return target instanceof Element ? target.closest(".annotationLayer a") : null;
}

// WKWebView turns a tap into a click only after dispatching a synthetic
// mousemove and watching the page for content changes for a few frames. While
// PDF.js is still rendering the page it just scrolled to, that check sees the
// new canvas, text and annotation layers appear, treats the tap as a hover and
// never sends the click, so links needed a second tap after every page change.
// Clicking the link from the touch itself skips that heuristic; PDF.js's own
// onclick handlers (GoTo destinations, named actions) and the external-link
// listener below still run.
function clickAnnotationLink(event, tap) {
    const link =
        annotationLinkAt(event.target) ?? annotationLinkAt(document.elementFromPoint(tap.x, tap.y));
    if (!link?.isConnected) return;
    event.preventDefault();
    link.click();
}

// Taps that miss a link are left to the browser. A second tap within the
// double-tap window is consumed for zooming.
container.addEventListener(
    "touchend",
    (event) => {
        if (pinch) {
            if (event.touches.length < 2) {
                const { startScale, factor, origin } = pinch;
                pinch = null;
                viewer.style.transform = "";
                viewer.style.transformOrigin = "";
                zoomTo(startScale * factor, origin);
            }
            tapStart = null;
            return;
        }
        if (!tapStart || event.touches.length > 0) return;

        const tap = tapStart;
        tapStart = null;
        if (event.timeStamp - tap.time > LONG_PRESS_MS) {
            lastTap = null;
            return;
        }

        if (state.columns > 1) {
            // Grid pages are not interactive; every tap picks a page.
            event.preventDefault();
            const pageNumber = pageNumberAt(event.target);
            if (pageNumber) post("pageTap", { pageNumber });
            return;
        }

        const isDoubleTap =
            lastTap !== null &&
            tap.time - lastTap.endTime < DOUBLE_TAP_MS &&
            Math.hypot(tap.x - lastTap.x, tap.y - lastTap.y) < DOUBLE_TAP_DISTANCE_PX;
        if (isDoubleTap) {
            lastTap = null;
            event.preventDefault();
            zoomOnDoubleTap(tap);
            return;
        }
        lastTap = { x: tap.x, y: tap.y, endTime: event.timeStamp };
        clickAnnotationLink(event, tap);
    },
    { passive: false }
);

container.addEventListener("touchcancel", () => {
    if (pinch) {
        viewer.style.transform = "";
        viewer.style.transformOrigin = "";
    }
    pinch = null;
    tapStart = null;
});

// iOS fires its own pinch gestures on top of touch events.
document.addEventListener("gesturestart", (event) => event.preventDefault());

// WKWebView can report a double tap as a dblclick without exposing the second
// touch. The touch path above prevents the browser's own dblclick, and the
// timestamp guard skips a duplicate when both still arrive.
container.addEventListener("dblclick", (event) => {
    if (!state.ready || state.columns > 1) return;
    event.preventDefault();
    if (performance.now() - lastDoubleTapZoomAt < DOUBLE_TAP_MS) return;
    zoomOnDoubleTap({ x: event.clientX, y: event.clientY });
});

// External links go to Dart; internal (#dest) and named-action links stay in PDF.js.
container.addEventListener(
    "click",
    (event) => {
        const anchor = event.target instanceof Element ? event.target.closest("a[href]") : null;
        const href = anchor?.getAttribute("href");
        if (!href || href.startsWith("#")) return;
        event.preventDefault();
        event.stopPropagation();
        post("externalLink", { url: anchor.href });
    },
    true
);

// ---- Outline ------------------------------------------------------------

// Large outlines have thousands of entries; resolve shared lookups once.
// Runs `task` once the first page has painted. The timeout is only a safety net
// for a document that never renders a page, so it has to sit well past a slow
// first paint — firing it early just puts the work back on the critical path.
const FIRST_PAINT_FALLBACK_MS = 15000;

function afterFirstPaint(task) {
    let started = false;
    const run = () => {
        if (started) return;
        started = true;
        const idle = globalThis.requestIdleCallback;
        if (idle) idle(task, { timeout: 1000 });
        else setTimeout(task, 0);
    };
    state.eventBus?.on("pagerendered", run, { once: true });
    setTimeout(run, FIRST_PAINT_FALLBACK_MS);
}

function createPageResolver(pdfDocument) {
    const namedDestinations = new Map();
    const pageIndexByRef = new Map();

    return async (dest) => {
        try {
            let explicitDest = dest;
            if (typeof dest === "string") {
                if (!namedDestinations.has(dest)) {
                    namedDestinations.set(dest, pdfDocument.getDestination(dest));
                }
                explicitDest = await namedDestinations.get(dest);
            }
            if (!Array.isArray(explicitDest)) return null;
            const ref = explicitDest[0];
            if (Number.isInteger(ref)) return ref + 1;
            if (!ref || typeof ref !== "object") return null;

            const num = Array.isArray(ref) ? ref[0] : ref.num;
            const gen = Array.isArray(ref) ? ref[1] : ref.gen;
            if (!Number.isInteger(num) || !Number.isInteger(gen)) return null;

            const key = `${num}R${gen}`;
            if (!pageIndexByRef.has(key)) {
                pageIndexByRef.set(key, pdfDocument.getPageIndex({ num, gen }));
            }
            const pageIndex = await pageIndexByRef.get(key);
            return Number.isInteger(pageIndex) && pageIndex >= 0 ? pageIndex + 1 : null;
        } catch {
            // Broken destinations behave like entries without a target.
            return null;
        }
    };
}

// A destination is either a name or an explicit array; both are stable keys.
function destKey(dest) {
    return typeof dest === "string" ? `s:${dest}` : `a:${JSON.stringify(dest)}`;
}

// Resolving destinations one node at a time serialises a worker round trip per
// node, and large outlines repeat the same handful of destinations thousands of
// times. Collect the distinct ones first and resolve them in one batch so the
// tree walk itself stays synchronous.
async function resolveOutlineTargets(resolvePageNumber, nodes) {
    const byKey = new Map();
    (function collect(list) {
        for (const node of list) {
            if (node.dest) byKey.set(destKey(node.dest), node.dest);
            collect(node.items ?? []);
        }
    })(nodes);

    const resolved = await Promise.all(
        [...byKey].map(async ([key, dest]) => [key, await resolvePageNumber(dest)])
    );
    return new Map(resolved);
}

function mapOutline(targets, nodes, parentPath) {
    const mapped = [];

    for (let index = 0; index < nodes.length; index++) {
        const node = nodes[index];
        const path = [...parentPath, index];
        const ownPageNumber = node.dest ? targets.get(destKey(node.dest)) ?? null : null;
        const ownTarget = ownPageNumber ? { destinationPath: path, pageNumber: ownPageNumber } : null;
        const children = mapOutline(targets, node.items ?? [], path);
        const childTarget = children.find((child) => child.destinationPath);
        const target = ownTarget ?? childTarget;

        mapped.push({
            title: String(node.title ?? ""),
            pageNumber: target?.pageNumber ?? null,
            path,
            destinationPath: target?.destinationPath ?? null,
            children,
        });
    }

    return mapped;
}

async function loadOutline(pdfDocument, resolvePageNumber) {
    let outline = null;
    try {
        outline = await pdfDocument.getOutline();
    } catch {
        outline = null;
    }
    state.outline = outline ?? [];
    const targets = await resolveOutlineTargets(resolvePageNumber, state.outline);
    const items = mapOutline(targets, state.outline, []);
    post("outline", { items });
}

function goToOutline(path) {
    if (!state.ready || !Array.isArray(path)) return;
    let nodes = state.outline;
    let node = null;
    for (const index of path) {
        node = Number.isInteger(index) ? nodes?.[index] : null;
        if (!node) return;
        nodes = node.items;
    }
    if (node?.dest) state.linkService.goToDestination(node.dest);
}

// ---- Search -------------------------------------------------------------

function postFindState(matchesCount, pending) {
    if (!state.lastQuery) return;
    post("findState", {
        current: matchesCount?.current ?? 0,
        total: matchesCount?.total ?? 0,
        pending,
    });
}

function find(query) {
    if (!state.ready) return;
    if (typeof query !== "string" || query.length === 0) {
        clearFind();
        return;
    }
    state.lastQuery = query;
    dispatchFind("", false);
}

function findAgain(previous) {
    if (!state.ready || !state.lastQuery) return;
    dispatchFind("again", previous === true);
}

function dispatchFind(type, findPrevious) {
    state.eventBus.dispatch("find", {
        source: null,
        type,
        query: state.lastQuery,
        caseSensitive: false,
        entireWord: false,
        highlightAll: true,
        findPrevious,
        matchDiacritics: true,
    });
}

function clearFind() {
    state.lastQuery = "";
    state.eventBus?.dispatch("findbarclose", { source: null });
}

// ---- Bridge -------------------------------------------------------------

function handle(message) {
    if (!message || message.v !== PROTOCOL_VERSION) return;
    switch (message.type) {
        case "open":
            if (!state.config && message.config && typeof message.config.documentUrl === "string") {
                open(message.config);
            }
            break;
        case "goToPage":
            if (state.ready && Number.isInteger(message.pageNumber)) {
                state.pdfViewer.currentPageNumber = clamp(message.pageNumber, 1, state.pdfViewer.pagesCount);
            }
            break;
        case "goToOutline":
            goToOutline(message.path);
            break;
        case "setLayout":
            setColumns(message.columns);
            break;
        case "find":
            find(message.query);
            break;
        case "findAgain":
            findAgain(message.previous);
            break;
        case "findClear":
            clearFind();
            break;
    }
}

globalThis.pdfjsBridge = Object.freeze({
    receive(json) {
        try {
            handle(JSON.parse(json));
        } catch (error) {
            post("error", { name: "BridgeError", message: String(error?.message ?? error) });
        }
    },
});

// Repeat the handshake until Dart answers, in case the channel attached late.
post("bridgeReady");
const handshakeTimer = setInterval(() => {
    if (state.config) {
        clearInterval(handshakeTimer);
    } else {
        post("bridgeReady");
    }
}, 1000);
