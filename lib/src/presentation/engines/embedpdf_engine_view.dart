import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../data/embedpdf/embedpdf_session.dart';
import '../../data/pdfjs/pdfjs_bridge_message.dart';
import '../../data/pdfjs/pdfjs_local_server.dart';
import '../../domain/entity/pdf_viewer_state.dart';
import '../../domain/repo/pdf_engine_session.dart';
import '../pdf_viewer_params.dart';

class EmbedPdfEngineView extends StatefulWidget {
  static Future<void> Function()? debugInjectFatal;
  static Future<void> Function()? debugTerminateWorker;

  const EmbedPdfEngineView({
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
  State<EmbedPdfEngineView> createState() => _EmbedPdfEngineViewState();
}

class _EmbedPdfEngineViewState extends State<EmbedPdfEngineView> with WidgetsBindingObserver {
  static const _blankHtml = '<!doctype html><html></html>';
  static const _cleanupTimeout = Duration(seconds: 1);

  late final EmbedPdfSession _session;
  PdfJsLocalServer? _server;
  WebViewController? _web;
  Timer? _watchdog;
  int _generation = 0;
  String _bridgeSession = '';
  bool _retired = false;
  bool _ready = false;
  bool _painted = false;
  bool _opening = false;
  bool _background = false;
  Duration _silent = Duration.zero;
  Duration _loading = Duration.zero;
  DateTime _lastTick = DateTime.now();
  Future<void>? _retiring;
  late final Future<void> Function() _debugInjectFatal;
  late final Future<void> Function() _debugTerminateWorker;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _background =
        WidgetsBinding.instance.lifecycleState != null &&
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed;
    _session = EmbedPdfSession(send: _send, onError: (error) => _report(error));
    _debugInjectFatal = _session.injectFatal;
    _debugTerminateWorker = _session.terminateWorker;
    if (PdfViewerParams.debugEngineOverride == PdfViewerEngine.embedPdf) {
      EmbedPdfEngineView.debugInjectFatal = _debugInjectFatal;
      EmbedPdfEngineView.debugTerminateWorker = _debugTerminateWorker;
    }
    widget.onAttach(_session);
    unawaited(_start(widget.initialPageNumber));
  }

  bool _current(int generation) => mounted && !_retired && generation == _generation;

  Future<void> _start(int initialPage) async {
    final generation = ++_generation;
    _bridgeSession = 'embedpdf-$generation-${identityHashCode(this)}';
    _ready = false;
    _painted = false;
    _opening = false;
    _silent = Duration.zero;
    _loading = Duration.zero;
    _lastTick = DateTime.now();
    _watchdog?.cancel();
    _watchdog = Timer.periodic(const Duration(seconds: 2), (_) => _tick());
    try {
      final file = File(widget.filePath);
      final size = await file.length();
      if (size <= 0 || size > 64 * 1024 * 1024) {
        _report(
          const PdfViewerException(
            'embedpdf-fatal-document-limit',
            'EmbedPDF document size limit exceeded',
          ),
        );
        return;
      }
      if (!_current(generation)) return;
      final server = await PdfJsLocalServer.start(file: file);
      if (!_current(generation)) {
        try {
          await Zone.root.run(() => server.close().timeout(_cleanupTimeout));
        } catch (_) {}
        return;
      }
      _server = server;
      final web = WebViewController();
      _web = web;
      await web.setJavaScriptMode(JavaScriptMode.unrestricted);
      await web.setBackgroundColor(widget.params.backgroundColor);
      await web.enableZoom(true);
      await web.addJavaScriptChannel(
        pdfJsBridgeChannelName,
        onMessageReceived: (message) {
          if (_current(generation)) _message(message.message, initialPage);
        },
      );
      await web.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            if (uri == null) return NavigationDecision.prevent;
            if ((_retired || generation != _generation) && request.url == 'about:blank') {
              return NavigationDecision.navigate;
            }
            if (!_current(generation)) return NavigationDecision.prevent;
            if (request.isMainFrame && request.url == server.embedPdfViewerUri.toString()) {
              return NavigationDecision.navigate;
            }
            return NavigationDecision.prevent;
          },
          onWebResourceError: (error) {
            if (!_current(generation)) return;
            if (error.errorType == WebResourceErrorType.webContentProcessTerminated) {
              _report(
                const PdfViewerException(
                  'embedpdf-fatal-content-terminated',
                  'EmbedPDF WebView content process terminated',
                ),
              );
            } else if (error.isForMainFrame == true) {
              _report(
                const PdfViewerException(
                  'embedpdf-fatal-resource-load',
                  'EmbedPDF host page failed to load',
                ),
              );
            }
          },
        ),
      );
      if (!_current(generation)) {
        await _retireResources();
        return;
      }
      setState(() => _web = web);
      await web.loadRequest(server.embedPdfViewerUri);
    } catch (_) {
      if (_current(generation)) {
        _report(
          const PdfViewerException('embedpdf-fatal-startup', 'EmbedPDF initialization failed'),
        );
      }
    }
  }

  void _tick() {
    final now = DateTime.now();
    final elapsed = now.difference(_lastTick);
    _lastTick = now;
    if (_background || _retired || !mounted) return;
    _silent += elapsed;
    if (!_painted) _loading += elapsed;
    if (!_painted && _loading >= const Duration(seconds: 45)) {
      _report(
        PdfViewerException(
          _ready ? 'embedpdf-fatal-render-timeout' : 'embedpdf-fatal-startup-timeout',
          'EmbedPDF initialization or first render timed out',
        ),
      );
    } else if (_painted && _silent >= const Duration(seconds: 30)) {
      _report(
        const PdfViewerException('embedpdf-fatal-worker-hang', 'EmbedPDF heartbeat timed out'),
      );
    }
  }

  Future<void> _send(String type, Map<String, Object?> payload) async {
    if (_retired || !mounted) return;
    final web = _web;
    if (web == null) return;
    try {
      await web.runJavaScript(
        pdfJsBridgeCommandScript(type, {...payload, 'session': _bridgeSession}),
      );
    } catch (_) {
      if (!_retired && mounted) {
        _report(
          const PdfViewerException(
            'embedpdf-command-transport',
            'EmbedPDF command transport failed',
          ),
        );
      }
    }
  }

  void _message(String raw, int initialPage) {
    if (raw.length > 16 * 1024 * 1024) {
      _report(
        const PdfViewerException(
          'embedpdf-fatal-bridge-limit',
          'EmbedPDF bridge message limit exceeded',
        ),
      );
      return;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return;
    }
    if (decoded is! Map<String, Object?> || decoded['v'] != 1) return;
    final bootstrap =
        !_opening &&
        decoded['session'] == null &&
        {'bridgeReady', 'tier', 'error'}.contains(decoded['type']);
    if (decoded['session'] != _bridgeSession && !bootstrap) return;
    _silent = Duration.zero;
    if (decoded['type'] == 'heartbeat') return;
    if (decoded['type'] == 'capabilities') {
      _diagnostic(capabilities: 'modules1.worker1.canvas1.wasm-compiled1.sign-extension1');
      return;
    }
    final message = PdfJsBridgeMessage.tryParse(raw);
    if (message == null) return;
    _session.accept(message);
    switch (message) {
      case PdfJsBridgeReadyMessage():
        if (!_opening) {
          _opening = true;
          final server = _server;
          if (server == null) return;
          unawaited(
            _send('open', {
              'config': {
                'session': _bridgeSession,
                'documentUrl': server.documentUri.toString(),
                'initialPage': initialPage,
                'columns': widget.layout.columns,
                'margin': widget.params.margin,
                'backgroundColor': _css(widget.params.backgroundColor),
                'pageShadowColor': _css(widget.params.pageShadowColor),
                'matchColor': _css(widget.params.matchColor),
                'activeMatchColor': _css(widget.params.activeMatchColor),
                'maxCanvasPixels': widget.params.maxCanvasPixels,
                'largeDocumentPageCount': widget.params.largeDocumentPageCount,
                'largeDocumentMaxCanvasPixels': widget.params.largeDocumentMaxCanvasPixels,
              },
            }),
          );
          unawaited(_send('setActive', {'active': !_background}));
        }
      case PdfJsReadyMessage():
        setState(() => _ready = true);
        widget.onReady();
      case PdfJsFirstPageRenderedMessage(:final pageNumber):
        _painted = true;
        widget.params.onFirstPageRendered?.call(pageNumber);
      case PdfJsPageChangedMessage(:final pageNumber):
        widget.params.onPageChanged?.call(pageNumber);
      case PdfJsPageTapMessage(:final pageNumber):
        widget.onPageTap(pageNumber);
      case PdfJsExternalLinkMessage(:final url):
        if ({'http', 'https', 'mailto', 'tel'}.contains(url.scheme.toLowerCase())) {
          widget.params.onExternalLinkTap?.call(url);
        }
      case PdfJsErrorMessage(:final name):
        final safeName = RegExp(r'^embedpdf-(fatal|command)-[a-z-]+$').hasMatch(name)
            ? name
            : name == 'EngineUnsupported'
            ? 'embedpdf-fatal-unsupported'
            : 'embedpdf-fatal-bootstrap';
        _report(PdfViewerException(safeName, safeName));
      default:
        break;
    }
  }

  void _diagnostic({String? capabilities, String? failure}) {
    try {
      widget.params.onDiagnostic?.call(
        PdfViewerDiagnostic(
          engine: widget.params.engine,
          bundle: 'embedpdf-2.15.1',
          source: 'worker',
          capabilities: capabilities,
          failure: failure,
          canvasHwa: 'bounded-canvas2d',
        ),
      );
    } catch (_) {}
  }

  void _report(PdfViewerException error) {
    if (_retired || !mounted) return;
    if (!error.name.startsWith('embedpdf-fatal-')) {
      widget.onError(error, null);
      return;
    }
    _retired = true;
    _session.retire();
    _watchdog?.cancel();
    _diagnostic(failure: error.name);
    unawaited(
      _retireResources().whenComplete(() {
        if (mounted) widget.onError(error, null);
      }),
    );
  }

  Future<void> _retireResources() => _retiring ??= _releaseResources();

  Future<void> _releaseResources() async {
    final web = _web;
    final server = _server;
    _web = null;
    _server = null;
    if (web != null) {
      try {
        await web
            .runJavaScript(pdfJsBridgeCommandScript('dispose', {'session': _bridgeSession}))
            .timeout(_cleanupTimeout);
      } catch (_) {}
      try {
        await web.removeJavaScriptChannel(pdfJsBridgeChannelName).timeout(_cleanupTimeout);
      } catch (_) {}
      try {
        await web.loadHtmlString(_blankHtml).timeout(_cleanupTimeout);
      } catch (_) {}
    }
    try {
      await Zone.root.run(() => server?.close().timeout(_cleanupTimeout));
    } catch (_) {}
  }

  @override
  void didUpdateWidget(EmbedPdfEngineView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.layout != oldWidget.layout) unawaited(_session.setLayout(widget.layout));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _background = state != AppLifecycleState.resumed;
    _lastTick = DateTime.now();
    _silent = Duration.zero;
    unawaited(_send('setActive', {'active': !_background}));
    if (!_background && !_retired) unawaited(_resume());
  }

  Future<void> _resume() async {
    final server = _server;
    if (server == null) return;
    try {
      if (await server.ensureListening()) {
        final page = _session.state.pageNumber ?? widget.initialPageNumber;
        ++_generation;
        await _retireResources();
        if (!mounted || _retired) return;
        _retiring = null;
        _session.reset(pageNumber: page);
        await _start(page);
      }
    } catch (_) {
      _report(
        const PdfViewerException('embedpdf-fatal-resume', 'EmbedPDF local server resume failed'),
      );
    }
  }

  static String _css(Color color) =>
      'rgba(${(color.r * 255).round()},${(color.g * 255).round()},${(color.b * 255).round()},${color.a.toStringAsFixed(3)})';

  @override
  void dispose() {
    _retired = true;
    ++_generation;
    if (identical(EmbedPdfEngineView.debugInjectFatal, _debugInjectFatal)) {
      EmbedPdfEngineView.debugInjectFatal = null;
    }
    if (identical(EmbedPdfEngineView.debugTerminateWorker, _debugTerminateWorker)) {
      EmbedPdfEngineView.debugTerminateWorker = null;
    }
    WidgetsBinding.instance.removeObserver(this);
    _watchdog?.cancel();
    widget.onDetach(_session);
    _session.dispose();
    unawaited(_retireResources());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      if (_web case final web?)
        WebViewWidget(
          controller: web,
          gestureRecognizers: const {
            Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new),
          },
        ),
      if (!_ready) widget.params.loadingBuilder?.call(context) ?? const SizedBox.shrink(),
    ],
  );
}
