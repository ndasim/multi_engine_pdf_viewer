import 'package:flutter_test/flutter_test.dart';

import 'package:pdfjs_perf_harness/main.dart';

void main() {
  test('uses the supplied fixture asset path', () {
    expect(profilingFixtureAssetPath, 'assets/6474643.pdf');
  });
}
