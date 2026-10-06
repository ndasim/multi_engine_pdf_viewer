part of 'pdfjs_viewer.dart';

/// Reads viewer state and drives navigation of an attached [PdfJsViewer].
class PdfJsViewerController extends ChangeNotifier {
  _PdfJsViewerState? _state;
  int _pageCount = 0;
  int? _pageNumber;
  List<PdfJsOutlineNode>? _outline;
  final List<ValueChanged<PdfJsFindStateMessage>> _findStateListeners = [];

  bool get isReady => _state != null && _pageCount > 0;

  int get pageCount => _pageCount;

  /// 1-based number of the page PDF.js considers current.
  int? get pageNumber => _pageNumber;

  /// `null` until PDF.js has read the outline, empty when there is none.
  List<PdfJsOutlineNode>? get outline => _outline;

  Future<void> goToPage(int pageNumber) {
    return _send('goToPage', {'pageNumber': pageNumber.clamp(1, max(1, _pageCount))});
  }

  /// Navigates to [node]'s target, or the first target-bearing descendant.
  Future<void> goToOutlineNode(PdfJsOutlineNode node) {
    final destinationPath = node.destinationPath;
    if (destinationPath == null) return Future.value();
    return _send('goToOutline', {'path': destinationPath});
  }

  Future<void> _send(String type, [Map<String, Object?> payload = const {}]) async {
    final state = _state;
    if (state == null || !isReady) return;
    await state._runCommand(type, payload);
  }

  // ignore: use_setters_to_change_properties
  void _attach(_PdfJsViewerState state) => _state = state;

  void _detach(_PdfJsViewerState state) {
    if (_state != state) return;
    _state = null;
    _pageCount = 0;
    _pageNumber = null;
    _outline = null;
  }

  void _reset() {
    _pageCount = 0;
    _pageNumber = null;
    _outline = null;
    notifyListeners();
  }

  void _onReady({required int pageCount, required int pageNumber}) {
    _pageCount = pageCount;
    _pageNumber = pageNumber;
    notifyListeners();
  }

  void _onOutline(List<PdfJsOutlineNode> outline) {
    _outline = List.unmodifiable(outline);
    notifyListeners();
  }

  void _onPageChanged(int pageNumber) {
    if (_pageNumber == pageNumber) return;
    _pageNumber = pageNumber;
    notifyListeners();
  }

  void _onFindState(PdfJsFindStateMessage message) {
    for (final listener in List.of(_findStateListeners)) {
      listener(message);
    }
  }
}
