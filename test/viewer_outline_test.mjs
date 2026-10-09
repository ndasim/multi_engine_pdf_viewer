import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";
import { pathToFileURL } from "node:url";

const source = readFileSync(new URL("../assets/viewer/viewer.mjs", import.meta.url), "utf8");
const start = source.indexOf("function createPageResolver(");
const end = source.indexOf("// ---- Search", start);
assert.ok(start >= 0 && end > start, "Cannot locate shipped outline functions");

async function readOutline(nodes, overrides = {}) {
    let items;
    let destination;
    const context = vm.createContext({
        state: {
            ready: true, linkService: {
                goToDestination(target) { destination = target; },
            }
        },
        post(type, payload) {
            assert.equal(type, "outline");
            items = payload.items;
        },
    });
    vm.runInContext(source.slice(start, end), context);
    const document = {
        getOutline: async () => nodes,
        getPageIndex: async (ref) => ref.num === 17 ? 6 : -1,
        ...overrides,
    };
    await context.loadOutline(document, context.createPageResolver(document));
    return {
        items,
        navigate: context.goToOutline,
        get destination() { return destination; },
    };
}

test("a real descendant target wins over inherited page 1 and navigates correctly", async () => {
    const destination = [3];
    const outline = await readOutline([{
        title: "Document", dest: [0], items: [{
            title: "Section", items: [
                { title: "Leading heading" },
                { title: "Page four", dest: destination },
                { title: "Trailing heading" },
            ],
        }],
    }]);
    const section = outline.items[0].children[0];
    assert.equal(outline.items[0].pageNumber, 1);
    assert.equal(section.pageNumber, 4);
    assert.deepEqual(Array.from(section.destinationPath), [0, 0, 1]);
    assert.deepEqual(Array.from(section.children, (child) => child.pageNumber), [null, 4, null]);
    outline.navigate(section.destinationPath);
    assert.equal(outline.destination, destination);
});

test("indirect destinations resolve from PDF.js reference shapes", async () => {
    const destination = { num: 17, gen: 0 };
    const outline = await readOutline([
        { title: "First", dest: [0] },
        { title: "Second", dest: [destination] },
    ]);
    assert.equal(outline.items[0].pageNumber, 1);
    assert.equal(outline.items[1].pageNumber, 7);
});

test("named destinations use single-name lookup when the bulk name tree is incomplete", async () => {
    let lookups = 0;
    const name = "Kabin Ekibi Brifingi:Bookmark 65";
    const outline = await readOutline([
        { title: "Cover", dest: [0] },
        { title: "Announcement", dest: name },
        { title: "Repeated announcement", dest: name },
        { title: "Missing", dest: "missing" },
    ], {
        getDestinations: async () => ({}),
        getDestination: async (destination) => {
            lookups++;
            return destination === name ? [{ num: 17, gen: 0 }, { name: "Fit" }] : null;
        },
    });
    assert.deepEqual(Array.from(outline.items, (node) => node.pageNumber), [1, 7, 7, null]);
    assert.equal(lookups, 2);
});

test("nested groups and later siblings keep their real destinations", async () => {
    const { items } = await readOutline([
        { title: "Cover", dest: [0] },
        {
            title: "Section", items: [{
                title: "Nested group", items: [
                    { title: "Leading heading" }, { title: "Page seven", dest: [6] },
                ]
            }]
        },
        { title: "Targetless sibling" },
        { title: "Later section", items: [{ title: "Page twelve", dest: [11] }] },
    ]);
    assert.deepEqual(Array.from(items, (item) => item.pageNumber), [1, 7, null, 12]);
    assert.deepEqual(Array.from(items[1].destinationPath), [1, 0, 1]);
    assert.equal(items[1].children[0].children[0].pageNumber, null);
    assert.deepEqual(Array.from(items[3].destinationPath), [3, 0]);
});

test("explicit section targets win without inventing targets for children", async () => {
    const { items } = await readOutline([{
        title: "Section", dest: [1], items: [
            { title: "Leading heading" },
            { title: "Page nine", dest: [8] },
            { title: "Trailing heading" },
        ]
    }]);
    assert.equal(items[0].pageNumber, 2);
    assert.deepEqual(Array.from(items[0].destinationPath), [0]);
    assert.deepEqual(Array.from(items[0].children, (child) => child.pageNumber), [null, 9, null]);
    assert.equal(items[0].children[2].destinationPath, null);
});

test("a page-one cover never turns unresolved headings into page-one links", async () => {
    const { items } = await readOutline([
        { title: "Cover", dest: [0] },
        { title: "Unresolved name", dest: "missing", items: [{ title: "Child" }] },
        { title: "Broken target", dest: [null] },
    ]);
    assert.equal(items[0].pageNumber, 1);
    for (const node of [items[1], items[1].children[0], items[2]]) {
        assert.equal(node.pageNumber, null);
        assert.equal(node.destinationPath, null);
    }
});

test("targetless or broken outlines never invent a page number or destination", async () => {
    const { items } = await readOutline([{
        title: "No destination", dest: [null], items: [{ title: "Child" }],
    }]);
    assert.equal(items[0].pageNumber, null);
    assert.equal(items[0].destinationPath, null);
    assert.equal(items[0].children[0].pageNumber, null);
    assert.equal(items[0].children[0].destinationPath, null);
    assert.equal((await readOutline([])).items.length, 0);
});

for (const tier of ["legacy", "compat", "current"]) {
    test(`${tier} resolves real fixture named outline destinations`, {
        skip: !process.env.PDFJS_OUTLINE_FIXTURE && "Set PDFJS_OUTLINE_FIXTURE to a local PDF fixture",
    }, async () => {
        const assets = new URL("../assets/", import.meta.url);
        const pdfjs = await import(new URL(`pdfjs/${tier}/build/pdf.min.mjs`, assets));
        pdfjs.GlobalWorkerOptions.workerSrc = new URL(`pdfjs/${tier}/build/pdf.worker.min.mjs`, assets).href;
        const task = pdfjs.getDocument({
            data: new Uint8Array(readFileSync(pathToFileURL(process.env.PDFJS_OUTLINE_FIXTURE))),
            isEvalSupported: false,
        });
        try {
            const document = await task.promise;
            const outline = await readOutline(await document.getOutline(), {
                getPageIndex: (ref) => document.getPageIndex(ref),
                getDestination: (name) => document.getDestination(name),
            });
            assert.deepEqual(Array.from(outline.items.slice(0, 10), (node) => node.pageNumber),
                [1, 100, 101, 99, 98, 97, 94, 89, 88, 85]);
        } finally {
            await task.destroy();
        }
    });
}