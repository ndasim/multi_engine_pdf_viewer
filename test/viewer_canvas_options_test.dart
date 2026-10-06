import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:multi_engine_pdf_viewer/src/data/pdfjs/pdfjs_bundle.dart';

/// Resolves a shipped asset directory whatever working directory the suite was
/// started from.
///
/// Same resolver shape as `viewer_asset_syntax_test.dart`: `flutter test`
/// inside the package runs with the package as the working directory while
/// `flutter test package/multi_engine_pdf_viewer/test` from the repo root runs
/// with the root, and a bare relative path silently fails in one of the two.
Directory _asset(String relative) {
  final candidates = [relative, 'package/multi_engine_pdf_viewer/$relative'];
  for (final candidate in candidates) {
    final directory = Directory(candidate);
    if (directory.existsSync()) return directory;
  }
  throw StateError(
    'cannot find $relative from ${Directory.current.path}; tried ${candidates.join(', ')}',
  );
}

/// Holds the facts the `enableHWA` A/B rests on.
///
/// The flag is applied per tier because the option simply does not exist in the
/// pinned 4.1.392 build. That is a property of the vendored bytes, not of a
/// changelog, so it is asserted against the vendored bytes: if a future
/// re-vendor changes it, the per-tier gate in `pdfjs_viewer.dart` is wrong and
/// this suite says so before a device run does.
void main() {
  final pdfjs = _asset('assets/pdfjs');
  final viewer = _asset('assets/viewer');

  File bundleFile(PdfJsBundle bundle, String relative) =>
      File('${pdfjs.path}/${bundle.id}/$relative');

  group('vendored builds', () {
    test('enableHWA and willReadFrequently exist only in the PDF.js 6 builds', () {
      for (final bundle in PdfJsBundle.values) {
        final source = bundleFile(bundle, 'build/pdf.min.mjs').readAsStringSync();
        final mentionsHwa = source.contains('enableHWA');
        final mentionsWillReadFrequently = source.contains('willReadFrequently');
        expect(
          mentionsHwa,
          bundle.supportsHardwareAcceleratedCanvas,
          reason: '${bundle.id}: supportsHardwareAcceleratedCanvas must describe the '
              'bytes actually shipped, because it is what decides whether the '
              'option is sent to this tier at all',
        );
        expect(
          mentionsWillReadFrequently,
          bundle.supportsHardwareAcceleratedCanvas,
          reason: '${bundle.id}: enableHWA is only interesting because it decides '
              'willReadFrequently on every page canvas',
        );
      }
    });

    test('the PDF.js 6 builds derive willReadFrequently from enableHWA', () {
      for (final bundle in PdfJsBundle.values.where(
        (bundle) => bundle.supportsHardwareAcceleratedCanvas,
      )) {
        expect(
          bundleFile(bundle, 'build/pdf.min.mjs').readAsStringSync(),
          contains('willReadFrequently:!this._enableHWA'),
          reason: '${bundle.id}: the page render context is the one that matters, and '
              'an unset enableHWA is what pins it to a software backing store',
        );
      }
    });

    test('the pinned 4.1.392 build never asks for a software backing store', () {
      final source = bundleFile(PdfJsBundle.legacy, 'build/pdf.min.mjs').readAsStringSync();
      // Ten `getContext("2d")` call sites, of which exactly one passes options
      // at all (`{alpha:!1}`, on the hidden text-measuring canvas) and none
      // passes `willReadFrequently`. So on `legacy` the browser's own canvas
      // heuristic decides, which is why there is nothing to A/B on this tier
      // and why the flag is applied per tier.
      final withOptions = RegExp(r'getContext\("2d",\s*\{([^}]*)\}').allMatches(source);
      for (final match in withOptions) {
        expect(
          match.group(1),
          isNot(contains('willReadFrequently')),
          reason: 'legacy must keep leaving the backing store to the browser',
        );
      }
      expect(
        source,
        contains('getContext("2d")'),
        reason: 'the page render target is created with no options at all',
      );
    });
  });

  group('viewer.mjs', () {
    late String source;

    setUp(() {
      source = File('${viewer.path}/viewer.mjs').readAsStringSync();
    });

    test('only sets enableHWA when the config carries a real boolean', () {
      expect(source, contains('typeof config.enableHwa === "boolean"'));
      expect(source, contains('documentOptions.enableHWA = config.enableHwa;'));
    });

    test('keeps the CVE-2024-4367 mitigation and XFA off in the same options', () {
      expect(source, contains('isEvalSupported: false'));
      expect(source, contains('enableXfa: false'));
      expect(
        source,
        contains('pdfjsLib.getDocument(documentOptions)'),
        reason: 'one options object: a second getDocument call site could carry a '
            'different isEvalSupported',
      );
      expect(
        RegExp('getDocument\\(').allMatches(source).length,
        1,
        reason: 'exactly one getDocument call site',
      );
    });

    test('does not touch maxCanvasPixels, which is a separate variable', () {
      expect(source, contains('maxCanvasPixels: largeDocument'));
      expect(source, contains('config.largeDocumentMaxCanvasPixels'));
    });
  });
}
