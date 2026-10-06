import 'dart:async';
import 'dart:developer';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_pdf_viewer/src/data/pdfjs/pdfjs_bundle.dart';
import 'package:flutter_pdf_viewer/src/data/pdfjs/pdfjs_viewer.dart';
import 'package:flutter_pdf_viewer/src/data/pdfjs/pdfjs_viewer_params.dart';

const String profilingFixtureAssetPath = 'assets/6474643.pdf';

void main() => runApp(const PdfJsProfilingHarnessApp());

class PdfJsProfilingHarnessApp extends StatelessWidget {
  const PdfJsProfilingHarnessApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PDF.js profiler', // TODO: use localization
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF006D77)),
        useMaterial3: true,
      ),
      home: const PdfJsProfilingHarnessScreen(),
    );
  }
}

class PdfJsProfilingHarnessScreen extends StatefulWidget {
  const PdfJsProfilingHarnessScreen({super.key});

  @override
  State<PdfJsProfilingHarnessScreen> createState() => _PdfJsProfilingHarnessScreenState();
}

class _PdfJsProfilingHarnessScreenState extends State<PdfJsProfilingHarnessScreen> {
  int _runId = 0;
  File? _document;
  PdfJsViewerController? _controller;
  VoidCallback? _controllerListener;
  Stopwatch? _viewerStopwatch;
  Stopwatch? _outlineStopwatch;
  TimelineTask? _viewerTask;
  TimelineTask? _firstPageTask;
  TimelineTask? _outlineTask;
  Duration? _copyDuration;
  Duration? _readyDuration;
  Duration? _firstPageDuration;
  Duration? _outlineDuration;
  Object? _error;
  _HarnessPhase _phase = _HarnessPhase.copyingAsset;

  @override
  void initState() {
    super.initState();
    unawaited(_prepareRun());
  }

  @override
  void dispose() {
    _detachController();
    super.dispose();
  }

  Future<void> _prepareRun() async {
    final int runId = ++_runId;
    _detachController();
    setState(() {
      _document = null;
      _copyDuration = null;
      _readyDuration = null;
      _firstPageDuration = null;
      _outlineDuration = null;
      _error = null;
      _phase = _HarnessPhase.copyingAsset;
    });

    final copyStopwatch = Stopwatch()..start();
    final copyTask = TimelineTask(filterKey: 'pdfjs-harness')
      ..start('fixture_copy', arguments: {'run': runId, 'asset': profilingFixtureAssetPath});
    try {
      final document = await _copyFixture();
      copyStopwatch.stop();
      copyTask.finish(arguments: {'run': runId, 'bytes': await document.length()});
      _reportDuration('fixture_copy', runId, copyStopwatch.elapsed);
      if (!mounted || runId != _runId) return;

      final controller = PdfJsViewerController();
      void listener() => _onControllerChanged(runId, controller);
      controller.addListener(listener);
      final viewerTask = TimelineTask(filterKey: 'pdfjs-harness')
        ..start('viewer_open', arguments: {'run': runId});
      final firstPageTask = TimelineTask(filterKey: 'pdfjs-harness')
        ..start('first_page_wait', arguments: {'run': runId});
      setState(() {
        _document = document;
        _controller = controller;
        _controllerListener = listener;
        _copyDuration = copyStopwatch.elapsed;
        _viewerStopwatch = Stopwatch()..start();
        _viewerTask = viewerTask;
        _firstPageTask = firstPageTask;
        _phase = _HarnessPhase.openingViewer;
      });
    } catch (error) {
      copyStopwatch.stop();
      copyTask.finish(arguments: {'run': runId, 'error': error.runtimeType.toString()});
      if (!mounted || runId != _runId) return;
      setState(() {
        _copyDuration = copyStopwatch.elapsed;
        _error = error;
        _phase = _HarnessPhase.failed;
      });
    }
  }

  Future<File> _copyFixture() async {
    final data = await rootBundle.load(profilingFixtureAssetPath);
    final directory = await getApplicationDocumentsDirectory();
    final file = File('${directory.path}/6474643.pdf');
    await file.writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      flush: true,
    );
    return file;
  }

  void _onViewerReady(int runId, PdfJsViewerController controller) {
    if (!mounted || runId != _runId || !identical(_controller, controller)) return;
    final stopwatch = _viewerStopwatch;
    if (stopwatch == null || _readyDuration != null) return;

    final duration = stopwatch.elapsed;
    _viewerTask?.finish(arguments: {'run': runId, 'elapsedUs': duration.inMicroseconds});
    _reportDuration('viewer_ready', runId, duration);
    _outlineStopwatch = Stopwatch()..start();
    _outlineTask = TimelineTask(filterKey: 'pdfjs-harness')
      ..start('outline_wait', arguments: {'run': runId});
    setState(() {
      _readyDuration = duration;
      _phase = _HarnessPhase.ready;
    });
  }

  void _onFirstPageRendered(int runId, PdfJsViewerController controller, int pageNumber) {
    if (!mounted || runId != _runId || !identical(_controller, controller)) return;
    if (_firstPageDuration != null) return;

    final stopwatch = _viewerStopwatch;
    if (stopwatch == null) return;
    stopwatch.stop();
    final duration = stopwatch.elapsed;
    _firstPageTask?.finish(arguments: {'run': runId, 'elapsedUs': duration.inMicroseconds});
    _reportDuration('first_page_rendered', runId, duration, pageNumber: pageNumber);
    setState(() => _firstPageDuration = duration);
  }

  void _onControllerChanged(int runId, PdfJsViewerController controller) {
    if (!mounted || runId != _runId || !identical(_controller, controller)) return;
    if (controller.outline == null || _outlineDuration != null) return;

    final stopwatch = _outlineStopwatch;
    if (stopwatch == null) return;
    stopwatch.stop();
    final duration = stopwatch.elapsed;
    _outlineTask?.finish(arguments: {'run': runId, 'elapsedUs': duration.inMicroseconds});
    _reportDuration('outline_ready', runId, duration);
    setState(() => _outlineDuration = duration);
  }

  void _onViewerError(int runId, Object error) {
    if (!mounted || runId != _runId) return;
    _viewerTask?.finish(arguments: {'run': runId, 'error': error.runtimeType.toString()});
    log('viewer_error run=$runId type=${error.runtimeType}', name: 'pdfjs-harness');
    setState(() {
      _error = error;
      _phase = _HarnessPhase.failed;
    });
  }

  void _detachController() {
    final controller = _controller;
    final listener = _controllerListener;
    if (controller != null && listener != null) controller.removeListener(listener);
    controller?.dispose();
    _controller = null;
    _controllerListener = null;
    _viewerStopwatch = null;
    _outlineStopwatch = null;
    _firstPageTask = null;
  }

  void _reportDuration(String event, int runId, Duration duration, {int? pageNumber}) {
    final page = pageNumber == null ? '' : ' page=$pageNumber';
    final message = '$event run=$runId$page elapsedUs=${duration.inMicroseconds}';
    log(message, name: 'pdfjs-harness');
    debugPrint('PDFJS_HARNESS $message');
  }

  @override
  Widget build(BuildContext context) {
    final document = _document;
    final controller = _controller;
    final int runId = _runId;
    return Scaffold(
      appBar: AppBar(
        title: const Text('PDF.js profiler'), // TODO: use localization
        actions: [
          IconButton(
            onPressed: _phase == _HarnessPhase.copyingAsset ? null : _prepareRun,
            tooltip: 'Reload fixture', // TODO: use localization
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (document != null && controller != null)
            PdfJsViewer.file(
              document.path,
              key: ValueKey<int>(runId),
              controller: controller,
              params: PdfJsViewerParams(
                loadingBuilder: (_) => const Center(child: CircularProgressIndicator()),
                onViewerReady: (readyController) => _onViewerReady(runId, readyController),
                onFirstPageRendered: (pageNumber) =>
                    _onFirstPageRendered(runId, controller, pageNumber),
                onError: (error, _) => _onViewerError(runId, error),
              ),
            )
          else
            const Center(child: CircularProgressIndicator()),
          Align(
            alignment: Alignment.topCenter,
            child: SafeArea(
              child: _MetricsPanel(
                copyDuration: _copyDuration,
                readyDuration: _readyDuration,
                firstPageDuration: _firstPageDuration,
                outlineDuration: _outlineDuration,
                phase: _phase,
                error: _error,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricsPanel extends StatelessWidget {
  const _MetricsPanel({
    required this.copyDuration,
    required this.readyDuration,
    required this.firstPageDuration,
    required this.outlineDuration,
    required this.phase,
    required this.error,
  });

  final Duration? copyDuration;
  final Duration? readyDuration;
  final Duration? firstPageDuration;
  final Duration? outlineDuration;
  final _HarnessPhase phase;
  final Object? error;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.all(8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colorScheme.surface.withValues(alpha: 0.94),
        border: Border.all(color: colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_phaseLabel(phase), style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 4),
          Wrap(
            spacing: 12,
            runSpacing: 2,
            children: [
              _Metric(
                label: 'Asset',
                value: _formatDuration(copyDuration),
              ), // TODO: use localization
              _Metric(
                label: 'Bootstrap',
                value: _formatDuration(readyDuration),
              ), // TODO: use localization
              _Metric(
                label: 'Paint',
                value: _formatDuration(firstPageDuration),
              ), // TODO: use localization
              _Metric(
                label: 'Outline',
                value: _formatDuration(outlineDuration),
              ), // TODO: use localization
            ],
          ),
          if (error != null) ...[
            const SizedBox(height: 4),
            Text(error.runtimeType.toString(), style: TextStyle(color: colorScheme.error)),
          ],
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Text('$label $value');
}

enum _HarnessPhase { copyingAsset, openingViewer, ready, failed }

String _phaseLabel(_HarnessPhase phase) => switch (phase) {
  _HarnessPhase.copyingAsset => 'Copying asset', // TODO: use localization
  _HarnessPhase.openingViewer => 'Opening viewer', // TODO: use localization
  _HarnessPhase.ready => 'First page ready', // TODO: use localization
  _HarnessPhase.failed => 'Load failed', // TODO: use localization
};

String _formatDuration(Duration? duration) {
  if (duration == null) return '-';
  return '${duration.inMilliseconds} ms';
}
