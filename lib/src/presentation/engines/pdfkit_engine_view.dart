import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' show CircularProgressIndicator;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../data/pdfkit/pdfkit_session.dart';
import '../../domain/entity/pdf_viewer_state.dart';
import '../../domain/repo/pdf_engine_session.dart';
import '../pdf_viewer_params.dart';

class PdfKitEngineView extends StatefulWidget {
  const PdfKitEngineView({
    required this.filePath,
    required this.initialPageNumber,
    required this.params,
    required this.layout,
    required this.onAttach,
    required this.onDetach,
    required this.onReady,
    required this.onError,
    required this.onPageTap,
    super.key,
  });

  static const viewType = 'multi_engine_pdf_viewer/pdfkit';
  final String filePath;
  final int initialPageNumber;
  final PdfViewerParams params;
  final PdfViewerLayout layout;
  final ValueChanged<PdfEngineSession> onAttach;
  final ValueChanged<PdfEngineSession> onDetach;
  final VoidCallback onReady;
  final void Function(Object, StackTrace?) onError;
  final ValueChanged<int> onPageTap;

  @override
  State<PdfKitEngineView> createState() => _PdfKitEngineViewState();
}

class _PdfKitEngineViewState extends State<PdfKitEngineView> {
  PdfKitSession? _session;
  bool _ready = false;
  bool _paintReported = false;
  int? _paintedPage;

  Map<String, Object> get _options => {
    'columns': widget.layout.columns,
    'margin': widget.params.margin,
    'backgroundColor': widget.params.backgroundColor.toARGB32(),
    'pageShadowColor': widget.params.pageShadowColor.toARGB32(),
    'matchColor': widget.params.matchColor.toARGB32(),
    'activeMatchColor': widget.params.activeMatchColor.toARGB32(),
    'maxCanvasPixels': widget.params.maxCanvasPixels,
    'largeDocumentPageCount': widget.params.largeDocumentPageCount,
    'largeDocumentMaxCanvasPixels': widget.params.largeDocumentMaxCanvasPixels,
  };

  @override
  void initState() {
    super.initState();
    if (defaultTargetPlatform != TargetPlatform.iOS) {
      scheduleMicrotask(() {
        if (mounted) {
          widget.onError(
            const PdfViewerException(
              'pdfkit-unsupported-platform',
              'PDFKit is available only on iOS.', // TODO: use localization
            ),
            null,
          );
        }
      });
    }
  }

  Future<void> _created(int id) async {
    if (!mounted) return;
    final channel = MethodChannel('${PdfKitEngineView.viewType}/$id');
    final session = PdfKitSession(
      channel,
      onError: (error, stack) {
        if (mounted) widget.onError(error, stack);
      },
    );
    _session = session;
    channel.setMethodCallHandler(_nativeCall);
    widget.onAttach(session);
    if (!await session.open() || !mounted) return;
    _ready = true;
    setState(() {});
    widget.params.onDiagnostic?.call(
      const PdfViewerDiagnostic(engine: PdfViewerEngine.pdfKit, bundle: 'pdfkit'),
    );
    widget.onReady();
    _reportPaint();
    unawaited(session.loadOutline());
    await session.configure(_options);
  }

  Future<void> _nativeCall(MethodCall call) async {
    if (!mounted) return;
    final session = _session;
    final previousPage = session?.state.pageNumber;
    session?.accept(call);
    switch (call.method) {
      case 'onPageChanged':
        final page = session?.state.pageNumber;
        if (_ready && page != null && page != previousPage) widget.params.onPageChanged?.call(page);
      case 'onFirstPageRendered':
        if (call.arguments case final int page when page > 0) {
          _paintedPage = page;
          _reportPaint();
        }
      case 'onPageTap':
        if (call.arguments case final int page when page > 0) widget.onPageTap(page);
      case 'onGridClosed':
        widget.params.onLayoutChanged?.call(PdfViewerLayout.vertical);
      case 'onExternalLinkTap':
        if (call.arguments case final String url) {
          final uri = Uri.tryParse(url);
          if (uri != null &&
              const {'http', 'https', 'mailto', 'tel'}.contains(uri.scheme.toLowerCase())) {
            widget.params.onExternalLinkTap?.call(uri);
          }
        }
      case 'onRenderError' || 'onSearchError':
        widget.onError(
          PdfViewerException(
            call.method == 'onRenderError' ? 'pdfkit-command-render' : 'pdfkit-command-search',
            'PDFKit operation failed.', // TODO: use localization
          ),
          null,
        );
    }
  }

  void _reportPaint() {
    final page = _paintedPage;
    if (!_ready || page == null || _paintReported) return;
    setState(() => _paintReported = true);
    widget.params.onFirstPageRendered?.call(page);
  }

  @override
  void didUpdateWidget(PdfKitEngineView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_ready) unawaited(_session?.configure(_options));
  }

  @override
  void dispose() {
    final session = _session;
    if (session != null) {
      widget.onDetach(session);
      session.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.iOS) return const SizedBox.expand();
    return Stack(
      fit: StackFit.expand,
      children: [
        UiKitView(
          viewType: PdfKitEngineView.viewType,
          layoutDirection: Directionality.of(context),
          creationParams: {
            'filePath': widget.filePath,
            'initialPage': widget.initialPageNumber,
            ..._options,
          },
          creationParamsCodec: const StandardMessageCodec(),
          onPlatformViewCreated: _created,
          gestureRecognizers: {Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new)},
        ),
        if (!_paintReported)
          IgnorePointer(
            child:
                widget.params.loadingBuilder?.call(context) ??
                const Center(child: CircularProgressIndicator.adaptive()),
          ),
      ],
    );
  }
}
