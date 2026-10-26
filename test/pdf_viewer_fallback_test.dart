import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show CircularProgressIndicator;
import 'package:flutter/services.dart';
import 'package:multi_engine_pdf_viewer/multi_engine_pdf_viewer.dart';
import 'package:multi_engine_pdf_viewer/src/presentation/engines/pdfjs_engine_view.dart';
import 'package:multi_engine_pdf_viewer/src/presentation/engines/pdfrx_engine_view.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

class _WebViewPlatform extends WebViewPlatform {
  final controllers = <_WebController>[];

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) {
    final controller = _WebController(params);
    controllers.add(controller);
    return controller;
  }

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => _NavigationDelegate(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(PlatformWebViewWidgetCreationParams params) =>
      _WebWidget(params);
}

class _NavigationDelegate extends PlatformNavigationDelegate {
  _NavigationDelegate(super.params) : super.implementation();

  @override
  Future<void> setOnNavigationRequest(NavigationRequestCallback onNavigationRequest) async {}

  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback onWebResourceError) async {}
}

class _WebWidget extends PlatformWebViewWidget {
  _WebWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

class _WebController extends PlatformWebViewController {
  _WebController(super.params) : super.implementation();

  JavaScriptChannelParams? channel;
  Uri? request;
  final commands = <Map<String, Object?>>[];
  bool channelRemoved = false;

  Map<String, Object?> get openConfig =>
      commands.singleWhere((command) => command['type'] == 'open')['config']
          as Map<String, Object?>;

  void message(String type, [Map<String, Object?> payload = const {}]) {
    channel!.onMessageReceived(
      JavaScriptMessage(
        message: jsonEncode({
          'v': 1,
          'type': type,
          if (commands.any((command) => command['type'] == 'open'))
            'session': openConfig['session'],
          ...payload,
        }),
      ),
    );
  }

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}

  @override
  Future<void> setBackgroundColor(Color color) async {}

  @override
  Future<void> enableZoom(bool enabled) async {}

  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams params) async => channel = params;

  @override
  Future<void> removeJavaScriptChannel(String name) async => channelRemoved = true;

  @override
  Future<void> setPlatformNavigationDelegate(PlatformNavigationDelegate handler) async {}

  @override
  Future<void> loadRequest(LoadRequestParams params) async => request = params.uri;

  @override
  Future<void> loadHtmlString(String value, {String? baseUrl}) async {}

  @override
  Future<void> runJavaScript(String script) async {
    const prefix = 'window.pdfjsBridge && window.pdfjsBridge.receive(';
    final encoded = jsonDecode(script.substring(prefix.length, script.length - 2)) as String;
    final command = jsonDecode(encoded) as Map<String, Object?>;
    commands.add(command);
  }
}

class _Host {
  final controller = PdfViewerController();
  final errors = <Object>[];
  final diagnostics = <PdfViewerDiagnostic>[];
  final ready = <PdfViewerController>[];
  final pages = <int>[];
  final rendered = <int>[];
  final taps = <int>[];
  final layouts = <PdfViewerLayout>[];
  final links = <Uri>[];

  Widget viewer(
    String file, {
    PdfViewerEngine engine = PdfViewerEngine.pdfJs,
    PdfViewerLayout layout = PdfViewerLayout.vertical,
    int initialPage = 1,
    PdfViewerController? externalController,
    WidgetBuilder? loadingBuilder,
  }) => Directionality(
    textDirection: TextDirection.ltr,
    child: PdfViewer.file(
      file,
      controller: externalController ?? controller,
      initialPageNumber: initialPage,
      params: PdfViewerParams(
        engine: engine,
        layout: layout,
        loadingBuilder: loadingBuilder,
        onViewerReady: ready.add,
        onFirstPageRendered: rendered.add,
        onPageChanged: pages.add,
        onPageTap: taps.add,
        onLayoutChanged: layouts.add,
        onExternalLinkTap: links.add,
        onDiagnostic: diagnostics.add,
        onError: (error, _) => errors.add(error),
        errorBuilder: (_, _) => const SizedBox(key: ValueKey('terminal-error')),
      ),
    ),
  );
}

Future<void> _waitFor(WidgetTester tester, bool Function() complete) async {
  for (var attempt = 0; attempt < 100 && !complete(); attempt++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump();
  }
  expect(complete(), isTrue, reason: 'the mocked WebView startup or retirement must complete');
  await tester.pump();
}

Future<_WebController> _web(WidgetTester tester, _WebViewPlatform platform, int index) async {
  await _waitFor(
    tester,
    () => platform.controllers.length > index && platform.controllers[index].request != null,
  );
  final web = platform.controllers[index];
  web.message('bridgeReady');
  await tester.pump();
  return web;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _WebViewPlatform platform;
  late WebViewPlatform? previousPlatform;
  late PdfViewerEngine? previousOverride;
  late Directory directory;
  late String file;
  late _Host host;

  test('only the three supported engines remain and PDF.js stays the default', () {
    expect(PdfViewerEngine.values, [
      PdfViewerEngine.pdfJs,
      PdfViewerEngine.pdfrx,
      PdfViewerEngine.pdfKit,
    ]);
    expect(const PdfViewerParams().engine, PdfViewerEngine.pdfJs);
  });

  setUp(() async {
    previousPlatform = WebViewPlatform.instance;
    previousOverride = PdfViewerParams.debugEngineOverride;
    PdfViewerParams.debugEngineOverride = null;
    platform = _WebViewPlatform();
    WebViewPlatform.instance = platform;
    directory = await Directory.systemTemp.createTemp('pdf-viewer-fallback-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => directory.path,
    );
    file = '${directory.path}/document.pdf';
    await File(file).writeAsString('%PDF-1.7\n%%EOF\n');
    host = _Host();
  });

  tearDown(() async {
    host.controller.dispose();
    WebViewPlatform.instance = previousPlatform ?? _WebViewPlatform();
    PdfViewerParams.debugEngineOverride = previousOverride;
    await directory.delete(recursive: true);
  });

  for (final debugOverride in [false, true]) {
    testWidgets('unsupported PDFKit falls back to PDF.js with one log, override=$debugOverride', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final previousPrint = debugPrint;
      final logs = <String>[];
      debugPrint = (message, {wrapWidth}) {
        if (message != null) logs.add(message);
      };
      try {
        if (debugOverride) PdfViewerParams.debugEngineOverride = PdfViewerEngine.pdfKit;
        Widget viewer() => host.viewer(
          file,
          engine: debugOverride ? PdfViewerEngine.pdfJs : PdfViewerEngine.pdfKit,
          initialPage: 4,
          layout: const PdfViewerLayout.grid(columns: 4),
        );
        await tester.pumpWidget(viewer());
        final web = await _web(tester, platform, 0);
        expect(find.byType(PdfJsEngineView), findsOneWidget);
        expect(find.byType(PdfrxEngineView), findsNothing);
        expect(find.byType(UiKitView), findsNothing);
        final fallback = host.diagnostics.single;
        expect(fallback.engine, PdfViewerEngine.pdfJs);
        expect(fallback.source, 'unsupported-platform-fallback');
        expect(fallback.failure, 'engine-unsupported-platform');
        expect(fallback.attempt, 1);
        final view = tester.widget<PdfJsEngineView>(find.byType(PdfJsEngineView));
        expect(view.initialPageNumber, 4);
        expect(view.layout.columns, 4);
        web.message('ready', {'pageCount': 20, 'pageNumber': 4});
        web.message('firstPageRendered', {'pageNumber': 4});
        web.message('pageChanged', {'pageNumber': 5});
        await tester.pump();
        expect(host.controller.pageNumber, 5);
        expect(host.ready, [host.controller]);
        expect(host.rendered, [4]);
        expect(host.errors, isEmpty);
        await tester.pumpWidget(viewer());
        await tester.pump();
        expect(logs.where((line) => line.contains('falling back to pdfJs')), hasLength(1));
        expect(logs.single, contains('pdfKit is unsupported on android'));
        expect(logs.single, isNot(contains(file)));
        expect(host.diagnostics, hasLength(1));
        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        debugPrint = previousPrint;
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  testWidgets('explicit supported engine after incompatibility retires fallback state', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await tester.pumpWidget(host.viewer(file, engine: PdfViewerEngine.pdfKit));
      final fallback = await _web(tester, platform, 0);
      fallback.message('ready', {'pageCount': 20, 'pageNumber': 4});
      await tester.pump();
      expect(host.controller.pageNumber, 4);
      await tester.pumpWidget(host.viewer(file, engine: PdfViewerEngine.pdfJs));
      final replacement = await _web(tester, platform, 1);
      expect(find.byType(PdfJsEngineView), findsOneWidget);
      expect(host.controller.isReady, isFalse);
      fallback.message('pageChanged', {'pageNumber': 9});
      replacement.message('ready', {'pageCount': 30, 'pageNumber': 1});
      await tester.pump();
      expect(host.controller.pageNumber, 1);
      expect(host.errors, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  for (final customLoading in [false, true]) {
    testWidgets('PDF.js hands off loading at layout ready, custom=$customLoading', (tester) async {
      const loadingKey = ValueKey('host-loading');
      final loading = customLoading
          ? find.byKey(loadingKey)
          : find.byType(CircularProgressIndicator);
      Widget viewer(String path) => host.viewer(
        path,
        engine: PdfViewerEngine.pdfJs,
        loadingBuilder: customLoading ? (_) => const SizedBox(key: loadingKey) : null,
      );

      await tester.pumpWidget(viewer(file));
      expect(loading, findsOneWidget);
      final web = await _web(tester, platform, 0);
      expect(loading, findsOneWidget);
      expect(host.ready, isEmpty);

      web.message('ready', {'pageCount': 20, 'pageNumber': 1});
      await tester.pump();
      expect(loading, findsNothing);
      expect(host.ready, hasLength(1));
      expect(host.rendered, isEmpty);

      web.message('firstPageRendered', {'pageNumber': 1});
      web.message('pageChanged', {'pageNumber': 2});
      await tester.pump();
      expect(loading, findsNothing);
      expect(host.rendered, [1]);
      expect(host.pages, [2]);

      final nextFile = '${directory.path}/replacement.pdf';
      await tester.runAsync(() => File(file).copy(nextFile));
      await tester.pumpWidget(viewer(nextFile));
      expect(loading, findsOneWidget);
      final replacement = await _web(tester, platform, 1);
      replacement.message('ready', {'pageCount': 10, 'pageNumber': 1});
      await tester.pump();
      expect(loading, findsNothing);
      expect(host.errors, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('controller replacement detaches the old controller without reopening PDF.js', (
    tester,
  ) async {
    final replacement = PdfViewerController();
    await tester.pumpWidget(host.viewer(file));
    final web = await _web(tester, platform, 0);
    web.message('ready', {'pageCount': 20, 'pageNumber': 3});
    await tester.pump();
    await tester.pumpWidget(host.viewer(file, externalController: replacement));
    expect(host.controller.isReady, isFalse);
    expect(replacement.pageNumber, 3);
    expect(platform.controllers, hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(replacement.isReady, isFalse);
    replacement.dispose();
  });

  testWidgets('retired PDF.js callbacks cannot mutate a replacement session', (tester) async {
    await tester.pumpWidget(host.viewer(file));
    final web = await _web(tester, platform, 0);
    web.message('ready', {'pageCount': 20, 'pageNumber': 3});
    await tester.pump();
    final retired = tester.widget<PdfJsEngineView>(find.byType(PdfJsEngineView));
    final nextFile = '${directory.path}/replacement.pdf';
    await tester.runAsync(() => File(file).copy(nextFile));
    await tester.pumpWidget(host.viewer(nextFile, initialPage: 2));
    final replacement = await _web(tester, platform, 1);
    replacement.message('ready', {'pageCount': 10, 'pageNumber': 2});
    await tester.pump();
    final readyCount = host.ready.length;
    retired.onReady();
    retired.params.onPageChanged!(19);
    retired.params.onFirstPageRendered!(19);
    retired.onError(const PdfViewerException('retired-session', 'Stale callback'), null);
    await tester.pump();
    expect(host.ready, hasLength(readyCount));
    expect(host.controller.pageNumber, 2);
    expect(host.pages, isEmpty);
    expect(host.rendered, isEmpty);
    expect(host.errors, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
