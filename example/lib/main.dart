import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:multi_engine_pdf_viewer/multi_engine_pdf_viewer.dart';

/// Opens a local PDF with PDFKit (iOS), PDF.js, EmbedPDF, or pdfrx.
///
/// Android cleartext access for 127.0.0.1 is configured in
/// `android/app/src/main/res/xml/network_security_config.xml`.
void main() {
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(title: 'PDF viewer example', home: ViewerPage());
  }
}

class ViewerPage extends StatefulWidget {
  const ViewerPage({super.key});

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> {
  final _controller = PdfViewerController();
  late final PdfTextSearcher _searcher = PdfTextSearcher(_controller);
  final _searchController = TextEditingController();

  String? _path;
  var _engine = const PdfViewerParams().engine;

  @override
  void dispose() {
    _searcher.dispose();
    _controller.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _pickPdf() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
    );
    final path = file?.path;
    if (!mounted || path == null) return;
    setState(() => _path = path);
  }

  @override
  Widget build(BuildContext context) {
    final path = _path;
    return Scaffold(
      appBar: AppBar(
        title: ListenableBuilder(
          listenable: _controller,
          builder: (context, _) {
            final page = _controller.pageNumber;
            final count = _controller.pageCount;
            final label = page == null ? 'PDF viewer' : 'Page $page of $count';
            return Text(label);
          },
        ),
        actions: [
          IconButton(
            onPressed: _pickPdf,
            tooltip: 'Open PDF',
            icon: const Icon(Icons.folder_open),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(
              children: [
                DropdownButton<PdfViewerEngine>(
                  value: _engine,
                  items: [
                    if (defaultTargetPlatform == TargetPlatform.iOS)
                      const DropdownMenuItem(
                        value: PdfViewerEngine.pdfKit,
                        child: Text('PDFKit'), // TODO: use localization
                      ),
                    const DropdownMenuItem(
                      value: PdfViewerEngine.pdfJs,
                      child: Text('PDF.js'),
                    ),
                    const DropdownMenuItem(
                      value: PdfViewerEngine.embedPdf,
                      child: Text('EmbedPDF'),
                    ),
                    const DropdownMenuItem(
                      value: PdfViewerEngine.pdfrx,
                      child: Text('pdfrx'),
                    ),
                  ],
                  onChanged: (engine) {
                    if (engine != null) setState(() => _engine = engine);
                  },
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    decoration: const InputDecoration(
                      hintText: 'Search',
                      isDense: true,
                    ),
                    textInputAction: TextInputAction.search,
                    onSubmitted: _searcher.startTextSearch,
                  ),
                ),
                ListenableBuilder(
                  listenable: _searcher,
                  builder: (context, _) {
                    if (_searcher.query.isEmpty) return const SizedBox.shrink();
                    final current = _searcher.currentIndex;
                    final shown = current == null ? 0 : current + 1;
                    return Text('$shown/${_searcher.matchCount}');
                  },
                ),
                IconButton(
                  tooltip: 'Previous match',
                  onPressed: _searcher.goToPrevMatch,
                  icon: const Icon(Icons.keyboard_arrow_up),
                ),
                IconButton(
                  tooltip: 'Next match',
                  onPressed: _searcher.goToNextMatch,
                  icon: const Icon(Icons.keyboard_arrow_down),
                ),
              ],
            ),
          ),
          Expanded(
            child: path == null
                ? const Center(child: Text('Open a PDF'))
                : PdfViewer.file(
                    path,
                    controller: _controller,
                    params: PdfViewerParams(
                      engine: _engine,
                      loadingBuilder: (_) =>
                          const Center(child: CircularProgressIndicator()),
                      errorBuilder: (context, error) =>
                          Center(child: Text('$error')),
                      onExternalLinkTap: (uri) {
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(SnackBar(content: Text(uri.toString())));
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
