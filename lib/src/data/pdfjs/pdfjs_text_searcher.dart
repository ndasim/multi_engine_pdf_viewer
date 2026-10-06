part of 'pdfjs_viewer.dart';

/// Full-text search over the document shown by a [PdfJsViewerController].
///
/// Matches are highlighted by PDF.js; this object mirrors the match counter.
class PdfJsTextSearcher extends ChangeNotifier {
  PdfJsTextSearcher(this._controller) {
    _controller._findStateListeners.add(_onFindState);
  }

  final PdfJsViewerController _controller;
  String _query = '';
  int _current = 0;
  int _total = 0;
  bool _isSearching = false;

  String get query => _query;

  /// 0-based index of the active match. `null` when there is no match or
  /// PDF.js has not selected one yet: it reports `current == 0` while
  /// matches are still being counted, before it scrolls to the first one.
  int? get currentIndex => hasMatches && _current > 0 ? _current - 1 : null;

  int get matchCount => _total;

  bool get hasMatches => _total > 0;

  bool get isSearching => _isSearching;

  void startTextSearch(String query) {
    if (query == _query) return;
    _query = query;
    _current = 0;
    _total = 0;
    _isSearching = query.isNotEmpty;
    notifyListeners();
    unawaited(
      query.isEmpty ? _controller._send('findClear') : _controller._send('find', {'query': query}),
    );
  }

  Future<void> goToNextMatch() => _findAgain(previous: false);

  Future<void> goToPrevMatch() => _findAgain(previous: true);

  Future<void> _findAgain({required bool previous}) async {
    if (!hasMatches) return;
    await _controller._send('findAgain', {'previous': previous});
  }

  void _onFindState(PdfJsFindStateMessage message) {
    if (_query.isEmpty) return;
    _current = message.current;
    _total = message.total;
    _isSearching = message.pending;
    notifyListeners();
  }

  @override
  void dispose() {
    _controller._findStateListeners.remove(_onFindState);
    if (_query.isNotEmpty) unawaited(_controller._send('findClear'));
    super.dispose();
  }
}
