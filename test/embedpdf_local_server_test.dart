import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:multi_engine_pdf_viewer/src/data/pdfjs/pdfjs_bundle.dart';
import 'package:multi_engine_pdf_viewer/src/data/pdfjs/pdfjs_local_server.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temporary;
  late PdfJsLocalServer server;
  late HttpClient client;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('embedpdf_server_test');
    final file = File('${temporary.path}/document.pdf')..writeAsStringSync('%PDF-1.7\nfixture');
    server = await PdfJsLocalServer.start(
      file: file,
      bundle: PdfJsBundle.current,
      assetLoader: (path) async => ByteData.sublistView(Uint8List.fromList(utf8.encode(path))),
    );
    client = HttpClient()..findProxy = (_) => 'DIRECT';
  });
  tearDown(() async {
    client.close(force: true);
    await server.close();
    await temporary.delete(recursive: true);
  });

  Future<HttpClientResponse> get(Uri uri) async => (await client.getUrl(uri)).close();
  Future<String> body(HttpClientResponse response) => utf8.decoder.bind(response).join();

  test('EmbedPDF-only CSP permits WASM but never JavaScript eval', () async {
    final html = await get(server.embedPdfViewerUri);
    expect(html.statusCode, HttpStatus.ok);
    expect(
      html.headers.value('content-security-policy'),
      PdfJsLocalServer.embedPdfContentSecurityPolicy,
    );
    expect(html.headers.value('x-pdfjs-instance'), isNull);
    expect(html.headers.value('x-content-type-options'), 'nosniff');
    expect(html.headers.value('referrer-policy'), 'no-referrer');
    expect(html.headers.value('cache-control'), 'no-store');
    expect(await body(html), 'embedpdf_viewer/index.html');
    expect(PdfJsLocalServer.embedPdfContentSecurityPolicy, contains("'wasm-unsafe-eval'"));
    expect(PdfJsLocalServer.embedPdfContentSecurityPolicy, isNot(contains("'unsafe-eval'")));
    expect(PdfJsLocalServer.embedPdfContentSecurityPolicy, contains("worker-src 'self'"));
    final original = await get(server.viewerUri);
    expect(
      original.headers.value('content-security-policy'),
      PdfJsLocalServer.contentSecurityPolicy,
    );
    expect(await body(original), 'viewer/index.html');
    expect(PdfJsLocalServer.contentSecurityPolicy, isNot(contains('wasm-unsafe-eval')));
  });

  test('pinned loader reuses unchanged bootstrap and probes but not PDF.js engines', () async {
    expect(server.embedPdfViewerUri.pathSegments.skip(1), [
      't',
      'legacy',
      'embedpdf_viewer',
      'index.html',
    ]);
    for (final (relative, asset, mime) in [
      ('../viewer/bootstrap.js', 'viewer/bootstrap.js', 'text/javascript'),
      ('probe_legacy.mjs', 'viewer/probe_legacy.mjs', 'text/javascript'),
      ('probe_compat.mjs', 'viewer/probe_compat.mjs', 'text/javascript'),
      ('viewer.mjs', 'embedpdf_viewer/viewer.mjs', 'text/javascript'),
      ('worker.mjs', 'embedpdf_viewer/worker.mjs', 'text/javascript'),
      ('../embedpdf/pdfium.wasm', 'embedpdf/pdfium.wasm', 'application/wasm'),
      ('../embedpdf/fonts/NotoSans-Regular.ttf', 'embedpdf/fonts/NotoSans-Regular.ttf', 'font/ttf'),
    ]) {
      final response = await get(server.embedPdfViewerUri.resolve(relative));
      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers.contentType!.mimeType, mime);
      expect(await body(response), asset);
    }
  });

  test('new paths preserve token rejection, instance identity, and rotation', () async {
    final stale = server.embedPdfViewerUri;
    final staleToken = stale.pathSegments.first;
    expect(server.redact(stale.toString()), isNot(contains(staleToken)));
    final wrong = await get(server.origin.resolve('/wrong/t/legacy/embedpdf_viewer/index.html'));
    expect(wrong.statusCode, HttpStatus.notFound);
    await wrong.drain<void>();
    for (final segments in [
      [staleToken, 'embedpdf', r'..\pdfium.wasm'],
      [staleToken, 'embedpdf', '', 'pdfium.wasm'],
      [staleToken, 't', 'unknown', 'embedpdf_viewer', 'index.html'],
    ]) {
      expect(server.resolvePath(Uri(pathSegments: segments)), isNull);
    }
    await server.close();
    client.close(force: true);
    client = HttpClient()..findProxy = (_) => 'DIRECT';
    expect(await server.ensureListening(), isTrue);
    expect(server.embedPdfViewerUri.pathSegments.first, isNot(staleToken));
    final old = await get(server.origin.replace(path: stale.path));
    expect(old.statusCode, HttpStatus.notFound);
    await old.drain<void>();
    final fresh = await get(server.embedPdfViewerUri);
    expect(fresh.statusCode, HttpStatus.ok);
    await fresh.drain<void>();
  });

  test(
    'actual module worker opens, paints, handles widgets and disposes',
    () async {
      await server.close();
      server = await PdfJsLocalServer.start(
        file: File('../../assets/pdf_harness/6474643.pdf'),
        assetLoader: (path) async => ByteData.sublistView(await File('assets/$path').readAsBytes()),
      );
      final result = await Process.run(Platform.environment['EMBEDPDF_NODE'] ?? 'node', [
        'test/embedpdf_worker_smoke.mjs',
        server.embedPdfViewerUri.toString(),
        server.documentUri.toString(),
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      stdout.write(result.stdout);
    },
    skip: Platform.environment['EMBEDPDF_NODE'] == null
        ? 'Optional Node worker proof not configured'
        : false,
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'desktop browser fixture smoke through the actual Dart server',
    () async {
      await server.close();
      server = await PdfJsLocalServer.start(
        file: File('../../assets/pdf_harness/6474643.pdf'),
        assetLoader: (path) async => ByteData.sublistView(await File('assets/$path').readAsBytes()),
      );
      final process = await Process.start(
        Platform.environment['EMBEDPDF_NODE'] ?? 'node',
        [
          'test/embedpdf_browser_smoke.mjs',
          server.embedPdfViewerUri.toString(),
          server.documentUri.toString(),
        ],
        environment: {
          'EMBEDPDF_PLAYWRIGHT_MODULE': Platform.environment['EMBEDPDF_PLAYWRIGHT_MODULE']!,
          'EMBEDPDF_CHROMIUM_EXECUTABLE': ?Platform.environment['EMBEDPDF_CHROMIUM_EXECUTABLE'],
          'EMBEDPDF_EVIDENCE_DIR': ?Platform.environment['EMBEDPDF_EVIDENCE_DIR'],
        },
      );
      final output = StringBuffer();
      final standard = process.stdout.transform(utf8.decoder).listen((text) {
        output.write(text);
        stdout.write(text);
      });
      final errors = process.stderr.transform(utf8.decoder).listen((text) {
        output.write(text);
        stderr.write(text);
      });
      try {
        final exitCode = await process.exitCode.timeout(
          const Duration(minutes: 2),
          onTimeout: () {
            process.kill(ProcessSignal.sigterm);
            return -1;
          },
        );
        expect(exitCode, 0, reason: output.toString());
      } finally {
        process.kill();
        await standard.cancel();
        await errors.cancel();
      }
    },
    skip: Platform.environment['EMBEDPDF_PLAYWRIGHT_MODULE'] == null
        ? 'Optional Playwright module not configured'
        : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
