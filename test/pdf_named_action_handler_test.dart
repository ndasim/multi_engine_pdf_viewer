// Tests for PdfNamedActionHandler's "never crash the app" contract.
//
// `handleTap` reaches into PDFium through raw FFI (`pdfium_dart`) and builds
// a form-fill environment by hand. The fakes below exercise the handler
// exactly as pdfrx would — a real `PdfDocument`/`PdfPage`/`PdfViewerController`
// subclass tree — but replace `useNativeDocumentHandle` with one we control,
// so we can create the exact timing windows (dispose mid-tap, two taps
// racing) that are impossible to force deterministically against real PDFium
// IO. The actual FFI calls inside the handler (`FPDF_LoadPage`,
// `FPDFDOC_InitFormFillEnvironment`, ...) do run for real against whatever
// PDFium this host resolves (hook-built `libpdfium`, see `_loadPdfium`), but
// are invoked with a native document handle of address 0 — PDFium's public C
// API already
// treats an invalid/null document handle as "no-op, return null" by
// contract (pdfrx_engine itself relies on this: a disposed/invalid handle
// must not crash the renderer), and the handler already treats a null page
// (`nativePage.address == 0`) as "nothing to do". This lets the test prove
// the Dart-level fencing (`requestId`, `_tapInFlight`) without needing a real
// PDF file on disk.
import 'dart:async';
import 'dart:io' show Directory, File, Platform;
import 'dart:typed_data';

import 'package:multi_engine_pdf_viewer/src/data/pdfrx/pdf_named_action_handler.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfium_dart/pdfium_dart.dart' as pdfium;
import 'package:pdfrx/pdfrx.dart';

String? _findHookBuiltPdfium() {
  final shared = Directory('.dart_tool/hooks_runner/shared/pdfium_dart');
  if (!shared.existsSync()) return null;
  final name = switch (Platform.operatingSystem) {
    'macos' => 'libpdfium.dylib',
    'linux' => 'libpdfium.so',
    'windows' => 'pdfium.dll',
    _ => null,
  };
  if (name == null) return null;
  for (final entity in shared.listSync(recursive: true)) {
    if (entity is File && entity.path.split('/').last == name) return entity.path;
  }
  return null;
}

pdfium.PDFium _loadPdfium() => pdfium.getPdfium(modulePath: _findHookBuiltPdfium());

bool get _pdfiumLoadable {
  try {
    _loadPdfium();
    return true;
  } catch (_) {
    return false;
  }
}

class _FakePdfDocument extends PdfDocument {
  _FakePdfDocument({this.useNativeHandleImpl}) : super(sourceName: 'fake');

  /// Lets a test control exactly when/how the "native" callback runs,
  /// including throwing, delaying (to open a race window) or simulating a
  /// disposed native backing (address 0).
  final Future<T> Function<T>(FutureOr<T> Function(int) task)? useNativeHandleImpl;

  int useNativeDocumentHandleCallCount = 0;

  @override
  PdfPermissions? get permissions => null;

  @override
  bool get isEncrypted => false;

  @override
  Future<void> dispose() async {}

  @override
  Stream<PdfDocumentEvent> get events => const Stream.empty();

  @override
  List<PdfPage> get pages => const [];

  @override
  set pages(List<PdfPage> value) {}

  @override
  Future<List<PdfOutlineNode>> loadOutline() async => [];

  @override
  bool isIdenticalDocumentHandle(Object? other) => identical(this, other);

  @override
  Future<bool> assemble() async => false;

  @override
  Future<Uint8List> encodePdf({bool incremental = false, bool removeSecurity = false}) async =>
      Uint8List(0);

  @override
  Future<T> useNativeDocumentHandle<T>(FutureOr<T> Function(int nativeDocumentHandle) task) async {
    useNativeDocumentHandleCallCount++;
    final impl = useNativeHandleImpl;
    if (impl != null) return impl<T>(task);
    // Address 0: PDFium's public API is documented/relied-on to treat an
    // invalid document handle as a no-op rather than crash.
    return await task(0);
  }

  @override
  Future<void> reloadPages({List<int>? pageNumbersToReload}) async {}

  @override
  Future<void> loadPagesProgressively<T>({
    PdfPageLoadingCallback<T>? onPageLoadProgress,
    T? data,
    Duration loadUnitDuration = const Duration(milliseconds: 250),
  }) async {}
}

class _FakePdfPage extends PdfPage {
  _FakePdfPage(this.document);

  @override
  final PdfDocument document;
  @override
  int get pageNumber => 1;
  @override
  double get width => 1536;
  @override
  double get height => 1908;
  @override
  PdfPageRotation get rotation => PdfPageRotation.none;
  @override
  bool get isLoaded => true;

  @override
  Future<PdfImage?> render({
    int x = 0,
    int y = 0,
    int? width,
    int? height,
    double? fullWidth,
    double? fullHeight,
    int? backgroundColor,
    PdfPageRotation? rotationOverride,
    PdfAnnotationRenderingMode annotationRenderingMode =
        PdfAnnotationRenderingMode.annotationAndForms,
    int flags = 0,
    PdfPageRenderCancellationToken? cancellationToken,
  }) async => null;

  @override
  PdfPageRenderCancellationToken createCancellationToken() => throw UnimplementedError();

  @override
  Future<PdfPageRawText?> loadText() async => null;

  @override
  Future<List<PdfLink>> loadLinks({
    bool compact = false,
    bool enableAutoLinkDetection = true,
  }) async => [];
}

/// A `PdfViewerController` that never attaches to a real `PdfViewer` widget.
/// `isReady`/`pageNumber`/`pageCount`/`goToPage` all read private state that
/// requires attachment, so they are overridden here to behave as if a
/// document were loaded.
class _FakePdfViewerController extends PdfViewerController {
  _FakePdfViewerController({required int pageNumber, required int pageCount})
    : _pageNumber = pageNumber,
      _pageCount = pageCount;

  int _pageNumber;
  final int _pageCount;
  final List<int> goToPageCalls = [];

  @override
  bool get isReady => true;

  @override
  int? get pageNumber => _pageNumber;

  @override
  int get pageCount => _pageCount;

  @override
  Future<void> goToPage({
    required int pageNumber,
    PdfPageAnchor? anchor,
    Duration duration = const Duration(milliseconds: 200),
  }) async {
    goToPageCalls.add(pageNumber);
    _pageNumber = pageNumber;
  }
}

void main() {
  group('PdfNamedActionHandler.targetPageForNamedAction (pure)', () {
    test('NextPage advances by one, clamped to pageCount', () {
      expect(
        PdfNamedActionHandler.targetPageForNamedAction(
          'NextPage',
          currentPage: 5,
          pageCount: 10,
        ),
        6,
      );
      expect(
        PdfNamedActionHandler.targetPageForNamedAction(
          'NextPage',
          currentPage: 10,
          pageCount: 10,
        ),
        10,
      );
    });

    test('PrevPage goes back by one, clamped to 1', () {
      expect(
        PdfNamedActionHandler.targetPageForNamedAction(
          'PrevPage',
          currentPage: 5,
          pageCount: 10,
        ),
        4,
      );
      expect(
        PdfNamedActionHandler.targetPageForNamedAction('PrevPage', currentPage: 1, pageCount: 10),
        1,
      );
    });

    test('unsupported or missing actions return null', () {
      expect(
        PdfNamedActionHandler.targetPageForNamedAction(null, currentPage: 1, pageCount: 10),
        isNull,
      );
      expect(
        PdfNamedActionHandler.targetPageForNamedAction('', currentPage: 1, pageCount: 10),
        isNull,
      );
      expect(
        PdfNamedActionHandler.targetPageForNamedAction(
          'FirstPage',
          currentPage: 1,
          pageCount: 10,
        ),
        isNull,
      );
      expect(
        PdfNamedActionHandler.targetPageForNamedAction(
          'JavaScript',
          currentPage: 1,
          pageCount: 10,
        ),
        isNull,
      );
    });
  });

  group('PdfNamedActionHandler.handleTap safety', () {
    late PdfNamedActionHandler handler;
    final pdfiumLoadable = _pdfiumLoadable;
    final noPdfium = pdfiumLoadable
        ? false
        : 'PDFium could not be loaded on this host; run `flutter pub get` first';

    setUp(() {
      handler = PdfNamedActionHandler(pdfiumLoader: _loadPdfium);
    });

    tearDown(() {
      handler.dispose();
    });

    test('null document never reaches FFI and returns false', () async {
      final controller = _FakePdfViewerController(pageNumber: 1, pageCount: 10);
      final result = await handler.handleTap(
        document: null,
        page: _FakePdfPage(_FakePdfDocument()),
        pageRect: const Rect.fromLTWH(0, 0, 100, 100),
        pagePosition: const Offset(10, 10),
        controller: controller,
      );
      expect(result, isFalse);
      expect(controller.goToPageCalls, isEmpty);
    });

    test('controller not ready never reaches FFI and returns false', () async {
      // A real, unattached PdfViewerController: isReady is false because it
      // was never attached to a PdfViewer widget.
      final controller = PdfViewerController();
      final document = _FakePdfDocument();
      final result = await handler.handleTap(
        document: document,
        page: _FakePdfPage(document),
        pageRect: const Rect.fromLTWH(0, 0, 100, 100),
        pagePosition: const Offset(10, 10),
        controller: controller,
      );
      expect(result, isFalse);
      expect(document.useNativeDocumentHandleCallCount, 0);
    });

    test(
      'a tap against an invalid (address-0) native handle does not throw and returns false',
      () async {
        final document = _FakePdfDocument();
        final controller = _FakePdfViewerController(pageNumber: 1, pageCount: 10);

        // Must not throw: this is the "document disposed" / "native backing
        // gone" shape from the handler's point of view (PDFium hands back a
        // null page for an invalid document).
        final result = await handler.handleTap(
          document: document,
          page: _FakePdfPage(document),
          pageRect: const Rect.fromLTWH(0, 0, 100, 100),
          pagePosition: const Offset(10, 10),
          controller: controller,
        );

        expect(result, isFalse);
        expect(controller.goToPageCalls, isEmpty);
        expect(document.useNativeDocumentHandleCallCount, 1);
      },
      skip: noPdfium,
    );

    test('dispose() mid-tap prevents the stale continuation from navigating', () async {
      final completer = Completer<void>();
      final document = _FakePdfDocument(
        useNativeHandleImpl: <T>(task) async {
          // Hold the native call open until the test disposes the handler,
          // exactly the "document disposed mid-tap" window.
          await completer.future;
          return await task(0);
        },
      );
      final controller = _FakePdfViewerController(pageNumber: 3, pageCount: 10);

      final future = handler.handleTap(
        document: document,
        page: _FakePdfPage(document),
        pageRect: const Rect.fromLTWH(0, 0, 100, 100),
        pagePosition: const Offset(10, 10),
        controller: controller,
      );

      // handleTap is now suspended inside useNativeDocumentHandle.
      handler.dispose(); // bumps requestId; must not throw
      completer.complete(); // let the stale continuation run

      final result = await future;

      expect(result, isFalse, reason: 'a disposed handler must not report a navigation');
      expect(
        controller.goToPageCalls,
        isEmpty,
        reason: 'the stale continuation must not call goToPage after dispose()',
      );
    }, skip: noPdfium);

    test('two taps racing: the second is rejected while the first is in flight', () async {
      final gate = Completer<void>();
      final document = _FakePdfDocument(
        useNativeHandleImpl: <T>(task) async {
          await gate.future;
          return await task(0);
        },
      );
      final controller = _FakePdfViewerController(pageNumber: 1, pageCount: 10);

      // Fired back-to-back, synchronously, with no await between them — the
      // closest a single-isolate Dart test can get to "simultaneous" taps.
      final firstFuture = handler.handleTap(
        document: document,
        page: _FakePdfPage(document),
        pageRect: const Rect.fromLTWH(0, 0, 100, 100),
        pagePosition: const Offset(10, 10),
        controller: controller,
      );
      final secondFuture = handler.handleTap(
        document: document,
        page: _FakePdfPage(document),
        pageRect: const Rect.fromLTWH(0, 0, 100, 100),
        pagePosition: const Offset(20, 20),
        controller: controller,
      );

      // The second call must have been rejected synchronously by the
      // `_tapInFlight` guard, without ever reaching the native handle.
      final secondResult = await secondFuture;
      expect(secondResult, isFalse);
      expect(document.useNativeDocumentHandleCallCount, 1, reason: 'only the first tap got in');

      gate.complete();
      await firstFuture; // must complete without throwing
    }, skip: noPdfium);

    test('dispose() is idempotent and safe to call without any prior tap', () {
      expect(handler.dispose, returnsNormally);
      expect(handler.dispose, returnsNormally);
    });
  });
}
