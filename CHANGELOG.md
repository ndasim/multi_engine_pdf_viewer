# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
