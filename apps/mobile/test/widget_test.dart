import 'package:flutter_test/flutter_test.dart';
import 'package:persalone_mobile/main.dart';

void main() {
  testWidgets('declares Android host and Halo evidence boundaries', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const PersalOneApp());

    expect(find.text('Dispositivo'), findsOneWidget);
    expect(find.textContaining('Host Android'), findsOneWidget);
    expect(find.textContaining('Halo'), findsOneWidget);
    expect(find.textContaining('BLOCKED'), findsWidgets);
    expect(find.textContaining('PREPARED'), findsWidgets);
  });
}
