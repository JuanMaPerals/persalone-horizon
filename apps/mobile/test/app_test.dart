import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:persalone_mobile/main.dart';

void main() {
  testWidgets('shows Android-first G3/G4 and G5 controls with evidence limits', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const PersalOneApp());

    expect(find.text('PersalOne HORIZON — Android'), findsOneWidget);
    expect(find.text('G3/G4: host audio real'), findsOneWidget);
    expect(find.textContaining('PREPARED'), findsWidgets);
    expect(find.textContaining('Halo audio'), findsOneWidget);
    expect(find.text('Solicitar micrófono'), findsOneWidget);
    expect(find.text('Iniciar captura real'), findsOneWidget);

    final g5Heading = find.textContaining('G5: Live Translator');
    await tester.scrollUntilVisible(
      g5Heading,
      300,
      scrollable: find.byType(Scrollable),
    );
    expect(g5Heading, findsOneWidget);
    final startLiveTranslation = find.text('Iniciar traducción en vivo');
    await tester.scrollUntilVisible(
      startLiveTranslation,
      300,
      scrollable: find.byType(Scrollable),
    );
    expect(startLiveTranslation, findsOneWidget);
  });
}
