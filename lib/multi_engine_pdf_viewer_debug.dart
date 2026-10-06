/// Profiling-only overrides. Do not use these in production UI.
library;

import 'src/data/pdfjs/pdfjs_bundle.dart';
import 'src/data/pdfjs/pdfjs_viewer_params.dart';
import 'src/domain/entity/pdf_viewer_state.dart';
import 'src/presentation/engines/embedpdf_engine_view.dart';
import 'src/presentation/pdf_viewer_params.dart';

typedef PdfViewerDebugBundle = PdfJsBundle;

class PdfViewerDebug {
  PdfViewerDebug._();

  static set debugBundleOverride(PdfViewerDebugBundle? value) =>
      PdfJsBundleSelector.debugBundleOverride = value;
  static PdfViewerDebugBundle select() => PdfJsBundleSelector.select();
  static set debugEnableHwaOverride(bool? value) => PdfJsViewerParams.debugEnableHwaOverride = value;
  static set debugEngineOverride(PdfViewerEngine? value) =>
      PdfViewerParams.debugEngineOverride = value;
  static Future<void> injectEmbedPdfFatal() =>
      EmbedPdfEngineView.debugInjectFatal?.call() ?? Future<void>.value();
  static Future<void> terminateEmbedPdfWorker() =>
      EmbedPdfEngineView.debugTerminateWorker?.call() ?? Future<void>.value();
}