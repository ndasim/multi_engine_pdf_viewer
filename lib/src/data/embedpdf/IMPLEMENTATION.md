# EmbedPDF Adapter Handoff

Date: 2026-10-06. This is an opt-in measurement implementation, not release approval.

## Focused Repair Spec And Plan

The device report identifies lost page/point anchoring during zoom and transient
page callbacks during layout/navigation. Security inspection identifies raster
rounding escaping the pixel budget and an annotation quota checked only during
widget enumeration. Repairs are restricted to the EmbedPDF adapter and new tests;
the server, PDF.js, facade, harness and manifests remain parent-owned.

Required outcomes: finite positive geometry, bounded final raster dimensions and
product before native allocation, a fatal 4,096-annotation ceiling before native
render/form/click work, page/point-preserving relayout, stale-session rejection,
and bounded WebView/server cleanup. Bootstrap fatal errors before open must work.

Plan: repair the sizing and annotation guards and validate pure/bounded synthetic
cases; repair document anchoring and validate deterministic repeated navigation;
repair session/cleanup handling and validate with a fake WebView; rerun raw K1,
font/search and package checks. No device use or live vulnerability execution.
Physical verification remains exclusively the later bench runner's responsibility.

### Repair Outcomes And Risk Record

The focused repairs are implemented. `rasterSize()` checks finite positive page
geometry and requests, caps each final integer dimension, and checks their product
before `FPDFBitmap_Create`. A synthetic `.001 x 10000000` page is exercised only
with budgets 1, 2, 17 and 256: at most 1,024 RGBA bytes. Full-budget extreme shapes
are checked only by the pure sizing function, never by unbounded native allocation.

`withPage()` rejects invalid counts or more than 4,096 annotations with
`embedpdf-fatal-annotation-limit` before rendering, form initialization or clicks.
A synthetic 4,097-widget PDF deterministically rejects all three operations,
closes each loaded page, and initializes no form environments. PDFium parsing and
internal allocations before this check still are not subject to a hard heap cap.

Zoom, double-tap, Ctrl-wheel, layout and custom two-touch pinch retain a logical
page and normalized document-point anchor. The anchor is installed before geometry
changes, restored when asynchronous raster dimensions arrive, and released on
manual pan/scroll/key intent. Scroll/intersection observers cannot publish stale
prefetch pages while it is held. Point preservation is limited by real document
scroll boundaries; a grid cannot always place its selected column under the same
screen x-coordinate. Native WebView pinch behavior has been replaced locally with
page-anchor-aware touch handling and must be retested on the physical device.

The Dart adapter accepts sessionless bootstrap failures only before open, then
requires the current session even for errors. Retirement uses the nonempty blank
document `<!doctype html><html></html>`, shares one cleanup future during resume
and disposal, and catches platform/server cleanup failures. Each wait is bounded
to one second; the native server I/O deadline uses the root zone, avoiding fake
widget-time teardown timers. A timeout bounds the wait, not cancellation of a
platform/native operation that has no cancellation API.

No shared server code, HMAC, CSP, PDF.js code/bundles, pdfrx, production facade,
root harness or manifest was changed by these repairs. The already-existing
EmbedPDF-only `script-src 'self' 'wasm-unsafe-eval'` remains a security-review gate;
this turn did not add or relax it. The worker transport is unchanged and carries
the new fatal quota code through its existing sanitized error-name path.

Static change review: native allocation/form sinks are guarded, stale bridge
errors cannot retire a current session, errors remain allowlisted names without
PDF text/URLs/tokens, and the existing loopback/token/HMAC/CSP boundaries remain
unchanged. This is not Fortify SAST/SCA/DAST or a WebView compatibility certificate.

## Ownership And Integration

### 0.1.4 Cleanup Spec And Plan

Keep PDF.js as the default. Retire fatal EmbedPDF sessions once and resume with
pdfrx at the last page and layout. The 200 MiB document limit also selects native
progressive loading; all other resource quotas remain terminal. Overlapping links
must select an actionable target, preserve explicit native destination coordinates,
and never act on a retired document or layout.

Plan: align the public fallback documentation; guard native link cache and async
tap ownership, prefer explicit annotations over detected URLs, and retain native
destination semantics; verify package Dart and JavaScript tests, analysis and the
publish dry run; release the patch without changes to the host application.

`EmbedPdfEngineView` has exactly the constructor contract of `PdfJsEngineView`.
`EmbedPdfSession` implements all `PdfEngineSession` operations. Layout and zoom
are additional session operations; `injectFatal()` sends a deterministic fatal
failure for the parent harness. Use a new widget key for another file, as with
PDF.js. The parent must add `PdfViewerEngine.embedPdf`, select this adapter, set
`params.engine` correctly for diagnostic attribution, and own fatal fallback,
page/layout preservation, harness mode/allowlist and README updates. PDF.js remains
the default. Those parent-owned files were not edited.

The implementation uses the unmodified published **raw PDFium** API, not private
fields or form helpers in `@embedpdf/engines`. There is no stock engine form
environment alongside ours. Every render, widget enumeration or click owns one
fresh environment, while one serialized worker owns the document. Mouse down/up
is the only action-acceptance interval. More than one callback rejects the click;
no deduplication or arbitrary last-callback choice is performed. Focus is killed,
the page detached, the environment exited, its synchronous Release verified, and
only then are callback pointers removed. The page closes afterwards. GetPage
returns only that loaded page, and timer callbacks do not create asynchronous work.
The JavaScript platform pointer is zero and no document/page JavaScript APIs run.
Named, GoTo and permitted URI callbacks use this same ownership. Unknown actions
are not executed. FirstPage/LastPage are supported in addition to NextPage/PrevPage.

## Executable K1 Evidence

From the repository root:

```sh
node package/flutter_pdf_viewer/test/embedpdf_fixture_proof.mjs assets/pdf_harness/6474643.pdf
```

[Generated evidence](k1_fixture.json) records the real 21,417,410-byte, 189-page
fixture, SHA-256 `0bd17bc8a853caf386cfd428ac8baa9eff403555d51c7ce199eb358730b69746`.
The WASM SHA-256 is `5e4cd023c3dad4a895b3571ca573d3fc51bac6de48360d95283134385b954eaa`.

On pages 2, 3 and 4, actual widget rectangles are transformed into raster-space
coordinates with PDFium. All **66** repeated NextPage/PrevPage clicks emit exactly
one callback and select exactly one adjacent page. Source and target pages have
nonblank, different raster hashes. All **78** environments release synchronously.
The full outline has **18,798** normalized nodes. Page-2 search for `a` finds
**260** matches with highlight rectangles. This is executable Node/WASM evidence,
not a mobile benchmark or WebView first-paint certification.

The actual browser-targeted glue and worker also pass through the real Dart
loopback server:

```sh
cd package/flutter_pdf_viewer
EMBEDPDF_NODE="$(command -v node)" ../../.fvm/flutter_sdk/bin/flutter test --no-pub test/embedpdf_local_server_test.dart test/embedpdf_session_test.dart
```

That proof covers actual artifact compilation, fonts/document loading, nonblank
raster transfer, native single-action clicks, outline, search geometry, recoverable
command failure, heartbeat and clean worker disposal. Nine checks pass, with the
optional desktop-browser test skipped.

## Offline Artifacts And Shared Code

Regenerate with `node tool/vendor_embedpdf.mjs`. Fixed npm tarball SHA-256 and
SHA-512 integrity values are verified before extracting named members to stdout;
no package scripts run. The generated `assets/embedpdf/VERSION` records 12 files,
7,805,450 bytes before the manifest/adapter, full licenses and provenance limits.
PDFium is 2.15.1; Latin fonts are 1.0.0. Engines/models 2.15.1 are reference-only.
Both browser and Node glue are retained so the proof needs no npm runtime install.
Four local Noto Sans styles cover Latin/Turkish substitution; other fallback
charsets and exact font fidelity remain device/document gates.

Only the shared `PdfJsLocalServer` receives behavioral additions:

- A token-authenticated `embedpdf/` and `embedpdf_viewer/` asset route and viewer URI.
- `application/wasm` MIME mapping.
- Two aliases to the existing capability probe modules.
- **EmbedPDF-only** CSP: `script-src 'self' 'wasm-unsafe-eval'`; never `'unsafe-eval'`.
  `worker-src 'self'`, `connect-src 'self'`, no CDN/blob workers or import maps.

Flag that CSP change for **pdf-security-reviewer**. Existing PDF.js policy, all
three bundle payloads, selector, bridge, bootstrap reporter, token rotation,
loopback bind/address check, instance-id header and range behavior are preserved.
The new page uses `/token/t/legacy/embedpdf_viewer/index.html` only to make the
unchanged bootstrap load its relative `viewer.mjs` immediately. The `legacy`
segment is a loader mechanism, not a PDF.js engine selection. No PDF.js engine
module is imported by the EmbedPDF page. Font/WASM/document fetches require the
same origin and token root, reject redirects, and never use CDN defaults.

## Diagnostics And Runtime Limits

Diagnostics contain `bundle=embedpdf-2.15.1`, `source=worker`, capability flags,
safe failure code and `canvasHwa=bounded-canvas2d`. Parent-provided `params.engine`
supplies the engine enum. No PDF text, paths, URLs, token, exception detail or
user-agent string is forwarded to telemetry. External URI events are not telemetry
and go only to the host's existing http/https/mailto/tel policy callback; the trusted
WebView cannot navigate to them. Outline titles become domain values, never HTML.

Fatal exception names start `embedpdf-fatal-`: unsupported artifact/runtime,
startup/render timeout, worker hang/crash/message failure, WASM trap, content
termination, memory/document/page limits, or injected failure. Recoverable errors
start `embedpdf-command-`. Fatal retirement ignores stale callbacks, stops timers,
disposes/terminates the worker, clears the WebView/channel and closes the server
before notifying the parent. Cleanup platform calls have one-second bounds.

- Startup/first paint: 45 seconds foreground time on Dart; open worker job 30 seconds.
- Render job: 20 seconds. Outline: 30 seconds. Other jobs: 15 seconds.
- Worker heartbeat: every 2 seconds, 20-second reply deadline. Dart heartbeat: 30 seconds.
- All watchdog accounting pauses while backgrounded; resume preserves the page,
  checks/rebinds the server, rejects old-generation callbacks and uses a fresh viewer.
- One worker, serialized native work, at most 64 queued jobs. No retained native pages.
- Document input: 200 MiB; page count: 10,000; annotations/page: 4,096.
- Raster/page: 2,097,152 pixels or the smaller host budget; at most 32 cached pages
  and 8,388,608 aggregate cached pixels. Grid thumbnails get a smaller per-page budget.
- Search: 512 UTF-16 units/query, 10,000 matches and 64,000 rectangles total;
  cancellation checked between page jobs. Only cached pages have highlight DOM.
- Outline: 25,000 nodes, depth 64, title buffer 8,192 bytes; cycle detection and
  cooperative yields every 128 nodes. Outline starts after first painted page.
- WASM memory: **post-operation** 256 MiB guard, not a hard allocator or total-RAM cap.
  The unmodified binary can grow to 2 GiB internally; a single native allocation can
  overshoot before the guard. Freed linear memory does not shrink. Worker termination
  is the recovery boundary. Browser/OS OOM and application process death cannot be
  promised recoverable by this adapter.

The actual artifact is compiled in the worker before initialization; unsupported
syntax, workers, Canvas, CSP/WASM compilation or artifact loading produces a fatal
outcome instead of an indefinite spinner. Candidate runtime floors in the research
are not certifications. The strict WASM CSP itself must be qualified per WebView.
WKWebView termination uses the actual `NavigationDelegate.onWebResourceError`
`webContentProcessTerminated` event. Pinned webview_flutter_android 4.12.0 has no
public renderer-process-gone callback; the native watchdog covers observable loss
of messages, not Android in-process OS/native kills.

## Verification And Release Blockers

FVM Flutter 3.41.6 package `dart analyze`: clean; owned Dart formatting: clean.
The focused repair suites pass **10 Node tests** and **4 fake-WebView tests**;
the existing facade/fallback suite also passes, **17 combined cleanup/fallback
tests**. The raw K1 rerun retains **66 exact-one-action clicks**, **78 environments
and 78 releases**, **18,798 outline nodes**, and **260 page-2 search matches**.
The four-style offline font fixture renders nonblank and finds four `CVL` matches.
The actual browser glue/worker proof through the Dart server passes, including
native widget actions, search geometry, recoverable command error and disposal.

Full FVM package tests with `EMBEDPDF_NODE` enabled: **152 passed, 3 failed,
1 skipped**. Two pre-existing failures in the untouched
`pdf_named_action_handler_test.dart` expect hook count 1 versus 0 at lines 290 and
359. The third is `embedpdf_local_server_test.dart:40`, which still expects an
instance header on an ordinary GET after the parent's HMAC fix moved proof to
the challenged HEAD liveness response. These tests are parent-owned and were not
edited. Do not claim the entire package suite is green. PDF.js server/tier/bridge/
syntax, controller and font suites pass in the full run.

Focused commands from the repository root:

```sh
node --experimental-vm-modules --test package/flutter_pdf_viewer/test/embedpdf_limits_test.mjs package/flutter_pdf_viewer/test/embedpdf_viewer_navigation_test.mjs
node package/flutter_pdf_viewer/test/embedpdf_fixture_proof.mjs assets/pdf_harness/6474643.pdf
cd package/flutter_pdf_viewer
~/fvm/versions/3.41.6/bin/flutter test --no-pub test/embedpdf_engine_cleanup_test.dart test/pdf_viewer_fallback_test.dart
EMBEDPDF_NODE="$(command -v node)" ~/fvm/versions/3.41.6/bin/flutter test --no-pub
~/fvm/versions/3.41.6/bin/dart analyze
```

The deterministic navigation tests load the actual viewer module in a controlled
DOM/worker model. They cover grid selection 2 -> 6, inherited outline target 4,
delayed observer updates, eight double-taps at (540,700), repeated layouts,
pinch midpoint movement, exactly one named-action navigation and manual pan.
They are JS regression evidence, not browser screenshots or mobile gesture proof.

Desktop browser smoke is executable in `test/embedpdf_browser_smoke.mjs`, enabled
through `EMBEDPDF_PLAYWRIGHT_MODULE`, optional `EMBEDPDF_CHROMIUM_EXECUTABLE` and
`EMBEDPDF_EVIDENCE_DIR`. It checks desktop/mobile-sized canvases, offline requests,
native widget 2-to-3-to-2, outline, search/cancellation/highlights, grid, zoom,
stale sessions, injected fatal error and disposal, and saves screenshots. It was
**not completed**: Playwright's download/extraction stalled and installed Chrome
also timed out before the page loaded. Owned processes were stopped. No browser
screenshots, UI assertions or zero-network browser result are claimed.

No physical device or simulator was booted, built or run by this repair invocation.
The separate [physical report](../../../../../../docs/implementation/2026-10-06-embedpdf-device-verification.md)
records the previous mobile measurements and page-6 zoom/transient-navigation
defects; those measurements are not post-repair passes. Runtime memory/timings,
browser interaction/paint, cancellation under load, iOS/Android content termination,
fallback and PDF.js/pdfrx first_page_painted regression gates belong to the parent
and embedpdf-bench-runner. PDF.js fallback grid page drift and pdfrx search page
disagreement in that report remain parent-owned. Byte-exact stable WASM build/
PDFium revision/V8-XFA flags and legal approval also remain release gates.

## Bench Runner Command

The parent has registered `HarnessMode.embedPdf`, its allowlist entry and fatal
fallback. Only embedpdf-bench-runner owns the single-device lock and executes,
from the repository root:

```sh
~/fvm/versions/3.41.6/bin/flutter run --release --flavor thyDev -d "$DEVICE_ID" -t lib/main_documents_pdf_viewer_harness.dart --dart-define=PDF_HARNESS_MODE=embedPdf
```

The runner must confirm run_start, document_opened, first_page_painted and
viewer_error keep their existing meanings and record the actual provider/version.
Retest grid page 6 -> vertical -> double-tap (540,700) twice, real two-pointer
pinch out/in, repeated zoom/layout, inherited outline target 4, exact-one
2-to-3-to-2 actions, fonts/search, reopen and fatal cleanup/fallback. Assert no
transient 4 -> 3 -> 4 or 2 -> 6 -> 3 -> 6 callbacks without user pan. Repeat
`pdfJsAuto` and `pdfrx` runs to `first_page_painted`; no post-repair mobile pass is
claimed here. This adapter does not change PDF.js versions or production defaults.
