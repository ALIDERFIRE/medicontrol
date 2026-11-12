import 'package:flutter_test/flutter_test.dart';
import 'package:medicontrol/main.dart';

void main() {
  testWidgets('La app MediControl arranca', (WidgetTester tester) async {
    await tester.pumpWidget(const MediControlApp());
    expect(find.byType(MediControlApp), findsOneWidget);
  });
}
