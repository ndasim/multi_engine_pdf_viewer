import 'dart:async';

import 'package:flutter/services.dart';

import '../../domain/entity/pdf_viewer_state.dart';
import '../../domain/repo/pdf_engine_session.dart';

class PdfKitSession implements PdfEngineSession {
  PdfKitSession(this.channel, {required this.onError});

  final MethodChannel channel;
  final void Function(PdfViewerException, StackTrace?) onError;
  final _states = StreamController<PdfViewerState>.broadcast(sync: true);
  PdfViewerState _state = PdfViewerState();
  int _searchId = 0;
  bool _disposed = false;

  @override
  PdfViewerState get state => _state;
  @override
  Stream<PdfViewerState> get states => _states.stream;

  Future<Object?> _invoke(String method, [Object? arguments]) async {
    if (_disposed) return null;
    try {
      return await channel
          .invokeMethod<Object?>(method, arguments)
          .timeout(const Duration(seconds: 45));
    } on PlatformException catch (error, stack) {
      if (!_disposed) {
        final code = switch (error.code) {
          'pdfkit-invalid-document' ||
          'pdfkit-password-required' ||
          'pdfkit-invalid-arguments' => error.code,
          _ => method == 'open' ? 'pdfkit-fatal-transport' : 'pdfkit-command-transport',
        };
        // TODO: use localization
        onError(PdfViewerException(code, 'PDFKit operation failed.'), stack);
      }
    } on MissingPluginException catch (_, stack) {
      if (!_disposed) {
        onError(
          const PdfViewerException(
            'pdfkit-fatal-transport',
            'PDFKit plugin unavailable.',
          ), // TODO: use localization
          stack,
        );
      }
    } on TimeoutException catch (_, stack) {
      if (!_disposed) {
        onError(
          PdfViewerException(
            method == 'open' ? 'pdfkit-fatal-timeout' : 'pdfkit-command-timeout',
            'PDFKit operation timed out.', // TODO: use localization
          ),
          stack,
        );
      }
    }
    return null;
  }

  Future<bool> open() async {
    final result = await _invoke('open');
    if (_disposed || result == null) return false;
    if (result is! Map || result['pageCount'] is! int || result['pageNumber'] is! int) {
      _protocolError();
      return false;
    }
    final count = result['pageCount'] as int;
    final page = result['pageNumber'] as int;
    if (count < 1 || page < 1 || page > count) {
      _protocolError();
      return false;
    }
    _publish(pageCount: count, pageNumber: page);
    return true;
  }

  Future<void> loadOutline() async {
    final result = await _invoke('getOutline');
    if (_disposed || result == null) return;
    try {
      _publish(outline: _outline(result));
    } on FormatException {
      _protocolError();
    }
  }

  List<PdfOutlineNode> _outline(Object? value) {
    if (value is! List) throw const FormatException();
    return value.map((item) {
      if (item is! Map || item['title'] is! String || item['path'] is! List) {
        throw const FormatException();
      }
      List<int> path(Object? raw) {
        if (raw is! List || raw.any((index) => index is! int || index < 0)) {
          throw const FormatException();
        }
        return raw.cast<int>();
      }

      final page = item['pageNumber'];
      if (page != null && (page is! int || page < 1 || page > state.pageCount)) {
        throw const FormatException();
      }
      return PdfOutlineNode(
        title: item['title'] as String,
        pageNumber: page as int?,
        path: path(item['path']),
        destinationPath: item['destinationPath'] == null ? null : path(item['destinationPath']),
        children: _outline(item['children']),
      );
    }).toList();
  }

  void accept(MethodCall call) {
    if (_disposed) return;
    final args = call.arguments;
    if (call.method == 'onPageChanged') {
      if (args is! int || args < 1 || args > state.pageCount) {
        if (state.isReady) _protocolError();
        return;
      }
      if (args != state.pageNumber) _publish(pageNumber: args);
    } else if (call.method == 'onSearchStateChanged') {
      if (args is! Map || args['searchId'] != _searchId) return;
      final count = args['matchCount'];
      final current = args['currentIndex'];
      final pending = args['isSearching'];
      if (count is! int ||
          count < 0 ||
          pending is! bool ||
          (current != null && (current is! int || current < 0 || current >= count))) {
        _protocolError();
        return;
      }
      _publish(
        search: PdfSearchState(
          query: state.search.query,
          matchCount: count,
          currentIndex: current as int?,
          isSearching: pending,
        ),
      );
    }
  }

  void _protocolError() => onError(
    const PdfViewerException(
      'pdfkit-command-protocol',
      'Invalid PDFKit response.',
    ), // TODO: use localization
    null,
  );

  void _publish({
    int? pageCount,
    int? pageNumber,
    List<PdfOutlineNode>? outline,
    PdfSearchState? search,
  }) {
    if (_disposed) return;
    _state = PdfViewerState(
      pageCount: pageCount ?? state.pageCount,
      pageNumber: pageNumber ?? state.pageNumber,
      outline: outline ?? state.outline,
      search: search ?? state.search,
    );
    _states.add(_state);
  }

  @override
  Future<void> goToPage(int pageNumber) async => await _invoke('goToPage', pageNumber);
  @override
  Future<void> goToOutlineNode(PdfOutlineNode node) async =>
      await _invoke('goToOutline', node.destinationPath);
  @override
  void startTextSearch(String query) {
    if (_disposed) return;
    final id = ++_searchId;
    _publish(
      search: PdfSearchState(query: query, isSearching: query.isNotEmpty),
    );
    unawaited(_invoke('search', {'query': query, 'searchId': id}));
  }

  @override
  Future<void> goToNextMatch() async => await _invoke('nextSearchMatch');
  @override
  Future<void> goToPrevMatch() async => await _invoke('previousSearchMatch');

  Future<void> configure(Map<String, Object> options) async => await _invoke('configure', options);

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    channel.setMethodCallHandler(null);
    unawaited(_states.close());
    unawaited(
      channel.invokeMethod<void>('dispose').catchError((Object error, StackTrace stack) {
        if (error is PlatformException || error is MissingPluginException) {
          onError(
            const PdfViewerException(
              'pdfkit-command-dispose',
              'PDFKit cleanup failed.',
            ), // TODO: use localization
            stack,
          );
        } else {
          Error.throwWithStackTrace(error, stack);
        }
      }),
    );
  }
}
