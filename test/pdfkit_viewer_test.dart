import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:multi_engine_pdf_viewer/multi_engine_pdf_viewer.dart';
import 'package:multi_engine_pdf_viewer/src/presentation/engines/pdfkit_engine_view.dart';
import 'package:multi_engine_pdf_viewer/src/presentation/engines/pdfrx_engine_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final channels = <MethodChannel>[];
  final commands = <MethodCall>[];
  late PdfViewerController controller;
  late List<Object> errors;
  late List<PdfViewerDiagnostic> diagnostics;
  late List<int> pages;
  late List<int> paints;
  late List<Uri> links;
  late List<PdfViewerLayout> layouts;
  late int ready;
  Object? openError;

  Future<void> event(String method, Object? value, {MethodChannel? channel}) async {
    final completer = Completer<void>();
    messenger.handlePlatformMessage(
      (channel ?? channels.last).name,
      const StandardMethodCodec().encodeMethodCall(MethodCall(method, value)),
      (_) => completer.complete(),
    );
    await completer.future;
  }

  Widget viewer({
    PdfViewerEngine engine = PdfViewerEngine.pdfKit,
    PdfViewerLayout layout = PdfViewerLayout.vertical,
    String path = '/document.pdf',
  }) => Directionality(
    textDirection: TextDirection.ltr,
    child: PdfViewer.file(
      path,
      controller: controller,
      initialPageNumber: 2,
      params: PdfViewerParams(
        engine: engine,
        layout: layout,
        onViewerReady: (_) => ready++,
        onPageChanged: pages.add,
        onFirstPageRendered: paints.add,
        onExternalLinkTap: links.add,
        onLayoutChanged: layouts.add,
        onDiagnostic: diagnostics.add,
        onError: (error, _) => errors.add(error),
        loadingBuilder: (_) => const SizedBox(key: ValueKey('loading')),
        errorBuilder: (_, _) => const SizedBox(key: ValueKey('error')),
      ),
    ),
  );

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    controller = PdfViewerController();
    errors = [];
    diagnostics = [];
    pages = [];
    paints = [];
    links = [];
    layouts = [];
    ready = 0;
    openError = null;
    commands.clear();
    channels.clear();
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, (call) async {
      if (call.method == 'create') {
        final args = call.arguments as Map;
        final channel = MethodChannel('${PdfKitEngineView.viewType}/${args['id']}');
        channels.add(channel);
        messenger.setMockMethodCallHandler(channel, (command) async {
          commands.add(command);
          if (command.method == 'open') {
            final error = openError;
            if (error != null) throw error;
            return {'pageCount': 5, 'pageNumber': 2};
          }
          if (command.method == 'getOutline') return <Object>[];
          return null;
        });
      }
      return null;
    });
  });
  tearDown(() async {
    controller.dispose();
    await Future<void>.delayed(Duration.zero);
    for (final channel in channels) {
      messenger.setMockMethodCallHandler(channel, null);
    }
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('explicit native view wires ready, paint once, links, pages and mutable layout', (
    tester,
  ) async {
    await tester.pumpWidget(viewer());
    await tester.pump();
    await tester.pump();
    expect(find.byType(UiKitView), findsOneWidget);
    expect(ready, 1);
    expect(controller.isReady, isTrue);
    expect(diagnostics.single.engine, PdfViewerEngine.pdfKit);
    expect(find.byKey(const ValueKey('loading')), findsOneWidget);
    await event('onFirstPageRendered', 2);
    await event('onFirstPageRendered', 3);
    await event('onPageChanged', 3);
    await event('onPageChanged', 3);
    await tester.pump();
    expect(paints, [2]);
    expect(pages, [3]);
    expect(controller.pageNumber, 3);
    expect(find.byKey(const ValueKey('loading')), findsNothing);
    await event('onExternalLinkTap', 'https://example.com');
    await event('onExternalLinkTap', 'file:///etc/passwd');
    await event('onExternalLinkTap', 'javascript:alert(1)');
    expect(links, [Uri.parse('https://example.com')]);
    await tester.pumpWidget(viewer(layout: const PdfViewerLayout.grid(columns: 4)));
    await tester.pump();
    final config = commands.lastWhere((call) => call.method == 'configure').arguments as Map;
    expect(config['columns'], 4);
    await event('onGridClosed', null);
    await tester.pump();
    expect(layouts, [PdfViewerLayout.vertical]);
    expect(errors, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('native transport failure falls back once preserving initial page and layout', (
    tester,
  ) async {
    openError = MissingPluginException();
    await tester.pumpWidget(viewer(layout: const PdfViewerLayout.grid(columns: 4)));
    await tester.pump();
    await tester.pump();
    final fallback = tester.widget<PdfrxEngineView>(find.byType(PdfrxEngineView));
    expect(fallback.initialPageNumber, 2);
    expect(fallback.layout.columns, 4);
    expect(diagnostics.single.source, 'pdfkit-fallback');
    expect(diagnostics.single.failure, 'pdfkit-fatal-transport');
    expect(errors, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('invalid PDF errors are terminal and redacted, not silently switched', (
    tester,
  ) async {
    openError = PlatformException(code: 'pdfkit-invalid-document', message: '/secret.pdf');
    await tester.pumpWidget(viewer());
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('error')), findsOneWidget);
    expect(diagnostics, isEmpty);
    expect(errors.single.toString(), isNot(contains('/secret.pdf')));
    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('file replacement retires native callbacks, search and first paint state', (
    tester,
  ) async {
    await tester.pumpWidget(viewer());
    await tester.pump();
    await event('onFirstPageRendered', 2);
    final retired = channels.single;
    await tester.pumpWidget(viewer(path: '/replacement.pdf'));
    await tester.pump();
    await tester.pump();
    await event('onPageChanged', 5, channel: retired);
    await event('onFirstPageRendered', 5, channel: retired);
    expect(controller.pageNumber, 2);
    expect(paints, [2]);
    await event('onFirstPageRendered', 2);
    expect(paints, [2, 2]);
    expect(ready, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = null;
  });
}
