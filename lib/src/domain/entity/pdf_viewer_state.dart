/// Rendering engines bundled with this package.
enum PdfViewerEngine { pdfJs, pdfrx, embedPdf }

/// Page arrangement independent of a rendering engine.
class PdfViewerLayout {
  const PdfViewerLayout.grid({this.columns = 3}) : assert(columns > 1);
  const PdfViewerLayout._vertical() : columns = 1;

  static const vertical = PdfViewerLayout._vertical();
  final int columns;
  bool get isGrid => columns > 1;

  @override
  bool operator ==(Object other) => other is PdfViewerLayout && columns == other.columns;

  @override
  int get hashCode => columns.hashCode;
}

/// An immutable bookmark. Index paths identify destinations within a session.
class PdfOutlineNode {
  PdfOutlineNode({
    required this.title,
    this.pageNumber,
    List<PdfOutlineNode> children = const [],
    List<int> path = const [],
    List<int>? destinationPath,
  }) : children = List.unmodifiable(children),
       path = List.unmodifiable(path),
       destinationPath = destinationPath == null ? null : List.unmodifiable(destinationPath);

  final String title;
  final int? pageNumber;
  final List<PdfOutlineNode> children;
  final List<int> path;
  final List<int>? destinationPath;
}

/// A snapshot of a search, with a zero-based active result index.
class PdfSearchState {
  const PdfSearchState({
    this.query = '',
    this.matchCount = 0,
    this.currentIndex,
    this.isSearching = false,
  });

  final String query;
  final int matchCount;
  final int? currentIndex;
  final bool isSearching;
  bool get hasMatches => matchCount > 0;
}

/// Engine-independent session state. Page numbers are one-based.
class PdfViewerState {
  PdfViewerState({
    this.pageCount = 0,
    this.pageNumber,
    List<PdfOutlineNode>? outline,
    this.search = const PdfSearchState(),
  }) : outline = outline == null ? null : List.unmodifiable(outline);

  final int pageCount;
  final int? pageNumber;
  final List<PdfOutlineNode>? outline;
  final PdfSearchState search;
  bool get isReady => pageCount > 0;
}

/// An optional native font substitution, supplied by the host application.
class PdfFontRegistration {
  const PdfFontRegistration.asset({required this.face, required this.asset, this.resolvedFace});

  final String face;
  final String asset;
  final String? resolvedFace;
}

/// Safe diagnostic metadata without native objects or local file URLs.
class PdfViewerDiagnostic {
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

  final PdfViewerEngine engine;
  final String? bundle;
  final String source;
  final int attempt;
  final String? capabilities;
  final String? probeSupported;
  final String? failure;
  final String? canvasHwa;

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
  const PdfViewerException(this.name, this.message);

  final String name;
  final String message;

  @override
  String toString() => 'PdfViewerException($name): $message';
}
