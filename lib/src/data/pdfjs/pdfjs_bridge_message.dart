import 'dart:convert';

import 'package:multi_engine_pdf_viewer/src/data/pdfjs/pdfjs_bundle.dart';
import 'package:multi_engine_pdf_viewer/src/data/pdfjs/pdfjs_outline_node.dart';

/// Version of the JSON protocol shared with `assets/viewer/viewer.mjs`.
const int pdfJsBridgeProtocolVersion = 1;

/// Name of the JavaScript channel the host page posts to.
const String pdfJsBridgeChannelName = 'PdfJsBridge';

/// A message posted by the host page. Unknown or malformed messages parse to `null`.
sealed class PdfJsBridgeMessage {
  const PdfJsBridgeMessage();

  static PdfJsBridgeMessage? tryParse(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, Object?>) return null;
    if (decoded['v'] != pdfJsBridgeProtocolVersion) return null;

    return switch (decoded['type']) {
      'bridgeReady' => const PdfJsBridgeReadyMessage(),
      'ready' => _parseReady(decoded),
      'firstPageRendered' => switch (_positiveInt(decoded['pageNumber'])) {
        final int pageNumber => PdfJsFirstPageRenderedMessage(pageNumber),
        null => null,
      },
      'outline' => _parseOutline(decoded),
      'pageChanged' => switch (_positiveInt(decoded['pageNumber'])) {
        final int pageNumber => PdfJsPageChangedMessage(pageNumber),
        null => null,
      },
      'findState' => _parseFindState(decoded),
      'pageTap' => switch (_positiveInt(decoded['pageNumber'])) {
        final int pageNumber => PdfJsPageTapMessage(pageNumber),
        null => null,
      },
      'externalLink' => _parseExternalLink(decoded),
      'tier' => _parseTier(decoded),
      'error' => PdfJsErrorMessage(
        name: decoded['name'] is String ? decoded['name']! as String : 'Error',
        message: decoded['message'] is String ? decoded['message']! as String : '',
        // `bootstrap.js` tags its failures with the bundle it was loading, so
        // the self-healing chain knows which rung broke.
        bundle: PdfJsBundle.tryParse(decoded['tier'] as String?),
      ),
      _ => null,
    };
  }

  static PdfJsBridgeMessage? _parseReady(Map<String, Object?> json) {
    final pageCount = _positiveInt(json['pageCount']);
    final pageNumber = _positiveInt(json['pageNumber']);
    if (pageCount == null || pageNumber == null) return null;
    return PdfJsReadyMessage(pageCount: pageCount, pageNumber: pageNumber);
  }

  static PdfJsBridgeMessage? _parseOutline(Map<String, Object?> json) {
    final items = json['items'];
    if (items is! List<Object?>) return null;
    return PdfJsOutlineMessage(PdfJsOutlineNode.listFromJson(items));
  }

  static PdfJsBridgeMessage? _parseFindState(Map<String, Object?> json) {
    final current = json['current'];
    final total = json['total'];
    if (current is! int || total is! int || current < 0 || total < 0) return null;
    return PdfJsFindStateMessage(
      current: current > total ? 0 : current,
      total: total,
      pending: json['pending'] == true,
    );
  }

  static PdfJsBridgeMessage? _parseExternalLink(Map<String, Object?> json) {
    final url = json['url'];
    if (url is! String) return null;
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return null;
    return PdfJsExternalLinkMessage(uri);
  }

  /// `{type: "tier"}` — the capability probe's answer from `bootstrap.js`.
  static PdfJsBridgeMessage? _parseTier(Map<String, Object?> json) {
    final source = json['source'];
    if (source is! String) return null;
    return PdfJsTierMessage(
      bundle: PdfJsBundle.tryParse(json['tier'] as String?),
      probeSupported: PdfJsBundle.tryParse(json['supported'] as String?),
      isPinned: source == 'pinned',
      capabilities: json['capabilities'] is String ? json['capabilities']! as String : '',
    );
  }

  static int? _positiveInt(Object? value) => value is int && value > 0 ? value : null;
}

final class PdfJsBridgeReadyMessage extends PdfJsBridgeMessage {
  const PdfJsBridgeReadyMessage();
}

final class PdfJsReadyMessage extends PdfJsBridgeMessage {
  const PdfJsReadyMessage({required this.pageCount, required this.pageNumber});

  final int pageCount;
  final int pageNumber;
}

final class PdfJsFirstPageRenderedMessage extends PdfJsBridgeMessage {
  const PdfJsFirstPageRenderedMessage(this.pageNumber);

  final int pageNumber;
}

final class PdfJsOutlineMessage extends PdfJsBridgeMessage {
  const PdfJsOutlineMessage(this.items);

  final List<PdfJsOutlineNode> items;
}

final class PdfJsPageChangedMessage extends PdfJsBridgeMessage {
  const PdfJsPageChangedMessage(this.pageNumber);

  final int pageNumber;
}

final class PdfJsFindStateMessage extends PdfJsBridgeMessage {
  const PdfJsFindStateMessage({required this.current, required this.total, required this.pending});

  /// 1-based index of the active match, `0` when there is none.
  final int current;
  final int total;
  final bool pending;
}

final class PdfJsPageTapMessage extends PdfJsBridgeMessage {
  const PdfJsPageTapMessage(this.pageNumber);

  final int pageNumber;
}

final class PdfJsExternalLinkMessage extends PdfJsBridgeMessage {
  const PdfJsExternalLinkMessage(this.url);

  final Uri url;
}

final class PdfJsErrorMessage extends PdfJsBridgeMessage {
  const PdfJsErrorMessage({required this.name, required this.message, this.bundle});

  /// `ViewerScriptError`, `ViewerLoadTimeout` and `EngineUnsupported` come from
  /// `assets/viewer/bootstrap.js`; anything else comes from PDF.js itself.
  static const String scriptErrorName = 'ViewerScriptError';
  static const String loadTimeoutName = 'ViewerLoadTimeout';
  static const String engineUnsupportedName = 'EngineUnsupported';

  final String name;
  final String message;

  String get diagnosticCode => switch (name) {
    scriptErrorName => 'viewer-script-error',
    loadTimeoutName => 'viewer-load-timeout',
    engineUnsupportedName => 'engine-unsupported',
    'SyntaxError' => 'syntax-error',
    'TypeError' => 'type-error',
    'ReferenceError' => 'reference-error',
    'InvalidPDFException' => 'invalid-document',
    'MissingPDFException' => 'missing-document',
    'PasswordException' => 'password-required',
    'UnknownErrorException' => 'document-load-error',
    _ => 'viewer-error',
  };

  /// The bundle that was loading when this failed, when `bootstrap.js` knew it.
  final PdfJsBundle? bundle;

  /// Whether this is a bundle-level failure the downgrade chain can retry.
  /// `EngineUnsupported` is deliberately excluded: the probe has already said
  /// no vendored build can run, so retrying would only waste the user's time.
  bool get isRetryableBundleFailure => name == scriptErrorName || name == loadTimeoutName;

  /// Whether this is reason enough to suspect the bundle rather than the
  /// document, and therefore to step the self-healing chain down.
  ///
  /// `bootstrap.js`'s two shapes are the clear cases, but they are not the
  /// only ones, and a device run proved it. On iOS 18.6 with `current` forced,
  /// the module parses, the bridge comes up, and PDF.js then throws
  /// `UnknownErrorException: this._requestsByChunk.getOrInsertComputed is not
  /// a function` while opening the document. `bootstrap.js` cannot report that
  /// — `pdfjsBridge` already exists by then, so its `fail()` guard correctly
  /// declines — and the name is PDF.js's own, so [isRetryableBundleFailure]
  /// misses it. Before this rule existed the viewer showed a dead page with a
  /// working bundle one rung below; with it, the chain recovers to `compat`
  /// and paints.
  ///
  /// So the rule is about *when*, not only *what*: an error raised before the
  /// viewer ever reached `ready` on this bundle makes the bundle suspect,
  /// because a document that fails to open on one build and opens on the next
  /// is exactly this failure. After `ready` the bundle has demonstrably
  /// worked, so a later error belongs to the document and must never trigger a
  /// reload — that would turn one bad page into a loop of downgrades.
  ///
  /// The cost is bounded and deliberate: a genuinely corrupt PDF is now tried
  /// on at most two further bundles before the failure view appears. The
  /// capability probe keeps production off this path — it excludes `current`
  /// on iOS 18.6 by feature-detecting `getOrInsertComputed`, reported as `g0`
  /// in the capability signature — so this is the recovery for a forced
  /// profiling mode or a probe false positive, which is what a self-healing
  /// chain is for.
  bool isBundleSuspect({required bool isViewerReady}) {
    if (name == engineUnsupportedName) return false;
    if (isRetryableBundleFailure) return true;
    return !isViewerReady;
  }
}

/// `bootstrap.js` reporting which bundle it loaded and what the engine can do.
final class PdfJsTierMessage extends PdfJsBridgeMessage {
  const PdfJsTierMessage({
    required this.bundle,
    required this.probeSupported,
    required this.isPinned,
    required this.capabilities,
  });

  /// The bundle actually being loaded. `null` means none could be.
  final PdfJsBundle? bundle;

  /// The best bundle the probe believes this engine supports. Differs from
  /// [bundle] when Dart pinned a tier and the WebView has since been updated.
  final PdfJsBundle? probeSupported;

  /// `true` when Dart pinned the bundle and the probe ran alongside the viewer
  /// instead of deciding.
  final bool isPinned;

  /// Opaque feature signature, e.g. `m1.l1.c1.g0.d0`. Feature flags only.
  final String capabilities;
}

/// Builds the JavaScript that delivers command to the host page.
///
/// The command is JSON-encoded twice so it reaches JS as a string literal and
/// is parsed there, never evaluated as code.
String pdfJsBridgeCommandScript(String type, [Map<String, Object?> payload = const {}]) {
  final command = jsonEncode({'v': pdfJsBridgeProtocolVersion, 'type': type, ...payload});
  return 'window.pdfjsBridge && window.pdfjsBridge.receive(${jsonEncode(command)});';
}
