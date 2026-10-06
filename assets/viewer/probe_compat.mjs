// Capability probe for the `compat` and `current` tiers (pdfjs-dist 6.3.289).
//
// Both 6.x bundles are syntactically equivalent — verified by grepping
// assets/pdfjs/{compat,current}/build/pdf.min.mjs: identical feature
// occurrence counts, one class static block each. The only thing that
// separates `current` from `compat` is the unpolyfilled runtime method
// `Map.prototype.getOrInsertComputed`, which bootstrap.js feature-detects
// directly, so there is no third probe module.
//
// On top of the `legacy` floor this adds:
//
//   class static blocks   static { }   Chrome 94, Safari 16.4
class Probe {
    static ok = false;

    static {
        this.ok = true;
    }

    #value = 1;

    run() {
        const target = {};
        target.a ??= this.#value;
        return Probe.ok && target?.a === 1;
    }
}

self.__pdfjsProbe.compat = new Probe().run() === true;
