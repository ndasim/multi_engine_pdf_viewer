import 'package:flutter/widgets.dart';

import '../domain/entity/pdf_viewer_state.dart';
import '../domain/repo/pdf_engine_session.dart';
import 'pdf_viewer_controller.dart';

/// Presentation options and host-owned event handlers. No application UI is bundled.
class PdfViewerParams {
  static PdfViewerEngine? debugEngineOverride;

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

  final PdfViewerEngine engine;
  final PdfViewerLayout layout;
  final double margin;
  final Color backgroundColor;
  final Color pageShadowColor;
  final Color matchColor;
  final Color activeMatchColor;
  final int maxCanvasPixels;
  final int largeDocumentPageCount;
  final int largeDocumentMaxCanvasPixels;
  final String appVersion;
  final PdfViewerCacheStore? cacheStore;
  final bool? enableHardwareAcceleratedCanvas;

  /// Native font substitutions are process-global and never automatically removed.
  /// Only used by pdfrx. PDF.js uses the bundled standard fonts.
  final List<PdfFontRegistration> fonts;
  final WidgetBuilder? loadingBuilder;
  final Widget Function(BuildContext context, Object error)? errorBuilder;
  final ValueChanged<PdfViewerController>? onViewerReady;
  final ValueChanged<int>? onFirstPageRendered;
  final ValueChanged<int>? onPageChanged;
  final ValueChanged<int>? onPageTap;
  final ValueChanged<PdfViewerLayout>? onLayoutChanged;
  final ValueChanged<Uri>? onExternalLinkTap;
  final ValueChanged<PdfViewerDiagnostic>? onDiagnostic;
  final void Function(Object error, StackTrace? stackTrace)? onError;
}
