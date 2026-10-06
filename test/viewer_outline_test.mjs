import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";

const source = readFileSync(new URL("../assets/viewer/viewer.mjs", import.meta.url), "utf8");
const start = source.indexOf("function createPageResolver(");
const end = source.indexOf("// ---- Search", start);
assert.ok(start >= 0 && end > start, "Cannot locate shipped outline functions");

async function readOutline(nodes) {
    let items;
    let destination;
    const context = vm.createContext({
        state: { ready: true, linkService: {
            goToDestination(target) { destination = target; },
        } },
        post(type, payload) {
            assert.equal(type, "outline");
            items = payload.items;
        },
    });
    vm.runInContext(source.slice(start, end), context);
    const document = { getOutline: async () => nodes };
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
    assert.deepEqual(Array.from(section.children, (child) => child.pageNumber), [4, 4, 4]);
    outline.navigate(section.destinationPath);
    assert.equal(outline.destination, destination);
});

test("nested groups and later siblings keep their real destinations", async () => {
    const { items } = await readOutline([
        { title: "Cover", dest: [0] },
        { title: "Section", items: [{ title: "Nested group", items: [
            { title: "Leading heading" }, { title: "Page seven", dest: [6] },
        ] }] },
        { title: "Targetless sibling" },
        { title: "Later section", items: [{ title: "Page twelve", dest: [11] }] },
    ]);
    assert.deepEqual(Array.from(items, (item) => item.pageNumber), [1, 7, 7, 12]);
    assert.deepEqual(Array.from(items[1].destinationPath), [1, 0, 1]);
    assert.equal(items[1].children[0].children[0].pageNumber, 7);
    assert.deepEqual(Array.from(items[3].destinationPath), [3, 0]);
});

test("explicit section targets win and targetless children inherit", async () => {
    const { items } = await readOutline([{ title: "Section", dest: [1], items: [
        { title: "Leading heading" },
        { title: "Page nine", dest: [8] },
        { title: "Trailing heading" },
    ] }]);
    assert.equal(items[0].pageNumber, 2);
    assert.deepEqual(Array.from(items[0].destinationPath), [0]);
    assert.deepEqual(Array.from(items[0].children, (child) => child.pageNumber), [2, 9, 9]);
    assert.deepEqual(Array.from(items[0].children[2].destinationPath), [0, 1]);
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