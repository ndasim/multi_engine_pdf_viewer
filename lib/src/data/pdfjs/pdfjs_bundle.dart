import 'dart:io';

/// A vendored PDF.js build. See `assets/pdfjs/VERSION` for the exact versions.
///
/// Declared oldest-engine-first, so [index] is the downgrade order: the
/// self-healing chain walks `current` -> `compat` -> `legacy` by stepping
/// [index] down, and anything below `legacy` is the error state.
enum PdfJsBundle {
  /// PDF.js 4.1.392 (pinned), transpiled. The only build whose CSS avoids
  /// `light-dark()`, so the only one that styles correctly below Safari 17.5.
  ///
  /// Its *syntax* floor, measured by grepping the vendored build rather than
  /// read off a support matrix: optional chaining and nullish coalescing
  /// (Chrome 80 / Safari 13.1), logical assignment (Chrome 85 / Safari 14) and
  /// class private instance fields and methods (Chrome 84 / Safari 15). The
  /// runtime APIs it uses above that line (`Object.hasOwn`,
  /// `Array.prototype.at`, `structuredClone`) are core-js polyfilled inside
  /// the bundle, so they do not raise the floor. Net floor: **Chrome 85**.
  legacy('pdfjs/legacy', 'legacy'),

  /// Newest PDF.js, transpiled and polyfilled (`pdfjs-dist/legacy`). Its
  /// JavaScript runs on older engines than [current], but its CSS is
  /// byte-identical to [current] and needs Safari 17.5 / Chrome 123 to style
  /// correctly.
  ///
  /// Adds exactly one syntax feature over [legacy] — a class static block
  /// (Chrome 94 / Safari 16.4). Verified: `static{` appears once in both
  /// `compat` and `current` and never in `legacy`.
  compat('pdfjs/compat', 'compat'),

  /// Newest PDF.js, untranspiled. Byte-for-byte the same *syntax* level as
  /// [compat] (identical feature occurrence counts in the vendored builds);
  /// what separates it is the unpolyfilled runtime method
  /// `Map.prototype.getOrInsertComputed`, which WebKit only gained in iOS 26.
  /// That is a `typeof` check, not a parse problem, so it is feature-detected
  /// directly in `bootstrap.js` instead of by a probe module.
  current('pdfjs/current', 'current');

  const PdfJsBundle(this.assetDirectory, this.id);

  final String assetDirectory;

  /// Stable wire name. Appears in the server's `t/<id>/` path segment, in the
  /// `bootstrap.js` bridge messages, in the tier cache and in telemetry, so it
  /// must never change without a protocol bump.
  final String id;

  /// Whether this build implements the `enableHWA` document option, which
  /// decides the backing store of every page canvas.
  ///
  /// PDF.js 6 threads `getDocument`'s `enableHWA` down to each page's 2D
  /// context as `getContext("2d", {alpha: false, willReadFrequently:
  /// !enableHWA})`, and its own default is `false` — so leaving the option
  /// unset pins [compat] and [current] to a software backing store. Counted in
  /// the vendored builds rather than read off a changelog: `enableHWA` appears
  /// 13 times and `willReadFrequently` 8 times in both `compat` and `current`
  /// `build/pdf.min.mjs`, and **zero** times anywhere in `legacy`, which calls
  /// `getContext("2d")` with no options at all.
  ///
  /// 4.1.392 would ignore the unknown option harmlessly, but the viewer sends
  /// it only where it exists rather than relying on that — see `_sendOpen` in
  /// `pdfjs_viewer.dart` and the gate in `assets/viewer/viewer.mjs`.
  bool get supportsHardwareAcceleratedCanvas => this != PdfJsBundle.legacy;

  /// The next bundle down, or `null` when this is already the oldest.
  PdfJsBundle? get downgrade => index == 0 ? null : PdfJsBundle.values[index - 1];

  /// Parses [id]. Returns `null` for anything else, which is what makes it
  /// safe to call on a value that came out of a URL or a cache.
  static PdfJsBundle? tryParse(String? id) {
    for (final bundle in PdfJsBundle.values) {
      if (bundle.id == id) return bundle;
    }
    return null;
  }
}

/// Picks the newest PDF.js build the device WebView can actually run.
///
/// The thresholds below were measured on simulators, not read off a support
/// matrix, because the two builds of the newest PDF.js fail in different ways:
///
/// * [PdfJsBundle.current] uses `Map.prototype.getOrInsertComputed`, which
///   WebKit only gained in iOS 26. On iOS 18.6 it throws
///   `UnknownErrorException` mid-load.
/// * [PdfJsBundle.compat] is transpiled and polyfills that method, but still
///   ships class static blocks, which WebKit gained in 16.4. On iOS 16.2 the
///   module fails to parse with `SyntaxError: Unexpected token '{'`.
/// * [PdfJsBundle.legacy] (PDF.js 4.x) has neither, and is also the only build
///   whose CSS avoids `light-dark()`.
///
/// Android is not version-gated here. The WebView is updated independently of
/// the OS, so its version cannot be derived from [Platform.operatingSystemVersion].
///
/// **This table is no longer the decision.** It is the *seed* for the very
/// first HTTP request of a cold, uncached device; the engine is identified by
/// the capability probe in `assets/viewer/bootstrap.js`, which runs before any
/// module is imported and reports its answer over the bridge. The Android 9
/// run that settled it: stock System WebView 66.0.3359.158 (Chrome 66, 2018)
/// failed identically on all three bundles, and the blocker was not a version
/// but syntax — our own host page and bootstrap script. A version table could
/// not have found that; a feature probe describes the engine instead of
/// guessing from a number. See
/// `docs/implementation/evidence/android9_stock_webview.md`.
///
/// One deliberate omission: the probe also reports whether the engine supports
/// CSS `light-dark()`, which [PdfJsBundle.compat] and [PdfJsBundle.current]
/// need to *style* correctly (Chrome 123 / Safari 17.5), but that fact is not
/// used to choose the tier. Gating on it would move every iOS 16.4-17.4 and
/// Chrome 94-122 device from `compat` down to `legacy` — a behaviour change
/// with styling and performance consequences nobody has measured, and the
/// table shipping today does not gate on it either. It is reported in
/// telemetry so the decision can be made on data.
class PdfJsBundleSelector {
  const PdfJsBundleSelector._();

  /// First iOS whose WebKit parses class static blocks, which every build of
  /// the newest PDF.js contains.
  static const (int, int) _minimumIosForCompat = (16, 4);

  /// First iOS whose WebKit implements `Map.prototype.getOrInsertComputed`.
  static const (int, int) _minimumIosForCurrent = (26, 0);

  /// Forces [select] to return this build on every platform.
  ///
  /// Only for profiling and manual testing, where every build has to be
  /// exercised on whatever device is at hand. The selector's own answer is the
  /// one that matches the WebView's JavaScript support, so forcing a newer
  /// build onto an old WebView is expected to fail. Production code leaves
  /// this `null`.
  static PdfJsBundle? debugBundleOverride;

  static PdfJsBundle select({bool? isIos, String? operatingSystemVersion}) {
    final override = debugBundleOverride;
    if (override != null) return override;

    if (!(isIos ?? Platform.isIOS)) return PdfJsBundle.compat;

    final version = _parseIosVersion(operatingSystemVersion ?? Platform.operatingSystemVersion);
    // An unreadable version is treated as the oldest supported device.
    if (version == null) return PdfJsBundle.legacy;
    if (_isAtLeast(version, _minimumIosForCurrent)) return PdfJsBundle.current;
    if (_isAtLeast(version, _minimumIosForCompat)) return PdfJsBundle.compat;
    return PdfJsBundle.legacy;
  }

  static bool _isAtLeast((int, int) version, (int, int) minimum) {
    if (version.$1 != minimum.$1) return version.$1 > minimum.$1;
    return version.$2 >= minimum.$2;
  }

  static (int, int)? _parseIosVersion(String value) {
    final match = RegExp(
      r'(?:\b(?:ios|iphone os)\s+|^version\s+)(\d+)(?:\.(\d+))?',
      caseSensitive: false,
    ).firstMatch(value);
    if (match == null) return null;

    final major = int.tryParse(match.group(1)!);
    if (major == null) return null;
    return (major, int.tryParse(match.group(2) ?? '') ?? 0);
  }
}
