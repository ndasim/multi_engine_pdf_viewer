import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:multi_engine_pdf_viewer/src/data/pdfjs/pdfjs_bundle.dart';

/// How a [PdfJsTierResolution] arrived at its bundle.
///
/// Operations needs this to answer "how many devices landed on `legacy`, and
/// did they get there because we detected it or because the newer build
/// crashed?" without a debug build, so it is reported on every open.
enum PdfJsTierSource {
  /// `PdfJsBundleSelector.debugBundleOverride` was set. Never in production.
  override('override'),

  /// The per-device cache answered, and the WebView's capability signature
  /// still matches the one that was cached.
  cache('cache'),

  /// `bootstrap.js` feature-detected the engine before importing any module.
  probe('probe'),

  /// A newer bundle was tried and reported `ViewerScriptError` /
  /// `ViewerLoadTimeout`, so the chain stepped down.
  downgrade('downgrade'),

  /// The iOS version table in [PdfJsBundleSelector]. Only the seed used for
  /// the very first request of a cold, uncached device, before the probe has
  /// answered.
  versionTable('version_table');

  const PdfJsTierSource(this.id);

  /// Stable, snake_case, safe as an analytics parameter value.
  final String id;
}

/// The bundle a viewer instance resolved to, and how.
@immutable
class PdfJsTierResolution {
  const PdfJsTierResolution({
    required this.bundle,
    required this.source,
    this.attempt = 0,
    this.capabilities,
    this.probeSupported,
    this.failure,
    this.canvasHwa,
  });

  /// The bundle in use. `null` means no vendored bundle can run here, which
  /// `bootstrap.js` reports as `EngineUnsupported`.
  final PdfJsBundle? bundle;

  final PdfJsTierSource source;

  /// 0 for the first load of this viewer, 1 for the first downgrade, and so on.
  final int attempt;

  /// Opaque capability signature from `bootstrap.js`, e.g. `m1.l1.c1.g0.d0`.
  /// Feature flags only: no user, document, token or device identifier.
  final String? capabilities;

  /// The best bundle the probe believes the engine supports, which can differ
  /// from [bundle] when a pinned tier is in use.
  final PdfJsBundle? probeSupported;

  /// For [PdfJsTierSource.downgrade], the failure that forced the step down,
  /// already passed through `PdfJsLocalServer.redact`. Carried here rather
  /// than reported through `onError` on purpose: a downgrade that then works
  /// is not a load failure, and callers treat a pre-ready `onError` as fatal.
  final String? failure;

  /// Canvas backing store this load asked PDF.js for: `on`, `off` or
  /// `default`.
  ///
  /// Deliberately a sibling of [capabilities] rather than a field inside it.
  /// The capability signature is also the tier cache's validity stamp — a
  /// signature that differs from the cached one means "the engine changed,
  /// discard the entry" — so folding a Dart-side configuration value into it
  /// would make flipping this flag silently invalidate every device's cached
  /// tier and re-run the downgrade chain. As its own parameter it costs one
  /// analytics key.
  ///
  /// `default` covers both "not configured" and [PdfJsBundle.legacy], which
  /// has no such option; see
  /// [PdfJsBundle.supportsHardwareAcceleratedCanvas]. Without this a
  /// performance regression in the field cannot be attributed, because a tier
  /// event alone does not say whether that device rendered on a software or a
  /// hardware canvas.
  final String? canvasHwa;

  /// Analytics parameters. Nothing here is user- or document-derived.
  Map<String, Object> toAnalyticsParameters() => <String, Object>{
    'tier': bundle?.id ?? 'none',
    'tier_source': source.id,
    'tier_attempt': attempt,
    'webview_capabilities': ?capabilities,
    'tier_probe_supported': ?probeSupported?.id,
    'tier_failure': ?failure,
    'canvas_hwa': ?canvasHwa,
  };

  @override
  String toString() =>
      'PdfJsTierResolution(${bundle?.id ?? 'none'}, ${source.id}, attempt $attempt, '
      'capabilities ${capabilities ?? '-'}, hwa ${canvasHwa ?? '-'})';
}

/// Durable store behind the per-device tier cache.
///
/// The package deliberately has no persistence dependency, so the app supplies
/// one (e.g. over `SharedPreferences`). Without one the viewer falls back to
/// [PdfJsInMemoryTierStore], which still stops a device paying the downgrade
/// cost on every open within a session but forgets across launches.
abstract interface class PdfJsTierStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Process-global fallback store. Survives viewer opens, not app launches.
class PdfJsInMemoryTierStore implements PdfJsTierStore {
  const PdfJsInMemoryTierStore();

  static final Map<String, String> _entries = <String, String>{};

  @visibleForTesting
  static void clear() => _entries.clear();

  @override
  Future<String?> read(String key) async => _entries[key];

  @override
  Future<void> write(String key, String value) async => _entries[key] = value;

  @override
  Future<void> delete(String key) async => _entries.remove(key);
}

/// Reads and writes the per-device tier cache.
///
/// The cache exists so a device that fails once does not pay the failure cost
/// on every open. Two invalidation axes, because a cache that pins a device to
/// `legacy` forever after one bad boot is its own bug:
///
/// * **App version and OS version are part of the key.** A new app build may
///   ship different bundles, and an OS upgrade may bring a new WebKit, so
///   neither can reuse an old answer.
/// * **The WebView's capability signature is part of the value.** Android's
///   System WebView updates without any OS version change, so the key cannot
///   see it. `bootstrap.js` reports the signature on every load, including
///   loads that used a pinned tier; a signature that differs from the cached
///   one means the engine changed and the entry is discarded rather than
///   trusted.
class PdfJsTierCache {
  PdfJsTierCache({
    required PdfJsTierStore store,
    String appVersion = '',
    String? operatingSystemVersion,
  }) : _store = store,
       _key = _buildKey(
         appVersion,
         operatingSystemVersion ?? _defaultOperatingSystemVersion(),
       );

  static const String _keyPrefix = 'multi_engine_pdf_viewer.tier.v1';

  final PdfJsTierStore _store;
  final String _key;

  @visibleForTesting
  String get key => _key;

  static String _defaultOperatingSystemVersion() =>
      '${Platform.operatingSystem}/${Platform.operatingSystemVersion}';

  static String _buildKey(String appVersion, String osVersion) =>
      '$_keyPrefix|$appVersion|$osVersion';

  /// The cached bundle, or `null` when there is no usable entry.
  Future<({PdfJsBundle bundle, String capabilities})?> read() async {
    final String? raw;
    try {
      raw = await _store.read(_key);
    } catch (_) {
      // A broken store must never stop a document from opening.
      return null;
    }
    if (raw == null) return null;
    final separator = raw.indexOf('|');
    if (separator <= 0) return null;
    final bundle = PdfJsBundle.tryParse(raw.substring(0, separator));
    if (bundle == null) return null;
    return (bundle: bundle, capabilities: raw.substring(separator + 1));
  }

  Future<void> write(PdfJsBundle bundle, String capabilities) async {
    try {
      await _store.write(_key, '${bundle.id}|$capabilities');
    } catch (_) {}
  }

  Future<void> clear() async {
    try {
      await _store.delete(_key);
    } catch (_) {}
  }
}
