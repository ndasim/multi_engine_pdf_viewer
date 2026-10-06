import 'dart:async';

import 'package:multi_engine_pdf_viewer/src/data/embedpdf/embedpdf_session.dart';
import 'package:multi_engine_pdf_viewer/src/data/pdfjs/pdfjs_bridge_message.dart';
import 'package:multi_engine_pdf_viewer/src/domain/entity/pdf_viewer_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late EmbedPdfSession session;
  late List<(String, Map<String, Object?>)> commands;
  late List<PdfViewerException> errors;

  setUp(() {
    commands = [];
    errors = [];
    session = EmbedPdfSession(
      send: (type, payload) async => commands.add((type, payload)),
      onError: errors.add,
    );
  });
  tearDown(() => session.dispose());

  test('ready, page, outline and search preserve public state contracts', () {
    session.accept(const PdfJsReadyMessage(pageCount: 189, pageNumber: 2));
    session.accept(
      PdfJsBridgeMessage.tryParse(
        '{"v":1,"type":"outline","items":[{"title":"Parent","pageNumber":3,"path":[0],"destinationPath":[0,0],"children":[{"title":"Target","pageNumber":3,"path":[0,0],"destinationPath":[0,0],"children":[]}]}]}',
      )!,
    );
    session.startTextSearch('crew');
    session.accept(const PdfJsFindStateMessage(current: 2, total: 7, pending: true));
    session.accept(const PdfJsPageChangedMessage(3));
    expect(session.state.pageCount, 189);
    expect(session.state.pageNumber, 3);
    expect(session.state.outline!.single.destinationPath, [0, 0]);
    expect(session.state.outline!.single.children.single.title, 'Target');
    expect(session.state.search.query, 'crew');
    expect(session.state.search.currentIndex, 1);
    expect(session.state.search.matchCount, 7);
    expect(session.state.search.isSearching, isTrue);
    session.accept(const PdfJsPageChangedMessage(190));
    expect(session.state.pageNumber, 3);
  });

  test('all navigation and search commands use the unchanged bridge schema', () async {
    await session.goToPage(3);
    await session.goToOutlineNode(PdfOutlineNode(title: 'Parent', destinationPath: [0, 1]));
    await session.goToOutlineNode(PdfOutlineNode(title: 'Page', pageNumber: 4));
    await session.goToOutlineNode(PdfOutlineNode(title: 'No target'));
    session.startTextSearch('crew');
    await session.goToNextMatch();
    await session.goToPrevMatch();
    session.startTextSearch('');
    await session.setLayout(const PdfViewerLayout.grid());
    await session.setZoom(2);
    expect(commands.map((command) => command.$1), [
      'goToPage',
      'goToOutline',
      'goToPage',
      'find',
      'findAgain',
      'findAgain',
      'findClear',
      'setLayout',
      'setZoom',
    ]);
    expect(commands.map((command) => command.$2), [
      {'pageNumber': 3},
      {
        'path': [0, 1],
      },
      {'pageNumber': 4},
      {'query': 'crew'},
      {'previous': false},
      {'previous': true},
      <String, Object?>{},
      {'columns': 3},
      {'zoom': 2.0},
    ]);
    expect(session.state.search.query, '');
    expect(session.state.search.isSearching, isFalse);
  });

  test('retirement rejects stale events and commands without losing last page', () async {
    session.accept(const PdfJsReadyMessage(pageCount: 189, pageNumber: 3));
    final events = <PdfViewerState>[];
    final subscription = session.states.listen(events.add);
    session.retire();
    session.accept(const PdfJsPageChangedMessage(4));
    session.accept(const PdfJsFindStateMessage(current: 1, total: 2, pending: true));
    session.reset(pageNumber: 5);
    session.startTextSearch('stale');
    await session.goToPage(7);
    expect(session.state.pageNumber, 3);
    expect(commands, isEmpty);
    expect(events, isEmpty);
    await subscription.cancel();
    session.dispose();
    session.dispose();
  });

  test('command failures are recoverable and redact transport details', () async {
    session.dispose();
    session = EmbedPdfSession(
      send: (_, _) async => throw StateError('/private/path/token/document.pdf'),
      onError: errors.add,
    );
    session.accept(const PdfJsReadyMessage(pageCount: 189, pageNumber: 2));
    await session.goToPage(3);
    expect(errors.single.name, 'embedpdf-command-transport');
    expect(errors.single.message, isNot(contains('private')));
    session.accept(const PdfJsPageChangedMessage(3));
    expect(session.state.pageNumber, 3);
  });

  test('worker death probe requests actual termination rather than a synthetic error', () async {
    await session.terminateWorker();
    expect(commands.single.$1, 'terminateWorker');
    expect(commands.single.$2, isEmpty);
  });

  test('late transport failures are ignored after retirement', () async {
    session.dispose();
    final completed = Completer<void>();
    session = EmbedPdfSession(send: (_, _) => completed.future, onError: errors.add);
    final command = session.goToPage(3);
    session.retire();
    completed.completeError(StateError('late'));
    await command;
    expect(errors, isEmpty);
  });
}
