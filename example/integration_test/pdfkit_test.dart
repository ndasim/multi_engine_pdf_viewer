import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:multi_engine_pdf_viewer/multi_engine_pdf_viewer.dart';

import 'pdfkit_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const localFile = String.fromEnvironment('PDFKIT_LOCAL_FILE');

  testWidgets(
    'PDFKit local large-document open, scan, grid and retirement',
    (tester) async {
      final controller = PdfViewerController();
      final key = GlobalKey<_HarnessScreenState>();
      await tester.pumpWidget(
        MaterialApp(
          home: _HarnessScreen(
            key: key,
            path: localFile,
            controller: controller,
          ),
        ),
      );
      final host = key.currentState!;
      try {
        await _wait(
          tester,
          () => host.ready == 1 && host.painted.isNotEmpty,
          'large native document ready',
        );
        expect(await File(localFile).length(), greaterThan(20 * 1024 * 1024));
        expect(controller.pageCount, greaterThan(0));
        await _wait(
          tester,
          () => controller.outline != null,
          'large outline parsed',
        );
        await controller.goToPage(controller.pageCount);
        await _wait(
          tester,
          () => controller.pageNumber == controller.pageCount,
          'large last page',
        );
        controller.startTextSearch('pdfkit___deliberately_missing_query');
        await _wait(
          tester,
          () => !controller.state.search.isSearching,
          'complete background scan',
        );
        expect(controller.state.search.matchCount, 0);
        controller.startTextSearch('');
        host.changeLayout(const PdfViewerLayout.grid(columns: 3));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        host.changeLayout(PdfViewerLayout.vertical);
        await tester.pump();
        host.reopen();
        await tester.pump();
        await _wait(
          tester,
          () => host.ready == 2 && host.painted.length == 2,
          'large reopen after cleanup',
        );
        expect(host.errors, isEmpty);
        debugPrint('PDFKIT_LARGE_PAGES=${controller.pageCount}');
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      }
    },
    skip: localFile.isEmpty,
  );

  testWidgets(
    'explicit PDFKit: render, controller, outline, search, grid, reopen, errors',
    (tester) async {
      final directory = await Directory.systemTemp.createTemp(
        'pdfkit-integration-',
      );
      final file = await File(
        '${directory.path}/fixture.pdf',
      ).writeAsBytes(pdfKitFixture());
      final controller = PdfViewerController();
      final searcher = PdfTextSearcher(controller);
      final key = GlobalKey<_HarnessScreenState>();
      await tester.pumpWidget(
        MaterialApp(
          home: _HarnessScreen(
            key: key,
            path: file.path,
            controller: controller,
          ),
        ),
      );
      final host = key.currentState!;
      try {
        await _wait(
          tester,
          () => host.ready == 1 && host.painted.length == 1,
          'native ready and first paint',
        );
        expect(controller.pageCount, 3);
        expect(controller.pageNumber, 2);
        expect(host.diagnostics.single.engine, PdfViewerEngine.pdfKit);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        await _wait(
          tester,
          () => controller.outline != null,
          'outline parsed off main',
        );
        final group = controller.outline!.first;
        expect(group.destinationPath, [0, 0]);
        expect(group.pageNumber, 3);
        expect(controller.outline!.last.destinationPath, isNull);

        await controller.goToPage(100);
        await _wait(
          tester,
          () => controller.pageNumber == 3,
          'clamped last page',
        );
        await controller.goToPage(-1);
        await _wait(
          tester,
          () => controller.pageNumber == 1,
          'clamped first page',
        );
        await controller.goToOutlineNode(group);
        await _wait(
          tester,
          () => controller.pageNumber == 3,
          'nested outline destination',
        );

        searcher.startTextSearch('NEEDLE');
        await _wait(
          tester,
          () => !searcher.isSearching && searcher.matchCount == 3,
          'case-insensitive complete search',
        );
        expect(searcher.currentIndex, 0);
        await searcher.goToPrevMatch();
        await _wait(
          tester,
          () => searcher.currentIndex == 2 && controller.pageNumber == 3,
          'previous wraps',
        );
        await searcher.goToNextMatch();
        await _wait(
          tester,
          () => searcher.currentIndex == 0 && controller.pageNumber == 1,
          'next wraps',
        );
        searcher.startTextSearch('missing');
        await _wait(
          tester,
          () => !searcher.isSearching && searcher.matchCount == 0,
          'zero-result completion',
        );
        searcher.startTextSearch('needle');
        searcher.startTextSearch('three');
        await _wait(
          tester,
          () => !searcher.isSearching && searcher.matchCount == 1,
          'cancelled search ignored',
        );
        expect(controller.pageNumber, 3);
        searcher.startTextSearch('');
        expect(searcher.currentIndex, isNull);
        expect(searcher.matchCount, 0);

        host.changeLayout(const PdfViewerLayout.grid(columns: 2));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        host.changeLayout(const PdfViewerLayout.grid(columns: 4));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        host.changeLayout(PdfViewerLayout.vertical);
        await tester.pump();
        await controller.goToPage(2);
        await _wait(
          tester,
          () => controller.pageNumber == 2,
          'return from configurable grid',
        );
        expect(host.errors, isEmpty);
        expect(host.painted, hasLength(1));

        host.reopen(layout: const PdfViewerLayout.grid(columns: 2));
        await tester.pump();
        await _wait(
          tester,
          () => host.ready == 2 && host.painted.length == 2,
          'reopen directly into grid paints thumbnails',
        );
        searcher.startTextSearch('three');
        await _wait(
          tester,
          () => !searcher.isSearching && searcher.matchCount == 1,
          'search exits native grid',
        );
        expect(host.layout, PdfViewerLayout.vertical);
        expect(controller.pageNumber, 3);

        host.reopen();
        await tester.pump();
        await _wait(
          tester,
          () => host.ready == 3 && host.painted.length == 3,
          'reopen after cleanup',
        );
        expect(controller.state.search.query, '');
        expect(host.errors, isEmpty);

        host.replacePath('${directory.path}/missing.pdf');
        await tester.pump();
        await _wait(
          tester,
          () => host.errors.isNotEmpty,
          'missing document error',
        );
        expect(
          (host.errors.single as PdfViewerException).name,
          'pdfkit-invalid-document',
        );
        expect(host.errors.single.toString(), isNot(contains(directory.path)));
        expect(find.byKey(const ValueKey('error')), findsOneWidget);
        expect(controller.isReady, isFalse);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        searcher.dispose();
        controller.dispose();
        await directory.delete(recursive: true);
      }
    },
  );
}

Future<void> _wait(
  WidgetTester tester,
  bool Function() done,
  String reason,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 45));
  while (!done() && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(done(), isTrue, reason: reason);
  await tester.pump();
}

class _HarnessScreen extends StatefulWidget {
  const _HarnessScreen({
    required this.path,
    required this.controller,
    super.key,
  });
  final String path;
  final PdfViewerController controller;

  @override
  State<_HarnessScreen> createState() => _HarnessScreenState();
}

class _HarnessScreenState extends State<_HarnessScreen> {
  late String path = widget.path;
  var layout = PdfViewerLayout.vertical;
  var generation = 0;
  var ready = 0;
  final painted = <int>[];
  final errors = <Object>[];
  final diagnostics = <PdfViewerDiagnostic>[];

  void changeLayout(PdfViewerLayout value) => setState(() => layout = value);
  void reopen({PdfViewerLayout layout = PdfViewerLayout.vertical}) =>
      setState(() {
        generation++;
        this.layout = layout;
      });
  void replacePath(String value) => setState(() => path = value);

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: PdfViewer.file(
        path,
        key: ValueKey(generation),
        controller: widget.controller,
        initialPageNumber: 2,
        params: PdfViewerParams(
          engine: PdfViewerEngine.pdfKit,
          layout: layout,
          onViewerReady: (_) => ready++,
          onFirstPageRendered: painted.add,
          onDiagnostic: diagnostics.add,
          onError: (error, _) => errors.add(error),
          onLayoutChanged: changeLayout,
          errorBuilder: (_, _) => const SizedBox(key: ValueKey('error')),
        ),
      ),
    ),
  );
}
