import 'package:flutter/services.dart';
import 'package:multi_engine_pdf_viewer/multi_engine_pdf_viewer.dart';
import 'package:multi_engine_pdf_viewer/src/data/pdfrx/pdf_font_fallback.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

class _Fonts implements PdfrxEntryFunctions {
  final registered = <({String face, List<int> bytes, String? resolvedFace})>[];
  int reloadCount = 0;

  @override
  Future<void> addFontData({required String face, required Uint8List data, String? resolvedFace}) async {
    registered.add((face: face, bytes: List.of(data), resolvedFace: resolvedFace));
  }

  @override
  Future<void> reloadFonts() async => reloadCount++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const registrations = [
    PdfFontRegistration.asset(face: 'Helvetica', asset: 'host.ttf', resolvedFace: 'Host Font'),
    PdfFontRegistration.asset(face: 'Arial', asset: 'host.ttf', resolvedFace: 'Host Font'),
  ];

  test('uses only injected assets and respects ByteData offsets', () async {
    final backend = _Fonts();
    final loaded = <String>[];
    final bytes = Uint8List.fromList([99, 1, 2, 3, 99]);
    final fallback = PdfFontFallback(
      faces: registrations,
      initialize: () async {},
      loadAsset: (key) async {
        loaded.add(key);
        return ByteData.view(bytes.buffer, 1, 3);
      },
      entryFunctions: backend,
    );
    await fallback.ensureFallbackFonts();
    expect(loaded, ['host.ttf']);
    expect(backend.registered.map((entry) => entry.face), ['Helvetica', 'Arial']);
    expect(backend.registered.first.bytes, [1, 2, 3]);
    expect(backend.registered.first.resolvedFace, 'Host Font');
    expect(backend.reloadCount, 1);
  });

  test('concurrent calls share registration and do not reload twice', () async {
    final backend = _Fonts();
    final fallback = PdfFontFallback(
      faces: registrations,
      initialize: () async {},
      loadAsset: (_) async => ByteData(4),
      entryFunctions: backend,
    );
    await Future.wait([fallback.ensureFallbackFonts(), fallback.ensureFallbackFonts()]);
    await fallback.ensureFallbackFonts();
    expect(backend.registered.length, 2);
    expect(backend.reloadCount, 1);
  });

  test('failed initialization is retried rather than cached forever', () async {
    var attempts = 0;
    final fallback = PdfFontFallback(
      faces: registrations,
      initialize: () async {
        if (++attempts == 1) throw StateError('initialization failed');
      },
      loadAsset: (_) async => ByteData(4),
      entryFunctions: _Fonts(),
    );
    await expectLater(fallback.ensureFallbackFonts(), throwsStateError);
    await fallback.ensureFallbackFonts();
    expect(attempts, 2);
  });
}