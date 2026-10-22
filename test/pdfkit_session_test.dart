import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:multi_engine_pdf_viewer/multi_engine_pdf_viewer.dart';
import 'package:multi_engine_pdf_viewer/src/data/pdfkit/pdfkit_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/pdfkit');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late PdfKitSession session;
  late PdfViewerController controller;
  late List<PdfViewerException> errors;
  late List<MethodCall> commands;

  setUp(() {
    errors = [];
    commands = [];
    session = PdfKitSession(channel, onError: (error, _) => errors.add(error));
    controller = PdfViewerController()..attach(session);
    messenger.setMockMethodCallHandler(channel, (call) async {
      commands.add(call);
      return switch (call.method) {
        'open' => {'pageCount': 5, 'pageNumber': 2},
        'getOutline' => [
          {
            'title': 'Group',
            'path': [0],
            'pageNumber': 4,
            'destinationPath': [0, 0],
            'children': [
              {
                'title': 'Target',
                'path': [0, 0],
                'pageNumber': 4,
                'destinationPath': [0, 0],
                'children': [],
              },
            ],
          },
          {
            'title': 'Unresolved',
            'path': [1],
            'children': [],
          },
        ],
        _ => null,
      };
    });
  });

  tearDown(() async {
    controller.dispose();
    session.dispose();
    await Future<void>.delayed(Duration.zero);
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('package default is PDF.js on iOS and Android; explicit choice wins', () {
    const defaults = PdfViewerParams();
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(defaults.engine, PdfViewerEngine.pdfJs);
    expect(const PdfViewerParams(engine: PdfViewerEngine.pdfKit).engine, PdfViewerEngine.pdfKit);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(defaults.engine, PdfViewerEngine.pdfJs);
  });

  test('ready, clamped navigation, outline targets and page state share the controller', () async {
    expect(await session.open(), isTrue);
    expect(controller.pageNumber, 2);
    expect(controller.outline, isNull);
    await controller.goToPage(100);
    expect(commands.last.arguments, 5);
    session.accept(const MethodCall('onPageChanged', 5));
    expect(controller.pageNumber, 5);
    await session.loadOutline();
    expect(controller.outline!.first.destinationPath, [0, 0]);
    await controller.goToOutlineNode(controller.outline!.first);
    expect(commands.last.method, 'goToOutline');
    expect(commands.last.arguments, [0, 0]);
    final count = commands.length;
    await controller.goToOutlineNode(controller.outline!.last);
    expect(commands, hasLength(count));
    expect(errors, isEmpty);
  });

  test('search completion, zero matches, clear and cancellation reject stale events', () async {
    await session.open();
    controller.startTextSearch('old');
    controller.startTextSearch('new');
    session.accept(
      const MethodCall('onSearchStateChanged', {
        'searchId': 1,
        'matchCount': 10,
        'currentIndex': 0,
        'isSearching': false,
      }),
    );
    expect(controller.state.search.query, 'new');
    expect(controller.state.search.matchCount, 0);
    session.accept(
      const MethodCall('onSearchStateChanged', {
        'searchId': 2,
        'matchCount': 3,
        'currentIndex': 0,
        'isSearching': true,
      }),
    );
    expect(controller.state.search.currentIndex, 0);
    session.accept(
      const MethodCall('onSearchStateChanged', {
        'searchId': 2,
        'matchCount': 3,
        'currentIndex': 2,
        'isSearching': false,
      }),
    );
    expect(controller.state.search.isSearching, isFalse);
    await controller.goToNextMatch();
    expect(commands.last.method, 'nextSearchMatch');
    await controller.goToPrevMatch();
    expect(commands.last.method, 'previousSearchMatch');
    controller.startTextSearch('');
    expect(controller.state.search.matchCount, 0);
    expect(controller.state.search.currentIndex, isNull);
    expect(controller.state.search.isSearching, isFalse);
    session.accept(
      const MethodCall('onSearchStateChanged', {
        'searchId': 2,
        'matchCount': 99,
        'currentIndex': 9,
        'isSearching': false,
      }),
    );
    expect(controller.state.search.query, '');
    expect(errors, isEmpty);
  });

  test('malformed responses are reported instead of publishing invalid state', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => {'pageCount': 0, 'pageNumber': 9});
    expect(await session.open(), isFalse);
    expect(controller.isReady, isFalse);
    expect(errors.single.name, 'pdfkit-command-protocol');
  });

  test('native errors redact paths and preserve stable error codes', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'pdfkit-invalid-document', message: '/secret/document.pdf');
    });
    expect(await session.open(), isFalse);
    expect(errors.single.name, 'pdfkit-invalid-document');
    expect(errors.single.toString(), isNot(contains('/secret')));
  });

  test('missing native plugin requests bounded fatal fallback', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => throw MissingPluginException());
    expect(await session.open(), isFalse);
    expect(errors.single.name, 'pdfkit-fatal-transport');
  });

  test('retired sessions reject callbacks and commands and dispose once', () async {
    await session.open();
    controller.detach(session);
    session.dispose();
    session.dispose();
    await Future<void>.delayed(Duration.zero);
    final count = commands.length;
    session.accept(const MethodCall('onPageChanged', 4));
    session.startTextSearch('ignored');
    await session.goToPage(3);
    expect(controller.isReady, isFalse);
    expect(commands, hasLength(count));
    expect(commands.where((call) => call.method == 'dispose'), hasLength(1));
  });
}
