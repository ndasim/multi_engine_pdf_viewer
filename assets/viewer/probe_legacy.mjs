// Capability probe for the `legacy` tier (pdfjs-dist 4.1.392).
//
// Loaded as a module by bootstrap.js. The point is the SYNTAX, not the
// result: an engine that cannot parse this file never runs it, so the flag
// below stays unset and bootstrap treats the tier as unavailable. Keep every
// construct here one that the vendored bundle actually contains — verified by
// grepping assets/pdfjs/legacy/build/pdf.min.mjs:
//
//   optional chaining / nullish      ?.  ??   Chrome 80, Safari 13.1
//   logical assignment               ||= ??=  Chrome 85, Safari 14
//   private instance fields/methods  #x #m()  Chrome 84, Safari 15
//   optional catch binding           catch {} Chrome 66, Safari 11.1
//
// Runtime APIs above that floor (Object.hasOwn, Array.prototype.at,
// structuredClone) are core-js polyfilled inside the legacy bundle itself, so
// they are deliberately NOT probed here.
class Probe {
    #value = 0;

    #bump() {
        return ++this.#value;
    }

    run() {
        const target = { a: null };
        target.a ??= 1;
        target.b ||= 2;
        target.c &&= 3;
        const nullish = target?.a ?? 0;
        const called = target.missing?.();
        try {
            null.boom;
        } catch {
            // Optional catch binding.
        }
        return this.#bump() + nullish + target.b + (called === undefined ? 0 : 1);
    }
}

self.__pdfjsProbe.legacy = new Probe().run() === 4;
