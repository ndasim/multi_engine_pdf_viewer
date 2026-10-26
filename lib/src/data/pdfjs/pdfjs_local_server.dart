import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:multi_engine_pdf_viewer/src/data/pdfjs/pdfjs_bundle.dart';

/// Loads a file from the package's `assets/` directory, e.g. `viewer/index.html`.
typedef PdfJsAssetLoader = Future<ByteData> Function(String assetPath);

/// Serves one PDF file and the bundled PDF.js viewer to the WebView.
///
/// Binds to `127.0.0.1` only and answers requests under a random path token,
/// so other processes on the device cannot guess the URLs. The token is
/// rotated whenever the socket is rebound: another process may have held the
/// port in between, and the liveness probe never sends the token, so a port
/// squatter learns nothing it could reuse against the new socket.
class PdfJsLocalServer {
  PdfJsLocalServer._(this._file, this._assetLoader, this._bundle);

  static const String contentSecurityPolicy =
      "default-src 'none'; script-src 'self'; worker-src 'self'; connect-src 'self'; "
      "img-src 'self' data: blob:; font-src 'self' data: blob:; "
      "style-src 'self' 'unsafe-inline'; base-uri 'none'; form-action 'none'; "
      "frame-ancestors 'none'";

  static const String _packageAssetPrefix = 'packages/multi_engine_pdf_viewer/assets/';
  static const String _documentPath = 'document.pdf';

  /// Path segment that introduces a pinned bundle: `<token>/t/<bundle id>/...`.
  static const String _tierSegment = 't';

  /// Response header carrying the challenge proof, never the private key.
  @visibleForTesting
  static const String instanceHeader = 'x-pdfjs-instance';
  @visibleForTesting
  static const String probeChallengeHeader = 'x-pdfjs-challenge';

  final File _file;
  final PdfJsAssetLoader _assetLoader;
  final PdfJsBundle _bundle;

  /// Secret path prefix of every URL. Regenerated on each bind.
  String _token = _createSecret();

  final List<int> _probeKey = utf8.encode(_createSecret());

  HttpServer? _server;
  int _port = 0;

  static Future<PdfJsLocalServer> start({
    required File file,
    PdfJsAssetLoader? assetLoader,
    PdfJsBundle? bundle,
  }) async {
    final server = PdfJsLocalServer._(
      file,
      assetLoader ?? _loadPackageAsset,
      bundle ?? PdfJsBundleSelector.select(),
    );
    await server._bind(0);
    return server;
  }

  /// The selector's seed answer, used for requests that pin no bundle.
  PdfJsBundle get seedBundle => _bundle;

  Uri get origin => Uri(scheme: 'http', host: InternetAddress.loopbackIPv4.address, port: _port);

  /// The host page, letting `bootstrap.js` pick the bundle by capability probe.
  Uri get viewerUri => viewerUriFor(null);

  /// The host page pinned to [tier], or unpinned when [tier] is `null`.
  ///
  /// Pinning inserts `t/<id>/` between the token and the rest of the path.
  /// Every URL inside the host page is relative, so one pinned host-page URL
  /// moves the whole page — build, worker, cmaps, standard fonts and the PDF.js
  /// stylesheet — onto that bundle, and the page itself never has to handle
  /// the path token to do it. The self-healing chain uses this to retry on the
  /// next bundle down, and the per-device tier cache uses it to skip the probe
  /// on the critical path.
  Uri viewerUriFor(PdfJsBundle? tier) => _baseUri.resolve(
    tier == null ? 'viewer/index.html' : '$_tierSegment/${tier.id}/viewer/index.html',
  );

  Uri get documentUri => _baseUri.resolve(_documentPath);

  Uri get _baseUri => origin.replace(path: '/$_token/');

  /// Rebinds the socket if the OS reclaimed it (iOS does this for suspended
  /// apps). Returns `true` when it rebound: the URLs changed and the page
  /// must reload.
  Future<bool> ensureListening() async {
    if (await _isAlive()) return false;

    final previousPort = _port;
    await _server?.close(force: true);
    try {
      await _bind(previousPort);
    } on SocketException {
      await _bind(0);
    }
    return true;
  }

  /// Replaces the current token in [text] with `<token>`, for log and crash
  /// reports. PDF.js error messages, for example, embed the document URL.
  String redact(String text) => text.replaceAll(_token, '<token>');

  Future<void> close() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  static Future<ByteData> _loadPackageAsset(String assetPath) {
    return rootBundle.load('$_packageAssetPrefix$assetPath');
  }

  static String _createSecret() {
    final random = Random.secure();
    final bytes = Uint8List.fromList(List<int>.generate(16, (_) => random.nextInt(256)));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  Future<void> _bind(int port) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server = server;
    _port = server.port;
    _token = _createSecret();
    server.listen((request) => unawaited(_handle(request)), onError: (Object _) {});
  }

  /// Probes the origin root without the token and accepts only a response
  /// that carries this instance's id, so a process that took over the port
  /// while the app was suspended neither learns the token nor passes as us.
  Future<bool> _isAlive() async {
    if (_server == null) return false;
    final challenge = _createSecret();
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 1)
      ..findProxy = (_) => 'DIRECT';
    try {
      final request = await client.headUrl(origin)
        ..followRedirects = false;
      request.headers.set(probeChallengeHeader, challenge);
      final response = await request.close().timeout(const Duration(seconds: 2));
      await response.drain<void>().timeout(const Duration(seconds: 2));
      return _constantTimeEqual(response.headers.value(instanceHeader) ?? '', _proof(challenge));
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      _applyCommonHeaders(response);

      if (!(request.connectionInfo?.remoteAddress.isLoopback ?? false)) {
        return await _sendStatus(response, HttpStatus.forbidden);
      }
      if (request.method != 'GET' && request.method != 'HEAD') {
        return await _sendStatus(response, HttpStatus.methodNotAllowed);
      }

      final challenge = request.headers.value(probeChallengeHeader);
      if (request.method == 'HEAD' &&
          request.uri.path == '/' &&
          challenge != null &&
          RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(challenge)) {
        response.headers.set(instanceHeader, _proof(challenge));
        return await _sendStatus(response, HttpStatus.noContent);
      }

      final resolved = _resolvePath(request.uri);
      if (resolved == null) {
        return await _sendStatus(response, HttpStatus.notFound);
      }
      final assetPath = resolved.path;
      if (assetPath == _documentPath) {
        return await _serveDocument(request);
      }
      if (assetPath.startsWith('viewer/') || assetPath.startsWith('pdfjs/')) {
        return await _serveAsset(request, assetPath, resolved.tier);
      }
      await _sendStatus(response, HttpStatus.notFound);
    } catch (_) {
      // The WebView may abort a streamed response; the socket is already gone.
      try {
        await response.close();
      } catch (_) {}
    }
  }

  /// Validates the token and path, and peels off an optional pinned bundle.
  ///
  /// The token check and the segment validation are unchanged and still run on
  /// every request before anything else looks at the path; the bundle segment
  /// is read only after they pass.
  @visibleForTesting
  ({PdfJsBundle? tier, String path})? resolvePath(Uri uri) => _resolvePath(uri);

  ({PdfJsBundle? tier, String path})? _resolvePath(Uri uri) {
    final segments = uri.pathSegments;
    if (segments.length < 2 || !_constantTimeEqual(segments.first, _token)) return null;
    final rest = segments.skip(1).toList();
    if (rest.any((segment) => segment.isEmpty || segment == '.' || segment == '..')) return null;
    if (rest.any(
      (segment) =>
          segment.contains(r'\') ||
          segment.contains('/') ||
          segment.codeUnits.any((value) => value < 32 || value == 127),
    )) {
      return null;
    }

    if (rest.first != _tierSegment) return (tier: null, path: rest.join('/'));

    // An unknown bundle id is a 404, not a fallback: a guessed URL must not be
    // able to select a build the selector never offered.
    if (rest.length < 3) return null;
    final tier = PdfJsBundle.tryParse(rest[1]);
    if (tier == null) return null;
    return (tier: tier, path: rest.skip(2).join('/'));
  }

  void _applyCommonHeaders(HttpResponse response) {
    response.headers
      ..set(HttpHeaders.cacheControlHeader, 'no-store')
      ..set('Content-Security-Policy', contentSecurityPolicy)
      ..set('X-Content-Type-Options', 'nosniff')
      ..set('Referrer-Policy', 'no-referrer')
      ..set('Cross-Origin-Resource-Policy', 'same-origin');
  }

  Future<void> _sendStatus(HttpResponse response, int statusCode) async {
    response
      ..statusCode = statusCode
      ..contentLength = 0;
    await response.close();
  }

  Future<void> _serveAsset(HttpRequest request, String assetPath, PdfJsBundle? tier) async {
    final assetKey = _assetPath(assetPath, tier);
    final canonical = Uri(path: assetKey).normalizePath().path;
    if (canonical != assetKey ||
        !const ['viewer/', 'pdfjs/'].any(canonical.startsWith)) {
      return _sendStatus(request.response, HttpStatus.notFound);
    }
    final ByteData data;
    try {
      data = await _assetLoader(canonical);
    } catch (_) {
      return _sendStatus(request.response, HttpStatus.notFound);
    }

    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    final response = request.response
      ..statusCode = HttpStatus.ok
      ..contentLength = bytes.length;
    response.headers.contentType = contentTypeFor(assetPath);
    if (request.method == 'GET') response.add(bytes);
    await response.close();
  }

  String _proof(String challenge) =>
      Hmac(sha256, _probeKey).convert(utf8.encode(challenge)).toString();

  static bool _constantTimeEqual(String first, String second) {
    if (first.length != second.length) return false;
    var difference = 0;
    for (var index = 0; index < first.length; index++) {
      difference |= first.codeUnitAt(index) ^ second.codeUnitAt(index);
    }
    return difference == 0;
  }

  /// Subtrees of `assets/pdfjs/` that are vendored once and shared by all
  /// three bundles, so they must NOT be rewritten onto a bundle directory.
  ///
  /// Getting this wrong is silent: `getDocument` is given `cMapUrl` and
  /// `standardFontDataUrl`, and PDF.js treats a 404 on either as "this
  /// document has no CJK encoding / no substitutable standard font" rather
  /// than as an error. The symptom is missing CJK glyphs and wrong metrics for
  /// non-embedded base-14 fonts, with nothing in any log.
  static const Set<String> _sharedAssetSubtrees = {'cmaps', 'standard_fonts'};

  /// Rewrites the viewer's stable `pdfjs/...` URLs onto a bundle's asset
  /// directory. Every bundle ships the same file names, so the viewer never
  /// has to know which build it is running.
  ///
  /// [tier] is the bundle pinned in the request path; without one the selector's
  /// seed answer is used, which is the unpinned first request of a cold device.
  String _assetPath(String assetPath, [PdfJsBundle? tier]) {
    if (!assetPath.startsWith('pdfjs/')) return assetPath;
    final rest = assetPath.substring('pdfjs/'.length);
    final firstSegment = rest.split('/').first;
    if (_sharedAssetSubtrees.contains(firstSegment)) return assetPath;
    return '${(tier ?? _bundle).assetDirectory}/$rest';
  }

  Future<void> _serveDocument(HttpRequest request) async {
    final response = request.response;
    final length = await _file.length();
    response.headers
      ..contentType = ContentType('application', 'pdf')
      ..set(HttpHeaders.acceptRangesHeader, 'bytes');

    var start = 0;
    var end = length - 1;
    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    if (rangeHeader != null && !rangeHeader.contains(',')) {
      final range = parseByteRange(rangeHeader, length);
      if (range == null) {
        response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$length');
        return _sendStatus(response, HttpStatus.requestedRangeNotSatisfiable);
      }
      (start, end) = range;
      response
        ..statusCode = HttpStatus.partialContent
        ..headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$length');
    } else {
      response.statusCode = HttpStatus.ok;
    }

    response.contentLength = length == 0 ? 0 : end - start + 1;
    if (request.method == 'GET' && length > 0) {
      await response.addStream(_file.openRead(start, end + 1));
    }
    await response.close();
  }

  /// Parses a single `bytes=` range. Returns `null` when unsatisfiable.
  @visibleForTesting
  static (int, int)? parseByteRange(String header, int length) {
    final match = RegExp(r'^\s*bytes\s*=\s*(\d*)\s*-\s*(\d*)\s*$').firstMatch(header);
    if (match == null || length <= 0) return null;

    final startText = match.group(1)!;
    final endText = match.group(2)!;
    if (startText.isEmpty && endText.isEmpty) return null;

    if (startText.isEmpty) {
      final suffixLength = int.tryParse(endText);
      if (suffixLength == null || suffixLength == 0) return null;
      return (max(0, length - suffixLength), length - 1);
    }

    final start = int.tryParse(startText);
    if (start == null || start >= length) return null;
    final end = endText.isEmpty ? length - 1 : int.tryParse(endText);
    if (end == null || end < start) return null;
    return (start, min(end, length - 1));
  }

  @visibleForTesting
  static ContentType contentTypeFor(String path) {
    final extension = path.substring(path.lastIndexOf('.') + 1).toLowerCase();
    return switch (extension) {
      'html' => ContentType.html,
      'mjs' || 'js' => ContentType('text', 'javascript', charset: 'utf-8'),
      'css' => ContentType('text', 'css', charset: 'utf-8'),
      'svg' => ContentType('image', 'svg+xml'),
      'gif' => ContentType('image', 'gif'),
      'ttf' => ContentType('font', 'ttf'),
      'wasm' => ContentType('application', 'wasm'),
      _ => ContentType.binary,
    };
  }
}
