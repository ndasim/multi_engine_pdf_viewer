import 'package:flutter/widgets.dart';

import 'package:multi_engine_pdf_viewer/src/data/pdfjs/pdfjs_bundle.dart';
import 'package:multi_engine_pdf_viewer/src/data/pdfjs/pdfjs_tier.dart';
import 'package:multi_engine_pdf_viewer/src/data/pdfjs/pdfjs_viewer.dart';

/// Page arrangement of the viewer.
@immutable
class PdfJsLayout {
  /// Pages in `columns` per row, scaled so a full row fits the width.
  const PdfJsLayout.grid({this.columns = 3})
    : assert(columns > 1, 'Grid layout must have more than one column');

  const PdfJsLayout._vertical() : columns = 1;

  /// One page per row, scaled to fit the width.
  static const PdfJsLayout vertical = PdfJsLayout._vertical();

  final int columns;

  bool get isGrid => columns > 1;

  @override
  bool operator ==(Object other) => other is PdfJsLayout && other.columns == columns;

  @override
  int get hashCode => columns.hashCode;
}

@immutable
class PdfJsViewerParams {
  const PdfJsViewerParams({
    this.layout = PdfJsLayout.vertical,
    this.margin = 8,
    this.backgroundColor = const Color(0xFF9E9E9E),
    this.pageShadowColor = const Color(0x8A000000),
    this.matchColor = const Color(0x80FFEB3B),
    this.activeMatchColor = const Color(0x80FF9800),
    this.maxCanvasPixels = 5242880,
    this.largeDocumentPageCount = 100,
    this.largeDocumentMaxCanvasPixels = 4194304,
    this.loadingBuilder,
    this.onViewerReady,
    this.onFirstPageRendered,
    this.onPageChanged,
    this.onPageTap,
    this.onExternalLinkTap,
    this.onError,
    this.onTierResolved,
    this.tierStore = const PdfJsInMemoryTierStore(),
    this.appVersion = '',
    this.enableHardwareAcceleratedCanvas,
  });

  final PdfJsLayout layout;

  /// Gap around pages, in logical pixels.
  final double margin;
  final Color backgroundColor;
  final Color pageShadowColor;
  final Color matchColor;
  final Color activeMatchColor;

  /// Canvas size cap per page. Above it PDF.js zooms with CSS instead of
  /// re-rendering, which bounds WebView memory.
  final int maxCanvasPixels;
  final int largeDocumentPageCount;
  final int largeDocumentMaxCanvasPixels;

  /// Shown until page layout is ready, then per-page spinners indicate rendering.
  /// Defaults to a centered adaptive spinner.
  final WidgetBuilder? loadingBuilder;
  final void Function(PdfJsViewerController controller)? onViewerReady;

  /// Called once PDF.js has painted the initially visible page.
  final ValueChanged<int>? onFirstPageRendered;
  final ValueChanged<int>? onPageChanged;

  /// Called with the tapped page number in [PdfJsLayout.grid] layouts.
  final ValueChanged<int>? onPageTap;

  /// Called for `http`, `https`, `mailto` and `tel` links. Other schemes are dropped.
  final ValueChanged<Uri>? onExternalLinkTap;
  final void Function(Object error, StackTrace? stackTrace)? onError;

  /// Called every time the viewer settles on a PDF.js build, including each
  /// rung of the downgrade chain, with how it got there.
  ///
  /// This is the observability requirement: without it nobody in operations
  /// can answer "how many devices landed on `legacy`?" without a debug build.
  /// Send it to analytics; [PdfJsTierResolution.toAnalyticsParameters] is
  /// already free of user, document and path-token data.
  final void Function(PdfJsTierResolution resolution)? onTierResolved;

  /// Durable store behind the per-device tier cache.
  ///
  /// Defaults to [PdfJsInMemoryTierStore], which stops a device paying the
  /// downgrade cost on every open within one app session but forgets across
  /// launches. Pass a `SharedPreferences`-backed store to make it survive.
  final PdfJsTierStore tierStore;

  /// App version, part of the tier cache key so a new build never reuses an
  /// answer measured against different vendored bundles.
  final String appVersion;

  /// PDF.js `enableHWA`: whether page canvases may use a hardware-accelerated
  /// backing store.
  ///
  /// `null` — the default — does not send the option at all, which is
  /// exactly today's behaviour and so changes nothing until it is measured.
  ///
  /// Only reaches [PdfJsBundle.compat] and [PdfJsBundle.current]; see
  /// [PdfJsBundle.supportsHardwareAcceleratedCanvas] for why, and for the
  /// occurrence counts that establish it. The asymmetry is the reason this
  /// flag exists: with the option unset PDF.js 6 defaults `enableHWA` to
  /// `false` and so asks for `willReadFrequently: true` on every page canvas,
  /// which forces a software backing store, while `legacy` 4.1.392 passes no
  /// options and leaves the browser's own heuristic alone. So the two newer
  /// tiers carry a rendering penalty the oldest one does not — the opposite
  /// direction from "newer bundle is faster".
  final bool? enableHardwareAcceleratedCanvas;

  /// Overrides [enableHardwareAcceleratedCanvas] for every viewer in the
  /// process. `null` means no override.
  ///
  /// Exists for the same reason as [PdfJsBundleSelector.debugBundleOverride]:
  /// the A/B has to be switchable on a device that is already built and
  /// installed, and the params are constructed deep inside the app's own
  /// screen where a profiling harness cannot reach them. The device harness
  /// drives it from the host through its `harness_mode` file (`hwa:on` /
  /// `hwa:off`), which costs one build instead of two. Production leaves it
  /// `null`.
  static bool? debugEnableHwaOverride;

  /// The flag the viewer should actually send, override first.
  bool? get resolvedEnableHardwareAcceleratedCanvas =>
      debugEnableHwaOverride ?? enableHardwareAcceleratedCanvas;
}

/// An error whose text contained the local server's path token, reported with
/// the token replaced.
///
/// The original exception object is deliberately not forwarded: its
/// `toString()` is what carried the token. [type] keeps the original runtime
/// type name so crash reports still group usefully.
class PdfJsRedactedException implements Exception {
  const PdfJsRedactedException(this.type, this.message);

  final String type;
  final String message;

  @override
  String toString() => 'PdfJsRedactedException($type): $message';
}

/// Error reported by PDF.js inside the WebView, e.g. `InvalidPDFException`.
class PdfJsViewerException implements Exception {
  const PdfJsViewerException(this.name, this.message);

  final String name;
  final String message;

  @override
  String toString() => 'PdfJsViewerException($name): $message';
}
