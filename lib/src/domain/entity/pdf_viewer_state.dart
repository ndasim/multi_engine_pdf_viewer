/// Rendering engines bundled with this package.
enum PdfViewerEngine {
  /// PDF.js in a WebView. This is the default.
  pdfJs,

  /// Native PDFium through pdfrx.
  pdfrx,

  /// Offline PDFium compiled to WASM. Opt in; a fatal failure falls back to PDF.js once.
  embedPdf,
}

/// Page arrangement independent of a rendering engine.
class PdfViewerLayout {
  /// Grid layout. [columns] must be greater than 1.
  const PdfViewerLayout.grid({this.columns = 3}) : assert(columns > 1);
  const PdfViewerLayout._vertical() : columns = 1;

  /// Single-column fit-width layout.
  static const vertical = PdfViewerLayout._vertical();

  /// Number of columns. `1` is the vertical layout.
  final int columns;

  /// Whether pages are arranged in a grid.
  bool get isGrid => columns > 1;

  @override
  bool operator ==(Object other) => other is PdfViewerLayout && columns == other.columns;

  @override
  int get hashCode => columns.hashCode;
}

/// An immutable bookmark. Index paths identify destinations within a session.
class PdfOutlineNode {
  /// A bookmark titled [title], optionally pointing at a one-based [pageNumber].
  PdfOutlineNode({
    required this.title,
    this.pageNumber,
    List<PdfOutlineNode> children = const [],
    List<int> path = const [],
    List<int>? destinationPath,
  }) : children = List.unmodifiable(children),
       path = List.unmodifiable(path),
       destinationPath = destinationPath == null ? null : List.unmodifiable(destinationPath);

  /// Bookmark label from the document.
  final String title;

  /// One-based destination page, when the engine resolved one.
  final int? pageNumber;

  /// Nested bookmarks, in document order.
  final List<PdfOutlineNode> children;

  /// Index path of this node within the outline tree.
  final List<int> path;

  /// Index path the engine uses to navigate, when it differs from [path].
  final List<int>? destinationPath;
}

/// A snapshot of a search, with a zero-based active result index.
class PdfSearchState {
  /// Search progress for [query].
  const PdfSearchState({
    this.query = '',
    this.matchCount = 0,
    this.currentIndex,
    this.isSearching = false,
  });

  /// Text currently being searched. Empty when no search is active.
  final String query;

  /// Matches found so far. Results can arrive progressively.
  final int matchCount;

  /// Zero-based index of the selected match, or null before one is selected.
  final int? currentIndex;

  /// Whether a search is still scanning the document.
  final bool isSearching;

  /// Whether [matchCount] is greater than zero.
  bool get hasMatches => matchCount > 0;
}

/// Engine-independent session state. Page numbers are one-based.
class PdfViewerState {
  /// A session snapshot. [outline] is null while loading and empty when the document has none.
  PdfViewerState({
    this.pageCount = 0,
    this.pageNumber,
    List<PdfOutlineNode>? outline,
    this.search = const PdfSearchState(),
  }) : outline = outline == null ? null : List.unmodifiable(outline);

  /// Pages in the open document. Zero before the document is ready.
  final int pageCount;

  /// Current one-based page, or null before navigation is available.
  final int? pageNumber;

  /// Outline bookmarks. Null while loading, empty when the document has none.
  final List<PdfOutlineNode>? outline;

  /// Latest text-search snapshot.
  final PdfSearchState search;

  /// Whether [pageCount] is known and positive.
  bool get isReady => pageCount > 0;
}

/// An optional native font substitution, supplied by the host application.
class PdfFontRegistration {
  /// Substitute the PDF face named [face] with a Flutter [asset].
  ///
  /// Registration is process-global, used only by pdfrx, and never automatically removed.
  const PdfFontRegistration.asset({required this.face, required this.asset, this.resolvedFace});

  /// Face name to replace in the PDF.
  final String face;

  /// Flutter asset key of the substitute font.
  final String asset;

  /// Face name PDFium actually registered, when it differs from [face].
  final String? resolvedFace;
}

/// Safe diagnostic metadata without native objects or local file URLs.
class PdfViewerDiagnostic {
  /// Metadata for the engine that actually rendered, which can differ from the requested engine.
  const PdfViewerDiagnostic({
    required this.engine,
    this.bundle,
    this.source = 'selected',
    this.attempt = 0,
    this.capabilities,
    this.probeSupported,
    this.failure,
    this.canvasHwa,
  });

  /// Engine that produced this event.
  final PdfViewerEngine engine;

  /// PDF.js bundle tier, when this event comes from PDF.js.
  final String? bundle;

  /// Why this engine was selected, such as `selected` or `embedpdf-fallback`.
  final String source;

  /// Zero-based attempt count for this resolution.
  final int attempt;

  /// WebView capability signature, when a probe ran.
  final String? capabilities;

  /// Whether the capability probe succeeded.
  final String? probeSupported;

  /// Fixed failure code, when resolution or rendering failed.
  final String? failure;

  /// Whether hardware-accelerated canvas was enabled.
  final String? canvasHwa;

  /// Parameter map safe to forward to product analytics.
  Map<String, Object> toAnalyticsParameters() => {
    'tier': bundle ?? 'none',
    'tier_source': source,
    'tier_attempt': attempt,
    'webview_capabilities': ?capabilities,
    'tier_probe_supported': ?probeSupported,
    'tier_failure': ?failure,
    'canvas_hwa': ?canvasHwa,
  };

  @override
  String toString() =>
      'PdfViewerDiagnostic(${engine.name}, ${bundle ?? 'none'}, $source, attempt $attempt)';
}

/// A rendering failure; resource URLs are redacted by the owning engine.
class PdfViewerException implements Exception {
  /// A failure identified by the stable [name] code and a redacted [message].
  const PdfViewerException(this.name, this.message);

  /// Stable failure code. Resource-limit codes end in `-limit`.
  final String name;

  /// Redacted explanation safe to display or log.
  final String message;

  @override
  String toString() => 'PdfViewerException($name): $message';
}
