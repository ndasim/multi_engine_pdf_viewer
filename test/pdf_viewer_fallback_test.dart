import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:multi_engine_pdf_viewer/multi_engine_pdf_viewer.dart';
import 'package:multi_engine_pdf_viewer/src/data/embedpdf/embedpdf_session.dart';
import 'package:multi_engine_pdf_viewer/src/presentation/engines/embedpdf_engine_view.dart';
import 'package:multi_engine_pdf_viewer/src/presentation/engines/pdfjs_engine_view.dart';
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
    if (command['type'] == 'injectFatal') {
      message('error', {'name': 'embedpdf-fatal-injected', 'message': 'Injected worker failure'});
    }
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
    PdfViewerEngine engine = PdfViewerEngine.embedPdf,
    PdfViewerLayout layout = PdfViewerLayout.vertical,
    int initialPage = 1,
    PdfViewerController? externalController,
  }) => Directionality(
    textDirection: TextDirection.ltr,
    child: PdfViewer.file(
      file,
      controller: externalController ?? controller,
      initialPageNumber: initialPage,
      params: PdfViewerParams(
        engine: engine,
        layout: layout,
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

  List<PdfViewerDiagnostic> get fallbacks =>
      diagnostics.where((diagnostic) => diagnostic.source == 'embedpdf-fallback').toList();
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
  late Future<void> Function()? previousFatalHook;
  late Directory directory;
  late String file;
  late _Host host;

  setUp(() async {
    previousPlatform = WebViewPlatform.instance;
    previousOverride = PdfViewerParams.debugEngineOverride;
    previousFatalHook = EmbedPdfEngineView.debugInjectFatal;
    PdfViewerParams.debugEngineOverride = null;
    EmbedPdfEngineView.debugInjectFatal = null;
    platform = _WebViewPlatform();
    WebViewPlatform.instance = platform;
    directory = await Directory.systemTemp.createTemp('pdf-viewer-fallback-');
    file = '${directory.path}/document.pdf';
    await File(file).writeAsString('%PDF-1.7\n%%EOF\n');
    host = _Host();
  });

  tearDown(() async {
    host.controller.dispose();
    WebViewPlatform.instance = previousPlatform ?? _WebViewPlatform();
    PdfViewerParams.debugEngineOverride = previousOverride;
    EmbedPdfEngineView.debugInjectFatal = previousFatalHook;
    await directory.delete(recursive: true);
  });

  testWidgets('pre-ready injected fatal falls back once without reporting a host error', (
    tester,
  ) async {
    PdfViewerParams.debugEngineOverride = PdfViewerEngine.embedPdf;
    await tester.pumpWidget(
      host.viewer(
        file,
        engine: PdfViewerEngine.pdfJs,
        initialPage: 7,
        layout: const PdfViewerLayout.grid(columns: 4),
      ),
    );
    final embed = await _web(tester, platform, 0);
    expect(host.controller.isReady, isFalse);
    expect(EmbedPdfEngineView.debugInjectFatal, isNotNull);
    await EmbedPdfEngineView.debugInjectFatal!();
    await _waitFor(tester, () => host.fallbacks.isNotEmpty);
    final fallback = tester.widget<PdfJsEngineView>(find.byType(PdfJsEngineView));
    expect(find.byType(EmbedPdfEngineView), findsNothing);
    expect(fallback.initialPageNumber, 7);
    expect(fallback.layout, const PdfViewerLayout.grid(columns: 4));
    expect(host.errors, isEmpty);
    expect(host.ready, isEmpty);
    expect(host.fallbacks.single.engine, PdfViewerEngine.pdfJs);
    expect(host.fallbacks.single.attempt, 1);
    expect(host.fallbacks.single.failure, 'embedpdf-fatal-injected');
    expect(embed.channelRemoved, isTrue);
    expect(embed.commands.where((command) => command['type'] == 'dispose'), hasLength(1));
    expect(EmbedPdfEngineView.debugInjectFatal, isNull);
    final pdfJs = await _web(tester, platform, 1);
    expect(pdfJs.openConfig['initialPage'], 7);
    expect(pdfJs.openConfig['columns'], 4);
    pdfJs.message('ready', {'pageCount': 20, 'pageNumber': 7});
    await tester.pump();
    expect(host.controller.pageNumber, 7);
    expect(host.ready, [host.controller]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final code in ['document', 'page', 'annotation', 'raster', 'memory']) {
    for (final ready in [false, true]) {
      testWidgets('$code quota rejection is terminal with ready=$ready', (tester) async {
        await tester.pumpWidget(host.viewer(file));
        final embed = await _web(tester, platform, 0);
        if (ready) embed.message('ready', {'pageCount': 20, 'pageNumber': 7});
        embed.message('error', {
          'name': 'embedpdf-fatal-$code-limit',
          'message': 'Resource policy rejection',
        });
        await _waitFor(tester, () => host.errors.isNotEmpty);
        await tester.pump();
        expect(find.byKey(const ValueKey('terminal-error')), findsOneWidget);
        expect(find.byType(PdfJsEngineView), findsNothing);
        expect(host.fallbacks, isEmpty);
        expect(platform.controllers, hasLength(1));
        expect((host.errors.single as PdfViewerException).name, 'embedpdf-fatal-$code-limit');
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  testWidgets('nonfatal command error reports to the host and keeps the ready engine', (
    tester,
  ) async {
    await tester.pumpWidget(host.viewer(file));
    final embed = await _web(tester, platform, 0);
    embed.message('ready', {'pageCount': 20, 'pageNumber': 3});
    embed.message('error', {'name': 'embedpdf-command-transport', 'message': 'Command failed'});
    await tester.pump();
    expect(find.byType(EmbedPdfEngineView), findsOneWidget);
    expect(find.byType(PdfJsEngineView), findsNothing);
    expect((host.errors.single as PdfViewerException).name, 'embedpdf-command-transport');
    expect(host.fallbacks, isEmpty);
    expect(host.controller.isReady, isTrue);
    embed.message('pageChanged', {'pageNumber': 4});
    await tester.pump();
    expect(host.controller.pageNumber, 4);
    expect(host.pages, [4]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('nonfatal command error before ready does not replace or hide EmbedPDF', (
    tester,
  ) async {
    await tester.pumpWidget(host.viewer(file));
    final embed = await _web(tester, platform, 0);
    embed.message('error', {'name': 'embedpdf-command-transport', 'message': 'Command failed'});
    await tester.pump();
    await tester.pump();
    expect((host.errors.single as PdfViewerException).name, 'embedpdf-command-transport');
    expect(host.fallbacks, isEmpty);
    expect(find.byKey(const ValueKey('terminal-error')), findsNothing);
    expect(find.byType(EmbedPdfEngineView), findsOneWidget);
    expect(find.byType(PdfJsEngineView), findsNothing);
    embed.message('ready', {'pageCount': 20, 'pageNumber': 1});
    await tester.pump();
    expect(host.controller.isReady, isTrue);
    expect(host.ready, [host.controller]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('mid-session fatal resumes the latest page and the unchanged grid layout', (
    tester,
  ) async {
    await tester.pumpWidget(
      host.viewer(file, initialPage: 2, layout: const PdfViewerLayout.grid(columns: 4)),
    );
    final embed = await _web(tester, platform, 0);
    embed.message('ready', {'pageCount': 20, 'pageNumber': 2});
    embed.message('pageChanged', {'pageNumber': 9});
    await tester.pump();
    expect(host.controller.pageNumber, 9);
    embed.message('error', {'name': 'embedpdf-fatal-worker-hang'});
    await _waitFor(tester, () => host.fallbacks.isNotEmpty);
    expect(host.controller.isReady, isFalse);
    final fallback = tester.widget<PdfJsEngineView>(find.byType(PdfJsEngineView));
    expect(fallback.initialPageNumber, 9);
    expect(fallback.layout, const PdfViewerLayout.grid(columns: 4));
    final pdfJs = await _web(tester, platform, 1);
    expect(pdfJs.openConfig['initialPage'], 9);
    expect(pdfJs.openConfig['columns'], 4);
    pdfJs.message('ready', {'pageCount': 20, 'pageNumber': 9});
    await tester.pump();
    expect(host.controller.pageNumber, 9);
    expect(host.ready, [host.controller, host.controller]);
    expect(host.errors, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('fatal preserves the vertical layout chosen by a grid page tap', (tester) async {
    await tester.pumpWidget(host.viewer(file, layout: const PdfViewerLayout.grid(columns: 4)));
    final embed = await _web(tester, platform, 0);
    embed.message('ready', {'pageCount': 20, 'pageNumber': 1});
    embed.message('pageTap', {'pageNumber': 12});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(host.layouts, [PdfViewerLayout.vertical]);
    expect(host.taps, [12]);
    expect(
      embed.commands
          .where((command) => command['type'] == 'goToPage')
          .map((command) => command['pageNumber']),
      [12],
    );
    embed.message('pageChanged', {'pageNumber': 12});
    embed.message('error', {'name': 'embedpdf-fatal-worker-hang'});
    await _waitFor(tester, () => host.fallbacks.isNotEmpty);
    final fallback = tester.widget<PdfJsEngineView>(find.byType(PdfJsEngineView));
    expect(fallback.initialPageNumber, 12);
    expect(fallback.layout, PdfViewerLayout.vertical);
    final pdfJs = await _web(tester, platform, 1);
    expect(pdfJs.openConfig['initialPage'], 12);
    expect(pdfJs.openConfig['columns'], 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('duplicate fatal callbacks schedule only one fallback', (tester) async {
    await tester.pumpWidget(host.viewer(file));
    await _web(tester, platform, 0);
    final retired = tester.widget<EmbedPdfEngineView>(find.byType(EmbedPdfEngineView));
    const first = PdfViewerException('embedpdf-fatal-worker-hang', 'Worker stopped');
    const second = PdfViewerException('embedpdf-fatal-resource-load', 'Host failed');
    retired.onError(first, null);
    retired.onError(second, null);
    await _waitFor(tester, () => host.fallbacks.isNotEmpty);
    final fallback = tester.widget<PdfJsEngineView>(find.byType(PdfJsEngineView));
    retired.onError(second, null);
    await tester.pump();
    await _web(tester, platform, 1);
    expect(host.fallbacks, hasLength(1));
    expect(host.fallbacks.single.failure, first.name);
    expect(host.errors, isEmpty);
    expect(platform.controllers, hasLength(2));
    expect(tester.widget<PdfJsEngineView>(find.byType(PdfJsEngineView)).key, fallback.key);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('PDF.js failure after fallback is terminal and never starts another engine', (
    tester,
  ) async {
    await tester.pumpWidget(host.viewer(file));
    final embed = await _web(tester, platform, 0);
    embed.message('error', {'name': 'embedpdf-fatal-bootstrap'});
    await _waitFor(tester, () => host.fallbacks.isNotEmpty);
    final pdfJs = await _web(tester, platform, 1);
    final fallback = tester.widget<PdfJsEngineView>(find.byType(PdfJsEngineView));
    pdfJs.message('error', {
      'name': 'InvalidPDFException',
      'message': 'Invalid PDF',
      'tier': 'legacy',
    });
    await _waitFor(tester, () => host.errors.isNotEmpty);
    await tester.pump();
    expect(host.errors, hasLength(1));
    expect(host.errors.single, isA<PdfViewerException>());
    expect(host.errors.single.toString(), contains('InvalidPDFException'));
    expect(find.byKey(const ValueKey('terminal-error')), findsOneWidget);
    expect(find.byType(PdfJsEngineView), findsNothing);
    expect(find.byType(EmbedPdfEngineView), findsNothing);
    fallback.onError(const PdfViewerException('embedpdf-fatal-late', 'Late failure'), null);
    await tester.pump();
    expect(host.fallbacks, hasLength(1));
    expect(platform.controllers, hasLength(2));
    expect(find.byKey(const ValueKey('terminal-error')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'retired ready, page, render, diagnostic, error, tap and attach callbacks are ignored',
    (tester) async {
      await tester.pumpWidget(host.viewer(file));
      final embed = await _web(tester, platform, 0);
      embed.message('ready', {'pageCount': 20, 'pageNumber': 3});
      await tester.pump();
      final retired = tester.widget<EmbedPdfEngineView>(find.byType(EmbedPdfEngineView));
      embed.message('error', {'name': 'embedpdf-fatal-worker-hang'});
      await _waitFor(tester, () => host.fallbacks.isNotEmpty);
      final pdfJs = await _web(tester, platform, 1);
      pdfJs.message('ready', {'pageCount': 20, 'pageNumber': 3});
      pdfJs.message('pageChanged', {'pageNumber': 4});
      await tester.pump();
      final readyCount = host.ready.length;
      final diagnostics = List<PdfViewerDiagnostic>.of(host.diagnostics);
      final staleSession = EmbedPdfSession(send: (_, _) async {}, onError: (_) {});
      retired.onReady();
      retired.params.onPageChanged!(19);
      retired.params.onFirstPageRendered!(19);
      retired.params.onDiagnostic!(const PdfViewerDiagnostic(engine: PdfViewerEngine.embedPdf));
      retired.params.onExternalLinkTap!(Uri.parse('https://example.com/stale'));
      retired.onError(const PdfViewerException('embedpdf-fatal-stale', 'Stale'), null);
      retired.onError(const PdfViewerException('embedpdf-command-stale', 'Stale'), null);
      retired.onPageTap(19);
      retired.onAttach(staleSession);
      retired.onDetach(staleSession);
      embed.message('ready', {'pageCount': 99, 'pageNumber': 19});
      embed.message('pageChanged', {'pageNumber': 19});
      await tester.pump();
      expect(host.ready, hasLength(readyCount));
      expect(host.diagnostics, diagnostics);
      expect(host.pages, [4]);
      expect(host.rendered, isEmpty);
      expect(host.links, isEmpty);
      expect(host.taps, isEmpty);
      expect(host.errors, isEmpty);
      expect(host.controller.pageNumber, 4);
      expect(host.controller.pageCount, 20);
      expect(host.controller.isReady, isTrue);
      pdfJs.message('firstPageRendered', {'pageNumber': 4});
      pdfJs.message('pageChanged', {'pageNumber': 5});
      await tester.pump();
      expect(host.rendered, [4]);
      expect(host.pages, [4, 5]);
      expect(host.controller.pageNumber, 5);
      staleSession.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('changing files resets fallback page, layout and one-shot allowance', (tester) async {
    PdfViewerParams.debugEngineOverride = PdfViewerEngine.embedPdf;
    await tester.pumpWidget(host.viewer(file, layout: const PdfViewerLayout.grid(columns: 4)));
    final embed = await _web(tester, platform, 0);
    embed.message('ready', {'pageCount': 20, 'pageNumber': 8});
    embed.message('pageTap', {'pageNumber': 8});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    embed.message('error', {'name': 'embedpdf-fatal-worker-hang'});
    await _waitFor(tester, () => host.fallbacks.isNotEmpty);
    await _web(tester, platform, 1);
    final nextFile = '${directory.path}/next.pdf';
    await tester.runAsync(() => File(nextFile).writeAsString('%PDF-1.7\n%%EOF\n'));
    await tester.pumpWidget(
      host.viewer(nextFile, initialPage: 2, layout: const PdfViewerLayout.grid(columns: 4)),
    );
    final reopened = tester.widget<EmbedPdfEngineView>(find.byType(EmbedPdfEngineView));
    expect(reopened.initialPageNumber, 2);
    expect(reopened.layout, const PdfViewerLayout.grid(columns: 4));
    expect(host.controller.isReady, isFalse);
    final nextEmbed = await _web(tester, platform, 2);
    expect(nextEmbed.openConfig['initialPage'], 2);
    expect(nextEmbed.openConfig['columns'], 4);
    await EmbedPdfEngineView.debugInjectFatal!();
    await _waitFor(tester, () => host.fallbacks.length == 2);
    expect(host.fallbacks.map((diagnostic) => diagnostic.attempt), [1, 1]);
    expect(tester.widget<PdfJsEngineView>(find.byType(PdfJsEngineView)).initialPageNumber, 2);
    expect(host.errors, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('changing requested engine clears the previous fallback override', (tester) async {
    PdfViewerParams.debugEngineOverride = PdfViewerEngine.embedPdf;
    await tester.pumpWidget(host.viewer(file));
    final embed = await _web(tester, platform, 0);
    embed.message('ready', {'pageCount': 20, 'pageNumber': 8});
    embed.message('error', {'name': 'embedpdf-fatal-worker-hang'});
    await _waitFor(tester, () => host.fallbacks.isNotEmpty);
    await _web(tester, platform, 1);
    await tester.pumpWidget(host.viewer(file, engine: PdfViewerEngine.pdfJs, initialPage: 2));
    expect(find.byType(EmbedPdfEngineView), findsOneWidget);
    final nextEmbed = await _web(tester, platform, 2);
    expect(nextEmbed.openConfig['initialPage'], 2);
    expect(host.controller.isReady, isFalse);
    expect(host.fallbacks, hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('controller replacement across fallback detaches the old external controller', (
    tester,
  ) async {
    final replacement = PdfViewerController();
    await tester.pumpWidget(host.viewer(file));
    final embed = await _web(tester, platform, 0);
    embed.message('ready', {'pageCount': 20, 'pageNumber': 3});
    await tester.pump();
    await tester.pumpWidget(host.viewer(file, externalController: replacement));
    expect(host.controller.isReady, isFalse);
    expect(host.controller.pageNumber, isNull);
    expect(replacement.pageNumber, 3);
    host.controller.dispose();
    embed.message('error', {'name': 'embedpdf-fatal-worker-hang'});
    await _waitFor(tester, () => host.fallbacks.isNotEmpty);
    final pdfJs = await _web(tester, platform, 1);
    pdfJs.message('ready', {'pageCount': 20, 'pageNumber': 3});
    await tester.pump();
    expect(replacement.isReady, isTrue);
    expect(host.ready.last, same(replacement));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(replacement.isReady, isFalse);
    expect(replacement.pageNumber, isNull);
    expect(() => replacement.addListener(() {}), returnsNormally);
    replacement.dispose();
    host = _Host();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'unmount with a pending fatal ignores retired callbacks and keeps the controller reusable',
    (tester) async {
      await tester.pumpWidget(host.viewer(file));
      final embed = await _web(tester, platform, 0);
      embed.message('ready', {'pageCount': 20, 'pageNumber': 3});
      await tester.pump();
      final retired = tester.widget<EmbedPdfEngineView>(find.byType(EmbedPdfEngineView));
      const fatal = PdfViewerException('embedpdf-fatal-worker-hang', 'Worker stopped');
      embed.message('error', {'name': fatal.name});
      await tester.pumpWidget(const SizedBox.shrink());
      retired.onError(fatal, null);
      retired.onReady();
      retired.params.onPageChanged!(19);
      await tester.pump();
      expect(host.fallbacks, isEmpty);
      expect(host.errors, isEmpty);
      expect(host.pages, isEmpty);
      expect(host.controller.isReady, isFalse);
      await tester.pumpWidget(host.viewer(file, initialPage: 2));
      final reopened = await _web(tester, platform, 1);
      reopened.message('ready', {'pageCount': 20, 'pageNumber': 2});
      await tester.pump();
      expect(host.controller.pageNumber, 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('external controller disposal after unmount is safe during fatal cleanup', (
    tester,
  ) async {
    await tester.pumpWidget(host.viewer(file));
    final embed = await _web(tester, platform, 0);
    embed.message('ready', {'pageCount': 20, 'pageNumber': 3});
    await tester.pump();
    final retired = tester.widget<EmbedPdfEngineView>(find.byType(EmbedPdfEngineView));
    embed.message('error', {'name': 'embedpdf-fatal-worker-hang'});
    await tester.pumpWidget(const SizedBox.shrink());
    final disposedHost = host;
    disposedHost.controller.dispose();
    host = _Host();
    retired.onReady();
    retired.onError(const PdfViewerException('embedpdf-fatal-late', 'Late fatal'), null);
    retired.params.onPageChanged!(19);
    await _waitFor(tester, () => embed.channelRemoved);
    expect(disposedHost.controller.isReady, isFalse);
    expect(disposedHost.fallbacks, isEmpty);
    expect(disposedHost.errors, isEmpty);
    expect(disposedHost.pages, isEmpty);
    expect(platform.controllers, hasLength(1));
    expect(tester.takeException(), isNull);
  });
}
