# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
