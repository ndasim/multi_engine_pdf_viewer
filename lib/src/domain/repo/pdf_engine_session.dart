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
  /// Returns the stored value for [key], or null when it is missing.
  Future<String?> read(String key);

  /// Stores [value] under [key].
  Future<void> write(String key, String value);

  /// Removes [key].
  Future<void> delete(String key);
}
