import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:multi_engine_pdf_viewer/src/data/pdfjs/pdfjs_bundle.dart';
import 'package:multi_engine_pdf_viewer/src/data/pdfjs/pdfjs_local_server.dart';

void main() {
  late Directory tempDir;
  late File pdfFile;
  late PdfJsLocalServer server;
  late HttpClient client;
  final pdfBytes = Uint8List.fromList(List<int>.generate(1000, (i) => i % 256));

  Future<ByteData> assetLoader(String path) async {
    if (path == 'viewer/index.html') {
      return ByteData.sublistView(Uint8List.fromList(utf8.encode('<html></html>')));
    }
    if (path == 'viewer/bootstrap.js') {
      return ByteData.sublistView(Uint8List.fromList(utf8.encode('// bootstrap')));
    }
    if (path.startsWith('pdfjs/') && path.endsWith('/build/pdf.min.mjs')) {
      return ByteData.sublistView(Uint8List.fromList(utf8.encode('// $path')));
    }
    throw StateError('missing asset $path');
  }

  Future<HttpClientResponse> send(String method, Uri uri, {String? range}) async {
    final request = await client.openUrl(method, uri);
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
    return request.close();
  }

  Future<List<int>> body(HttpClientResponse response) async =>
      (await response.toList()).expand((chunk) => chunk).toList();

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pdfjs_server_test');
    pdfFile = File('${tempDir.path}/doc.pdf')..writeAsBytesSync(pdfBytes);
    server = await PdfJsLocalServer.start(
      file: pdfFile,
      assetLoader: assetLoader,
      bundle: PdfJsBundle.legacy,
    );
    client = HttpClient()..findProxy = (_) => 'DIRECT';
  });

  tearDown(() async {
    client.close(force: true);
    await server.close();
    await tempDir.delete(recursive: true);
  });

  test('binds to loopback and exposes token-scoped URLs', () {
    expect(server.origin.host, '127.0.0.1');
    expect(server.viewerUri.pathSegments, hasLength(3));
    expect(server.viewerUri.pathSegments.first, server.documentUri.pathSegments.first);
    expect(server.viewerUri.pathSegments.first.length, greaterThanOrEqualTo(22));
  });

  group('pinned bundle path', () {
    test('viewerUriFor inserts t/<id> between the token and the page', () {
      final pinned = server.viewerUriFor(PdfJsBundle.compat);
      expect(pinned.pathSegments.first, server.viewerUri.pathSegments.first);
      expect(pinned.pathSegments.sublist(1), ['t', 'compat', 'viewer', 'index.html']);
      // The unpinned form is unchanged, so the cold path still probes.
      expect(server.viewerUri.pathSegments.sublist(1), ['viewer', 'index.html']);
    });

    test('a pinned host page resolves every relative URL onto that bundle', () async {
      // This is the whole mechanism: the page never handles the path token, it
      // just uses relative URLs, and the tier segment carries the choice.
      for (final bundle in PdfJsBundle.values) {
        final page = server.viewerUriFor(bundle);
        final html = await send('GET', page);
        expect(html.statusCode, HttpStatus.ok, reason: bundle.id);
        await body(html);

        final script = await send('GET', page.resolve('../pdfjs/build/pdf.min.mjs'));
        expect(script.statusCode, HttpStatus.ok, reason: bundle.id);
        expect(
          utf8.decode(await body(script)),
          '// pdfjs/${bundle.id}/build/pdf.min.mjs',
          reason: bundle.id,
        );

        // bootstrap.js and the probes are shared, not per bundle.
        final bootstrap = await send('GET', page.resolve('bootstrap.js'));
        expect(bootstrap.statusCode, HttpStatus.ok, reason: bundle.id);
        await body(bootstrap);
      }
    });

    test('cmaps and standard_fonts are shared, not rewritten per bundle', () async {
      // Regression: `_assetPath` used to rewrite every `pdfjs/...` URL onto the
      // bundle directory, but `cmaps/` and `standard_fonts/` are vendored once
      // and live outside it, so every request for them 404ed. PDF.js treats a
      // 404 on `cMapUrl`/`standardFontDataUrl` as "not needed" instead of as
      // an error, so CJK glyphs and non-embedded base-14 font substitution
      // failed silently on all three bundles.
      final requested = <String>[];
      final sharingServer = await PdfJsLocalServer.start(
        file: pdfFile,
        bundle: PdfJsBundle.current,
        assetLoader: (path) async {
          requested.add(path);
          return ByteData.sublistView(Uint8List.fromList(utf8.encode('x')));
        },
      );
      addTearDown(sharingServer.close);

      final page = sharingServer.viewerUriFor(PdfJsBundle.compat);
      for (final relative in [
        '../pdfjs/cmaps/78-EUC-H.bcmap',
        '../pdfjs/standard_fonts/FoxitFixed.pfb',
        '../pdfjs/build/pdf.min.mjs',
        '../pdfjs/web/pdf_viewer.css',
      ]) {
        final response = await send('GET', page.resolve(relative));
        expect(response.statusCode, HttpStatus.ok, reason: relative);
        await body(response);
      }

      expect(requested, [
        'pdfjs/cmaps/78-EUC-H.bcmap',
        'pdfjs/standard_fonts/FoxitFixed.pfb',
        'pdfjs/compat/build/pdf.min.mjs',
        'pdfjs/compat/web/pdf_viewer.css',
      ]);
    });

    test('an unpinned pdfjs URL falls back to the selector seed', () async {
      final script = await send('GET', server.viewerUri.resolve('../pdfjs/build/pdf.min.mjs'));
      expect(script.statusCode, HttpStatus.ok);
      expect(utf8.decode(await body(script)), '// pdfjs/legacy/build/pdf.min.mjs');
      expect(server.seedBundle, PdfJsBundle.legacy);
    });

    test('an unknown or absent bundle id is a 404, never a fallback', () async {
      // A guessed URL must not be able to select a build the selector never
      // offered, and must not silently resolve to the seed either.
      final token = server.viewerUri.pathSegments.first;
      for (final path in [
        't/nope/viewer/index.html',
        't/LEGACY/viewer/index.html',
        't/legacy',
        't',
      ]) {
        final response = await send('GET', server.origin.replace(path: '/$token/$path'));
        expect(response.statusCode, HttpStatus.notFound, reason: path);
        await body(response);
      }
    });

    test('the tier segment does not weaken traversal or token checks', () async {
      // Asserted against `resolvePath` rather than over HTTP: Dart's `Uri`
      // normalises `%2e%2e` back to `..` and HttpClient then collapses the
      // segments, so an HTTP-level traversal test only exercises Uri
      // normalisation and never reaches the segment check it means to test.
      final token = server.viewerUri.pathSegments.first;

      expect(server.resolvePath(Uri.parse('/$token/t/legacy/viewer/index.html')), isNotNull);
      expect(
        server.resolvePath(Uri.parse('/$token/t/legacy/viewer/index.html'))?.tier,
        PdfJsBundle.legacy,
      );

      expect(
        server.resolvePath(Uri(pathSegments: ['wrong-token', 't', 'legacy', 'viewer'])),
        isNull,
        reason: 'the token is still checked before the tier segment is read',
      );

      // `.` and `..` are unreachable by construction, not by this check:
      // `Uri.pathSegments` runs RFC 3986 dot-segment removal, so neither a
      // parsed URL nor a hand-built `Uri(pathSegments: [...])` can deliver one
      // to `_resolvePath`. The explicit `.`/`..` rejection there is defence in
      // depth and is deliberately not asserted here, because any assertion
      // would pass for the wrong reason. What this test does cover is that the
      // new tier segment adds no way around the token, backslash and empty
      // segment checks.
      for (final segments in <List<String>>[
        // Backslash in any segment.
        [token, 't', 'legacy', 'viewer', r'..\index.html'],
        [token, 't', r'legacy\viewer', 'index.html'],
        [token, 'embedpdf', '../../../../AssetManifest.bin'],
        [token, 'embedpdf_viewer', '../pdfjs/current/build/pdf.min.mjs'],
        [token, 'embedpdf', '\u0000pdfium.wasm'],
        // Empty segment.
        [token, 't', 'legacy', '', 'viewer', 'index.html'],
        // Unknown, mis-cased or missing bundle id.
        [token, 't', 'nope', 'viewer', 'index.html'],
        [token, 't', 'LEGACY', 'viewer', 'index.html'],
        [token, 't', 'legacy'],
        [token, 't'],
      ]) {
        expect(
          server.resolvePath(Uri(pathSegments: segments)),
          isNull,
          reason: segments.join('/'),
        );
      }

      // The document is only reachable at its own unpinned URL.
      expect(server.resolvePath(server.documentUri)?.path, 'document.pdf');
      expect(server.resolvePath(server.documentUri)?.tier, isNull);
    });
  });

  test('serves assets with security headers and a JavaScript MIME type', () async {
    final html = await send('GET', server.viewerUri);
    expect(html.statusCode, HttpStatus.ok);
    expect(html.headers.value('content-security-policy'), PdfJsLocalServer.contentSecurityPolicy);
    expect(html.headers.value(HttpHeaders.cacheControlHeader), 'no-store');
    expect(utf8.decode(await body(html)), '<html></html>');

    final script = await send('GET', server.viewerUri.resolve('../pdfjs/build/pdf.min.mjs'));
    expect(script.statusCode, HttpStatus.ok);
    expect(script.headers.contentType?.mimeType, 'text/javascript');
    await body(script);
  });

  test('maps stable PDF.js URLs to the selected bundle assets', () async {
    final requestedAssets = <String>[];
    final currentServer = await PdfJsLocalServer.start(
      file: pdfFile,
      bundle: PdfJsBundle.current,
      assetLoader: (path) async {
        requestedAssets.add(path);
        return ByteData.sublistView(Uint8List.fromList(utf8.encode('export {};')));
      },
    );
    addTearDown(currentServer.close);

    final response = await send(
      'GET',
      currentServer.viewerUri.resolve('../pdfjs/build/pdf.min.mjs'),
    );
    expect(response.statusCode, HttpStatus.ok);
    await body(response);
    expect(requestedAssets, ['pdfjs/current/build/pdf.min.mjs']);

    requestedAssets.clear();
    final workerResponse = await send(
      'GET',
      currentServer.viewerUri.resolve('../pdfjs/build/pdf.worker.min.mjs'),
    );
    expect(workerResponse.statusCode, HttpStatus.ok);
    await body(workerResponse);
    expect(requestedAssets, ['pdfjs/current/build/pdf.worker.min.mjs']);
  });

  test('serves each bundle from its own asset directory', () async {
    for (final (bundle, expected) in [
      (PdfJsBundle.legacy, 'pdfjs/legacy/build/pdf.min.mjs'),
      (PdfJsBundle.compat, 'pdfjs/compat/build/pdf.min.mjs'),
      (PdfJsBundle.current, 'pdfjs/current/build/pdf.min.mjs'),
    ]) {
      final requestedAssets = <String>[];
      final server = await PdfJsLocalServer.start(
        file: pdfFile,
        bundle: bundle,
        assetLoader: (path) async {
          requestedAssets.add(path);
          return ByteData.sublistView(Uint8List.fromList(utf8.encode('export {};')));
        },
      );
      addTearDown(server.close);

      final response = await send('GET', server.viewerUri.resolve('../pdfjs/build/pdf.min.mjs'));
      expect(response.statusCode, HttpStatus.ok);
      await body(response);
      expect(requestedAssets, [expected]);
    }
  });

  test('rejects wrong tokens, unknown assets, traversal and other methods', () async {
    final wrongToken = server.origin.replace(path: '/not-the-token/viewer/index.html');
    expect((await send('GET', wrongToken)).statusCode, HttpStatus.notFound);

    final missing = server.viewerUri.resolve('missing.js');
    expect((await send('GET', missing)).statusCode, HttpStatus.notFound);

    final token = server.viewerUri.pathSegments.first;
    final traversal = server.origin.replace(path: '/$token/viewer/%2E%2E/%2E%2E/secret');
    expect((await send('GET', traversal)).statusCode, HttpStatus.notFound);

    expect((await send('POST', server.documentUri)).statusCode, HttpStatus.methodNotAllowed);
  });

  test('serves the whole document and advertises range support', () async {
    final response = await send('GET', server.documentUri);
    expect(response.statusCode, HttpStatus.ok);
    expect(response.headers.value(HttpHeaders.acceptRangesHeader), 'bytes');
    expect(response.headers.contentType?.mimeType, 'application/pdf');
    expect(await body(response), pdfBytes);
  });

  test('serves byte ranges', () async {
    final response = await send('GET', server.documentUri, range: 'bytes=10-19');
    expect(response.statusCode, HttpStatus.partialContent);
    expect(response.headers.value(HttpHeaders.contentRangeHeader), 'bytes 10-19/1000');
    expect(await body(response), pdfBytes.sublist(10, 20));

    final suffix = await send('GET', server.documentUri, range: 'bytes=-5');
    expect(await body(suffix), pdfBytes.sublist(995));
  });

  test('answers unsatisfiable ranges with 416', () async {
    final response = await send('GET', server.documentUri, range: 'bytes=5000-');
    expect(response.statusCode, HttpStatus.requestedRangeNotSatisfiable);
    expect(response.headers.value(HttpHeaders.contentRangeHeader), 'bytes */1000');
  });

  test('HEAD returns headers without a body', () async {
    final response = await send('HEAD', server.documentUri);
    expect(response.statusCode, HttpStatus.ok);
    expect(response.headers.contentLength, 1000);
    expect(await body(response), isEmpty);
  });

  test('ensureListening keeps a live origin and rebinds a closed one', () async {
    final origin = server.origin;
    expect(await server.ensureListening(), isFalse);
    expect(server.origin, origin);

    await server.close();
    await server.ensureListening();
    final response = await send('GET', server.documentUri);
    expect(response.statusCode, HttpStatus.ok);
    await body(response);
  });

  test('rotates the token when rebinding so stale URLs stop working', () async {
    final previousToken = server.viewerUri.pathSegments.first;
    await server.close();
    expect(await server.ensureListening(), isTrue);
    expect(server.viewerUri.pathSegments.first, isNot(previousToken));

    final stale = server.origin.replace(path: '/$previousToken/viewer/index.html');
    expect((await send('GET', stale)).statusCode, HttpStatus.notFound);
    final fresh = await send('GET', server.viewerUri);
    expect(fresh.statusCode, HttpStatus.ok);
    await body(fresh);
  });

  test('rebinds elsewhere when another process holds the old port', () async {
    final port = server.origin.port;
    await server.close();
    final squatter = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    squatter.listen((request) => request.response.close());
    try {
      expect(await server.ensureListening(), isTrue);
      expect(server.origin.port, isNot(port));
      final response = await send('GET', server.documentUri);
      expect(response.statusCode, HttpStatus.ok);
      await body(response);
    } finally {
      await squatter.close(force: true);
    }
  });

  test('an unauthenticated response never exposes the liveness key or proof', () async {
    final response = await send('HEAD', server.origin);
    expect(response.statusCode, HttpStatus.notFound);
    expect(response.headers.value(PdfJsLocalServer.instanceHeader), isNull);
    await body(response);
  });

  test('token-free challenge proofs change and cannot be replayed across instances', () async {
    Future<String?> proof(PdfJsLocalServer target, String challenge) async {
      final request = await client.openUrl('HEAD', target.origin);
      request.headers.set(PdfJsLocalServer.probeChallengeHeader, challenge);
      final response = await request.close();
      expect(response.statusCode, HttpStatus.noContent);
      final result = response.headers.value(PdfJsLocalServer.instanceHeader);
      await body(response);
      return result;
    }
    final first = await proof(server, 'AAAAAAAAAAAAAAAAAAAAAA');
    final second = await proof(server, 'BBBBBBBBBBBBBBBBBBBBBB');
    expect(first, hasLength(64));
    expect(second, isNot(first));
    final other = await PdfJsLocalServer.start(file: pdfFile, assetLoader: assetLoader);
    addTearDown(other.close);
    expect(await proof(other, 'AAAAAAAAAAAAAAAAAAAAAA'), isNot(first));
    expect(await server.ensureListening(), isFalse);
  });

  test('encoded separators never reach an asset loader or relaxed CSP', () async {
    final token = server.viewerUri.pathSegments.first;
    final response = await send('GET', Uri.parse(
      '${server.origin}/$token/embedpdf/..%2F..%2F..%2F..%2FAssetManifest.bin',
    ));
    expect(response.statusCode, HttpStatus.notFound);
    expect(response.headers.value('content-security-policy'), PdfJsLocalServer.contentSecurityPolicy);
    await body(response);
  });

  test('redact removes the token from messages', () {
    final token = server.viewerUri.pathSegments.first;
    final redacted = server.redact('Missing PDF "${server.documentUri}".');
    expect(redacted, isNot(contains(token)));
    expect(redacted, contains('/<token>/document.pdf'));
  });

  group('parseByteRange', () {
    test('parses closed, open and suffix ranges', () {
      expect(PdfJsLocalServer.parseByteRange('bytes=0-99', 1000), (0, 99));
      expect(PdfJsLocalServer.parseByteRange('bytes=900-', 1000), (900, 999));
      expect(PdfJsLocalServer.parseByteRange('bytes=900-5000', 1000), (900, 999));
      expect(PdfJsLocalServer.parseByteRange('bytes=-100', 1000), (900, 999));
      expect(PdfJsLocalServer.parseByteRange('bytes=-5000', 1000), (0, 999));
    });

    test('rejects malformed and unsatisfiable ranges', () {
      expect(PdfJsLocalServer.parseByteRange('bytes=1000-', 1000), isNull);
      expect(PdfJsLocalServer.parseByteRange('bytes=20-10', 1000), isNull);
      expect(PdfJsLocalServer.parseByteRange('bytes=-', 1000), isNull);
      expect(PdfJsLocalServer.parseByteRange('bytes=-0', 1000), isNull);
      expect(PdfJsLocalServer.parseByteRange('items=0-1', 1000), isNull);
    });
  });
}
