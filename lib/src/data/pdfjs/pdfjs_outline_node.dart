import 'package:flutter/foundation.dart';

/// An entry of the document outline (bookmarks).
@immutable
class PdfJsOutlineNode {
  const PdfJsOutlineNode({
    required this.title,
    this.pageNumber,
    this.children = const [],
    this.path = const [],
    this.destinationPath,
  });

  final String title;

  /// 1-based target page, `null` when the entry has no in-document destination.
  final int? pageNumber;
  final List<PdfJsOutlineNode> children;

  /// Index path from the outline root; identifies the entry inside the viewer.
  final List<int> path;

  /// Path of this entry's own target, or its first target-bearing descendant.
  ///
  /// PDF outlines commonly use group headings without a direct destination.
  final List<int>? destinationPath;

  static List<PdfJsOutlineNode> listFromJson(List<Object?> items) {
    return [
      for (final item in items)
        if (item is Map<String, Object?>) ?_fromJson(item),
    ];
  }

  static PdfJsOutlineNode? _fromJson(Map<String, Object?> json) {
    final title = json['title'];
    final path = json['path'];
    if (title is! String || path is! List<Object?> || path.any((index) => index is! int)) {
      return null;
    }
    final pageNumber = json['pageNumber'];
    final children = json['children'];
    final destinationPath = json['destinationPath'];
    return PdfJsOutlineNode(
      title: title,
      pageNumber: pageNumber is int && pageNumber > 0 ? pageNumber : null,
      children: children is List<Object?> ? listFromJson(children) : const [],
      path: List.unmodifiable(path.cast<int>()),
      destinationPath:
          destinationPath is List<Object?> && destinationPath.every((index) => index is int)
          ? List.unmodifiable(destinationPath.cast<int>())
          : null,
    );
  }
}
