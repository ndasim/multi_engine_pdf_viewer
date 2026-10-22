import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/entity/pdf_viewer_state.dart';
import '../domain/repo/pdf_engine_session.dart';

/// Drives one attached viewer without exposing its rendering engine.
class PdfViewerController extends ChangeNotifier {
  PdfEngineSession? _session;
  StreamSubscription<PdfViewerState>? _subscription;
  PdfViewerState _state = PdfViewerState();
  bool _disposed = false;

  /// Latest session snapshot. Empty before a viewer attaches.
  PdfViewerState get state => _state;

  /// Whether a live session has a known page count.
  bool get isReady => !_disposed && _session != null && _state.isReady;

  /// Pages in the open document, or zero before it is ready.
  int get pageCount => _state.pageCount;

  /// Current one-based page, or null before navigation is available.
  int? get pageNumber => _state.pageNumber;

  /// Outline bookmarks. Null while loading, empty when the document has none.
  List<PdfOutlineNode>? get outline => _state.outline;

  /// Navigates to a one-based page. No-op before the viewer is ready; out-of-range pages are clamped.
  Future<void> goToPage(int pageNumber) async {
    if (!isReady) return;
    await _session!.goToPage(pageNumber.clamp(1, pageCount));
  }

  /// Navigates to [node] when it has a destination. No-op otherwise.
  Future<void> goToOutlineNode(PdfOutlineNode node) async {
    if (!isReady || node.destinationPath == null) return;
    await _session!.goToOutlineNode(node);
  }

  /// Internal attachment used by the rendering surface.
  @internal
  void attach(PdfEngineSession session) {
    if (_disposed) throw StateError('The PDF controller has been disposed.');
    if (_session != null && !identical(_session, session)) {
      throw StateError('A PDF controller cannot be attached to two viewers.');
    }
    if (identical(_session, session)) return;
    _session = session;
    _state = session.state;
    _subscription = session.states.listen((state) {
      if (_disposed || !identical(_session, session)) return;
      _state = state;
      notifyListeners();
    });
  }

  /// Internal detachment used by the rendering surface.
  @internal
  void detach(PdfEngineSession session) {
    if (!identical(_session, session)) return;
    unawaited(_subscription?.cancel());
    _subscription = null;
    _session = null;
    _state = PdfViewerState();
  }

  /// Starts a search, or clears it when [query] is empty. No-op before the viewer is ready.
  void startTextSearch(String query) {
    if (isReady) _session!.startTextSearch(query);
  }

  /// Selects the next match. No-op before the viewer is ready.
  Future<void> goToNextMatch() async {
    if (isReady) await _session!.goToNextMatch();
  }

  /// Selects the previous match. No-op before the viewer is ready.
  Future<void> goToPrevMatch() async {
    if (isReady) await _session!.goToPrevMatch();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_subscription?.cancel());
    _subscription = null;
    _session = null;
    _state = PdfViewerState();
    super.dispose();
  }
}

/// Search counters and commands for any engine.
class PdfTextSearcher extends ChangeNotifier {
  /// Listens to [controller]. Dispose this before the controller.
  PdfTextSearcher(this._controller) {
    _controller.addListener(_changed);
  }

  final PdfViewerController _controller;

  /// Latest search snapshot from the attached viewer.
  PdfSearchState get state => _controller.state.search;

  /// Text currently being searched.
  String get query => state.query;

  /// Zero-based index of the selected match, or null before one is selected.
  int? get currentIndex => state.currentIndex;

  /// Matches found so far.
  int get matchCount => state.matchCount;

  /// Whether [matchCount] is greater than zero.
  bool get hasMatches => state.hasMatches;

  /// Whether a search is still scanning the document.
  bool get isSearching => state.isSearching;

  /// Starts a search, or clears it when [query] is empty.
  void startTextSearch(String query) => _controller.startTextSearch(query);

  /// Selects the next match.
  Future<void> goToNextMatch() => _controller.goToNextMatch();

  /// Selects the previous match.
  Future<void> goToPrevMatch() => _controller.goToPrevMatch();
  void _changed() => notifyListeners();

  @override
  void dispose() {
    _controller.removeListener(_changed);
    if (query.isNotEmpty) _controller.startTextSearch('');
    super.dispose();
  }
}
