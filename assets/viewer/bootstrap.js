// Classic script. Runs before any module, picks the PDF.js bundle this engine
// can actually parse, and reports a module that fails anyway.
//
// WHY THIS FILE IS ES5 AND MUST STAY ES5
//
// Its whole job is to keep running on an engine too old for the PDF.js
// bundles. A previous version claimed "plain ES5" in a comment while using
// `globalThis` twice; on Android 9's stock WebView (Chrome 66) the file parsed
// — `globalThis` is a valid identifier — the listeners installed, and then the
// very first call into viewerLoaded() threw ReferenceError, so the error
// handler died before it could post anything and the user got an infinite
// spinner instead of an error. A comment cannot hold a floor, so the floor is
// enforced by test/viewer_asset_syntax_test.dart, which greps this file and
// fails the suite on anything above ES5.
//
// The CSP is `script-src 'self'`, so this cannot be inlined in index.html, and
// `new Function(...)`/`eval` are blocked by the same policy (and would
// contradict `isEvalSupported: false`, CVE-2024-4367). Syntax-level capability
// detection therefore uses same-origin probe MODULES whose load/error we
// observe, never string compilation.
(function () {
  "use strict";

  var PROTOCOL_VERSION = 1;

  // Generous: it only has to beat a user's patience, and firing while a slow
  // device is still parsing a 2 MB bundle would report a healthy viewer as
  // broken.
  var LOAD_TIMEOUT_MS = 20000;

  // Backstop for the probe modules. Old engines do not reliably fire an
  // `error` event for a module that fails to parse, so a tier whose probe has
  // neither set its flag nor errored by now counts as unsupported. Two
  // ~1 KB same-origin loopback requests; see the first-run cost note in the
  // Phase 1 report.
  var PROBE_TIMEOUT_MS = 1500;

  // `globalThis` is Chrome 71 / Safari 12.1 — above this file's floor. Resolve
  // the global object the ES5 way, once.
  var root =
    typeof globalThis !== "undefined"
      ? globalThis
      : typeof self !== "undefined"
        ? self
        : window;

  // Newest first. Mirrors PdfJsBundle in lib/src/pdfjs_bundle.dart.
  var TIER_CURRENT = "current";
  var TIER_COMPAT = "compat";
  var TIER_LEGACY = "legacy";

  var reported = false;
  var chosenTier = null;

  // ---- Bridge -----------------------------------------------------------

  function postRaw(payload) {
    var channel = root.PdfJsBridge;
    if (!channel) return;
    try {
      channel.postMessage(JSON.stringify(payload));
    } catch (e) {
      // Nothing left to report with.
    }
  }

  // viewer.mjs publishes this once it has run to completion.
  function viewerLoaded() {
    return Boolean(root.pdfjsBridge);
  }

  function fail(name, message) {
    if (reported || viewerLoaded()) return;
    reported = true;
    postRaw({
      v: PROTOCOL_VERSION,
      type: "error",
      name: name,
      message: message,
      tier: chosenTier
    });
  }

  // ---- Failure detection, installed before anything can fail ------------

  function isProbeElement(node) {
    return Boolean(node && node.getAttribute && node.getAttribute("data-pdfjs-probe"));
  }

  // A probe module that parses but throws reports through the WINDOW error
  // event, not the element, so it has to be filtered by source file or a
  // working probe would be mistaken for a broken viewer.
  function isProbeSource(filename) {
    var name = String(filename || "");
    return name.indexOf("/probe_") >= 0 && name.indexOf(".mjs") >= 0;
  }

  // Capture phase also catches the `error` event a failing <script> fires at
  // the element, which does not bubble.
  window.addEventListener(
    "error",
    function (event) {
      var target = event && event.target;
      if (target && target !== window && target.tagName === "SCRIPT") {
        // A probe module that fails to parse is the probe working, not the
        // viewer breaking.
        if (isProbeElement(target)) return;
        fail("ViewerScriptError", "failed to load " + (target.src || "a viewer script"));
        return;
      }
      if (event && isProbeSource(event.filename)) return;
      fail("ViewerScriptError", String((event && event.message) || "script error"));
    },
    true
  );

  window.addEventListener("unhandledrejection", function (event) {
    fail("ViewerScriptError", String((event && event.reason) || "unhandled rejection"));
  });

  setTimeout(function () {
    fail(
      "ViewerLoadTimeout",
      "viewer.mjs did not initialise within " +
        LOAD_TIMEOUT_MS +
        "ms; the WebView engine most likely cannot parse this PDF.js build"
    );
  }, LOAD_TIMEOUT_MS);

  // ---- Where are we, and is the tier already pinned? --------------------

  // The server serves the host page at one of two shapes:
  //   /<token>/viewer/index.html            tier not pinned: probe and decide
  //   /<token>/t/<tier>/viewer/index.html   tier pinned by Dart (cache hit or
  //                                         downgrade); load it immediately
  // Every URL inside the page is relative, so the pinned form makes the whole
  // page — bundle, worker, cmaps, standard fonts, CSS — resolve to that tier
  // without this file touching the path token.
  function pathSegments() {
    var raw = String(root.location.pathname).split("/");
    var out = [];
    for (var i = 0; i < raw.length; i++) {
      if (raw[i] !== "") out.push(raw[i]);
    }
    return out;
  }

  function knownTier(value) {
    return value === TIER_CURRENT || value === TIER_COMPAT || value === TIER_LEGACY;
  }

  function readPinnedTier() {
    var segments = pathSegments();
    if (segments.length >= 3 && segments[1] === "t" && knownTier(segments[2])) {
      return segments[2];
    }
    return null;
  }

  var pinnedTier = readPinnedTier();

  function viewerModuleUrl(tier) {
    return pinnedTier ? "viewer.mjs" : "../t/" + tier + "/viewer/viewer.mjs";
  }

  function pdfJsStylesheetUrl(tier) {
    return "../t/" + tier + "/pdfjs/web/pdf_viewer.css";
  }

  // ---- Runtime capability facts (ES5-safe, no string compilation) --------

  function supportsModules() {
    try {
      return "noModule" in document.createElement("script");
    } catch (e) {
      return false;
    }
  }

  // `current` is untranspiled and unpolyfilled, and the one runtime method it
  // needs that no shipping WebKit before iOS 26 has.
  function supportsGetOrInsertComputed() {
    try {
      return typeof Map !== "undefined" && typeof Map.prototype.getOrInsertComputed === "function";
    } catch (e) {
      return false;
    }
  }

  // `compat` and `current` share a stylesheet that uses CSS `light-dark()`
  // (Chrome 123 / Safari 17.5); `legacy`'s avoids it. Reported as a fact, not
  // used to choose the tier — see the note in pdfjs_bundle.dart.
  function supportsLightDark() {
    try {
      return Boolean(
        root.CSS &&
          root.CSS.supports &&
          root.CSS.supports("color", "light-dark(#000000, #ffffff)")
      );
    } catch (e) {
      return false;
    }
  }

  // ---- Syntax capability probes -----------------------------------------

  root.__pdfjsProbe = {};

  var probes = [
    { tier: TIER_LEGACY, url: "probe_legacy.mjs", key: "legacy" },
    { tier: TIER_COMPAT, url: "probe_compat.mjs", key: "compat" }
  ];

  function capabilitySignature(facts) {
    // Compact and free of anything device-identifying: Dart uses it as the
    // per-device tier cache's validity stamp and puts it in telemetry.
    return (
      "m" + (facts.modules ? 1 : 0) +
      ".l" + (facts.legacySyntax ? 1 : 0) +
      ".c" + (facts.compatSyntax ? 1 : 0) +
      ".g" + (facts.getOrInsertComputed ? 1 : 0) +
      ".d" + (facts.lightDark ? 1 : 0)
    );
  }

  function collectFacts() {
    return {
      modules: supportsModules(),
      legacySyntax: root.__pdfjsProbe.legacy === true,
      compatSyntax: root.__pdfjsProbe.compat === true,
      getOrInsertComputed: supportsGetOrInsertComputed(),
      lightDark: supportsLightDark()
    };
  }

  function pickTier(facts) {
    if (!facts.modules) return null;
    if (facts.compatSyntax && facts.getOrInsertComputed) return TIER_CURRENT;
    if (facts.compatSyntax) return TIER_COMPAT;
    if (facts.legacySyntax) return TIER_LEGACY;
    return null;
  }

  function loadProbes(done) {
    var settled = 0;
    var finished = false;

    function settle() {
      if (finished) return;
      finished = true;
      done();
    }

    function onSettled() {
      settled++;
      if (settled >= probes.length) settle();
    }

    if (!supportsModules()) {
      settle();
      return;
    }

    for (var i = 0; i < probes.length; i++) {
      var element = document.createElement("script");
      element.type = "module";
      element.setAttribute("data-pdfjs-probe", probes[i].key);
      element.addEventListener("load", onSettled);
      element.addEventListener("error", onSettled);
      element.src = probes[i].url;
      document.head.appendChild(element);
    }

    setTimeout(settle, PROBE_TIMEOUT_MS);
  }

  // ---- Loading the host page --------------------------------------------

  function loadViewer(tier) {
    chosenTier = tier;
    if (!pinnedTier) {
      var link = document.getElementById("pdfJsStylesheet");
      if (link) link.setAttribute("href", pdfJsStylesheetUrl(tier));
    }
    var element = document.createElement("script");
    element.type = "module";
    element.src = viewerModuleUrl(tier);
    document.head.appendChild(element);
  }

  function reportTier(tier, source, facts) {
    postRaw({
      v: PROTOCOL_VERSION,
      type: "tier",
      tier: tier,
      source: source,
      capabilities: capabilitySignature(facts),
      supported: pickTier(facts)
    });
  }

  if (pinnedTier) {
    // Pinned is the steady state: start the real viewer immediately and let
    // the probes run alongside it, so the probe round trip is off the critical
    // path. Their answer still reaches Dart, which uses it to notice that the
    // System WebView was updated under a cached tier.
    loadViewer(pinnedTier);
    loadProbes(function () {
      reportTier(pinnedTier, "pinned", collectFacts());
    });
  } else {
    loadProbes(function () {
      var facts = collectFacts();
      var tier = pickTier(facts);
      if (tier === null) {
        reportTier(null, "probe", facts);
        fail(
          "EngineUnsupported",
          "no vendored PDF.js build can run in this WebView (capabilities " +
            capabilitySignature(facts) +
            "); the oldest build still needs class private methods, optional " +
            "chaining and logical assignment"
        );
        return;
      }
      reportTier(tier, "probe", facts);
      loadViewer(tier);
    });
  }
})();
