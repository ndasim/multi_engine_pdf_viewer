import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:multi_engine_pdf_viewer/multi_engine_pdf_viewer.dart';
import 'package:multi_engine_pdf_viewer/src/presentation/engines/embedpdf_engine_view.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

class _Platform extends WebViewPlatform {
  final controllers = <_Controller>[];

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) {
    final controller = _Controller(params);
    controllers.add(controller);
    return controller;
  }

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => _Delegate(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(PlatformWebViewWidgetCreationParams params) =>
      _Widget(params);
}

class _Delegate extends PlatformNavigationDelegate {
  _Delegate(super.params) : super.implementation();

  @override
  Future<void> setOnNavigationRequest(NavigationRequestCallback callback) async {}

  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback callback) async {}
}

class _Widget extends PlatformWebViewWidget {
  _Widget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

class _Controller extends PlatformWebViewController {
  _Controller(super.params) : super.implementation();

  JavaScriptChannelParams? channel;
  Uri? request;
  String? html;
  bool throwCleanup = false;
  bool hangCleanup = false;
  int disposeCount = 0;
  bool removed = false;
  final commands = <Map<String, Object?>>[];

  String get session =>
      (commands.singleWhere((command) => command['type'] == 'open')['config']
              as Map<String, Object?>)['session']
          as String;

  void message(String type, [Map<String, Object?> payload = const {}]) =>
      channel!.onMessageReceived(
        JavaScriptMessage(message: jsonEncode({'v': 1, 'type': type, ...payload})),
      );

  Future<void> cleanup() async {
    if (throwCleanup) throw StateError('synthetic platform failure');
    if (hangCleanup) await Completer<void>().future;
  }

  @override
  Future<void> setJavaScriptMode(JavaScriptMode mode) async {}

  @override
  Future<void> setBackgroundColor(Color color) async {}

  @override
  Future<void> enableZoom(bool enabled) async {}

  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams params) async => channel = params;

  @override
  Future<void> removeJavaScriptChannel(String name) async {
    removed = true;
    await cleanup();
  }

  @override
  Future<void> setPlatformNavigationDelegate(PlatformNavigationDelegate delegate) async {}

  @override
  Future<void> loadRequest(LoadRequestParams params) async => request = params.uri;

  @override
  Future<void> loadHtmlString(String value, {String? baseUrl}) async {
    assert(value.isNotEmpty);
    html = value;
    await cleanup();
  }

  @override
  Future<void> runJavaScript(String script) async {
    const prefix = 'window.pdfjsBridge && window.pdfjsBridge.receive(';
    final encoded = jsonDecode(script.substring(prefix.length, script.length - 2)) as String;
    final command = jsonDecode(encoded) as Map<String, Object?>;
    commands.add(command);
    if (command['type'] == 'dispose') {
      disposeCount++;
      await cleanup();
    }
  }
}

Future<void> _wait(WidgetTester tester, bool Function() complete) async {
  for (var attempt = 0; attempt < 100 && !complete(); attempt++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump();
  }
  expect(complete(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late WebViewPlatform? previous;
  late _Platform platform;
  late Directory directory;
  late String file;
  late List<Object> errors;
  late List<int> pages;

  setUp(() async {
    previous = WebViewPlatform.instance;
    platform = _Platform();
    WebViewPlatform.instance = platform;
    directory = await Directory.systemTemp.createTemp('embedpdf-cleanup-');
    file = '${directory.path}/bounded.pdf';
    await File(file).writeAsString('%PDF-1.7\n%%EOF\n');
    errors = [];
    pages = [];
  });

  tearDown(() async {
    WebViewPlatform.instance = previous ?? _Platform();
    await directory.delete(recursive: true);
  });

  Future<_Controller> start(WidgetTester tester) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: EmbedPdfEngineView(
          filePath: file,
          initialPageNumber: 6,
          params: PdfViewerParams(engine: PdfViewerEngine.embedPdf, onPageChanged: pages.add),
          layout: PdfViewerLayout.vertical,
          onAttach: (_) {},
          onDetach: (_) {},
          onReady: () {},
          onError: (error, _) => errors.add(error),
          onPageTap: (_) {},
        ),
      ),
    );
    await _wait(
      tester,
      () => platform.controllers.isNotEmpty && platform.controllers.single.request != null,
    );
    return platform.controllers.single;
  }

  Future<void> closed(_Controller web) async {
    Socket? socket;
    try {
      await expectLater(
        Socket.connect(
          web.request!.host,
          web.request!.port,
          timeout: const Duration(seconds: 1),
        ).then((connected) => socket = connected),
        throwsA(isA<SocketException>()),
      );
    } finally {
      socket?.destroy();
    }
  }

  testWidgets('bootstrap fatal before open is reported after safe retirement', (tester) async {
    final web = await start(tester);
    web.message('error', {'name': 'EngineUnsupported', 'message': 'bootstrap'});
    await _wait(tester, () => errors.isNotEmpty);
    expect((errors.single as PdfViewerException).name, 'embedpdf-fatal-unsupported');
    expect(web.html, '<!doctype html><html></html>');
    expect(web.removed, isTrue);
    await tester.runAsync(() => closed(web));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(web.disposeCount, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('only current-session messages can error or update a session after open', (
    tester,
  ) async {
    final web = await start(tester);
    web.message('bridgeReady');
    await tester.pump();
    for (final session in [null, 'retired-session']) {
      for (final name in ['embedpdf-fatal-worker-crash', 'embedpdf-command-transport']) {
        web.message('error', {'session': session, 'name': name, 'message': 'stale'});
      }
      web.message('pageChanged', {'session': session, 'pageNumber': 3});
    }
    await tester.pump();
    expect(errors, isEmpty);
    expect(pages, isEmpty);
    web.message('pageChanged', {'session': web.session, 'pageNumber': 6});
    web.message('error', {
      'session': web.session,
      'name': 'embedpdf-command-transport',
      'message': 'current',
    });
    await tester.pump();
    expect(pages, [6]);
    expect((errors.single as PdfViewerException).name, 'embedpdf-command-transport');
    web.message('error', {
      'session': web.session,
      'name': 'embedpdf-fatal-worker-crash',
      'message': 'current',
    });
    await _wait(tester, () => errors.length == 2);
    await tester.runAsync(() => closed(web));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final hang in [false, true]) {
    testWidgets(
      'cleanup ${hang ? 'hangs' : 'throws'} still closes the server and reports fatal once',
      (tester) async {
        final web = await start(tester);
        web.throwCleanup = !hang;
        web.hangCleanup = hang;
        web.message('error', {'name': 'EngineUnsupported', 'message': 'bootstrap'});
        if (hang) {
          for (var step = 0; step < 4; step++) {
            await tester.pump(const Duration(seconds: 1));
          }
        }
        await _wait(tester, () => errors.isNotEmpty);
        expect(errors, hasLength(1));
        expect(web.html, '<!doctype html><html></html>');
        await tester.runAsync(() => closed(web));
        await tester.pumpWidget(const SizedBox.shrink());
        expect(web.disposeCount, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
