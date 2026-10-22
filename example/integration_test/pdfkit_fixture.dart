import 'dart:convert';
import 'dart:typed_data';

/// Small, deterministic PDF with real text, nested outlines and annotation actions.
Uint8List pdfKitFixture() {
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R /Outlines 10 0 R >>',
    '<< /Type /Pages /Kids [3 0 R 5 0 R 7 0 R] /Count 3 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 800] '
        '/Resources << /Font << /F1 9 0 R >> >> /Contents 4 0 R >>',
    _stream('BT /F1 28 Tf 40 700 Td (needle page one) Tj ET'),
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 800] '
        '/Resources << /Font << /F1 9 0 R >> >> /Contents 6 0 R '
        '/Annots [14 0 R 15 0 R 16 0 R 17 0 R 18 0 R 19 0 R] >>',
    _stream(
      'BT /F1 28 Tf 40 700 Td (needle page two) Tj '
      '0 -170 Td (NEXT           PREVIOUS) Tj '
      '0 -100 Td (INTERNAL PAGE ONE) Tj '
      '0 -100 Td (EXTERNAL HTTPS) Tj '
      '0 -100 Td (BLOCKED FILE URL) Tj ET',
    ),
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 800 600] '
        '/Resources << /Font << /F1 9 0 R >> >> /Contents 8 0 R >>',
    _stream('BT /F1 28 Tf 40 500 Td (needle page three landscape) Tj ET'),
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
    '<< /Type /Outlines /First 11 0 R /Last 13 0 R /Count 3 >>',
    '<< /Title (Group) /Parent 10 0 R /First 12 0 R /Last 12 0 R '
        '/Next 13 0 R /Count 1 >>',
    '<< /Title (Page three) /Parent 11 0 R /Dest [7 0 R /XYZ 40 500 0] >>',
    '<< /Title (Unresolved) /Parent 10 0 R /Prev 11 0 R >>',
    '<< /Type /Annot /Subtype /Widget /FT /Btn /Ff 65536 /F 4 '
        '/Rect [40 500 190 565] /A << /S /Named /N /NextPage >> >>',
    '<< /Type /Annot /Subtype /Widget /FT /Btn /Ff 65536 /F 4 '
        '/Rect [220 500 480 565] /A << /S /Named /N /PrevPage >> >>',
    '<< /Type /Annot /Subtype /Link /Rect [40 400 440 465] /Border [0 0 0] '
        '/Dest [3 0 R /XYZ 40 700 0] >>',
    '<< /Type /Annot /Subtype /Link /Rect [40 300 440 365] /Border [0 0 0] '
        '/A << /S /URI /URI (https://example.com/pdf) >> >>',
    '<< /Type /Annot /Subtype /Link /Rect [40 200 440 265] /Border [0 0 0] '
        '/A << /S /URI /URI (file:///etc/passwd) >> >>',
    // Targetless annotation deliberately overlaps the valid internal link.
    '<< /Type /Annot /Subtype /Link /Rect [40 400 440 465] /Border [0 0 0] >>',
  ];
  final output = BytesBuilder()..add(ascii.encode('%PDF-1.7\n'));
  final offsets = <int>[0];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(output.length);
    output.add(ascii.encode('${i + 1} 0 obj\n${objects[i]}\nendobj\n'));
  }
  final xref = output.length;
  output.add(
    ascii.encode('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n'),
  );
  for (final offset in offsets.skip(1)) {
    output.add(
      ascii.encode('${offset.toString().padLeft(10, '0')} 00000 n \n'),
    );
  }
  output.add(
    ascii.encode(
      'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n',
    ),
  );
  return output.takeBytes();
}

String _stream(String content) =>
    '<< /Length ${content.length} >>\nstream\n$content\nendstream';
