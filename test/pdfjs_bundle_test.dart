import 'package:flutter_test/flutter_test.dart';
import 'package:multi_engine_pdf_viewer/src/data/pdfjs/pdfjs_bundle.dart';

void main() {
  group('enableHWA support per bundle', () {
    test('only the PDF.js 6 builds implement the option', () {
      expect(PdfJsBundle.legacy.supportsHardwareAcceleratedCanvas, isFalse);
      expect(PdfJsBundle.compat.supportsHardwareAcceleratedCanvas, isTrue);
      expect(PdfJsBundle.current.supportsHardwareAcceleratedCanvas, isTrue);
    });
  });

  group('PdfJsBundleSelector', () {
    tearDown(() => PdfJsBundleSelector.debugBundleOverride = null);

    test('selects the legacy build below iOS 16.4, where compat fails to parse', () {
      expect(
        PdfJsBundleSelector.select(
          isIos: true,
          operatingSystemVersion: 'Version 15.8.4 (Build 19H370)',
        ),
        PdfJsBundle.legacy,
      );
      expect(
        PdfJsBundleSelector.select(isIos: true, operatingSystemVersion: 'iOS 16.3'),
        PdfJsBundle.legacy,
      );
    });

    test('selects the compat build from iOS 16.4 up to iOS 26', () {
      for (final version in ['Version 16.4 (Build 20E247)', 'iPhone OS 18.1', 'iOS 25.9']) {
        expect(
          PdfJsBundleSelector.select(isIos: true, operatingSystemVersion: version),
          PdfJsBundle.compat,
          reason: version,
        );
      }
    });

    test('selects the current build from iOS 26, which has getOrInsertComputed', () {
      for (final version in ['iOS 26.0', 'Version 26.4 (Build 23E254a)', 'iPhone OS 27.1']) {
        expect(
          PdfJsBundleSelector.select(isIos: true, operatingSystemVersion: version),
          PdfJsBundle.current,
          reason: version,
        );
      }
    });

    test('uses the legacy build when the iOS version cannot be identified', () {
      expect(
        PdfJsBundleSelector.select(
          isIos: true,
          operatingSystemVersion: 'Darwin Kernel Version 23.0.0',
        ),
        PdfJsBundle.legacy,
      );
    });

    test('selects the compat build on Android, whose WebView version is unknown here', () {
      for (final version in ['Android 10', 'Android 15']) {
        expect(
          PdfJsBundleSelector.select(isIos: false, operatingSystemVersion: version),
          PdfJsBundle.compat,
          reason: version,
        );
      }
    });

    test('debugBundleOverride wins over the platform answer', () {
      PdfJsBundleSelector.debugBundleOverride = PdfJsBundle.legacy;
      expect(
        PdfJsBundleSelector.select(isIos: false, operatingSystemVersion: 'Android 10'),
        PdfJsBundle.legacy,
      );

      PdfJsBundleSelector.debugBundleOverride = PdfJsBundle.current;
      expect(
        PdfJsBundleSelector.select(isIos: true, operatingSystemVersion: 'iOS 15.8'),
        PdfJsBundle.current,
      );
    });

    test('clearing debugBundleOverride restores the platform answer', () {
      PdfJsBundleSelector.debugBundleOverride = PdfJsBundle.legacy;
      PdfJsBundleSelector.debugBundleOverride = null;
      expect(
        PdfJsBundleSelector.select(isIos: false, operatingSystemVersion: 'Android 10'),
        PdfJsBundle.compat,
      );
    });
  });
}
