export const limits = Object.freeze({
    documentBytes: 64 * 1024 * 1024,
    wasmBytes: 256 * 1024 * 1024,
    pages: 10000,
    rasterPixels: 2097152,
    cachedPixels: 8388608,
    cachedPages: 32,
    outlineNodes: 25000,
    outlineDepth: 64,
    searchMatches: 10000,
    searchRectangles: 64000,
    queuedJobs: 64,
    queryLength: 512,
    annotations: 4096,
});

export function failure(code, fatal = false) {
    const error = new Error(code);
    error.name = `embedpdf-${fatal ? 'fatal' : 'command'}-${code}`;
    return error;
}

export function rasterSize(pageWidth, pageHeight, requestedWidth, requestedPixels = limits.rasterPixels) {
    if (![pageWidth, pageHeight].every(value => Number.isFinite(value) && value > 0)) {
        throw failure('page-size', true);
    }
    if (![requestedWidth, requestedPixels].every(value => Number.isFinite(value) && value > 0)) {
        throw failure('raster-range');
    }
    const budget = Math.max(1, Math.floor(Math.min(limits.rasterPixels, requestedPixels)));
    const scale = Math.min(Math.max(1, requestedWidth) / pageWidth,
        Math.sqrt(budget / pageWidth / pageHeight), budget / pageWidth, budget / pageHeight);
    const width = Math.max(1, Math.min(budget, Math.floor(pageWidth * scale)));
    const height = Math.max(1, Math.min(Math.floor(budget / width), Math.floor(pageHeight * scale)));
    if (!Number.isSafeInteger(width) || !Number.isSafeInteger(height) || width > budget || height > budget || width * height > budget) {
        throw failure('raster-limit', true);
    }
    return { width, height };
}

export class PdfiumDocument {
    constructor(api) {
        this.api = api;
        this.runtime = api.pdfium;
        this.document = 0;
        this.data = 0;
        this.pageCount = 0;
        this.environments = 0;
        this.releases = 0;
        api.PDFiumExt_Init();
    }

    heap() { return new Uint8Array(this.runtime.wasmExports.memory.buffer); }
    alloc(size) {
        const pointer = this.runtime.wasmExports.malloc(size);
        if (!pointer) throw failure('memory-limit', true);
        return pointer;
    }
    free(pointer) { if (pointer) this.runtime.wasmExports.free(pointer); }
    checkMemory() {
        if (this.heap().byteLength > limits.wasmBytes) throw failure('memory-limit', true);
    }

    installFonts(fonts) {
        if (fonts.length !== 4) throw failure('font-setup', true);
        const runtime = this.runtime;
        const info = this.alloc(36);
        this.heap().fill(0, info, info + 36);
        const pointers = [];
        this.fonts = { info, pointers, bytes: fonts };
        const register = (offset, signature, callback) => {
            const pointer = runtime.addFunction(callback, signature);
            pointers.push(pointer);
            runtime.setValue(info + offset, pointer, 'i32');
        };
        const handles = new Map();
        let nextHandle = 1;
        const map = (weight, italic, charset) => {
            if (![0, 1, 162].includes(charset)) return 0;
            const handle = nextHandle++;
            handles.set(handle, { index: (weight >= 600 ? 1 : 0) + (italic ? 2 : 0), charset });
            return handle;
        };
        runtime.setValue(info, 1, 'i32');
        register(4, 'vi', () => { });
        register(8, 'vii', () => { });
        register(12, 'iiiiiiii', (_info, weight, italic, charset, _family, _face, exact) => {
            if (exact) runtime.setValue(exact, 0, 'i32');
            return map(weight, italic, charset);
        });
        register(16, 'iii', () => map(400, false, 0));
        register(20, 'iiiiii', (_info, handle, table, buffer, size) => {
            const selected = handles.get(handle);
            if (!selected || table !== 0) return 0;
            const bytes = fonts[selected.index];
            if (buffer && size >= bytes.length) this.heap().set(bytes, buffer);
            return bytes.length;
        });
        register(24, 'iiiii', () => 0);
        register(28, 'iii', (_info, handle) => handles.get(handle)?.charset ?? 0);
        register(32, 'vii', (_info, handle) => { handles.delete(handle); });
        this.api.FPDF_SetSystemFontInfo(info);
    }

    open(bytes) {
        if (this.document) throw failure('already-open');
        if (!bytes.length || bytes.length > limits.documentBytes) throw failure('document-limit', true);
        this.data = this.alloc(bytes.length);
        this.heap().set(bytes, this.data);
        this.document = this.api.FPDF_LoadMemDocument(this.data, bytes.length, null);
        if (!this.document) throw failure('document-open', true);
        this.pageCount = this.api.FPDF_GetPageCount(this.document);
        if (this.pageCount < 1 || this.pageCount > limits.pages) throw failure('page-limit', true);
        this.checkMemory();
        return this.pageCount;
    }

    withPage(number, operation) {
        if (!this.document || !Number.isInteger(number) || number < 1 || number > this.pageCount) {
            throw failure('page-range');
        }
        const page = this.api.FPDF_LoadPage(this.document, number - 1);
        if (!page) throw failure('page-load');
        try {
            const count = this.api.FPDFPage_GetAnnotCount(page);
            if (!Number.isInteger(count) || count < 0 || count > limits.annotations) throw failure('annotation-limit', true);
            const result = operation(page);
            this.checkMemory();
            return result;
        } finally {
            this.api.FPDF_ClosePage(page);
        }
    }

    withEnvironment(page, number, operation) {
        const api = this.api;
        const runtime = this.runtime;
        const info = this.alloc(256);
        this.heap().fill(0, info, info + 256);
        runtime.setValue(info, 1, 'i32');
        const pointers = [];
        const actions = [];
        let environment = 0;
        let phase = 'idle';
        let released = false;
        let removed = false;
        const register = (offset, signature, callback) => {
            const pointer = runtime.addFunction(callback, signature);
            pointers.push(pointer);
            runtime.setValue(info + offset, pointer, 'i32');
        };
        try {
            register(4, 'vi', () => { if (removed) throw failure('callback-lifetime', true); released = true; });
            register(8, 'viidddd', () => { });
            register(12, 'viidddd', () => { });
            register(16, 'vii', () => { });
            register(20, 'iiii', () => 0);
            register(24, 'vii', () => { });
            register(32, 'vi', () => { });
            register(36, 'iiii', (_info, _document, index) => index === number - 1 ? page : 0);
            register(40, 'iii', () => page);
            register(44, 'iii', () => api.FPDFPage_GetRotation(page));
            register(48, 'vii', (_info, name) => {
                if (removed) throw failure('callback-lifetime', true);
                if (phase === 'click') actions.push(runtime.UTF8ToString(name));
            });
            register(56, 'vii', (_info, uri) => {
                if (phase === 'click') actions.push({ kind: 'uri', url: runtime.UTF8ToString(uri) });
            });
            register(60, 'viiiii', (_info, pageIndex) => {
                if (phase === 'click') actions.push({ kind: 'goto', pageNumber: pageIndex + 1 });
            });
            environment = api.FPDFDOC_InitFormFillEnvironment(this.document, info);
            if (!environment) throw failure('form-environment');
            this.environments++;
            api.FORM_OnAfterLoadPage(page, environment);
            return operation(environment, actions, (value) => { phase = value; });
        } finally {
            if (environment) {
                phase = 'cleanup';
                try {
                    api.FORM_ForceToKillFocus(environment);
                    api.FORM_OnBeforeClosePage(page, environment);
                } finally {
                    api.FPDFDOC_ExitFormFillEnvironment(environment);
                }
                if (released) this.releases++;
            }
            removed = true;
            for (const pointer of pointers) runtime.removeFunction(pointer);
            this.free(info);
            if (environment && !released) throw failure('callback-release', true);
        }
    }

    size(page) {
        const width = this.api.FPDF_GetPageWidthF(page);
        const height = this.api.FPDF_GetPageHeightF(page);
        if (![width, height].every(value => Number.isFinite(value) && value > 0)) throw failure('page-size', true);
        return { width, height };
    }

    pagePoint(page, width, height, x, y) {
        const scratch = this.alloc(16);
        try {
            if (!this.api.FPDF_DeviceToPage(page, 0, 0, width, height, 0, Math.round(x), Math.round(y), scratch, scratch + 8)) {
                throw failure('coordinates');
            }
            return { x: this.runtime.getValue(scratch, 'double'), y: this.runtime.getValue(scratch + 8, 'double') };
        } finally { this.free(scratch); }
    }

    deviceRect(page, left, top, right, bottom) {
        const scratch = this.alloc(16);
        try {
            const convert = (x, y, offset) => {
                if (!this.api.FPDF_PageToDevice(page, 0, 0, 100000, 100000, 0, x, y, scratch + offset, scratch + offset + 4)) {
                    throw failure('coordinates');
                }
                return [this.runtime.getValue(scratch + offset, 'i32') / 100000, this.runtime.getValue(scratch + offset + 4, 'i32') / 100000];
            };
            const first = convert(left, top, 0);
            const second = convert(right, bottom, 8);
            return {
                left: Math.min(first[0], second[0]), top: Math.min(first[1], second[1]),
                width: Math.abs(first[0] - second[0]), height: Math.abs(first[1] - second[1])
            };
        } finally { this.free(scratch); }
    }

    render(number, requestedWidth, requestedPixels = limits.rasterPixels) {
        return this.withPage(number, (page) => {
            const size = this.size(page);
            const { width, height } = rasterSize(size.width, size.height, requestedWidth, requestedPixels);
            const bitmap = this.api.FPDFBitmap_Create(width, height, 1);
            if (!bitmap) throw failure('bitmap-allocation', true);
            try {
                this.api.FPDFBitmap_FillRect(bitmap, 0, 0, width, height, 0xffffffff);
                this.api.FPDF_RenderPageBitmap(bitmap, page, 0, 0, width, height, 0, 1);
                this.withEnvironment(page, number, (environment) => {
                    this.api.FPDF_FFLDraw(environment, bitmap, page, 0, 0, width, height, 0, 1);
                });
                const stride = this.api.FPDFBitmap_GetStride(bitmap);
                const pointer = this.api.FPDFBitmap_GetBuffer(bitmap);
                const pixels = new Uint8ClampedArray(width * height * 4);
                const heap = this.heap();
                for (let row = 0; row < height; row++) {
                    for (let column = 0; column < width; column++) {
                        const source = pointer + row * stride + column * 4;
                        const target = (row * width + column) * 4;
                        pixels[target] = heap[source + 2];
                        pixels[target + 1] = heap[source + 1];
                        pixels[target + 2] = heap[source];
                        pixels[target + 3] = heap[source + 3];
                    }
                }
                return { width, height, pageWidth: size.width, pageHeight: size.height, pixels };
            } finally { this.api.FPDFBitmap_Destroy(bitmap); }
        });
    }

    widgets(number) {
        return this.withPage(number, (page) => this.withEnvironment(page, number, (environment) => {
            const rect = this.alloc(16);
            const widgets = [];
            try {
                const count = this.api.FPDFPage_GetAnnotCount(page);
                for (let index = 0; index < count; index++) {
                    const annotation = this.api.FPDFPage_GetAnnot(page, index);
                    if (!annotation) continue;
                    try {
                        if (this.api.FPDFAnnot_GetFormFieldType(environment, annotation) !== 1) continue;
                        if (!this.api.FPDFAnnot_GetRect(annotation, rect)) continue;
                        const left = this.runtime.getValue(rect, 'float');
                        const top = this.runtime.getValue(rect + 4, 'float');
                        const right = this.runtime.getValue(rect + 8, 'float');
                        const bottom = this.runtime.getValue(rect + 12, 'float');
                        widgets.push({ index, pdfRect: { left, top, right, bottom }, rect: this.deviceRect(page, left, top, right, bottom) });
                    } finally { this.api.FPDFPage_CloseAnnot(annotation); }
                }
                return widgets;
            } finally { this.free(rect); }
        }));
    }

    click(number, point) {
        return this.withPage(number, (page) => this.withEnvironment(page, number, (environment, actions, setPhase) => {
            const position = point.pdf === true ? point : this.pagePoint(page, point.width, point.height, point.x, point.y);
            if (this.api.FPDFPage_HasFormFieldAtPoint(environment, page, position.x, position.y) !== 1) return { actions: [], targetPage: null };
            setPhase('click');
            try {
                this.api.FORM_OnLButtonDown(environment, page, 0, position.x, position.y);
                this.api.FORM_OnLButtonUp(environment, page, 0, position.x, position.y);
            } finally { setPhase('idle'); }
            if (actions.length > 1) throw failure('ambiguous-widget-action');
            const name = actions[0];
            const offset = name === 'NextPage' ? 1 : name === 'PrevPage' ? -1 : 0;
            const goToTarget = name?.kind === 'goto' && Number.isInteger(name.pageNumber) && name.pageNumber >= 1 && name.pageNumber <= this.pageCount ? name.pageNumber : null;
            const namedTarget = offset ? number + offset : name === 'FirstPage' ? 1 : name === 'LastPage' ? this.pageCount : null;
            const target = goToTarget ?? namedTarget;
            // A widget whose goto resolved to an invalid page (e.g. pageIndex -1
            // from PDFium) must still fall through to the link path in viewer.mjs,
            // so do not claim a target and do not declare the action handled.
            const handled = target !== null || (name?.kind !== 'goto');
            return {
                actions: handled ? actions : [], targetPage: target,
                ...(name?.kind === 'uri' && /^(https?:|mailto:|tel:)/i.test(name.url) && name.url.length <= 8192 ? { url: name.url } : {})
            };
        }));
    }

    actionTarget(action, destination = 0) {
        const api = this.api;
        if (!destination && action && api.FPDFAction_GetType(action) === 1) destination = api.FPDFAction_GetDest(this.document, action);
        if (destination) {
            const index = api.FPDFDest_GetDestPageIndex(this.document, destination);
            if (index >= 0 && index < this.pageCount) return { pageNumber: index + 1 };
        }
        if (action && api.FPDFAction_GetType(action) === 3) {
            const length = api.FPDFAction_GetURIPath(this.document, action, 0, 0);
            if (length > 0 && length <= 8192) {
                const pointer = this.alloc(length);
                try {
                    api.FPDFAction_GetURIPath(this.document, action, pointer, length);
                    const url = this.runtime.UTF8ToString(pointer);
                    if (/^(https?:|mailto:|tel:)/i.test(url)) return { url };
                } finally { this.free(pointer); }
            }
        }
        return null;
    }

    linkAt(number, point) {
        return this.withPage(number, (page) => {
            const position = this.pagePoint(page, point.width, point.height, point.x, point.y);
            const link = this.api.FPDFLink_GetLinkAtPoint(page, position.x, position.y);
            return link ? this.actionTarget(this.api.FPDFLink_GetAction(link), this.api.FPDFLink_GetDest(this.document, link)) : null;
        });
    }

    async outline(yieldControl = async () => { }) {
        const api = this.api;
        const root = [];
        const seen = new Set();
        const stack = [{ pointer: api.FPDFBookmark_GetFirstChild(this.document, 0), nodes: root, path: [], depth: 0 }];
        while (stack.length) {
            const frame = stack.pop();
            if (!frame.pointer) continue;
            if (seen.has(frame.pointer) || seen.size >= limits.outlineNodes || frame.depth >= limits.outlineDepth) throw failure('outline-limit');
            seen.add(frame.pointer);
            const path = [...frame.path, frame.nodes.length];
            const length = api.FPDFBookmark_GetTitle(frame.pointer, 0, 0);
            let title = '';
            if (length > 0 && length <= 8192) {
                const pointer = this.alloc(length);
                try {
                    api.FPDFBookmark_GetTitle(frame.pointer, pointer, length);
                    title = this.runtime.UTF16ToString(pointer);
                } finally { this.free(pointer); }
            }
            const target = this.actionTarget(api.FPDFBookmark_GetAction(frame.pointer), api.FPDFBookmark_GetDest(this.document, frame.pointer));
            const node = { title, pageNumber: target?.pageNumber ?? null, path, destinationPath: target?.pageNumber ? path : null, children: [] };
            frame.nodes.push(node);
            stack.push({ ...frame, pointer: api.FPDFBookmark_GetNextSibling(this.document, frame.pointer) });
            stack.push({ pointer: api.FPDFBookmark_GetFirstChild(this.document, frame.pointer), nodes: node.children, path, depth: frame.depth + 1 });
            if (seen.size % 128 === 0) { this.checkMemory(); await yieldControl(); }
        }
        const targets = (nodes) => {
            for (const node of nodes) {
                targets(node.children);
                const target = node.destinationPath ? node : node.children.find(child => child.destinationPath);
                node.pageNumber = target?.pageNumber ?? null;
                node.destinationPath = target?.destinationPath ?? null;
            }
        };
        targets(root);
        return root;
    }

    searchPage(number, query, remaining = limits.searchMatches) {
        if (!query || query.length > limits.queryLength) throw failure('query-limit');
        return this.withPage(number, (page) => {
            const api = this.api;
            const text = api.FPDFText_LoadPage(page);
            if (!text) return [];
            const queryPointer = this.alloc((query.length + 1) * 2);
            const scratch = this.alloc(32);
            let find = 0;
            try {
                this.runtime.stringToUTF16(query, queryPointer, (query.length + 1) * 2);
                find = api.FPDFText_FindStart(text, queryPointer, 0, 0);
                const results = [];
                let geometryCount = 0;
                while (find && api.FPDFText_FindNext(find)) {
                    if (results.length >= remaining) throw failure('search-limit');
                    const index = api.FPDFText_GetSchResultIndex(find);
                    const count = api.FPDFText_GetSchCount(find);
                    const rects = [];
                    const rectCount = api.FPDFText_CountRects(text, index, count);
                    geometryCount += rectCount;
                    if (geometryCount > limits.searchRectangles) throw failure('search-geometry-limit');
                    if (rectCount > 128) throw failure('search-geometry-limit');
                    for (let rectIndex = 0; rectIndex < rectCount; rectIndex++) {
                        if (api.FPDFText_GetRect(text, rectIndex, scratch, scratch + 8, scratch + 16, scratch + 24)) {
                            rects.push(this.deviceRect(page, this.runtime.getValue(scratch, 'double'), this.runtime.getValue(scratch + 8, 'double'),
                                this.runtime.getValue(scratch + 16, 'double'), this.runtime.getValue(scratch + 24, 'double')));
                        }
                    }
                    results.push({ pageNumber: number, index, count, rects });
                }
                return results;
            } finally {
                if (find) api.FPDFText_FindClose(find);
                this.free(scratch);
                this.free(queryPointer);
                api.FPDFText_ClosePage(text);
            }
        });
    }

    close() {
        if (this.document) this.api.FPDF_CloseDocument(this.document);
        this.document = 0;
        this.free(this.data);
        this.data = 0;
        this.api.FPDF_DestroyLibrary();
        if (this.fonts) {
            for (const pointer of this.fonts.pointers) this.runtime.removeFunction(pointer);
            this.free(this.fonts.info);
            this.fonts = null;
        }
    }
}