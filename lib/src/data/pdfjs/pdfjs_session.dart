import 'dart:async';

import '../../domain/entity/pdf_viewer_state.dart';
import '../../domain/repo/pdf_engine_session.dart';
import 'pdfjs_outline_node.dart';
import 'pdfjs_viewer.dart';

class PdfJsSession implements PdfEngineSession {
  PdfJsSession() {
    controller.addListener(_changed);
    searcher.addListener(_changed);
  }

  final controller = PdfJsViewerController();
  late final searcher = PdfJsTextSearcher(controller);
  final _states = StreamController<PdfViewerState>.broadcast(sync: true);
  List<PdfJsOutlineNode>? _nativeOutline;
  List<PdfOutlineNode>? _outlineCache;

  List<PdfOutlineNode>? get _outlineState {
    final outline = controller.outline;
    if (!identical(outline, _nativeOutline)) {
      _nativeOutline = outline;
      _outlineCache = outline?.map(_outline).toList();
    }
    return _outlineCache;
  }

  @override
  Stream<PdfViewerState> get states => _states.stream;

  @override
  PdfViewerState get state => PdfViewerState(
    pageCount: controller.pageCount,
    pageNumber: controller.pageNumber,
    outline: _outlineState,
    search: PdfSearchState(
      query: searcher.query,
      matchCount: searcher.matchCount,
      currentIndex: searcher.currentIndex,
      isSearching: searcher.isSearching,
    ),
  );

  PdfOutlineNode _outline(PdfJsOutlineNode node) => PdfOutlineNode(
    title: node.title,
    pageNumber: node.pageNumber,
    children: node.children.map(_outline).toList(),
    path: node.path,
    destinationPath: node.destinationPath,
  );

  void _changed() => _states.add(state);

  @override
  Future<void> goToPage(int pageNumber) => controller.goToPage(pageNumber);

  @override
  Future<void> goToOutlineNode(PdfOutlineNode node) => controller.goToOutlineNode(
    PdfJsOutlineNode(title: node.title, destinationPath: node.destinationPath),
  );

  @override
  void startTextSearch(String query) => searcher.startTextSearch(query);
  @override
  Future<void> goToNextMatch() => searcher.goToNextMatch();
  @override
  Future<void> goToPrevMatch() => searcher.goToPrevMatch();

  void dispose() {
    controller.removeListener(_changed);
    searcher.removeListener(_changed);
    searcher.dispose();
    controller.dispose();
    unawaited(_states.close());
  }
}
