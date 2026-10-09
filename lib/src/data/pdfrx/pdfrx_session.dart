import 'dart:async';

import 'package:pdfrx/pdfrx.dart' as native;

import '../../domain/entity/pdf_viewer_state.dart';
import '../../domain/repo/pdf_engine_session.dart';

class PdfrxSession implements PdfEngineSession {
  final controller = native.PdfViewerController();
  final _states = StreamController<PdfViewerState>.broadcast(sync: true);
  final _destinations = <String, native.PdfDest>{};
  native.PdfTextSearcher? searcher;
  List<PdfOutlineNode>? _outline;
  String _query = '';
  PdfViewerState _state = PdfViewerState();

  @override
  PdfViewerState get state => _state;
  @override
  Stream<PdfViewerState> get states => _states.stream;

  void ready(List<native.PdfOutlineNode> nodes) {
    searcher?.removeListener(publish);
    searcher?.dispose();
    searcher = native.PdfTextSearcher(controller)..addListener(publish);
    _destinations.clear();
    _outline = [
      for (var index = 0; index < nodes.length; index++) _node(nodes[index], [index]),
    ];
    publish();
  }

  PdfOutlineNode _node(native.PdfOutlineNode node, List<int> path) {
    final children = [
      for (var index = 0; index < node.children.length; index++)
        _node(node.children[index], [...path, index]),
    ];
    // PDFium reports an unresolvable destination as page 0.
    final destination = node.dest != null && node.dest!.pageNumber >= 1 ? node.dest : null;
    if (destination != null) _destinations[path.join('/')] = destination;
    final descendants = children.where((child) => child.destinationPath != null);
    final descendant = descendants.isEmpty ? null : descendants.first;
    return PdfOutlineNode(
      title: node.title,
      path: path,
      children: children,
      pageNumber: destination?.pageNumber ?? descendant?.pageNumber,
      destinationPath: destination == null ? descendant?.destinationPath : path,
    );
  }

  void publish() {
    final ready = controller.isReady && searcher != null;
    _state = PdfViewerState(
      pageCount: ready ? controller.pageCount : 0,
      pageNumber: ready ? controller.pageNumber : null,
      outline: _outline,
      search: PdfSearchState(
        query: _query,
        matchCount: searcher?.matches.length ?? 0,
        currentIndex: searcher?.currentIndex,
        isSearching: searcher?.isSearching ?? false,
      ),
    );
    _states.add(_state);
  }

  void reset() {
    searcher?.removeListener(publish);
    searcher?.dispose();
    searcher = null;
    _outline = null;
    _query = '';
    _destinations.clear();
    publish();
  }

  @override
  Future<void> goToPage(int pageNumber) async {
    if (controller.isReady) await controller.goToPage(pageNumber: pageNumber);
  }

  @override
  Future<void> goToOutlineNode(PdfOutlineNode node) async {
    if (!controller.isReady) return;
    final destination = _destinations[node.destinationPath?.join('/')];
    if (destination != null) await controller.goToDest(destination);
  }

  @override
  void startTextSearch(String query) {
    _query = query;
    searcher?.startTextSearch(query);
    publish();
  }

  @override
  Future<void> goToNextMatch() async {
    if (searcher?.hasMatches ?? false) await searcher!.goToNextMatch();
  }

  @override
  Future<void> goToPrevMatch() async {
    if (searcher?.hasMatches ?? false) await searcher!.goToPrevMatch();
  }

  void dispose() {
    reset();
    unawaited(_states.close());
  }
}
