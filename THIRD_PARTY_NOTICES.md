# Third-Party Notices

Vendored Mozilla PDF.js is distributed under Apache-2.0. Its license is retained
at `assets/pdfjs/LICENSE`. Exact bundled versions are recorded in
`assets/pdfjs/VERSION`. Standard fonts retain the licenses at
`assets/pdfjs/standard_fonts/LICENSE_FOXIT` and `LICENSE_LIBERATION`.

Runtime dependencies (`webview_flutter`, `pdfrx`, `pdfium_dart`, `ffi` and `crypto`) retain
their own package and transitive native-library licenses. Flutter's license
registry collects dependency licenses; host applications must preserve the native
PDFium notices distributed by those packages. These notices do not license the
package's own source. Its distribution license must be approved by the source owner.

The offline EmbedPDF raw-PDFium adapter uses unmodified `@embedpdf/pdfium` 2.15.1
WASM and JavaScript glue (MIT wrapper). The full PDFium third-party notice is
preserved at `assets/embedpdf/LICENSE.pdfium`; wrapper notices are retained at
`assets/embedpdf/LICENSE.pdfium-wrapper`. The reference-only `@embedpdf/engines`
and `@embedpdf/models` 2.15.1 notices are also preserved. Their high-level engines
are not loaded by this adapter, which owns its form-fill environments directly.
Four unmodified Noto Sans styles from `@embedpdf/fonts-latin` 1.0.0 retain their
OFL-1.1 notice at `assets/embedpdf/LICENSE.fonts`.

`assets/embedpdf/VERSION` records pinned tarball SHA-256/SHA-512 integrity,
artifact sizes, individual SHA-256 values, provenance limits, and the generator
`node tool/vendor_embedpdf.mjs`. No CDN or remote font default is used at runtime.
Byte-exact stable WASM build provenance and organizational legal approval remain
release gates; these notices are not such approval.