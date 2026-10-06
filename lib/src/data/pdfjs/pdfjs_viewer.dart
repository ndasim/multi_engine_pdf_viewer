import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:multi_engine_pdf_viewer/src/data/pdfjs/pdfjs_bridge_message.dart';
import 'package:multi_engine_pdf_viewer/src/data/pdfjs/pdfjs_bundle.dart';
import 'package:multi_engine_pdf_viewer/src/data/pdfjs/pdfjs_local_server.dart';
import 'package:multi_engine_pdf_viewer/src/data/pdfjs/pdfjs_outline_node.dart';
import 'package:multi_engine_pdf_viewer/src/data/pdfjs/pdfjs_tier.dart';
import 'package:multi_engine_pdf_viewer/src/data/pdfjs/pdfjs_viewer_params.dart';
import 'package:webview_flutter/webview_flutter.dart';

part 'pdfjs_text_searcher.dart';
part 'pdfjs_viewer_controller.dart';

/// Displays a local PDF file with the bundled PDF.js build.
///
/// Give the widget a new [Key] to open a different file.
class PdfJsViewer extends StatefulWidget {
  const PdfJsViewer.file(
    this.filePath, {
    super.key,
    this.controller,
    this.initialPageNumber = 1,
    this.params = const PdfJsViewerParams(),
  });

  final String filePath;
  final PdfJsViewerController? controller;
  final int initialPageNumber;
  final PdfJsViewerParams params;

  @override
  State<PdfJsViewer> createState() => _PdfJsViewerState();
}

class _PdfJsViewerState extends State<PdfJsViewer> with WidgetsBindingObserver {
  static const Set<String> _externalSchemes = {'http', 'https', 'mailto', 'tel'};

  late PdfJsViewerController _controller;
  bool _ownsController = false;
  PdfJsLocalServer? _server;
  WebViewController? _webController;
  bool _isReady = false;
  int? _reloadPageNumber;

  // ---- Self-healing bundle chain ----------------------------------------

  late final PdfJsTierCache _tierCache = PdfJsTierCache(
    store: widget.params.tierStore,
    appVersion: widget.params.appVersion,
  );

  /// Bundle pinned into the host-page URL. `null` lets `bootstrap.js` decide
  /// by capability probe, which is the cold, uncached path.
  PdfJsBundle? _pinnedBundle;

  /// Bundles already tried in this viewer's lifetime, so the chain cannot loop.
  final Set<PdfJsBundle> _attemptedBundles = <PdfJsBundle>{};

  /// 0 for the first load, 1 for the first downgrade, and so on.
  int _attempt = 0;

  /// Capability signature from the cache entry the pin came from, and the one
  /// `bootstrap.js` last reported. A difference means the engine changed under
  /// a cached answer — on Android the System WebView updates without any OS
  /// version change, which the cache key cannot see.
  String? _cachedCapabilities;
  String? _reportedCapabilities;

  /// Set when [_pinnedBundle] came from [PdfJsBundleSelector.debugBundleOverride]
  /// (harness-only, forced profiling). A forced tier must still be allowed to
  /// load and downgrade, but it must never overwrite the real per-device cache
  /// an unforced `pdfJsAuto` run would otherwise read.
  bool _pinnedFromOverride = false;

  /// Fires when the host page has not said anything at all.
  ///
  /// `bootstrap.js` owns the two in-page failure shapes, but it can only
  /// report them if it ran. If `index.html` or `bootstrap.js` itself fails to
  /// load there is nothing left in the page to notice, and since index.html no
  /// longer contains a static module script the result would be a permanently
  /// blank page — the exact bug class this work exists to remove. Well past
  /// `bootstrap.js`'s own 20 s timeout, so a slow device reports through the
  /// in-page path first and this only catches "the page never ran".
  static const Duration _bootstrapWatchdog = Duration(seconds: 30);

  Timer? _bootstrapTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = widget.controller ?? PdfJsViewerController();
    _ownsController = widget.controller == null;
    _controller._attach(this);
    unawaited(_start());
  }

  @override
  void didUpdateWidget(PdfJsViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != oldWidget.controller) {
      _controller._detach(this);
      if (_ownsController) _controller.dispose();
      _controller = widget.controller ?? PdfJsViewerController();
      _ownsController = widget.controller == null;
      _controller._attach(this);
    }
    if (widget.params.layout != oldWidget.params.layout) {
      unawaited(_runCommand('setLayout', {'columns': widget.params.layout.columns}));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_ensureServer());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller._detach(this);
    if (_ownsController) _controller.dispose();
    _bootstrapTimer?.cancel();
    _bootstrapTimer = null;
    unawaited(_server?.close());
    _server = null;
    _webController = null;
    super.dispose();
  }

  Future<void> _start() async {
    try {
      // An explicit override pins the tier outright, ahead of both the cache
      // and the probe. Without this the override only reached the server's
      // seed, which the probe then overrode by injecting its own tier into the
      // page — so a "forced" profiling mode did not actually force anything
      // and the matrix measured whatever the probe chose. The downgrade chain
      // stays active underneath, so a forced tier that cannot run still
      // recovers; the telemetry is what makes the difference observable.
      final override = PdfJsBundleSelector.debugBundleOverride;
      if (override != null) {
        _pinnedBundle = override;
        _pinnedFromOverride = true;
        _attemptedBundles.add(override);
        _publishResolution(override, PdfJsTierSource.override);
      } else {
        // Read the cache before the server so the very first host-page request
        // can already be pinned: a device that failed once must not pay the
        // failure cost on every open.
        final cached = await _tierCache.read();
        if (!mounted) return;
        if (cached != null) {
          _pinnedBundle = cached.bundle;
          _cachedCapabilities = cached.capabilities;
          _attemptedBundles.add(cached.bundle);
          _publishResolution(cached.bundle, PdfJsTierSource.cache);
        }
      }

      final server = await PdfJsLocalServer.start(file: File(widget.filePath));
      if (!mounted) {
        await server.close();
        return;
      }
      _server = server;

      final webController = WebViewController();
      await webController.setJavaScriptMode(JavaScriptMode.unrestricted);
      await webController.setBackgroundColor(widget.params.backgroundColor);
      await webController.enableZoom(false);
      await webController.addJavaScriptChannel(
        pdfJsBridgeChannelName,
        onMessageReceived: (message) => _onMessage(message.message),
      );
      await webController.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: _onNavigationRequest,
          onWebResourceError: _onWebResourceError,
        ),
      );
      if (!mounted) return;

      setState(() => _webController = webController);
      _armBootstrapWatchdog();
      await webController.loadRequest(server.viewerUriFor(_pinnedBundle));
    } catch (e, s) {
      _reportError(e, s);
    }
  }

  /// The one place `onError` is called from.
  ///
  /// Every URL this widget hands to the platform embeds the server's path
  /// token, and a platform load failure puts the URL it was given into its
  /// message, so an unredacted report lands the token in the crash reporter.
  /// Redaction only rewraps the error when the token was actually present, so
  /// ordinary failures keep their type and their crash-report grouping.
  void _reportError(Object error, StackTrace? stackTrace) {
    final onError = widget.params.onError;
    if (onError == null) return;
    final server = _server;
    if (server == null) {
      onError(error, stackTrace);
      return;
    }
    final raw = error.toString();
    final redacted = server.redact(raw);
    if (redacted == raw) {
      onError(error, stackTrace);
      return;
    }
    onError(PdfJsRedactedException(error.runtimeType.toString(), redacted), stackTrace);
  }

  String _redact(String text) => _server?.redact(text) ?? text;

  Future<void> _ensureServer() async {
    final server = _server;
    if (server == null || _webController == null) return;
    try {
      if (await server.ensureListening()) await _reload();
    } catch (e, s) {
      _reportError(e, s);
    }
  }

  /// Reloads the host page and reopens the document at the current page.
  Future<void> _reload() async {
    final server = _server;
    final webController = _webController;
    if (!mounted || server == null || webController == null) return;

    _reloadPageNumber = _controller.pageNumber;
    _controller._reset();
    setState(() => _isReady = false);
    _armBootstrapWatchdog();
    await webController.loadRequest(server.viewerUriFor(_pinnedBundle));
  }

  /// `_reload` with its own error handling.
  ///
  /// Both callers are fire-and-forget — the content-process-terminated
  /// recovery path and the downgrade chain — and `loadRequest` can throw, so
  /// without this a failure here becomes an unhandled asynchronous error
  /// instead of a reported one. It is also the path the chain depends on, so a
  /// silent failure here would strand the viewer on a dead bundle.
  Future<void> _reloadGuarded() async {
    try {
      await _reload();
    } catch (e, s) {
      _reportError(e, s);
    }
  }

  Future<void> _runCommand(String type, [Map<String, Object?> payload = const {}]) async {
    final webController = _webController;
    if (webController == null) return;
    try {
      await webController.runJavaScript(pdfJsBridgeCommandScript(type, payload));
    } catch (e, s) {
      _reportError(e, s);
    }
  }

  void _armBootstrapWatchdog() {
    _bootstrapTimer?.cancel();
    _bootstrapTimer = Timer(_bootstrapWatchdog, () {
      if (!mounted || _isReady) return;
      // Record what was actually attempted. With no probe answer the only
      // thing that chose a bundle is the pin, or failing that the selector's
      // version-table seed — so this is the one path where `versionTable` is
      // the honest source, and operations needs it to tell "the probe said
      // legacy" apart from "the page never ran at all".
      _publishResolution(
        _pinnedBundle ?? _server?.seedBundle,
        _pinnedBundle == null ? PdfJsTierSource.versionTable : PdfJsTierSource.cache,
        failure: 'ViewerBootstrapTimeout',
      );
      // Not routed through the downgrade chain on purpose: a different bundle
      // cannot help when the page never executed a line of our own script.
      _reportError(
        const PdfJsViewerException(
          'ViewerBootstrapTimeout',
          'the host page never reported anything; bootstrap.js did not run',
        ),
        null,
      );
    });
  }

  void _onMessage(String raw) {
    if (!mounted) return;
    final message = PdfJsBridgeMessage.tryParse(raw);
    // Any message at all proves bootstrap.js ran; from here on the in-page
    // detectors own the failure modes.
    if (message != null) {
      _bootstrapTimer?.cancel();
      _bootstrapTimer = null;
    }
    switch (message) {
      case null:
        return;
      case PdfJsBridgeReadyMessage():
        unawaited(_sendOpen());
      case PdfJsReadyMessage(:final pageCount, :final pageNumber):
        _reloadPageNumber = null;
        _confirmTier();
        _controller._onReady(pageCount: pageCount, pageNumber: pageNumber);
        setState(() => _isReady = true);
        widget.params.onViewerReady?.call(_controller);
      case PdfJsFirstPageRenderedMessage(:final pageNumber):
        widget.params.onFirstPageRendered?.call(pageNumber);
      case PdfJsOutlineMessage(:final items):
        _controller._onOutline(items);
      case PdfJsPageChangedMessage(:final pageNumber):
        _controller._onPageChanged(pageNumber);
        widget.params.onPageChanged?.call(pageNumber);
      case PdfJsFindStateMessage():
        _controller._onFindState(message);
      case PdfJsPageTapMessage(:final pageNumber):
        widget.params.onPageTap?.call(pageNumber);
      case PdfJsExternalLinkMessage(:final url):
        _openExternal(url);
      case PdfJsTierMessage():
        _onTierMessage(message);
      case PdfJsErrorMessage():
        _onErrorMessage(message);
    }
  }

  // ---- The chain ---------------------------------------------------------

  /// `bootstrap.js` reporting the capability probe's answer.
  void _onTierMessage(PdfJsTierMessage message) {
    _reportedCapabilities = message.capabilities;

    if (!message.isPinned) {
      // Cold path: the probe decided, before any module was imported.
      // State first, telemetry last — see _publishResolution.
      final bundle = message.bundle;
      if (bundle != null) {
        _pinnedBundle = bundle;
        _attemptedBundles.add(bundle);
        unawaited(_tierCache.write(bundle, message.capabilities));
      }
      _publishResolution(bundle, PdfJsTierSource.probe, probeSupported: message.probeSupported);
      return;
    }

    // Pinned path: the probe ran alongside the real viewer, so it costs
    // nothing on the critical path and its only job is to notice that the
    // engine changed under a cached answer. Only a changed signature
    // invalidates — otherwise a tier reached by downgrade (where the probe was
    // too optimistic) would be overwritten by the probe on every open and loop.
    if (_cachedCapabilities == null || message.capabilities == _cachedCapabilities) return;
    final supported = message.probeSupported;
    if (supported == null) return;
    _cachedCapabilities = message.capabilities;
    unawaited(_tierCache.write(supported, message.capabilities));
  }

  void _onErrorMessage(PdfJsErrorMessage message) {
    // PDF.js and `bootstrap.js` both embed the document URL, and with it the
    // token, in messages.
    final text = _redact(message.message);

    if (!message.isBundleSuspect(isViewerReady: _isReady)) {
      _reportError(PdfJsViewerException(message.name, text), null);
      return;
    }

    final failed = message.bundle ?? _pinnedBundle ?? _server?.seedBundle;
    final next = failed?.downgrade;
    if (next == null || _attemptedBundles.contains(next)) {
      // The chain is exhausted; this is the error state and the only point at
      // which a bundle failure becomes a load failure for the caller.
      _reportError(PdfJsViewerException(message.name, text), null);
      return;
    }

    _attempt += 1;
    _pinnedBundle = next;
    _attemptedBundles.add(next);
    _publishResolution(next, PdfJsTierSource.downgrade, failure: message.diagnosticCode);
    unawaited(_tierCache.write(next, _reportedCapabilities ?? _cachedCapabilities ?? ''));
    unawaited(_reloadGuarded());
  }

  /// Hands a resolution to the caller's telemetry.
  ///
  /// Guarded, and called only after the chain's own state has been updated.
  /// A telemetry sink is the least important thing in this file and the most
  /// likely to throw — it reaches out to analytics, DI and the network — and
  /// an exception here used to propagate out through `_onTierMessage` and the
  /// JavaScript channel, skipping the tier pin and the cache write. The
  /// visible symptom was no telemetry at all; the invisible one was a viewer
  /// that silently stopped pinning tiers and caching them, i.e. the whole
  /// self-healing chain disabled by a broken analytics call.
  void _publishResolution(
    PdfJsBundle? bundle,
    PdfJsTierSource source, {
    PdfJsBundle? probeSupported,
    String? failure,
  }) {
    final onTierResolved = widget.params.onTierResolved;
    if (onTierResolved == null) return;
    final resolution = PdfJsTierResolution(
      bundle: bundle,
      source: source,
      attempt: _attempt,
      capabilities: _reportedCapabilities ?? _cachedCapabilities,
      probeSupported: probeSupported,
      failure: failure,
      canvasHwa: _canvasHwaLabel(bundle),
    );
    try {
      onTierResolved(resolution);
    } catch (e, s) {
      // Reported, not swallowed: a telemetry sink that always throws is a bug
      // worth seeing, just not one worth breaking the viewer over.
      _reportError(e, s);
    }
  }

  /// What this load asks PDF.js for on the canvas, as a telemetry value.
  ///
  /// `default` for an unset flag and for [PdfJsBundle.legacy], which has no
  /// `enableHWA` option, so the value always describes what the engine was
  /// actually given rather than what was configured.
  String _canvasHwaLabel(PdfJsBundle? bundle) {
    final enabled = widget.params.resolvedEnableHardwareAcceleratedCanvas;
    if (enabled == null || bundle == null || !bundle.supportsHardwareAcceleratedCanvas) {
      return 'default';
    }
    return enabled ? 'on' : 'off';
  }

  /// The bundle in use actually initialised a document, so make the pin
  /// durable. Writing only here (and on each downgrade) keeps a bundle that
  /// merely *loaded* from being cached as working.
  void _confirmTier() {
    if (_pinnedFromOverride) return;
    final bundle = _pinnedBundle;
    if (bundle == null) return;
    final capabilities = _reportedCapabilities ?? _cachedCapabilities;
    if (capabilities == null) return;
    _cachedCapabilities = capabilities;
    unawaited(_tierCache.write(bundle, capabilities));
  }

  Future<void> _sendOpen() async {
    final server = _server;
    if (server == null) return;
    final params = widget.params;
    // The bundle that is actually running: on the cold path `bootstrap.js`
    // reports its probe answer before it injects `viewer.mjs`, so the pin is
    // set by the time the host page says it is ready, and on the pinned and
    // downgrade paths it was set before the load.
    final bundle = _pinnedBundle ?? _server?.seedBundle;
    // `enableHWA` exists only in PDF.js 6, i.e. `compat` and `current`;
    // `legacy` 4.1.392 has no such option. 4.1.392 would ignore an unknown
    // option, but the key is withheld instead of relying on that, so the
    // oldest bundle is sent exactly the options it was before this flag
    // existed. Unset (the default) is also withheld, which keeps today's
    // behaviour byte-for-byte until the A/B says otherwise.
    final enableHwa = params.resolvedEnableHardwareAcceleratedCanvas;
    final sendEnableHwa = enableHwa != null && (bundle?.supportsHardwareAcceleratedCanvas ?? false);
    await _runCommand('open', {
      'config': {
        'documentUrl': server.documentUri.toString(),
        'initialPage': max(1, _reloadPageNumber ?? widget.initialPageNumber),
        'columns': params.layout.columns,
        'margin': params.margin,
        'backgroundColor': _cssColor(params.backgroundColor),
        'pageShadowColor': _cssColor(params.pageShadowColor),
        'matchColor': _cssColor(params.matchColor),
        'activeMatchColor': _cssColor(params.activeMatchColor),
        'maxCanvasPixels': params.maxCanvasPixels,
        'largeDocumentPageCount': params.largeDocumentPageCount,
        'largeDocumentMaxCanvasPixels': params.largeDocumentMaxCanvasPixels,
        if (sendEnableHwa) 'enableHwa': enableHwa,
      },
    });
  }

  FutureOr<NavigationDecision> _onNavigationRequest(NavigationRequest request) {
    final uri = Uri.tryParse(request.url);
    if (uri == null) return NavigationDecision.prevent;
    final server = _server;
    // `Uri.origin` throws for every scheme but http(s); a throwing delegate
    // would leave the WebView without a decision.
    final isHttp = uri.scheme == 'http' || uri.scheme == 'https';
    if (isHttp && server != null && uri.origin == server.origin.origin) {
      return NavigationDecision.navigate;
    }
    if (request.isMainFrame) _openExternal(uri);
    return NavigationDecision.prevent;
  }

  void _onWebResourceError(WebResourceError error) {
    if (error.errorType == WebResourceErrorType.webContentProcessTerminated) {
      unawaited(_reloadGuarded());
    }
  }

  void _openExternal(Uri uri) {
    if (_externalSchemes.contains(uri.scheme.toLowerCase())) {
      widget.params.onExternalLinkTap?.call(uri);
    }
  }

  static String _cssColor(Color color) {
    int channel(double value) => (value * 255).round().clamp(0, 255);
    return 'rgba(${channel(color.r)}, ${channel(color.g)}, ${channel(color.b)}, '
        '${color.a.toStringAsFixed(3)})';
  }

  @override
  Widget build(BuildContext context) {
    final webController = _webController;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (webController != null)
          // The host page owns every gesture (scroll, pinch, taps, double-tap
          // zoom). Claiming pointers eagerly keeps Flutter's gesture arena from
          // holding touches back, which would delay or drop single taps on
          // PDF.js links and buttons.
          WebViewWidget(
            controller: webController,
            gestureRecognizers: const {
              Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new),
            },
          ),
        if (!_isReady) widget.params.loadingBuilder?.call(context) ?? const SizedBox.shrink(),
      ],
    );
  }
}
