import assert from 'node:assert/strict';
import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';

const { chromium } = await import(process.env.EMBEDPDF_PLAYWRIGHT_MODULE);
const [viewerUrl, documentUrl] = process.argv.slice(2);
const evidence = process.env.EMBEDPDF_EVIDENCE_DIR ?? '/tmp/crewapp-embedpdf-browser/evidence';
const browser = await chromium.launch({
    headless: true, timeout: 10000,
    ...(process.env.EMBEDPDF_CHROMIUM_EXECUTABLE ? { executablePath: process.env.EMBEDPDF_CHROMIUM_EXECUTABLE } : { channel: 'chromium' })
});
const externalRequests = [];
const errors = [];
const origin = new URL(viewerUrl).origin;
let page;
const wait = (predicate, argument) => page.waitForFunction(predicate, argument, { timeout: 30000 });
const stage = name => console.error(JSON.stringify({ stage: name }));
async function command(type, payload = {}) {
    await page.evaluate(message => window.pdfjsBridge.receive(JSON.stringify({ v: 1, session: 'fixture-smoke', ...message })), { type, ...payload });
}
async function nonblank(number) {
    await wait(number => {
        const canvas = document.querySelector(`[data-page="${number}"] canvas`);
        if (!canvas || !canvas.width || !canvas.height) return false;
        const pixels = canvas.getContext('2d').getImageData(0, 0, canvas.width, canvas.height).data;
        let dark = 0;
        for (let index = 0; index < pixels.length; index += 4) if (pixels[index] < 200 && pixels[index + 1] < 200 && pixels[index + 2] < 200) dark++;
        return dark > 100;
    }, number);
}
async function verifyPinch() {
    return page.evaluate(async () => {
        const root = document.getElementById('pages');
        const page = root.children[5];
        const x = innerWidth / 2, y = innerHeight / 2;
        const frame = () => new Promise(resolve => requestAnimationFrame(resolve));
        const touch = (type, distance) => root.dispatchEvent(new TouchEvent(type, {
            bubbles: true, cancelable: true,
            touches: distance === null ? [] : [
                new Touch({ identifier: 1, target: root, clientX: x - distance / 2, clientY: y }),
                new Touch({ identifier: 2, target: root, clientX: x + distance / 2, clientY: y }),
            ],
        }));
        let maximumEndJump = 0, maximumAnchorDrift = 0;
        for (let repeat = 0; repeat < 12; repeat++) {
            const initial = page.getBoundingClientRect();
            const anchor = { x: (x - initial.left) / initial.width, y: (y - initial.top) / initial.height };
            touch('touchstart', 100);
            touch('touchmove', repeat % 2 === 0 ? 150 : 100 / 1.5);
            await frame();
            await frame();
            const before = page.getBoundingClientRect();
            maximumAnchorDrift = Math.max(maximumAnchorDrift,
                Math.abs(before.left + anchor.x * before.width - x),
                Math.abs(before.top + anchor.y * before.height - y));
            const canvas = page.querySelector('canvas');
            touch(repeat % 3 === 0 ? 'touchcancel' : 'touchend', null);
            await frame();
            const after = page.getBoundingClientRect();
            maximumEndJump = Math.max(maximumEndJump, ...['left', 'top', 'width', 'height']
                .map(key => Math.abs(before[key] - after[key])));
            if (!canvas || page.querySelector('canvas') !== canvas) throw new Error('Canvas cleared at pinch end');
            if (root.style.transform) throw new Error('Full-document transform during pinch');
            await new Promise(resolve => setTimeout(resolve, 300));
            if (page.querySelectorAll('canvas').length !== 1) throw new Error('Missing or duplicated pinch raster');
        }
        return { maximumEndJump, maximumAnchorDrift };
    });
}
try {
    await mkdir(evidence, { recursive: true });
    for (const viewport of [{ width: 1200, height: 800 }, { width: 390, height: 844 }]) {
        const context = await browser.newContext({ viewport, deviceScaleFactor: 1 });
        await context.route('**/*', route => {
            if (new URL(route.request().url()).origin !== origin) { externalRequests.push(new URL(route.request().url()).origin); return route.abort(); }
            return route.continue();
        });
        page = await context.newPage();
        page.on('pageerror', error => errors.push(error.name));
        page.on('crash', () => errors.push('PageCrash'));
        await page.addInitScript(() => {
            window.events = [];
            window.PdfJsBridge = { postMessage: raw => window.events.push(JSON.parse(raw)) };
        });
        stage(`load-${viewport.width}`);
        const response = await page.goto(viewerUrl, { waitUntil: 'domcontentloaded' });
        assert.ok(response.headers()['content-security-policy'].includes("'wasm-unsafe-eval'"));
        await wait(() => Boolean(window.pdfjsBridge));
        stage('open');
        await command('open', {
            config: {
                session: 'fixture-smoke', documentUrl, initialPage: 2, columns: 1, margin: 8,
                backgroundColor: '#9e9e9e', matchColor: '#ffeb3b80', activeMatchColor: '#ff980080',
                maxCanvasPixels: 2097152, largeDocumentPageCount: 100, largeDocumentMaxCanvasPixels: 2097152
            }
        });
        await wait(() => window.events.some(event => event.type === 'ready' && event.pageCount === 189));
        await wait(() => window.events.some(event => event.type === 'firstPageRendered' && event.pageNumber === 2));
        await nonblank(2);
        stage('first-paint');
        await page.screenshot({ path: path.join(evidence, `${viewport.width}-first-paint.png`) });
        await wait(() => window.events.some(event => event.type === 'outline'));
        const outlineCount = await page.evaluate(() => {
            const flatten = items => items.reduce((sum, item) => sum + 1 + flatten(item.children), 0);
            return flatten(window.events.find(event => event.type === 'outline').items);
        });
        assert.equal(outlineCount, 18798);
        stage('outline');
        await command('goToPage', { pageNumber: 2 });
        await nonblank(2);
        const click = async (number, normalizedX) => {
            const canvas = page.locator(`[data-page="${number}"] canvas`).first();
            const rect = await canvas.boundingBox();
            await page.mouse.click(rect.x + rect.width * normalizedX, rect.y + rect.height * 0.069885);
        };
        const count = await page.evaluate(() => window.events.filter(event => event.type === 'pageChanged').length);
        await click(2, 0.90842);
        await wait(() => window.events.filter(event => event.type === 'pageChanged').at(-1)?.pageNumber === 3);
        await nonblank(3);
        await click(3, 0.82509);
        await wait(() => window.events.filter(event => event.type === 'pageChanged').at(-1)?.pageNumber === 2);
        await nonblank(2);
        const transitions = await page.evaluate(count => window.events.filter(event => event.type === 'pageChanged').slice(count).map(event => event.pageNumber), count);
        assert.deepEqual(transitions, [3, 2]);
        stage('named-actions');
        await command('find', { query: 'zzzz-no-fixture-match' });
        await command('findClear');
        await wait(() => window.events.filter(event => event.type === 'findState').at(-1)?.pending === false);
        await command('find', { query: 'crew' });
        await wait(() => window.events.some(event => event.type === 'findState' && event.total > 0));
        await wait(() => document.querySelector('.match'));
        await command('findAgain', { previous: false });
        await command('findClear');
        await wait(() => document.querySelectorAll('.match').length === 0);
        stage('search');
        await command('goToPage', { pageNumber: 2 });
        await command('setLayout', { columns: 3 });
        await nonblank(2);
        await wait(() => document.querySelectorAll('canvas').length >= 3);
        await page.screenshot({ path: path.join(evidence, `${viewport.width}-grid.png`) });
        stage('grid');
        await command('setLayout', { columns: 1 });
        await command('setZoom', { zoom: 2 });
        await nonblank(2);
        stage('zoom');
        assert.equal(await page.evaluate(() => document.getElementById('pages').style.width), '200%');
        await command('setZoom', { zoom: 1 });
        await command('goToPage', { pageNumber: 6 });
        await nonblank(6);
        const pinch = await verifyPinch();
        assert.ok(pinch.maximumEndJump <= 0.5, `Pinch-end jump: ${pinch.maximumEndJump}px`);
        assert.ok(pinch.maximumAnchorDrift <= 1, `Pinch anchor drift: ${pinch.maximumAnchorDrift}px`);
        stage('anchored-pinch');
        await command('goToPage', { pageNumber: 2 });
        await nonblank(2);
        await page.evaluate(() => window.pdfjsBridge.receive(JSON.stringify({ v: 1, type: 'goToPage', session: 'retired-session', pageNumber: 9 })));
        await command('goToPage', { pageNumber: 2 });
        assert.equal(await page.evaluate(() => window.events.filter(event => event.type === 'pageChanged').at(-1).pageNumber), 2);
        const fatalName = viewport.width === 1200 ? 'embedpdf-fatal-worker-hang' : 'embedpdf-fatal-injected';
        if (viewport.width === 1200) {
            const worker = page.workers()[0];
            assert.ok(worker, 'the actual PDFium worker must be running');
            const closed = new Promise(resolve => worker.once('close', resolve));
            await command('terminateWorker');
            await Promise.race([closed, new Promise((_, reject) => setTimeout(() => reject(new Error('Worker did not close')), 5000))]);
            assert.equal(page.workers().length, 0);
            stage('actual-worker-terminated');
        } else {
            await command('injectFatal');
        }
        await wait(name => window.events.some(event => event.type === 'error' && event.name === name), fatalName);
        await command('dispose');
        await wait(() => document.querySelectorAll('.page').length === 0);
        const fatalErrors = await page.evaluate(() => window.events.filter(event => event.type === 'error').map(event => event.name));
        assert.deepEqual(fatalErrors, [fatalName]);
        stage('disposed');
        assert.equal(errors.length, 0);
        await context.close();
    }
    assert.deepEqual(externalRequests, []);
    const result = {
        engine: 'embedpdf-2.15.1', browser: browser.version(), environment: 'desktop Chromium, not mobile certification or performance evidence',
        viewports: ['1200x800', '390x844'], pageCount: 189, outlineNodes: 18798, transitions: [3, 2],
        checks: ['actual WASM compile', 'nonblank first paint', 'native widget NextPage/PrevPage', 'search/cancellation/highlights', 'grid', 'zoom', 'stale-session rejection', 'actual worker termination/watchdog', 'fatal injection', 'dispose'], externalRequests, pageErrors: errors
    };
    await writeFile(path.join(evidence, 'browser-smoke.json'), `${JSON.stringify(result, null, 2)}\n`);
    console.log(JSON.stringify(result));
} catch (error) {
    if (page) console.error(JSON.stringify({ events: await page.evaluate(() => window.events?.filter(event => ['error', 'ready', 'firstPageRendered', 'pageChanged', 'findState'].includes(event.type)).map(({ type, name, pageNumber, total, pending }) => ({ type, name, pageNumber, total, pending }))).catch(() => []), pageErrors: errors }));
    console.error(String(error).replace(/https?:\/\/[^\s)]+/g, '<local-url>'));
    process.exitCode = 1;
} finally { await browser.close(); }