import 'package:flutter/widgets.dart';

import '../domain/entity/pdf_viewer_state.dart';
import '../domain/repo/pdf_engine_session.dart';
import 'pdf_viewer_controller.dart';

/// Presentation options and host-owned event handlers. No application UI is bundled.
class PdfViewerParams {
  /// Profiling override. Production code should pass [engine] instead.
  static PdfViewerEngine? debugEngineOverride;

  /// Options for one viewer. Host applications own platform-specific defaults.
  const PdfViewerParams({
    this.engine = PdfViewerEngine.pdfJs,
    this.layout = PdfViewerLayout.vertical,
    this.margin = 8,
    this.backgroundColor = const Color(0xFF9E9E9E),
    this.pageShadowColor = const Color(0x8A000000),
    this.matchColor = const Color(0x80FFEB3B),
    this.activeMatchColor = const Color(0x80FF9800),
    this.maxCanvasPixels = 5242880,
    this.largeDocumentPageCount = 100,
    this.largeDocumentMaxCanvasPixels = 4194304,
    this.appVersion = '',
    this.cacheStore,
    this.enableHardwareAcceleratedCanvas,
    this.fonts = const [],
    this.loadingBuilder,
    this.errorBuilder,
    this.onViewerReady,
    this.onFirstPageRendered,
    this.onPageChanged,
    this.onPageTap,
    this.onLayoutChanged,
    this.onExternalLinkTap,
    this.onDiagnostic,
    this.onError,
  }) : assert(margin >= 0),
       assert(maxCanvasPixels > 0),
       assert(largeDocumentPageCount > 0),
       assert(largeDocumentMaxCanvasPixels > 0);

  /// Requested engine. Defaults to PDF.js on both Android and iOS.
  /// Unsupported selections fall back to PDF.js with a log and diagnostic.
  final PdfViewerEngine engine;

  /// Vertical or grid page arrangement.
  final PdfViewerLayout layout;

  /// Gap around pages, in logical pixels.
  final double margin;

  /// Color behind the pages.
  final Color backgroundColor;

  /// Shadow drawn around each page.
  /// PDFKit uses its native shadow color; a transparent color disables it.
  final Color pageShadowColor;

  /// Highlight color for search matches.
  final Color matchColor;

  /// Highlight color for the selected search match.
  final Color activeMatchColor;

  /// Canvas pixel budget for a normal document.
  final int maxCanvasPixels;

  /// Page count at which [largeDocumentMaxCanvasPixels] replaces [maxCanvasPixels].
  final int largeDocumentPageCount;

  /// Canvas pixel budget used when [largeDocumentPageCount] is reached.
  final int largeDocumentMaxCanvasPixels;

  /// Host version mixed into the PDF.js capability cache key. Empty skips that component.
  final String appVersion;

  /// Optional store for the PDF.js capability decision. Failures never block opening.
  final PdfViewerCacheStore? cacheStore;

  /// Forces hardware-accelerated canvas on or off. Null lets the engine decide.
  final bool? enableHardwareAcceleratedCanvas;

  /// Native font substitutions are process-global and never automatically removed.
  /// Only used by pdfrx. PDF.js uses the bundled standard fonts.
  /// PDFKit uses system and document-embedded fonts.
  final List<PdfFontRegistration> fonts;

  /// Shown until the first page can be displayed.
  /// PDF.js hands off to per-page spinners when page layout is ready.
  final WidgetBuilder? loadingBuilder;

  /// Shown when opening or rendering fails and no fallback is available.
  final Widget Function(BuildContext context, Object error)? errorBuilder;

  /// Called when navigation is available, not when every page has loaded.
  final ValueChanged<PdfViewerController>? onViewerReady;

  /// Called once per session with the first painted one-based page.
  final ValueChanged<int>? onFirstPageRendered;

  /// Called with the new one-based page after a page change.
  final ValueChanged<int>? onPageChanged;

  /// Called with the tapped one-based page.
  final ValueChanged<int>? onPageTap;

  /// Called when a grid-page tap returns the viewer to vertical layout.
  final ValueChanged<PdfViewerLayout>? onLayoutChanged;

  /// Called for an allowlisted external link. The package never opens it.
  final ValueChanged<Uri>? onExternalLinkTap;

  /// Engine and bundle resolution metadata, without document contents.
  final ValueChanged<PdfViewerDiagnostic>? onDiagnostic;

  /// Called for a failure reported to the host. The viewer may still fall back after some errors.
  final void Function(Object error, StackTrace? stackTrace)? onError;
}
