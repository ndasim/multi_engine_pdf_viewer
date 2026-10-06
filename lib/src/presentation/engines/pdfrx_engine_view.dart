import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:pdfrx/pdfrx.dart' as native;

import '../../data/pdfrx/pdf_font_fallback.dart';
import '../../data/pdfrx/pdf_named_action_handler.dart';
import '../../data/pdfrx/pdf_viewer_helper.dart';
import '../../data/pdfrx/pdfrx_session.dart';
import '../../domain/entity/pdf_viewer_state.dart';
import '../../domain/repo/pdf_engine_session.dart';
import '../pdf_viewer_params.dart';

class PdfrxEngineView extends StatefulWidget {
  const PdfrxEngineView({
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
  State<PdfrxEngineView> createState() => _PdfrxEngineViewState();
}

class _PdfrxEngineViewState extends State<PdfrxEngineView> {
  static const _sizeDelegate = native.PdfViewerSizeDelegateProviderLegacy(
    useAlternativeFitScaleAsMinScale: false,
    onePassRenderingScaleThreshold: 1.5,
  );
  static final _fontRegistrations = <String, PdfFontFallback>{};
  late final PdfrxSession _session;
  late final PdfNamedActionHandler _namedActions;
  late final native.PdfDocumentRef _documentRef;
  late PdfViewerHelper _layout;
  native.PdfDocument? _document;
  bool _paintReported = false;

  @override
  void initState() {
    super.initState();
    _session = PdfrxSession();
    _namedActions = PdfNamedActionHandler(onError: _error);
    _layout = PdfViewerHelper(pagesPerRow: widget.layout.columns, onError: _error);
    _documentRef = native.PdfDocumentRefByLoader((_) async {
      try {
        await native.pdfrxFlutterInitialize();
        final fonts = widget.params.fonts;
        if (fonts.isNotEmpty) {
          final key = fonts
              .map((font) => '${font.face}|${font.asset}|${font.resolvedFace}')
              .join('\n');
          final registration = _fontRegistrations.putIfAbsent(
            key,
            () => PdfFontFallback(faces: List.unmodifiable(fonts)),
          );
          try {
            await registration.ensureFallbackFonts();
          } catch (_) {
            try {
              widget.params.onDiagnostic?.call(
                const PdfViewerDiagnostic(
                  engine: PdfViewerEngine.pdfrx,
                  bundle: 'pdfium',
                  failure: 'FontRegistrationFailed',
                ),
              );
            } catch (_) {}
          }
        }
        return await native.PdfDocument.openFile(widget.filePath, useProgressiveLoading: true);
      } catch (error, stack) {
        _error(error, stack);
        rethrow;
      }
    }, key: native.PdfDocumentRefKey(_cacheKey()));
    widget.onAttach(_session);
  }

  String _cacheKey() {
    try {
      final stat = File(widget.filePath).statSync();
      return '${widget.filePath}#${stat.modified.millisecondsSinceEpoch}-${stat.size}';
    } catch (_) {
      return widget.filePath;
    }
  }

  void _error(Object error, StackTrace? stack) {
    if (mounted) widget.onError(error, stack);
  }

  void _pageChanged(int? page) {
    if (!mounted || page == null) return;
    _session.publish();
    widget.params.onPageChanged?.call(page);
  }

  @override
  void didUpdateWidget(PdfrxEngineView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.layout != widget.layout) {
      _layout.dispose();
      _layout = PdfViewerHelper(pagesPerRow: widget.layout.columns, onError: _error);
      unawaited(
        widget.layout.isGrid
            ? _layout.zoomDownAfterLayoutChange(_session.controller)
            : _layout.fitPageToWidth(_session.controller),
      );
    }
  }

  Future<void> _ready(native.PdfDocument document, native.PdfViewerController controller) async {
    try {
      final outline = await document.loadOutline();
      if (!mounted || !identical(_document, document)) return;
      _session.ready(outline);
      setState(() {});
      try {
        widget.params.onDiagnostic?.call(
          const PdfViewerDiagnostic(engine: PdfViewerEngine.pdfrx, bundle: 'pdfium'),
        );
      } catch (_) {}
      widget.onReady();
    } catch (error, stack) {
      _error(error, stack);
    }
  }

  @override
  void dispose() {
    widget.onDetach(_session);
    _namedActions.dispose();
    _layout.dispose();
    _session.dispose();
    super.dispose();
  }

  bool get _conservative =>
      !_session.state.isReady ||
      _session.controller.pageCount >= widget.params.largeDocumentPageCount;

  @override
  Widget build(BuildContext context) {
    final params = widget.params;
    return native.PdfViewer(
      _documentRef,
      controller: _session.controller,
      initialPageNumber: widget.initialPageNumber,
      params: native.PdfViewerParams(
        margin: params.margin,
        backgroundColor: params.backgroundColor,
        matchTextColor: params.matchColor,
        activeMatchTextColor: params.activeMatchColor,
        onPageChanged: _pageChanged,
        sizeDelegateProvider: widget.layout.isGrid ? null : _sizeDelegate,
        linkHandlerParams: native.PdfLinkHandlerParams(
          linkColor: const Color(0x00000000),
          laidOverPageOverlays: false,
          onLinkTap: (link) async {
            final uri = link.url;
            if (uri != null && const {'http', 'https', 'mailto', 'tel'}.contains(uri.scheme)) {
              params.onExternalLinkTap?.call(uri);
            } else if (link.dest != null) {
              await _session.controller.goToDest(link.dest);
            }
          },
        ),
        interactionEndFrictionCoefficient: .4,
        onePassRenderingSizeThreshold: _conservative ? 900 : 1400,
        maxImageBytesCachedOnMemory: (_conservative ? 12 : 24) * 1024 * 1024,
        horizontalCacheExtent: _conservative ? .15 : .5,
        verticalCacheExtent: _conservative ? .1 : .25,
        layoutPages: _layout.getLayoutFunction(
          widget.layout.isGrid ? PdfLayoutType.triplePages : PdfLayoutType.singlePage,
          MediaQuery.sizeOf(context),
        ),
        onViewerReady: _ready,
        onDocumentChanged: (document) {
          _document = document;
          if (document == null) {
            _namedActions.dispose();
            _session.reset();
          }
        },
        pagePaintCallbacks: [
          ..._layout.buildPagePaintCallbacks(_session.searcher),
          (canvas, rect, page) {
            if (_paintReported) return;
            _paintReported = true;
            scheduleMicrotask(() {
              if (mounted) params.onFirstPageRendered?.call(page.pageNumber);
            });
          },
        ],
        loadingBannerBuilder: (context, downloaded, total) =>
            params.loadingBuilder?.call(context) ?? const SizedBox.shrink(),
        errorBannerBuilder: (context, error, stack, documentRef) =>
            params.errorBuilder?.call(context, error) ?? const SizedBox.shrink(),
        onViewSizeChanged: (size, oldSize, controller) {
          unawaited(
            widget.layout.isGrid
                ? _layout.handleTriplePagesViewSizeChange(controller: controller)
                : _layout.handleSinglePageViewSizeChange(viewSize: size, controller: controller),
          );
        },
        getPageRenderingScale: (context, page, controller, scale) {
          final limit = _conservative ? 2048.0 : 4096.0;
          return math.min(scale, math.min(limit / page.width, limit / page.height));
        },
        pageOverlaysBuilder: (context, rect, page) => [
          native.PdfOverlayInteractionRegion(
            child: const SizedBox.expand(),
            onDoubleTap: (details) {
              if (!_session.controller.isReady) return false;
              final local = _session.controller.globalToLocal(details.globalPosition);
              if (local == null) return false;
              unawaited(
                _session.controller.zoomUpOnLocalPosition(localPosition: local, loop: true),
              );
              return true;
            },
            onTap: (details) {
              if (widget.layout.isGrid) {
                widget.onPageTap(page.pageNumber);
                return true;
              }
              unawaited(
                _namedActions.handleTap(
                  document: _document,
                  page: page,
                  pageRect: rect,
                  pagePosition: details.localPosition,
                  controller: _session.controller,
                ),
              );
              return false;
            },
          ),
        ],
      ),
    );
  }
}
