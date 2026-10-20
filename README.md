# multi_engine_pdf_viewer

An engine-independent local-file PDF viewer for Android and iOS, with PDF.js,
EmbedPDF and pdfrx/PDFium adapters behind one controller. Toolbars, localization and
application state remain in the host. Requires Dart 3.10+ and Flutter 3.41+.
The combined package does not support web or desktop.

## Install

```yaml
dependencies:
  multi_engine_pdf_viewer: ^0.1.6
```

Android must allow cleartext HTTP for `127.0.0.1` only. See [Platform setup](#platform-setup). The runnable example in [`example/`](example/) already includes that configuration.

## Features

- Vertical fit-width and grid layout (`PdfViewerLayout.grid(columns: 3)`), pinch and double-tap zoom.
- Text search, result navigation and counters (`PdfTextSearcher`).
- Engine-neutral outline bookmarks (`PdfViewerController.outline`).
- Internal links and NextPage/PrevPage PDF push-button named actions in all three adapters.
- Allowlisted external links forwarded to the host, never opened by the package.
- No stock PDF.js toolbar; all UI stays in Flutter.

## Engine Selection And Benefits

PDF.js remains the default. EmbedPDF is opt-in, not a fleet-certified replacement.
All engines share page navigation, outline, search and grid contracts, but their
render/ready hooks and resource ownership differ.

| Engine | Main benefit | Cost / qualification boundary |
| --- | --- | --- |
| PDF.js | Mature JavaScript rendering, tier downgrade, standard fonts and annotation handling without app-owned native FFI | WebView/renderer memory; legacy security mitigations are not an upstream patch |
| EmbedPDF 2.15.1 | Offline PDFium-WASM in a dedicated worker; on the measured Samsung, faster visible content and lower end PSS than PDF.js | WASM/CSP/module-worker requirements; app-owned raw form callback adapter; minimum-runtime and real renderer-crash qualification remain open |
| pdfrx 2.4.x / PDFium | Native progressive loading; lowest measured visible-content latency and end PSS on the same Samsung | Native FFI/callback lifetime and process-global font ownership; physical search/page-state disagreement remains open |

Named-action evidence means taps on actual PDF `/Btn` widgets, not Flutter next/prev
commands or a WASM export table. Samsung release verified 2 -> 3 -> 2 with one
page event per tap for all engines; Android API 37 also verified EmbedPDF. iOS
16.2 simulator verified actual EmbedPDF named widgets 2 -> 3 -> 2 with one callback
per HID tap. Other recorded iOS versions have rendering/reopen evidence only.
These fixture results do not establish support for arbitrary PDF actions/scripts.

## PDF.js version

The package ships three bundle tiers (see `assets/pdfjs/VERSION`):

- iOS/iPadOS 15.0-16.3 uses `pdfjs-dist` **4.1.392**, `legacy` build.
- Compatibility and current tiers use `pdfjs-dist` **6.3.289**, selected by a
  runtime WebView capability probe with automatic downgrade on bundle failure.

The version table is only a seed. A runtime probe and cached capability signature
determine the actual tier, including changes to Android System WebView. A failed
PDF.js bundle can downgrade but never silently switches engines. Supply a
`PdfViewerCacheStore` and `appVersion` for durable cache invalidation.

CVE-2024-4367 (fixed upstream in 4.2.67) is mitigated by `isEvalSupported: false` and a Content Security Policy without `unsafe-eval`, so PDF.js can never compile font glyphs with `new Function`. Scripting and XFA are disabled.

Update with `tool/vendor_pdfjs_bundles.sh [legacy-version] [current-version]` and review the diff of `assets/pdfjs/`.

## Example

The runnable example is in [`example/`](example/). It opens a PDF from the system file picker on Android and iOS and can switch among PDF.js, EmbedPDF and pdfrx.

`tool/performance_harness/` is a development harness and is excluded from the published package. PDF fixtures, archives and build products are not distributed.

## Usage

```dart
import 'package:multi_engine_pdf_viewer/multi_engine_pdf_viewer.dart';

final controller = PdfViewerController();

PdfViewer.file(
  '/path/to/document.pdf',
  controller: controller,
  initialPageNumber: 1,
  params: PdfViewerParams(
    engine: PdfViewerEngine.embedPdf, // Opt-in; the default is pdfJs. Also: pdfrx.
    layout: PdfViewerLayout.vertical,
    loadingBuilder: (_) => const Center(child: CircularProgressIndicator()),
    onViewerReady: (controller) {},
    onExternalLinkTap: (uri) {},
    onError: (error, stackTrace) {},
  ),
);

final searcher = PdfTextSearcher(controller)..startTextSearch('fuel');
await searcher.goToNextMatch();
```

A controller attaches to only one live viewer. Dispose searchers before their
controller when removing the host screen. A viewer with no supplied controller
owns it. File/engine changes replace the session. Give the viewer a new key to
retry or reopen a file replaced at the same path. Pages are one-based and clamped;
commands before readiness are no-ops. Outline is null while loading and empty if
absent. Search indexes are zero-based and null before a result is selected.
Results arrive progressively; clear them with `startTextSearch('')`.

A grid-page tap returns to vertical layout and navigates to the page.
`onLayoutChanged` lets the host synchronize its controls. `onViewerReady` means
navigation is available, not that every page is loaded. `onFirstPageRendered`
fires once per session. `onDiagnostic` carries engine/bundle resolution metadata.
Downloading, document authorization and persistence remain host responsibilities.

## Architecture

`src/domain` defines source-independent entities and the internal session contract.
`src/data` owns protocols, local serving and native helpers. `src/presentation`
owns the Flutter facade and engine rendering adapters. There are no application
services, service locator or private package dependencies. Import only
`multi_engine_pdf_viewer.dart` in production; the separate `multi_engine_pdf_viewer_debug.dart`
entry point is profiling-only.

All three adapters implement `PdfEngineSession`. The viewer owner selects and
retires sessions; generation guards discard callbacks from replaced sessions.
EmbedPDF owns its WebView/server/worker resources, while the serialized worker
owns the raw PDFium document and short-lived form environments.

## EmbedPDF And Fatal Fallback

The offline runtime is vendored, unmodified `@embedpdf/pdfium` **2.15.1**, with
`@embedpdf/fonts-latin` **1.0.0**. Stock `@embedpdf/engines` and `@embedpdf/models`
are reference-only, not runtime dependencies. Each named-action operation opens
and synchronously closes one form environment, removes its callback and closes
the page. Node/WASM fixture proof records 66 next/previous clicks with one callback
each, and all 78 environments released. This is not mobile lifetime certification.
See [implementation ownership notes](lib/src/data/embedpdf/IMPLEMENTATION.md).

Pinch zoom updates the anchored page layout once per animation frame, without
scaling the whole document into a compositor layer or switching geometry at
touch end. Raster work pauses during pinch and resumes after a 150 ms settling
delay. Zoom and column changes retain the old canvas until a fully painted
replacement is ready, release its backing store after replacement, and reuse
rasters already at the pixel cap. The cache reserves replacement headroom and
evicts offscreen pages rather than clearing visible pages to make room. These
are raster budgets, not a hard cap on total WebView, GPU or PDFium memory.

This adapter already calls PDFium's low-level APIs, but inside WebAssembly in a
WebView worker. It cannot turn those calls into native FFI calls by configuration.
For native PDFium rendering and Flutter-owned gestures, select the existing
`PdfViewerEngine.pdfrx` adapter instead; that is an engine change, not an EmbedPDF
optimization, and requires its own device qualification.

Unsupported startup capabilities or an observable fatal EmbedPDF failure retire
that session and fall back **once to pdfrx**, preserving the last page and layout.
The failed worker is stopped before replacement; retired callbacks are ignored.
Recoverable command failures do not replace the engine. Resource-quota violations
are terminal errors, except for the EmbedPDF document-size limit: files over
200 MiB fall back to native progressive loading before a WebView starts.
PDF.js may downgrade its own bundle tiers, but never retries EmbedPDF or switches
to pdfrx. If the fallback pdfrx session fails, the viewer reports failure.

Search state and zoom are not guaranteed to survive engine replacement.
`onDiagnostic` identifies the actual engine; the originally requested engine is
not evidence of the rendering engine. Ready/first-paint callbacks can occur again
for the replacement session. The debug-only entry point exposes exception
injection and actual worker termination for harness verification.

The active-time watchdog checks worker requests/heartbeat; suspension pauses its
clock. Exception injection verifies the fallback path, **not worker or renderer
death**. Native WebView termination is only observable where the platform plugin
reports it. A killed Flutter application cannot perform in-process recovery.
Historical testing with `Worker.terminate()` on iOS 16.2 triggered watchdog fallback to PDF.js
legacy, repainted page 2 and retained the application PID through a 12-second
stability window. This is actual worker termination, not exception injection or
an application kill. That result does not qualify the current pdfrx fallback.
OS content-process crash and OOM qualification remain gates.

Re-vendor from the workspace root with `node tool/vendor_embedpdf.mjs`. Pinned
tarball integrity, artifact hashes, sizes and notices are in
[assets/embedpdf/VERSION](assets/embedpdf/VERSION). Review artifacts, licenses,
worker CSP and regression/device evidence before changing pins.

## Native Engine

pdfrx uses progressive PDFium loading, conservative caches for large documents and
search highlighting. Its named-action FFI supports NextPage/PrevPage only. The
verified pdfrx 2.4.x and pdfium_dart 0.2.5 API ranges are bounded deliberately:
native callback threading and lifetimes must be reviewed before upgrades.

Host-supplied `PdfFontRegistration.asset` entries substitute native font faces.
Registration is process-global and never automatically undone; it can affect
other native viewers. A failed registration reports a diagnostic and continues
with PDFium's built-in fallback. PDF.js uses bundled standard fonts.

## PDF.js Internals

The widget starts a `dart:io` `HttpServer` bound to `127.0.0.1` on a random port. Every URL carries a random 128-bit path token. The server answers only `GET`/`HEAD`, supports HTTP Range requests for progressive loading, and sets `Cache-Control: no-store`, `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer` and a strict CSP. The WebView may only navigate inside that origin (`http`/`https` URLs on it); `mailto:`, `tel:`, `http(s)` links elsewhere go to `onExternalLinkTap`, every other scheme is dropped.

Other apps on the device can reach loopback ports. The path token protects document
access. The resume liveness probe never sends that token or a reusable secret:
it checks a fresh challenge and a per-instance HMAC response. Every rebind rotates
the token. Encoded traversal is rejected, exceptions redact loopback tokens, and
EmbedPDF errors/telemetry use fixed codes rather than document/error contents.

EmbedPDF uses the same authenticated loopback server with separate page/worker
CSP: `script-src 'self' 'wasm-unsafe-eval'`, never JavaScript `unsafe-eval`.
Runtime assets, WASM and fonts are local; no document upload or CDN is required.

Dart and the host page (`assets/viewer/viewer.mjs`) exchange versioned JSON messages over the `PdfJsBridge` JavaScript channel. Commands are JSON-encoded twice so they reach JavaScript as string data, never as code.

All gestures are handled in the host page: the WebView claims every pointer eagerly, PDF.js handles internal links and named actions from the browser's click, and `viewer.mjs` adds pinch zoom, double-tap zoom and the grid page tap on top of the touch events. Taps on annotation links are turned into clicks by the host page instead of by WebKit, because WKWebView withholds its synthetic click while the page content is still changing (PDF.js rendering a freshly scrolled-to page). Links and push buttons whose destination cannot be resolved stop receiving pointer events, so a tap reaches the annotation beneath them.

When iOS reclaims the socket of a suspended app, the server rebinds on resume with a fresh token and the page reloads at the current page. A terminated WebKit content process also reloads the page.

The fit-width scale is that of the widest page: PDF.js applies one scale to the whole document, so fitting a narrower page would let landscape pages overflow. PDF.js only knows the real page sizes once it has fetched every page; the viewer refits at that point unless the user has zoomed already.

## Platform setup

Android blocks cleartext HTTP by default. Allow it for the loopback address only, in `android/app/src/main/res/xml/network_security_config.xml`:

```xml
<network-security-config>
  <domain-config cleartextTrafficPermitted="true">
    <domain includeSubdomains="false">127.0.0.1</domain>
  </domain-config>
</network-security-config>
```

and reference it from the `<application>` element with `android:networkSecurityConfig="@xml/network_security_config"`.

iOS: App Transport Security exempts loopback IP literals on iOS 10 and later, so no `Info.plist` change should be needed. If the WebView reports an ATS block on your minimum iOS version, add `NSAllowsLocalNetworking` (not `NSAllowsArbitraryLoads`) to `NSAppTransportSecurity`.

## Verification

```sh
flutter pub get
dart analyze lib test
flutter test test
node --test test/viewer_outline_test.mjs
node --experimental-vm-modules --test test/viewer_layout_test.mjs test/embedpdf_limits_test.mjs test/embedpdf_viewer_navigation_test.mjs
cd example && flutter pub get && dart analyze && flutter test
cd .. && flutter pub publish --dry-run
```

## Compatibility Evidence

Strict-CSP **candidate** floor: iOS 16+ WKWebView, or Android minSdk 24 with
WebView 97+, **and** successful actual worker/WASM/Canvas probes. This is primary
source research, not minimum-version device certification; a currently patched
provider is required in production. Never relax CSP to support an older runtime.

| Target | EmbedPDF evidence, 2026-10-06 | Remaining boundary |
| --- | --- | --- |
| Physical Samsung SM-A137F, Android 13, 32-bit userland, WebView 153.0.8010.36 | Release render, actual named widgets, search, outline, grid, reopen, background/resume | One device, not fleet/minimum/OOM certification |
| iOS 16.2 simulator | Debug open/nonblank/reopen, actual named widgets 2 -> 3 -> 2, controlled worker termination -> PDF.js legacy at page 2 | Not physical iOS or iOS 16.0 minimum certification |
| iOS 17.2 / 18.6 / actual 26.4.1 simulators | Debug open, nonblank render and reopen | Named-action taps and physical iOS unverified |
| Pixel_10, Android 17/API 37, WebView 153.0.8010.36 emulator | Debug render and actual named widgets 2 -> 3 -> 2 | Not a physical or minimum-runtime pass |
| Android 9/API 28, WebView 66 emulator | EmbedPDF -> PDF.js attempted; neither rendered | Unsupported measured combination, not a fallback success |
| iOS 15 | Runtime unavailable | No unsupported/fallback acceptance test |

These figures supersede the earlier zoom and grid defects: four physical double-taps and a real pinch retained page 6, and an injected fallback stayed at grid page 7 and vertical page 6. The physical pdfrx search and page-state disagreement is still open. Do not infer a green whole-package test suite or crash certification from these scoped passes. Lab notes outside this package are not published with it.

## Same-Device Performance

Samsung SM-A137F, Android 13, WebView 153.0.8010.36, **release harness**, identical
21,417,410-byte / 189-page fixture, starting page 1. Twelve samples: one
process-cold and three warm reopens per engine. Cold means force-stop/launch, not
reboot or cleared provider/filesystem caches. Warm means a new viewer in the same
process; PDF.js resolved current/cache (6.3.289).

Each timing cell below is **cold / warm median**, milliseconds.

| Engine | Open hook ms | Paint hook ms | Recorded visible content ms | Warm end PSS median KiB |
| --- | ---: | ---: | ---: | ---: |
| EmbedPDF 2.15.1 | 2428 / 1383 | 4824 / 3675 | 4800 / 3700 | 372159 |
| PDF.js current | 1564 / 1231 | 7258 / 6226 | 7200 / 6300 | 451233 |
| pdfrx | 2712 / 2521 | 495 / 353 | 2100 / 1800 | 219602 |

Open/paint hooks are engine-specific lifecycle callbacks, **not cross-engine
visible-content comparisons**; native paint can precede ready/outline loading.
Visible content is measured from the document region in screen recordings,
resampled at 100 ms with sustained blank/content transitions. Three warm samples
per engine are insufficient for fleet or percentile claims. Recording/memory
instrumentation adds overhead. PSS sums observed host plus listed renderer
snapshots; it is neither a continuous true peak nor a resource ceiling.

The table is the release matrix for that device and fixture. Debug and simulator measurements are not mixed into these cells. Rejected historical baseline and ratio claims are not reused. Raw recordings are not part of this package.

## Release status

This package is licensed under the MIT license in [LICENSE](LICENSE). Source and issues: https://github.com/ndasim/multi_engine_pdf_viewer

The name `flutter_pdf_viewer` is already taken on pub.dev (0.6.1, 2018). This package is published as `multi_engine_pdf_viewer`.

Android and iOS device smoke tests remain a release gate. Changing the default to EmbedPDF requires broader device and minimum-runtime coverage, broader iOS named-action qualification and measured failure recovery. Current evidence is a partial verification. Minimum devices, OS renderer crash and low-memory behavior, and the native search and page-state regression remain open.

For 0.1.4, the maintainer explicitly deferred new Android/iOS device smoke tests
because no physical devices were connected. Automated checks do not qualify the
new native fallback or link changes on physical devices.

For 0.1.5, the maintainer explicitly deferred new physical iOS smoke tests until
after publication. Automated touch-event regressions verify that EmbedPDF no
longer clamps native dragging or momentum; they are not physical-device
qualification. Existing PDF.js scrolling behavior is unchanged.

For 0.1.6, the maintainer explicitly deferred new physical-device smoke tests
until after publication. Automated regressions verify that PDF.js legacy,
compatibility and current tiers no longer clamp single-touch dragging or
momentum, while preserving zoom and navigation anchors. These checks are not
physical iOS qualification.

For 0.1.7, the maintainer explicitly prohibited running unit tests and deferred
new physical Android/iOS smoke checks. Real-PDF PDFium-WASM inspection and iOS
simulator forward/backward taps verify the duplicate form-action fix only;
they do not qualify physical devices or the full automated regression suite.

The maintainer also deferred the pre-existing syntax-floor test failure that
requires `??=` in the shared viewer source. The same assertion fails on the
unmodified 0.1.5 release. Other automated checks remain required for 0.1.6.

PDF.js retains Apache-2.0 (`assets/pdfjs/LICENSE`); EmbedPDF retains its MIT wrapper,
PDFium third-party and OFL font notices. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
Disabling eval and CSP are
mitigations for legacy CVE-2024-4367, not an upstream patch. Maintained engines and
security monitoring remain necessary for untrusted PDFs.
