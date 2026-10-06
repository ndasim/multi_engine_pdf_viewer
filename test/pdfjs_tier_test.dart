import 'package:flutter_test/flutter_test.dart';
import 'package:multi_engine_pdf_viewer/src/data/pdfjs/pdfjs_bundle.dart';
import 'package:multi_engine_pdf_viewer/src/data/pdfjs/pdfjs_bridge_message.dart';
import 'package:multi_engine_pdf_viewer/src/data/pdfjs/pdfjs_tier.dart';

class _RecordingStore implements PdfJsTierStore {
  final Map<String, String> entries = <String, String>{};
  final List<String> reads = <String>[];
  bool throwOnEverything = false;

  @override
  Future<String?> read(String key) async {
    if (throwOnEverything) throw StateError('store is broken');
    reads.add(key);
    return entries[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (throwOnEverything) throw StateError('store is broken');
    entries[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (throwOnEverything) throw StateError('store is broken');
    entries.remove(key);
  }
}

void main() {
  group('PdfJsBundle', () {
    test('downgrades current -> compat -> legacy -> error state', () {
      expect(PdfJsBundle.current.downgrade, PdfJsBundle.compat);
      expect(PdfJsBundle.compat.downgrade, PdfJsBundle.legacy);
      expect(
        PdfJsBundle.legacy.downgrade,
        isNull,
        reason: 'below legacy is the error state, not a fourth bundle',
      );
    });

    test('ids are stable and parse round-trip', () {
      expect(PdfJsBundle.values.map((b) => b.id), ['legacy', 'compat', 'current']);
      for (final bundle in PdfJsBundle.values) {
        expect(PdfJsBundle.tryParse(bundle.id), bundle);
      }
    });

    test('tryParse rejects anything else, so URLs and caches are safe inputs', () {
      for (final value in [null, '', 'LEGACY', 'legacy ', 'pdfjs/legacy', '../legacy', '0']) {
        expect(PdfJsBundle.tryParse(value), isNull, reason: '$value');
      }
    });
  });

  group('PdfJsTierCache', () {
    test('key is scoped by app version and OS version', () {
      String keyFor(String app, String os) =>
          PdfJsTierCache(store: _RecordingStore(), appVersion: app, operatingSystemVersion: os).key;

      final base = keyFor('2.1.9', 'android/9');
      expect(keyFor('2.2.0', 'android/9'), isNot(base), reason: 'app version invalidates');
      expect(keyFor('2.1.9', 'android/14'), isNot(base), reason: 'OS version invalidates');
      expect(keyFor('2.1.9', 'android/9'), base);
    });

    test('round-trips a bundle and its capability signature', () async {
      final store = _RecordingStore();
      final cache = PdfJsTierCache(
        store: store,
        appVersion: '2.1.9',
        operatingSystemVersion: 'android/9',
      );

      expect(await cache.read(), isNull);
      await cache.write(PdfJsBundle.legacy, 'm1.l1.c0.g0.d0');

      final entry = await cache.read();
      expect(entry?.bundle, PdfJsBundle.legacy);
      expect(entry?.capabilities, 'm1.l1.c0.g0.d0');

      await cache.clear();
      expect(await cache.read(), isNull);
    });

    test('a corrupt entry reads as a miss rather than pinning a bogus bundle', () async {
      final store = _RecordingStore();
      final cache = PdfJsTierCache(store: store, operatingSystemVersion: 'ios/18.6');
      for (final raw in ['', 'legacy', '|m1', 'nope|m1', '|', 'pdfjs/legacy|m1']) {
        store.entries[cache.key] = raw;
        expect(await cache.read(), isNull, reason: raw);
      }
    });

    test('a broken store never stops a document opening', () async {
      final store = _RecordingStore()..throwOnEverything = true;
      final cache = PdfJsTierCache(store: store, operatingSystemVersion: 'ios/18.6');
      expect(await cache.read(), isNull);
      await cache.write(PdfJsBundle.compat, 'm1');
      await cache.clear();
    });
  });

  group('PdfJsInMemoryTierStore', () {
    tearDown(PdfJsInMemoryTierStore.clear);

    test('is process-global, so it survives viewer instances in one session', () async {
      await const PdfJsInMemoryTierStore().write('k', 'v');
      expect(await const PdfJsInMemoryTierStore().read('k'), 'v');
    });
  });

  group('PdfJsTierResolution telemetry', () {
    test('carries the tier, how it was reached and the engine signature', () {
      final resolution = PdfJsTierResolution(
        bundle: PdfJsBundle.legacy,
        source: PdfJsTierSource.downgrade,
        attempt: 2,
        capabilities: 'm1.l1.c1.g0.d0',
        probeSupported: PdfJsBundle.compat,
        failure: 'ViewerLoadTimeout: viewer.mjs did not initialise',
      );

      expect(resolution.toAnalyticsParameters(), {
        'tier': 'legacy',
        'tier_source': 'downgrade',
        'tier_attempt': 2,
        'webview_capabilities': 'm1.l1.c1.g0.d0',
        'tier_probe_supported': 'compat',
        'tier_failure': 'ViewerLoadTimeout: viewer.mjs did not initialise',
      });
    });

    test('an engine no bundle can run reports as "none", not as a missing event', () {
      const resolution = PdfJsTierResolution(
        bundle: null,
        source: PdfJsTierSource.probe,
        capabilities: 'm1.l0.c0.g0.d0',
      );
      final parameters = resolution.toAnalyticsParameters();
      expect(parameters['tier'], 'none');
      expect(parameters['tier_source'], 'probe');
      expect(parameters.containsKey('tier_probe_supported'), isFalse);
      expect(parameters.containsKey('tier_failure'), isFalse);
    });

    test('source ids are snake_case and stable', () {
      expect(PdfJsTierSource.values.map((s) => s.id), [
        'override',
        'cache',
        'probe',
        'downgrade',
        'version_table',
      ]);
    });
  });

  group('canvas backing store telemetry', () {
    test('reports the canvas flag alongside the tier, not inside its signature', () {
      const resolution = PdfJsTierResolution(
        bundle: PdfJsBundle.current,
        source: PdfJsTierSource.probe,
        capabilities: 'm1.l1.c1.g1.d1',
        canvasHwa: 'on',
      );

      final parameters = resolution.toAnalyticsParameters();
      expect(parameters['canvas_hwa'], 'on');
      expect(
        parameters['webview_capabilities'],
        'm1.l1.c1.g1.d1',
        reason: 'the signature is also the tier cache validity stamp: folding a '
            'Dart-side config value into it would invalidate every cached tier '
            'the moment the flag is flipped',
      );
    });

    test('is absent when nothing configured it, so old events stay comparable', () {
      const resolution = PdfJsTierResolution(
        bundle: PdfJsBundle.legacy,
        source: PdfJsTierSource.cache,
      );
      expect(resolution.toAnalyticsParameters().containsKey('canvas_hwa'), isFalse);
    });
  });

  group('what makes the chain suspect the bundle', () {
    // Measured on iOS 18.6 (simulator 62A7E9F1), forced `current`: the module
    // parses, the bridge comes up, and PDF.js then throws
    // `UnknownErrorException: this._requestsByChunk.getOrInsertComputed is not
    // a function` while opening the document. bootstrap.js cannot report that
    // — `pdfjsBridge` already exists, so its own guard correctly declines —
    // so if the chain only trusted bootstrap's two shapes it would show a dead
    // viewer with a working bundle one rung below. It did exactly that until
    // this rule existed. Do not narrow it back to `isRetryableBundleFailure`.
    PdfJsErrorMessage error(String name) => PdfJsErrorMessage(name: name, message: 'x');

    test('diagnostics never include document-controlled names or parser messages', () {
      const canary = 'PRIVATE-DOCUMENT-CANARY';
      const parserError = PdfJsErrorMessage(
        name: 'UnknownErrorException',
        message: 'Bad filter name "$canary"',
      );
      const unknownError = PdfJsErrorMessage(name: canary, message: canary);
      expect(parserError.diagnosticCode, 'document-load-error');
      expect(unknownError.diagnosticCode, 'viewer-error');
      expect(parserError.diagnosticCode, isNot(contains(canary)));
    });

    test('bootstrap failure shapes are always suspect', () {
      for (final name in [
        PdfJsErrorMessage.scriptErrorName,
        PdfJsErrorMessage.loadTimeoutName,
      ]) {
        expect(
          error(name).isBundleSuspect(isViewerReady: false),
          isTrue,
          reason: name,
        );
      }
    });

    test('a PDF.js error before ready is suspect — the iOS 18.6 current case', () {
      expect(
        error('UnknownErrorException').isBundleSuspect(isViewerReady: false),
        isTrue,
      );
    });

    test('the same error after ready is the document, not the bundle', () {
      // The bundle has demonstrably worked, so no reload: reloading here would
      // turn one bad page into an endless loop of downgrades.
      for (final name in ['UnknownErrorException', 'InvalidPDFException', 'BridgeError']) {
        expect(
          error(name).isBundleSuspect(isViewerReady: true),
          isFalse,
          reason: name,
        );
      }
    });

    test('EngineUnsupported is never suspect, even before ready', () {
      expect(
        error(PdfJsErrorMessage.engineUnsupportedName).isBundleSuspect(isViewerReady: false),
        isFalse,
      );
    });
  });
}
