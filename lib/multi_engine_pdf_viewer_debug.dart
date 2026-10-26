/// Profiling-only overrides. Do not use these in production UI.
library;

import 'src/data/pdfjs/pdfjs_bundle.dart';
import 'src/data/pdfjs/pdfjs_viewer_params.dart';
import 'src/domain/entity/pdf_viewer_state.dart';
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

}
