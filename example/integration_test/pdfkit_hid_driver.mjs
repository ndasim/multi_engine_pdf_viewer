import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdirSync} from 'node:fs';
import {resolve} from 'node:path';

const [port, udid, executable = 'idb'] = process.argv.slice(2);
assert.match(port ?? '', /^\d+$/, 'Pass the printed PDFKIT_HID_PORT and simulator UDID.');
assert.match(udid ?? '', /^[A-Fa-f0-9-]{36}$/);
const base = `http://127.0.0.1:${port}`;
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const state = async (path = '/state') => {
  const response = await fetch(`${base}${path}`);
  assert.equal(response.status, 200);
  return response.json();
};
async function waitFor(predicate, message) {
  for (let i = 0; i < 100; i++) {
    const snapshot = await state();
    if (predicate(snapshot)) return snapshot;
    await sleep(100);
  }
  assert.fail(message);
}
function hid(command, ...arguments_) {
  const prefix = process.env.IDB_COMPANION_PATH
    ? ['--companion-path', process.env.IDB_COMPANION_PATH] : [];
  execFileSync(executable, [
    ...prefix, 'ui', command, ...arguments_.map(String), '--udid', udid,
    '--reason', 'Verify real PDFKit simulator gestures and annotation actions',
  ], {stdio: 'inherit'});
}
const output = resolve('build/pdfkit-hid');
mkdirSync(output, {recursive: true});
function screenshot(name) {
  execFileSync('xcrun', ['simctl', 'io', udid, 'screenshot', resolve(output, `${name}.png`)]);
}
await waitFor(s => s.ready === 1 && s.paints.length === 1, 'PDFKit must render natively.');
await state('/page/2');
await sleep(500);
const initial = await state();
const {width, height, top, bottom} = initial.viewport;
// The fixture's widest page is 800pt. PDFKit includes 8pt page-break margins in its fit scale.
const scale = width / 816;
const left = (width - 600 * scale) / 2;
const pageTop = top + (height - top - bottom - 800 * scale) / 2;
const point = (x, y) => [Math.round(left + x * scale), Math.round(pageTop + (800 - y) * scale)];
async function annotation(x, y, expectedPage, name) {
  const before = await state();
  hid('tap', ...point(x, y), '--duration', 0.15);
  const after = await waitFor(s => s.page === expectedPage, name);
  await sleep(300);
  const settled = await state();
  assert.equal(settled.pages.length, before.pages.length + 1, `${name}: one page callback`);
  assert.equal(settled.page, after.page);
  console.log(`PASS ${name}`);
}
await annotation(100, 535, 3, 'NextPage PDF button');
await state('/page/2'); await sleep(300);
await annotation(300, 535, 1, 'PrevPage PDF button');
await state('/page/2'); await sleep(300);
await annotation(200, 435, 1, 'internal destination beneath targetless annotation');
await state('/page/2'); await sleep(300);
hid('tap', ...point(200, 335), '--duration', 0.15);
await waitFor(s => s.links.length === 1, 'HTTPS must reach the host.');
hid('tap', ...point(200, 235), '--duration', 0.15);
await sleep(300);
assert.deepEqual((await state()).links, ['https://example.com/pdf']);
console.log('PASS external HTTPS callback and blocked file URL');
screenshot('fit-width');
const zoomPoint = point(300, 650);
hid('multi-tap', ...zoomPoint);
await sleep(600);
screenshot('double-tap');
hid('pinch', ...zoomPoint, 1.6, '--radius', 50, '--duration', 0.5);
await sleep(600);
screenshot('pinch');
assert.equal((await state()).page, 2, 'Zoom retains the selected page.');
await state('/grid'); await sleep(600);
screenshot('grid');
const cellWidth = Math.floor((width - 32) / 3);
hid('tap', 8 + (cellWidth + 8) * 2 + cellWidth / 2, top + 8 + cellWidth * 2 / 3, '--duration', 0.15);
const selected = await waitFor(s => s.page === 3 && s.columns === 1, 'Grid tap must return to vertical page 3.');
assert.deepEqual(selected.layouts, [1]);
assert.equal(selected.paints.length, 1);
assert.deepEqual(selected.errors, []);
console.log('PASS grid selection, layout synchronization and one-shot paint');
console.log(`Zoom screenshots for visual inspection: ${output}`);
await state('/done');
