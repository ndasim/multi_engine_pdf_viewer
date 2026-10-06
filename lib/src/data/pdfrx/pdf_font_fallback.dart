import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../domain/entity/pdf_viewer_state.dart';

/// Registers host-supplied substitutes for non-embedded font faces.
///
/// Registration is process-global, not document-local. This package never
/// clears registrations because other viewers may still be using those faces.
class PdfFontFallback {
  PdfFontFallback({
    required this.faces,
    Future<void> Function()? initialize,
    Future<ByteData> Function(String assetKey)? loadAsset,
    PdfrxEntryFunctions? entryFunctions,
  }) : _initialize = initialize ?? pdfrxFlutterInitialize,
       _loadAsset = loadAsset ?? rootBundle.load,
       _entryFunctions = entryFunctions ?? PdfrxEntryFunctions.instance;

  final List<PdfFontRegistration> faces;

  final Future<void> Function() _initialize;
  final Future<ByteData> Function(String assetKey) _loadAsset;
  final PdfrxEntryFunctions _entryFunctions;

  Future<void>? _registration;

  /// Registers the fallback faces once. Concurrent callers share one
  /// registration; a failed registration is retried by the next caller.
  Future<void> ensureFallbackFonts() {
    final existing = _registration;
    if (existing != null) return existing;

    final registration = _register();
    _registration = registration;
    return registration.catchError((Object error, StackTrace stackTrace) {
      if (identical(_registration, registration)) _registration = null;
      Error.throwWithStackTrace(error, stackTrace);
    });
  }

  Future<void> _register() async {
    await _initialize();

    final loadedAssets = <String, Uint8List>{};
    for (final entry in faces) {
      final data = loadedAssets[entry.asset] ??= await _loadBytes(entry.asset);
      await _entryFunctions.addFontData(
        face: entry.face,
        data: data,
        resolvedFace: entry.resolvedFace,
      );
    }

    await _entryFunctions.reloadFonts();
  }

  Future<Uint8List> _loadBytes(String assetKey) async {
    final data = await _loadAsset(assetKey);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }
}
