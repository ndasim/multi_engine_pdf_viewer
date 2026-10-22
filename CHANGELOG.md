# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 0.2.0

- Add an automatically registered iOS PDFKit engine, adapted from `feature/pdf_native_ios`, behind the existing controller/session contract.
- Keep PDF.js as the package default on iOS and Android; host applications own the PDFKit platform default and disable flags.
- Log unsupported mobile engine selections and fall back to PDF.js before creating the adapter, retaining page/layout/callbacks and emitting a diagnostic.
- Support native vertical/grid rendering, pinch/double-tap zoom, page callbacks, internal/named links, outline destinations and cancellable progressive search.
- Forward only allowlisted external links to the host, redact native errors, and fall back once to pdfrx for PDFKit plugin/transport failures.
- Add native-session/facade regression tests, generated-fixture iOS integration coverage and an opt-in real-HID simulator harness.
- Show per-page PDF.js loading indicators and remove the startup overlay once page layout is ready.
- Keep the JavaScript compatibility guard as an upper bound without requiring unused logical-assignment syntax.

## 0.1.8

- Keep the same anchored page geometry throughout EmbedPDF pinch, touch end and cancellation instead of transforming the full document and relaying it out on release.
- Defer zoom raster work until the gesture settles; replace canvases atomically, release old backing stores and reuse pixel-capped resolutions.
- Reserve raster-cache headroom for replacements and recheck the budget when overlapping worker results arrive, without evicting visible pages.
- Cover pinch geometry, stale render results, large-document limits, overlapping navigation and real-browser pinch thresholds while preserving fatal fallback.

## 0.1.7

- Coalesce identical PDFium form-action callbacks from a single EmbedPDF click so PDFs that repeat `NextPage` or `PrevPage` navigate once instead of failing with `ambiguous-widget-action`. Conflicting actions remain rejected.
- Verify forward and backward navigation with a real PDF in the iOS simulator. Unit tests and new physical Android/iOS smoke checks were explicitly deferred by the maintainer for this release.

## 0.1.6

- Remove the four-page touch-scroll limiter from all PDF.js tiers, preserving native dragging and momentum without changing pinch zoom, grid layout or navigation anchors.
- Remove the unused shared scroll limiter and cover forward and backward scrolling during dragging, after touch end and after touch cancellation in legacy, compatibility and current tiers.

## 0.1.5

- Remove the four-page touch-scroll limiter from EmbedPDF so native dragging and momentum no longer snap back at the gesture boundary. PDF.js behavior is unchanged.
- Cover forward and backward touch scrolling during dragging, after touch end, and after touch cancellation while preserving pinch zoom and navigation anchors.

## 0.1.4

- Fall back once from fatal EmbedPDF failures to native pdfrx while retaining the last page and layout. PDF.js remains the default engine.
- Raise the EmbedPDF document limit to 200 MiB and send larger documents directly to native progressive loading; other resource quotas remain terminal.
- Ignore targetless overlapping PDFium links, prefer explicit native link annotations over detected URLs, and preserve coordinate-bearing native destinations.
- Clear native link caches on document changes and discard asynchronous taps after document or layout replacement.
- Cover overlapping link selection with a real PDFium-WASM regression test and align fallback documentation.

## 0.1.3

- Polyfill `ReadableStream` async iteration in the PDF.js host page. WebKit lacks it, so PDF.js text extraction failed and in-document search found nothing on iOS.

## 0.1.2

- Keep unresolved outline destinations null in PDF.js and EmbedPDF instead of copying a preceding or parent target. A heading still uses the first descendant that has a real destination.
- Resolve PDF.js named destinations one name at a time, so an incomplete bulk name tree does not drop a real target, and accept indirect page references.
- Treat a pdfrx outline destination whose page number is below 1 as unresolved. PDFium reports that case as page 0.
- Limit single-column touch scrolling to four pages of momentum in the PDF.js and EmbedPDF viewers.
- Pause the EmbedPDF heartbeat while another route covers the viewer, and restore it when that route is current again.
- Include the failure in `PdfViewerDiagnostic.toString`.

## 0.1.1

- Ship the PDF.js `pdf.min.mjs` and `pdf.worker.min.mjs` files for the legacy, compat, and current tiers. Version 0.1.0 omitted them.

## 0.1.0

Initial release.

- Engine-independent PDF viewer for Android and iOS behind a single controller.
- Three interchangeable rendering engines: PDF.js (WebView), EmbedPDF
  (offline PDFium-WASM) and pdfrx/PDFium (native).
- Vertical fit-width and grid layouts, pinch and double-tap zoom.
- Text search with result navigation and counters.
- Engine-neutral outline bookmarks, internal links and named-action handling.
- Allowlisted external links forwarded to the host application.
- Runnable Android and iOS example application.
