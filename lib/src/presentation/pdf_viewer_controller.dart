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

  PdfViewerState get state => _state;
  bool get isReady => !_disposed && _session != null && _state.isReady;
  int get pageCount => _state.pageCount;
  int? get pageNumber => _state.pageNumber;
  List<PdfOutlineNode>? get outline => _state.outline;

  Future<void> goToPage(int pageNumber) async {
    if (!isReady) return;
    await _session!.goToPage(pageNumber.clamp(1, pageCount));
  }

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

  @internal
  void detach(PdfEngineSession session) {
    if (!identical(_session, session)) return;
    unawaited(_subscription?.cancel());
    _subscription = null;
    _session = null;
    _state = PdfViewerState();
  }

  void startTextSearch(String query) {
    if (isReady) _session!.startTextSearch(query);
  }

  Future<void> goToNextMatch() async {
    if (isReady) await _session!.goToNextMatch();
  }

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

/// Search counters and commands for either engine.
class PdfTextSearcher extends ChangeNotifier {
  PdfTextSearcher(this._controller) {
    _controller.addListener(_changed);
  }

  final PdfViewerController _controller;
  PdfSearchState get state => _controller.state.search;
  String get query => state.query;
  int? get currentIndex => state.currentIndex;
  int get matchCount => state.matchCount;
  bool get hasMatches => state.hasMatches;
  bool get isSearching => state.isSearching;

  void startTextSearch(String query) => _controller.startTextSearch(query);
  Future<void> goToNextMatch() => _controller.goToNextMatch();
  Future<void> goToPrevMatch() => _controller.goToPrevMatch();
  void _changed() => notifyListeners();

  @override
  void dispose() {
    _controller.removeListener(_changed);
    if (query.isNotEmpty) _controller.startTextSearch('');
    super.dispose();
  }
}
