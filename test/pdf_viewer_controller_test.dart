import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:multi_engine_pdf_viewer/multi_engine_pdf_viewer.dart';
import 'package:multi_engine_pdf_viewer/src/data/pdfrx/pdfrx_session.dart';
import 'package:multi_engine_pdf_viewer/src/domain/repo/pdf_engine_session.dart';

class _Session implements PdfEngineSession {
  final changes = StreamController<PdfViewerState>.broadcast(sync: true);
  @override
  PdfViewerState state = PdfViewerState();
  final pages = <int>[];
  final outlines = <PdfOutlineNode>[];
  final queries = <String>[];
  int next = 0;
  int previous = 0;

  void publish(PdfViewerState value) {
    state = value;
    changes.add(value);
  }

  @override
  Stream<PdfViewerState> get states => changes.stream;
  @override
  Future<void> goToPage(int pageNumber) async => pages.add(pageNumber);
  @override
  Future<void> goToOutlineNode(PdfOutlineNode node) async => outlines.add(node);
  @override
  void startTextSearch(String query) => queries.add(query);
  @override
  Future<void> goToNextMatch() async => next++;
  @override
  Future<void> goToPrevMatch() async => previous++;
}

void main() {
  test('native reset/dispose after detach never reads unsafe controller getters', () async {
    final session = PdfrxSession();
    expect(session.reset, returnsNormally);
    expect(session.state.pageCount, 0);
    expect(session.state.pageNumber, isNull);
    await session.goToPage(1);
    expect(session.dispose, returnsNormally);
  });

  late PdfViewerController controller;
  late _Session session;

  setUp(() {
    controller = PdfViewerController();
    session = _Session();
  });
  tearDown(() async {
    controller.dispose();
    await session.changes.close();
  });

  test('commands before readiness are no-ops', () async {
    await controller.goToPage(3);
    controller.startTextSearch('query');
    expect(session.pages, isEmpty);
    expect(session.queries, isEmpty);
  });

  test('navigation is one-based and clamped for every adapter', () async {
    controller.attach(session);
    session.publish(PdfViewerState(pageCount: 5, pageNumber: 1));
    await controller.goToPage(-1);
    await controller.goToPage(99);
    expect(session.pages, [1, 5]);
  });

  test('a controller cannot attach to two viewers', () async {
    controller.attach(session);
    final other = _Session();
    expect(() => controller.attach(other), throwsStateError);
    await other.changes.close();
  });

  test('detach clears old page, outline and search state', () {
    controller.attach(session);
    session.publish(PdfViewerState(
      pageCount: 5,
      pageNumber: 4,
      outline: [PdfOutlineNode(title: 'Chapter')],
      search: const PdfSearchState(query: 'old', matchCount: 2),
    ));
    controller.detach(session);
    session.publish(PdfViewerState(pageCount: 99));
    expect(controller.isReady, isFalse);
    expect(controller.pageCount, 0);
    expect(controller.outline, isNull);
    expect(controller.state.search.query, isEmpty);
  });

  test('search counters and commands are engine-independent', () async {
    controller.attach(session);
    session.publish(PdfViewerState(
      pageCount: 5,
      search: const PdfSearchState(query: 'word', matchCount: 3, currentIndex: 0),
    ));
    final searcher = PdfTextSearcher(controller);
    expect(searcher.currentIndex, 0);
    expect(searcher.matchCount, 3);
    searcher.startTextSearch('next');
    await searcher.goToNextMatch();
    await searcher.goToPrevMatch();
    expect(session.queries, ['next']);
    expect(session.next, 1);
    expect(session.previous, 1);
    searcher.dispose();
    expect(session.queries.last, '');
  });

  test('targetless outline groups never invent destinations', () async {
    controller.attach(session);
    session.publish(PdfViewerState(pageCount: 5));
    await controller.goToOutlineNode(PdfOutlineNode(title: 'Group'));
    final target = PdfOutlineNode(title: 'Target', destinationPath: [2, 1]);
    await controller.goToOutlineNode(target);
    expect(session.outlines, [target]);
  });

  test('public outline values are immutable', () {
    final path = [1];
    final node = PdfOutlineNode(title: 'Chapter', path: path, destinationPath: path);
    path.add(2);
    expect(node.path, [1]);
    expect(() => node.children.add(node), throwsUnsupportedError);
    expect(() => node.destinationPath!.add(2), throwsUnsupportedError);
  });

  test('diagnostic parameters contain no engine objects or resource URLs', () {
    const diagnostic = PdfViewerDiagnostic(engine: PdfViewerEngine.pdfJs, bundle: 'legacy');
    expect(diagnostic.toAnalyticsParameters()['tier'], 'legacy');
    expect(diagnostic.toAnalyticsParameters().keys, isNot(contains('documentPath')));
  });
}