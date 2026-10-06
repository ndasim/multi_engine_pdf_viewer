import 'dart:async';

import '../../domain/entity/pdf_viewer_state.dart';
import '../../domain/repo/pdf_engine_session.dart';
import '../pdfjs/pdfjs_bridge_message.dart';
import '../pdfjs/pdfjs_outline_node.dart';

class EmbedPdfSession implements PdfEngineSession {
  EmbedPdfSession({
    required Future<void> Function(String type, Map<String, Object?> payload) send,
    required void Function(PdfViewerException error) onError,
  }) : _send = send,
       _onError = onError;

  final Future<void> Function(String, Map<String, Object?>) _send;
  final void Function(PdfViewerException) _onError;
  final _states = StreamController<PdfViewerState>.broadcast(sync: true);
  PdfViewerState _state = PdfViewerState();
  String _query = '';
  bool _retired = false;
  bool _disposed = false;

  @override
  PdfViewerState get state => _state;
  @override
  Stream<PdfViewerState> get states => _states.stream;

  void reset({int? pageNumber}) {
    if (_retired) return;
    _query = '';
    _state = PdfViewerState(pageNumber: pageNumber);
    _states.add(_state);
  }

  void accept(PdfJsBridgeMessage message) {
    if (_retired) return;
    switch (message) {
      case PdfJsReadyMessage(:final pageCount, :final pageNumber):
        _replace(pageCount: pageCount, pageNumber: pageNumber);
      case PdfJsPageChangedMessage(:final pageNumber):
        if (pageNumber <= _state.pageCount) _replace(pageNumber: pageNumber);
      case PdfJsOutlineMessage(:final items):
        _replace(outline: items.map(_outline).toList());
      case PdfJsFindStateMessage(:final current, :final total, :final pending):
        _replace(
          search: PdfSearchState(
            query: _query,
            matchCount: total,
            currentIndex: current == 0 ? null : current - 1,
            isSearching: pending,
          ),
        );
      default:
        break;
    }
  }

  PdfOutlineNode _outline(PdfJsOutlineNode node) => PdfOutlineNode(
    title: node.title,
    pageNumber: node.pageNumber,
    path: node.path,
    destinationPath: node.destinationPath,
    children: node.children.map(_outline).toList(),
  );

  void _replace({
    int? pageCount,
    int? pageNumber,
    List<PdfOutlineNode>? outline,
    PdfSearchState? search,
  }) {
    if (_retired) return;
    _state = PdfViewerState(
      pageCount: pageCount ?? _state.pageCount,
      pageNumber: pageNumber ?? _state.pageNumber,
      outline: outline ?? _state.outline,
      search: search ?? _state.search,
    );
    _states.add(_state);
  }

  Future<void> _command(String type, [Map<String, Object?> payload = const {}]) async {
    if (_retired) return;
    try {
      await _send(type, payload);
    } catch (_) {
      if (!_retired) {
        _onError(
          const PdfViewerException(
            'embedpdf-command-transport',
            'EmbedPDF command transport failed',
          ),
        );
      }
    }
  }

  @override
  Future<void> goToPage(int pageNumber) => _command('goToPage', {'pageNumber': pageNumber});

  @override
  Future<void> goToOutlineNode(PdfOutlineNode node) {
    final path = node.destinationPath;
    if (path != null) return _command('goToOutline', {'path': path});
    if (node.pageNumber != null) return goToPage(node.pageNumber!);
    return Future<void>.value();
  }

  @override
  void startTextSearch(String query) {
    if (_retired) return;
    _query = query;
    _replace(
      search: PdfSearchState(query: query, isSearching: query.isNotEmpty),
    );
    unawaited(
      _command(query.isEmpty ? 'findClear' : 'find', query.isEmpty ? {} : {'query': query}),
    );
  }

  @override
  Future<void> goToNextMatch() => _command('findAgain', {'previous': false});
  @override
  Future<void> goToPrevMatch() => _command('findAgain', {'previous': true});

  Future<void> setZoom(double zoom) => _command('setZoom', {'zoom': zoom});
  Future<void> injectFatal() => _command('injectFatal');
  Future<void> terminateWorker() => _command('terminateWorker');
  Future<void> setLayout(PdfViewerLayout layout) =>
      _command('setLayout', {'columns': layout.columns});

  void retire() => _retired = true;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    retire();
    unawaited(_states.close());
  }
}
