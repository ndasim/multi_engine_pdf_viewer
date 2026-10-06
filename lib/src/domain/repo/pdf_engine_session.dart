import '../entity/pdf_viewer_state.dart';

/// Internal operation contract implemented by each rendering adapter.
abstract interface class PdfEngineSession {
  PdfViewerState get state;
  Stream<PdfViewerState> get states;
  Future<void> goToPage(int pageNumber);
  Future<void> goToOutlineNode(PdfOutlineNode node);
  void startTextSearch(String query);
  Future<void> goToNextMatch();
  Future<void> goToPrevMatch();
}

/// Optional durable storage for capability resolutions. Failures never block opening.
abstract interface class PdfViewerCacheStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}
