import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:multi_engine_pdf_viewer/multi_engine_pdf_viewer.dart';

import 'pdfkit_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  for (final engine in [PdfViewerEngine.pdfJs, PdfViewerEngine.pdfrx]) {
    testWidgets('${engine.name}: render, navigation, search, grid and reopen', (tester) async {
      final directory = await Directory.systemTemp.createTemp('remaining-engines-');
      final file = await File('${directory.path}/fixture.pdf').writeAsBytes(pdfKitFixture());
      final controller = PdfViewerController();
      final searcher = PdfTextSearcher(controller);
      final errors = <Object>[];
      final diagnostics = <PdfViewerDiagnostic>[];
      var ready = 0;
      var painted = 0;

      Widget viewer({PdfViewerLayout layout = PdfViewerLayout.vertical, int generation = 0}) =>
          MaterialApp(
            home: Scaffold(
              body: SafeArea(
                child: PdfViewer.file(
                  file.path,
                  key: ValueKey(generation),
                  controller: controller,
                  params: PdfViewerParams(
                    engine: engine,
                    layout: layout,
                    onViewerReady: (_) => ready++,
                    onFirstPageRendered: (_) => painted++,
                    onDiagnostic: diagnostics.add,
                    onPageChanged: (page) => debugPrint('SMOKE_PAGE ${engine.name} $page'),
                    onError: (error, _) {
                      errors.add(error);
                      debugPrint('SMOKE_ERROR ${engine.name} $error');
                    },
                  ),
                ),
              ),
            ),
          );

      try {
        await tester.pumpWidget(viewer());
        await _wait(tester, () => ready == 1 && painted == 1, 'ready and painted');
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
        expect(controller.pageCount, 3);
        expect(diagnostics.every((event) => event.engine == engine), isTrue);
        await _wait(tester, () => controller.outline != null, 'outline loaded');
        expect(controller.outline, isNotEmpty);
        await _command(tester, controller.goToPage(3), 'navigate to last page');
        await _wait(tester, () => controller.pageNumber == 3, 'last page');
        await tester.pump(const Duration(milliseconds: 500));
        await _command(tester, controller.goToPage(1), 'navigate to first page');
        await _wait(tester, () => controller.pageNumber == 1, 'first page');
        await tester.pump(const Duration(milliseconds: 500));

        searcher.startTextSearch('needle');
        await _wait(
          tester,
          () => !searcher.isSearching && searcher.matchCount == 3,
          'three search matches',
        );
        await _command(tester, searcher.goToNextMatch(), 'navigate to search match');
        await _wait(tester, () => searcher.currentIndex != null, 'selected search result');
        searcher.startTextSearch('deliberately_missing_query');
        await tester.pump(const Duration(milliseconds: 600));
        await _wait(
          tester,
          () => !searcher.isSearching && searcher.matchCount == 0,
          'zero results',
        );
        searcher.startTextSearch('');
        await _wait(
          tester,
          () => searcher.currentIndex == null && searcher.matchCount == 0,
          'search cleared',
        );

        await tester.pumpWidget(viewer(layout: const PdfViewerLayout.grid(columns: 2)));
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpWidget(viewer());
        await tester.pump(const Duration(seconds: 1));
        expect(ready, 1);
        expect(errors, isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(controller.isReady, isFalse);
        await tester.pumpWidget(viewer(generation: 1));
        await _wait(tester, () => ready == 2 && painted == 2, 'reopen after cleanup');
        expect(controller.pageCount, 3);
        expect(errors, isEmpty);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        searcher.dispose();
        controller.dispose();
        await directory.delete(recursive: true);
      }
    });
  }
}

Future<void> _command(WidgetTester tester, Future<void> command, String reason) async {
  var completed = false;
  final result = command.whenComplete(() => completed = true);
  await _wait(tester, () => completed, reason);
  await result;
}

Future<void> _wait(WidgetTester tester, bool Function() done, String reason) async {
  final deadline = DateTime.now().add(const Duration(seconds: 60));
  while (!done() && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(done(), isTrue, reason: reason);
  await tester.pump();
}
