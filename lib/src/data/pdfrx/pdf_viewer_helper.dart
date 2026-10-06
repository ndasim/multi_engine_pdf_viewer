import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';

/// Layout type for PDF viewer
enum PdfLayoutType {
  singlePage(0),
  triplePages(1);

  const PdfLayoutType(this.value);
  final int value;
}

/// Helper class for PDF viewer operations
class PdfViewerHelper {
  PdfViewerHelper({this.pagesPerRow = 3, this.onError});

  final int pagesPerRow;
  final void Function(Object error, StackTrace stackTrace)? onError;

  Size? currentViewSize;
  int _resizeOperationEpoch = 0;
  int _layoutOperationEpoch = 0;

  void dispose() {
    _resizeOperationEpoch++;
    _layoutOperationEpoch++;
  }

  Future<void> _runControllerAction(Future<void> Function() action) async {
    try {
      await action();
    } catch (e, s) {
      try {
        onError?.call(e, s);
      } catch (_) {}
    }
  }

  /// Handles view size changes for single page layout
  Future<void> handleSinglePageViewSizeChange({
    required Size viewSize,
    required PdfViewerController controller,
  }) async {
    if (currentViewSize != viewSize) {
      final expectedEpoch = ++_resizeOperationEpoch;
      currentViewSize = viewSize;
      await Future.delayed(const Duration(milliseconds: 200));
      if (controller.isReady && controller.pageNumber != null) {
        if (_resizeOperationEpoch != expectedEpoch) return;
        final pageMatrix = controller.calcMatrixFitWidthForPage(pageNumber: controller.pageNumber!);
        await _runControllerAction(() => controller.goTo(pageMatrix));
      }
    }
  }

  /// Handles view size changes for triple pages layout
  Future<void> handleTriplePagesViewSizeChange({required PdfViewerController controller}) async {
    final expectedEpoch = ++_resizeOperationEpoch;
    await Future.delayed(const Duration(milliseconds: 200));
    if (controller.isReady) {
      if (_resizeOperationEpoch != expectedEpoch) return;
      await _runControllerAction(controller.zoomDown);
    }
  }

  /// Fits the current page to width after layout change
  Future<void> fitPageToWidth(PdfViewerController controller) async {
    final expectedEpoch = ++_layoutOperationEpoch;
    await Future.delayed(const Duration(milliseconds: 200));
    if (controller.isReady && controller.pageNumber != null) {
      if (_layoutOperationEpoch != expectedEpoch) return;
      final pageMatrix = controller.calcMatrixFitWidthForPage(pageNumber: controller.pageNumber!);
      await _runControllerAction(() => controller.goTo(pageMatrix));
    }
  }

  /// Zooms down after layout change
  Future<void> zoomDownAfterLayoutChange(PdfViewerController controller) async {
    final expectedEpoch = ++_layoutOperationEpoch;
    await Future.delayed(const Duration(milliseconds: 200));
    if (controller.isReady) {
      if (_layoutOperationEpoch != expectedEpoch) return;
      await _runControllerAction(controller.zoomDown);
    }
  }

  /// Creates a triple page layout for the PDF viewer
  PdfPageLayout createTriplePageLayout(
    List<PdfPage> pages,
    PdfViewerParams params,
    Size fallbackSize,
  ) {
    if (pages.isEmpty) {
      return PdfPageLayout(pageLayouts: [], documentSize: Size.zero);
    }

    final margin = params.margin;
    final viewSize = currentViewSize ?? fallbackSize;

    // Calculate the scale factor to fit pages within the view width
    final maxPageWidth = pages.fold(0.0, (prev, page) => max(prev, page.width));
    final totalWidthNeeded = (maxPageWidth * pagesPerRow) + (margin * (pagesPerRow + 1));
    final scale = viewSize.width / totalWidthNeeded;

    // Scale page dimensions
    final scaledPageWidth = maxPageWidth * scale;
    final pageLayouts = <Rect>[];
    double y = margin;

    // Group pages in sets of pagesPerRow and position them
    for (int i = 0; i < pages.length; i += pagesPerRow) {
      final pagesInRow = <dynamic>[];
      double maxHeight = 0;

      // Collect pages for this row and find max height
      for (int j = i; j < min(i + pagesPerRow, pages.length); j++) {
        pagesInRow.add(pages[j]);
        final scaledHeight = (pages[j].height) * scale;
        maxHeight = max(maxHeight, scaledHeight);
      }

      // Position each page in the row
      for (int j = 0; j < pagesInRow.length; j++) {
        final page = pagesInRow[j];
        final scaledWidth = (page.width as double) * scale;
        final scaledHeight = (page.height as double) * scale;
        final x = margin + j * (scaledPageWidth + margin);

        pageLayouts.add(
          Rect.fromLTWH(x, y + (maxHeight - scaledHeight) / 2, scaledWidth, scaledHeight),
        );
      }

      y += maxHeight + margin;
    }

    // Calculate final dimensions
    final totalWidth = margin + (scaledPageWidth + margin) * pagesPerRow;
    final totalHeight = max(y, viewSize.height);

    return PdfPageLayout(pageLayouts: pageLayouts, documentSize: Size(totalWidth, totalHeight));
  }

  /// Returns the layout function for the given layout type
  PdfPageLayoutFunction? getLayoutFunction(PdfLayoutType layoutType, Size fallbackSize) {
    switch (layoutType) {
      case PdfLayoutType.singlePage:
        return null;
      case PdfLayoutType.triplePages:
        return (pages, params) => createTriplePageLayout(pages, params, fallbackSize);
    }
  }

  /// Builds page paint callbacks for text search highlighting
  List<PdfViewerPagePaintCallback> buildPagePaintCallbacks(PdfTextSearcher? textSearcher) {
    final callbacks = <PdfViewerPagePaintCallback>[];
    if (textSearcher != null) {
      callbacks.add(textSearcher.pageTextMatchPaintCallback);
    }
    return callbacks;
  }
}
