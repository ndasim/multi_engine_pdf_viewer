import assert from 'node:assert/strict';
import { Worker } from 'node:worker_threads';

const [viewerUrl, documentUrl] = process.argv.slice(2);
const worker = new Worker(new URL('./embedpdf_worker_bootstrap.mjs', import.meta.url), { workerData: { location: new URL('worker.mjs', viewerUrl).href } });
const pending = new Map();
let sequence = 0;
worker.on('message', message => {
    const request = pending.get(message.id);
    if (!request) return;
    clearTimeout(request.timer);
    pending.delete(message.id);
    if (message.error) request.reject(new Error(message.error));
    else request.resolve(message.result);
});
worker.on('error', error => {
    for (const request of pending.values()) { clearTimeout(request.timer); request.reject(error); }
    pending.clear();
});
function rpc(type, payload = {}) {
    const id = ++sequence;
    return new Promise((resolve, reject) => {
        const timer = setTimeout(() => { pending.delete(id); reject(new Error(`Worker timeout: ${type}`)); }, 30000);
        pending.set(id, { resolve, reject, timer });
        worker.postMessage({ id, type, payload });
    });
}
try {
    const opened = await rpc('open', { documentUrl });
    assert.equal(opened.pageCount, 189);
    assert.ok(opened.capabilities.includes('wasm-compiled1'));
    const bitmap = await rpc('render', { pageNumber: 2, width: 320, pixels: 2097152 });
    assert.ok(bitmap.pixels.some((value, index) => index % 4 !== 3 && value < 200));
    const outcomes = [];
    for (const widget of await rpc('widgets', { pageNumber: 2 })) {
        const rect = widget.rect;
        const result = await rpc('click', { pageNumber: 2, point: { width: bitmap.width, height: bitmap.height,
            x: (rect.left + rect.width / 2) * bitmap.width, y: (rect.top + rect.height / 2) * bitmap.height } });
        if (['NextPage', 'PrevPage'].includes(result.actions[0])) {
            assert.equal(result.actions.length, 1);
            assert.equal(Math.abs(result.targetPage - 2), 1);
            outcomes.push(result);
        }
    }
    assert.deepEqual(outcomes.map(outcome => outcome.actions[0]).sort(), ['NextPage', 'PrevPage']);
    const outline = await rpc('outline');
    const count = items => items.reduce((sum, item) => sum + 1 + count(item.children), 0);
    assert.equal(count(outline), 18798);
    const matches = await rpc('searchPage', { pageNumber: 2, query: 'a', remaining: 10000 });
    assert.equal(matches.length, 260);
    assert.ok(matches.every(match => match.rects.length));
    await assert.rejects(rpc('render', { pageNumber: 190, width: 320 }), /embedpdf-command-page-range/);
    assert.equal(await rpc('ping'), 'pong');
    const exited = new Promise(resolve => worker.once('exit', resolve));
    worker.postMessage({ id: ++sequence, type: 'dispose' });
    assert.equal(await exited, 0);
    console.log(JSON.stringify({ environment: 'Node worker using actual browser glue and Dart server, not WebView certification', pageCount: 189,
        outlineNodes: 18798, page2Matches: matches.length, outcomes, recoverableCommand: true, heartbeat: true, cleanDispose: true }));
} catch (error) {
    console.error(String(error).replace(/https?:\/\/[^\s)]+/g, '<local-url>'));
    process.exitCode = 1;
} finally {
    for (const request of pending.values()) clearTimeout(request.timer);
    await worker.terminate();
}