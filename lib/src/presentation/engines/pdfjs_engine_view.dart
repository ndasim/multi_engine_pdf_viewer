import 'package:flutter/widgets.dart';

import '../../domain/entity/pdf_viewer_state.dart';
import '../../domain/repo/pdf_engine_session.dart';
import '../../data/pdfjs/pdfjs_session.dart';
import '../../data/pdfjs/pdfjs_tier.dart';
import '../../data/pdfjs/pdfjs_viewer.dart';
import '../../data/pdfjs/pdfjs_viewer_params.dart';
import '../pdf_viewer_params.dart';

class PdfJsEngineView extends StatefulWidget {
  const PdfJsEngineView({
    required this.filePath,
    required this.initialPageNumber,
    required this.params,
    required this.onAttach,
    required this.onDetach,
    required this.onReady,
    required this.onError,
    required this.layout,
    required this.onPageTap,
    super.key,
  });

  final String filePath;
  final int initialPageNumber;
  final PdfViewerParams params;
  final ValueChanged<PdfEngineSession> onAttach;
  final ValueChanged<PdfEngineSession> onDetach;
  final VoidCallback onReady;
  final void Function(Object error, StackTrace? stackTrace) onError;
  final PdfViewerLayout layout;
  final ValueChanged<int> onPageTap;

  @override
  State<PdfJsEngineView> createState() => _PdfJsEngineViewState();
}

class _PdfJsEngineViewState extends State<PdfJsEngineView> {
  late final PdfJsSession _session;

  @override
  void initState() {
    super.initState();
    _session = PdfJsSession();
    widget.onAttach(_session);
  }

  @override
  void dispose() {
    widget.onDetach(_session);
    _session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final params = widget.params;
    return PdfJsViewer.file(
      widget.filePath,
      controller: _session.controller,
      initialPageNumber: widget.initialPageNumber,
      params: PdfJsViewerParams(
        layout: widget.layout.isGrid
            ? PdfJsLayout.grid(columns: widget.layout.columns)
            : PdfJsLayout.vertical,
        margin: params.margin,
        backgroundColor: params.backgroundColor,
        pageShadowColor: params.pageShadowColor,
        matchColor: params.matchColor,
        activeMatchColor: params.activeMatchColor,
        maxCanvasPixels: params.maxCanvasPixels,
        largeDocumentPageCount: params.largeDocumentPageCount,
        largeDocumentMaxCanvasPixels: params.largeDocumentMaxCanvasPixels,
        appVersion: params.appVersion,
        tierStore: params.cacheStore == null
            ? const PdfJsInMemoryTierStore()
            : _CacheStore(params.cacheStore!),
        enableHardwareAcceleratedCanvas: params.enableHardwareAcceleratedCanvas,
        loadingBuilder: params.loadingBuilder,
        onViewerReady: (_) => widget.onReady(),
        onFirstPageRendered: params.onFirstPageRendered,
        onPageChanged: params.onPageChanged,
        onPageTap: widget.onPageTap,
        onExternalLinkTap: params.onExternalLinkTap,
        onError: (error, stack) {
          if (!mounted) return;
          widget.onError(PdfViewerException(error.runtimeType.toString(), error.toString()), stack);
        },
        onTierResolved: (resolution) => params.onDiagnostic?.call(
          PdfViewerDiagnostic(
            engine: PdfViewerEngine.pdfJs,
            bundle: resolution.bundle?.id,
            source: resolution.source.id,
            attempt: resolution.attempt,
            capabilities: resolution.capabilities,
            probeSupported: resolution.probeSupported?.id,
            failure: resolution.failure,
            canvasHwa: resolution.canvasHwa,
          ),
        ),
      ),
    );
  }
}

class _CacheStore implements PdfJsTierStore {
  const _CacheStore(this.store);
  final PdfViewerCacheStore store;
  @override
  Future<String?> read(String key) => store.read(key);
  @override
  Future<void> write(String key, String value) => store.write(key, value);
  @override
  Future<void> delete(String key) => store.delete(key);
}
