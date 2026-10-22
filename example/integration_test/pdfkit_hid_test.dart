import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:multi_engine_pdf_viewer/multi_engine_pdf_viewer.dart';

import 'pdfkit_fixture.dart';

/// Development-only bridge for real simulator HID touches, not tester.tapAt.
/// Run with PDFKIT_HID=true and use the printed loopback port.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized()
          .shouldPropagateDevicePointerEvents =
      true;
  const enabled = bool.fromEnvironment('PDFKIT_HID');
  testWidgets('PDFKit real simulator touches', (tester) async {
    final directory = await Directory.systemTemp.createTemp('pdfkit-hid-');
    final file = await File(
      '${directory.path}/fixture.pdf',
    ).writeAsBytes(pdfKitFixture());
    final key = GlobalKey<_PdfKitHidScreenState>();
    await tester.pumpWidget(
      MaterialApp(
        home: _PdfKitHidScreen(key: key, path: file.path),
      ),
    );
    final host = key.currentState!;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var finished = false;
    final subscription = server.listen((request) async {
      final path = request.uri.path;
      if (request.method != 'GET' ||
          !const {
            '/state',
            '/page/1',
            '/page/2',
            '/page/3',
            '/grid',
            '/vertical',
            '/done',
          }.contains(path)) {
        request.response.statusCode = request.method == 'GET'
            ? HttpStatus.notFound
            : HttpStatus.methodNotAllowed;
        await request.response.close();
        return;
      }
      if (path == '/page/1') await host.controller.goToPage(1);
      if (path == '/page/2') await host.controller.goToPage(2);
      if (path == '/page/3') await host.controller.goToPage(3);
      if (path == '/grid') host.grid();
      if (path == '/vertical') host.vertical();
      if (path == '/done') finished = true;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(host.snapshot));
      await request.response.close();
    });
    debugPrint('PDFKIT_HID_PORT=${server.port}');
    try {
      final deadline = DateTime.now().add(const Duration(minutes: 4));
      while (!finished && DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(finished, isTrue, reason: 'external HID driver must finish');
      expect(host.errors, isEmpty);
      expect(host.paints, hasLength(1));
      expect(host.links, [Uri.parse('https://example.com/pdf')]);
      expect(host.layouts, [PdfViewerLayout.vertical]);
    } finally {
      await subscription.cancel();
      await server.close(force: true);
      await tester.pumpWidget(const SizedBox.shrink());
      await directory.delete(recursive: true);
    }
  }, skip: !enabled);
}

class _PdfKitHidScreen extends StatefulWidget {
  const _PdfKitHidScreen({required this.path, super.key});
  final String path;
  @override
  State<_PdfKitHidScreen> createState() => _PdfKitHidScreenState();
}

class _PdfKitHidScreenState extends State<_PdfKitHidScreen> {
  final controller = PdfViewerController();
  var layout = PdfViewerLayout.vertical;
  var ready = 0;
  final pages = <int>[];
  final paints = <int>[];
  final taps = <int>[];
  final links = <Uri>[];
  final layouts = <PdfViewerLayout>[];
  final errors = <Object>[];

  Map<String, Object?> get snapshot => {
    'viewport': {
      'width': MediaQuery.sizeOf(context).width,
      'height': MediaQuery.sizeOf(context).height,
      'top': MediaQuery.paddingOf(context).top,
      'bottom': MediaQuery.paddingOf(context).bottom,
    },
    'ready': ready,
    'page': controller.pageNumber,
    'count': controller.pageCount,
    'pages': pages,
    'paints': paints,
    'taps': taps,
    'links': links.map((uri) => uri.toString()).toList(),
    'columns': layout.columns,
    'layouts': layouts.map((value) => value.columns).toList(),
    'errors': errors.map((error) => error.toString()).toList(),
  };

  void grid() =>
      setState(() => layout = const PdfViewerLayout.grid(columns: 3));
  void vertical() => setState(() => layout = PdfViewerLayout.vertical);

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: PdfViewer.file(
        widget.path,
        controller: controller,
        initialPageNumber: 2,
        params: PdfViewerParams(
          engine: PdfViewerEngine.pdfKit,
          layout: layout,
          onViewerReady: (_) => ready++,
          onPageChanged: pages.add,
          onFirstPageRendered: paints.add,
          onPageTap: taps.add,
          onExternalLinkTap: links.add,
          onLayoutChanged: (value) => setState(() {
            layout = value;
            layouts.add(value);
          }),
          onError: (error, _) => errors.add(error),
        ),
      ),
    ),
  );
}
