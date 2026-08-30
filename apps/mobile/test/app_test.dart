import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:persalone_mobile/main.dart';

void main() {
  testWidgets('shows product states, live controls and evidence limits', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const PersalOneApp());

    expect(find.text('PersalOne HORIZON'), findsOneWidget);
    expect(find.text('Dispositivo'), findsOneWidget);
    expect(find.textContaining('Halo'), findsOneWidget);
    expect(find.textContaining('BLOCKED'), findsWidgets);
    expect(find.text('Solicitar micrófono'), findsOneWidget);
    expect(find.text('Iniciar captura real'), findsOneWidget);

    final conversation = find.text('Conversación en vivo / EN ↔ ES');
    await tester.scrollUntilVisible(
      conversation,
      300,
      scrollable: find.byType(Scrollable),
    );
    expect(conversation, findsOneWidget);

    final startLiveTranslation = find.text('Iniciar traducción en vivo');
    await tester.scrollUntilVisible(
      startLiveTranslation,
      300,
      scrollable: find.byType(Scrollable),
    );
    expect(startLiveTranslation, findsOneWidget);

    final agents = find.text('Agentes y permisos');
    await tester.scrollUntilVisible(
      agents,
      300,
      scrollable: find.byType(Scrollable),
    );
    expect(agents, findsOneWidget);
    final memory = find.textContaining('Memoria de agente');
    await tester.scrollUntilVisible(
      memory,
      300,
      scrollable: find.byType(Scrollable),
    );
    expect(memory, findsOneWidget);

    final privacy = find.text('Privacidad, diagnósticos y latencia');
    await tester.scrollUntilVisible(
      privacy,
      300,
      scrollable: find.byType(Scrollable),
    );
    expect(privacy, findsOneWidget);
    final latency = find.textContaining('No medida');
    await tester.scrollUntilVisible(
      latency,
      300,
      scrollable: find.byType(Scrollable),
    );
    expect(latency, findsOneWidget);
  });
}
