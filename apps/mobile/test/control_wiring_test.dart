import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:persalone_contracts/persalone_contracts.dart';
import 'package:persalone_mobile/main.dart';

void main() {
  Future<_FakeControl> pump(WidgetTester tester) async {
    final _FakeControl control = _FakeControl();
    await tester.pumpWidget(
        MaterialApp(home: AndroidHostAudioScreen(control: control)));
    return control;
  }

  testWidgets('PANIC is always reachable and goes through the control port',
      (WidgetTester tester) async {
    final _FakeControl control = await pump(tester);

    await tester.tap(find.byKey(const Key('panic-button')));
    await tester.pumpAndSettle();

    final RuntimeCommand command = control.commands.single;
    expect(command, isA<PanicCommand>());
    expect(command.origin, ControlOrigin.local);
    await _scrollTo(tester, find.textContaining('PANIC ejecutado'));
    expect(find.textContaining('buffers efímeros vaciados'), findsOneWidget);
  });

  testWidgets('PANIC reports components whose cleanup failed',
      (WidgetTester tester) async {
    final _FakeControl control = await pump(tester);
    control.panicFailures = <String>['captions'];

    await tester.tap(find.byKey(const Key('panic-button')));
    await tester.pumpAndSettle();

    await _scrollTo(tester, find.textContaining('fallos de limpieza'));
    expect(find.textContaining('captions'), findsOneWidget);
  });

  testWidgets('language changes are sent as next-session commands',
      (WidgetTester tester) async {
    final _FakeControl control = await pump(tester);
    final Finder dropdown =
        find.byType(DropdownButtonFormField<TranslationDirection>);
    await _scrollTo(tester, dropdown);

    await tester.tap(dropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Español → Inglés').last);
    await tester.pumpAndSettle();

    final SetLanguageCommand command =
        control.commands.whereType<SetLanguageCommand>().single;
    expect(command.direction, TranslationDirection.spanishToEnglish);
    expect(command.origin, ControlOrigin.local);
    final Finder pendingCard =
        find.textContaining('Pendiente (próxima sesión): Español → Inglés');
    await _scrollTo(tester, pendingCard, up: true);
    expect(pendingCard, findsOneWidget);
  });

  testWidgets('start without per-session consent sends no command',
      (WidgetTester tester) async {
    final _FakeControl control = await pump(tester);
    final Finder start = find.text('Iniciar traducción en vivo');
    await _scrollTo(tester, start);

    await tester.tap(start);
    await tester.pumpAndSettle();

    expect(control.commands, isEmpty);
    final Finder blocked = find.textContaining('G5 bloqueado');
    await _scrollTo(tester, blocked, up: true);
    expect(blocked, findsOneWidget);
  });
}

Future<void> _scrollTo(WidgetTester tester, Finder finder, {bool up = false}) =>
    tester.scrollUntilVisible(finder, up ? -300 : 300,
        scrollable: find.byType(Scrollable).first);

final class _FakeControl implements RuntimeControlPort {
  final List<RuntimeCommand> commands = <RuntimeCommand>[];
  List<String> panicFailures = const <String>[];
  TranslationDirection pending = TranslationDirection.englishToSpanish;

  @override
  Stream<CommandResult> get results => const Stream<CommandResult>.empty();

  @override
  LanguageState get language =>
      LanguageState(effective: null, pending: pending);

  @override
  String? get activeSessionId => null;

  @override
  int get sessionGeneration => 0;

  @override
  Future<CommandResult> execute(RuntimeCommand command) async {
    commands.add(command);
    if (command is SetLanguageCommand) pending = command.direction;
    return CommandResult(
      commandId: command.commandId,
      kind: command.kind,
      origin: command.origin,
      status: CommandStatus.accepted,
      observedAtMicros: 1,
      failedCleanup: command is PanicCommand ? panicFailures : const <String>[],
    );
  }
}
