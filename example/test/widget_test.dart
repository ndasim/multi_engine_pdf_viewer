import 'package:flutter_test/flutter_test.dart';
import 'package:multi_engine_pdf_viewer_example/main.dart';

void main() {
  testWidgets('shows an empty state until a PDF is opened', (tester) async {
    await tester.pumpWidget(const ExampleApp());

    expect(find.text('Open a PDF'), findsOneWidget);
    expect(find.text('PDF viewer'), findsOneWidget);
  });
}
