import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../domain/entity/pdf_viewer_state.dart';
import '../domain/repo/pdf_engine_session.dart';
import 'engines/pdfrx_engine_view.dart';
import 'engines/pdfjs_engine_view.dart';
import 'engines/pdfkit_engine_view.dart';
import 'pdf_viewer_controller.dart';
import 'pdf_viewer_params.dart';

/// An unframed PDF rendering surface. Toolbar and navigation UI belong to the host.
class PdfViewer extends StatefulWidget {
  /// Renders the local PDF at [filePath].
  ///
  /// [initialPageNumber] is one-based. A null [controller] is owned by this widget.
  /// Give the widget a new key to reopen a file replaced at the same path.
  const PdfViewer.file(
    this.filePath, {
    this.controller,
    this.initialPageNumber = 1,
    this.params = const PdfViewerParams(),
    super.key,
  }) : assert(initialPageNumber > 0);

  /// Absolute path of the PDF to open.
  final String filePath;

  /// Controller for this viewer. When null, the widget creates and disposes one.
  final PdfViewerController? controller;

  /// One-based page shown when the document becomes ready.
  final int initialPageNumber;

  /// Engine, layout and host callbacks.
  final PdfViewerParams params;

  @override
  State<PdfViewer> createState() => _PdfViewerState();
}

class _PdfViewerState extends State<PdfViewer> {
  late PdfViewerController _controller;
  PdfEngineSession? _session;
  Object? _error;
  PdfViewerLayout? _layoutOverride;
  PdfViewerEngine? _engineOverride;
  int? _resumePage;
  bool _fallbackPending = false;
  int _generation = 0;
  late PdfViewerEngine _selectedEngine;

  PdfViewerEngine get _requestedEngine =>
      PdfViewerParams.debugEngineOverride ?? widget.params.engine;
  PdfViewerEngine get _engine => _engineOverride ?? _selectedEngine;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? PdfViewerController();
    _resolvePlatformEngine();
  }

  void _resolvePlatformEngine() {
    _selectedEngine = _requestedEngine;
    final supported = switch (_selectedEngine) {
      PdfViewerEngine.pdfKit => defaultTargetPlatform == TargetPlatform.iOS,
      PdfViewerEngine.pdfJs || PdfViewerEngine.pdfrx => true,
    };
    if (supported) return;
    _engineOverride = PdfViewerEngine.pdfJs;
    final generation = _generation;
    final requested = _selectedEngine;
    final platform = defaultTargetPlatform.name;
    debugPrint(
      'multi_engine_pdf_viewer: ${requested.name} is unsupported on $platform; falling back to pdfJs.',
    );
    scheduleMicrotask(() {
      if (!mounted || generation != _generation) return;
      widget.params.onDiagnostic?.call(
        const PdfViewerDiagnostic(
          engine: PdfViewerEngine.pdfJs,
          source: 'unsupported-platform-fallback',
          attempt: 1,
          failure: 'engine-unsupported-platform',
        ),
      );
    });
  }

  @override
  void didUpdateWidget(PdfViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      final session = _session;
      if (session != null) _controller.detach(session);
      if (oldWidget.controller == null) _controller.dispose();
      _controller = widget.controller ?? PdfViewerController();
      if (session != null) _controller.attach(session);
    }
    if (oldWidget.filePath != widget.filePath ||
        oldWidget.params.engine != widget.params.engine ||
        _selectedEngine != _requestedEngine) {
      _error = null;
      _generation++;
      _layoutOverride = null;
      _engineOverride = null;
      _resumePage = null;
      _fallbackPending = false;
      _resolvePlatformEngine();
    }
    if (oldWidget.params.layout != widget.params.layout) _layoutOverride = null;
  }

  void _attach(PdfEngineSession session) {
    final previous = _session;
    if (previous != null) _controller.detach(previous);
    _controller.attach(session);
    _session = session;
  }

  void _detach(PdfEngineSession session) {
    _controller.detach(session);
    if (identical(_session, session)) _session = null;
  }

  void _onError(int generation, Object error, StackTrace? stackTrace) {
    if (!mounted || generation != _generation) return;
    final pdfKitFatal =
        _engine == PdfViewerEngine.pdfKit &&
        error is PdfViewerException &&
        error.name.startsWith('pdfkit-fatal-');
    if (pdfKitFatal) {
      if (_fallbackPending) return;
      _fallbackPending = true;
      final page = _controller.pageNumber ?? _resumePage ?? widget.initialPageNumber;
      scheduleMicrotask(() {
        if (!mounted || generation != _generation) return;
        final session = _session;
        if (session != null) _detach(session);
        setState(() {
          _engineOverride = PdfViewerEngine.pdfrx;
          _resumePage = page;
          _error = null;
          _generation++;
          _fallbackPending = false;
        });
        try {
          widget.params.onDiagnostic?.call(
            PdfViewerDiagnostic(
              engine: PdfViewerEngine.pdfrx,
              source: 'pdfkit-fallback',
              attempt: 1,
              failure: error.name,
            ),
          );
        } catch (_) {}
      });
      return;
    }
    final recoverableCommand =
        error is PdfViewerException &&
        error.name.startsWith('pdfkit-command-');
    if (!_controller.isReady && !recoverableCommand) {
      scheduleMicrotask(() {
        if (mounted && generation == _generation) setState(() => _error = error);
      });
    }
    try {
      widget.params.onError?.call(error, stackTrace);
    } catch (_) {}
  }

  Future<void> _onPageTap(int pageNumber) async {
    try {
      final layout = _layoutOverride ?? widget.params.layout;
      if (layout.isGrid) {
        final generation = _generation;
        setState(() => _layoutOverride = PdfViewerLayout.vertical);
        widget.params.onLayoutChanged?.call(PdfViewerLayout.vertical);
        await WidgetsBinding.instance.endOfFrame;
        await Future<void>.delayed(const Duration(milliseconds: 400));
        if (!mounted || generation != _generation) return;
        await _controller.goToPage(pageNumber);
      }
      if (mounted) widget.params.onPageTap?.call(pageNumber);
    } catch (error, stack) {
      if (mounted) _onError(_generation, error, stack);
    }
  }

  PdfViewerParams _paramsFor(int generation) {
    final params = widget.params;
    bool current() => mounted && generation == _generation;
    return PdfViewerParams(
      engine: _engine,
      layout: _layoutOverride ?? params.layout,
      margin: params.margin,
      backgroundColor: params.backgroundColor,
      pageShadowColor: params.pageShadowColor,
      matchColor: params.matchColor,
      activeMatchColor: params.activeMatchColor,
      maxCanvasPixels: params.maxCanvasPixels,
      largeDocumentPageCount: params.largeDocumentPageCount,
      largeDocumentMaxCanvasPixels: params.largeDocumentMaxCanvasPixels,
      appVersion: params.appVersion,
      cacheStore: params.cacheStore,
      enableHardwareAcceleratedCanvas: params.enableHardwareAcceleratedCanvas,
      fonts: params.fonts,
      loadingBuilder: params.loadingBuilder,
      errorBuilder: params.errorBuilder,
      onFirstPageRendered: (page) {
        if (current()) params.onFirstPageRendered?.call(page);
      },
      onPageChanged: (page) {
        if (current()) params.onPageChanged?.call(page);
      },
      onExternalLinkTap: (uri) {
        if (current()) params.onExternalLinkTap?.call(uri);
      },
      onDiagnostic: (diagnostic) {
        if (current()) params.onDiagnostic?.call(diagnostic);
      },
      onLayoutChanged: (layout) {
        if (!current()) return;
        setState(() => _layoutOverride = layout);
        params.onLayoutChanged?.call(layout);
      },
    );
  }

  @override
  void dispose() {
    final session = _session;
    if (session != null) _controller.detach(session);
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return widget.params.errorBuilder?.call(context, _error!) ?? const SizedBox.expand();
    }
    final generation = _generation;
    final params = _paramsFor(generation);
    final key = ValueKey((widget.filePath, _engine, generation));
    final initialPage = _resumePage ?? widget.initialPageNumber;
    void attach(PdfEngineSession session) {
      if (mounted && generation == _generation) _attach(session);
    }

    void ready() {
      if (mounted && generation == _generation) widget.params.onViewerReady?.call(_controller);
    }

    void onError(Object error, StackTrace? stack) => _onError(generation, error, stack);
    void onPageTap(int page) {
      if (mounted && generation == _generation) unawaited(_onPageTap(page));
    }

    if (_engine == PdfViewerEngine.pdfKit) {
      return PdfKitEngineView(
        key: key,
        filePath: widget.filePath,
        initialPageNumber: initialPage,
        params: params,
        onAttach: attach,
        onDetach: _detach,
        onReady: ready,
        onError: onError,
        layout: params.layout,
        onPageTap: onPageTap,
      );
    }
    if (_engine == PdfViewerEngine.pdfrx) {
      return PdfrxEngineView(
        key: key,
        filePath: widget.filePath,
        initialPageNumber: initialPage,
        params: params,
        onAttach: attach,
        onDetach: _detach,
        onReady: ready,
        onError: onError,
        layout: params.layout,
        onPageTap: onPageTap,
      );
    }
    return PdfJsEngineView(
      key: key,
      filePath: widget.filePath,
      initialPageNumber: initialPage,
      params: params,
      onAttach: attach,
      onDetach: _detach,
      onReady: ready,
      onError: onError,
      layout: params.layout,
      onPageTap: onPageTap,
    );
  }
}
