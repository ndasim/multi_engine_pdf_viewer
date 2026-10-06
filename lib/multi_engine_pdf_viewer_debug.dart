/// Profiling-only overrides. Do not use these in production UI.
library;

import 'src/data/pdfjs/pdfjs_bundle.dart';
import 'src/data/pdfjs/pdfjs_viewer_params.dart';
import 'src/domain/entity/pdf_viewer_state.dart';
import 'src/presentation/engines/embedpdf_engine_view.dart';
import 'src/presentation/pdf_viewer_params.dart';

/// PDF.js bundle tier used by profiling overrides.
typedef PdfViewerDebugBundle = PdfJsBundle;

/// Profiling hooks. Do not call these from production UI.
class PdfViewerDebug {
  PdfViewerDebug._();

  /// Forces the next PDF.js bundle selection.
  static set debugBundleOverride(PdfViewerDebugBundle? value) =>
      PdfJsBundleSelector.debugBundleOverride = value;

  /// Returns the PDF.js bundle the selector would use now.
  static PdfViewerDebugBundle select() => PdfJsBundleSelector.select();

  /// Forces hardware-accelerated canvas on or off for PDF.js.
  static set debugEnableHwaOverride(bool? value) =>
      PdfJsViewerParams.debugEnableHwaOverride = value;

  /// Forces the engine used by the next viewer, ignoring [PdfViewerParams.engine].
  static set debugEngineOverride(PdfViewerEngine? value) =>
      PdfViewerParams.debugEngineOverride = value;

  /// Injects a fatal EmbedPDF failure so the viewer can fall back to PDF.js.
  static Future<void> injectEmbedPdfFatal() =>
      EmbedPdfEngineView.debugInjectFatal?.call() ?? Future<void>.value();

  /// Terminates the EmbedPDF worker so the watchdog can fall back to PDF.js.
  static Future<void> terminateEmbedPdfWorker() =>
      EmbedPdfEngineView.debugTerminateWorker?.call() ?? Future<void>.value();
}
