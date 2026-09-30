import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:persalone_contracts/persalone_contracts.dart';
import 'package:persalone_translation_runtime/persalone_translation_runtime.dart';
import 'package:test/test.dart';

void main() {
  late _Port port;
  late int nowMicros;
  late RemoteControlGateway gateway;
  int ids = 0;

  Map<String, Object?> envelope(String action,
          {String? id, int? issuedAt, int? generation, int schema = 1}) =>
      <String, Object?>{
        'schemaVersion': schema,
        'commandId': id ?? 'cmd-${(++ids).toString().padLeft(6, '0')}',
        'issuedAt': issuedAt ?? nowMicros,
        'sessionGeneration': generation ?? port.sessionGeneration,
        'action': action,
      };

  setUp(() {
    ids = 0;
    port = _Port()..active = 'session-1';
    nowMicros = 1000000000;
    gateway = RemoteControlGateway(port,
        clock: () => DateTime.fromMicrosecondsSinceEpoch(nowMicros));
  });

  test('remote v1 matrix: allow STOP, PANIC, DEVICE_DISCONNECT; deny the rest',
      () async {
    for (final String action in <String>['stop', 'panic', 'deviceDisconnect']) {
      expect((await gateway.submit(envelope(action))).resultCode,
          ControlResultCode.accepted,
          reason: action);
    }
    port.commands.clear();
    for (final String action in <String>[
      'start',
      'languageChange',
      'deviceConnect',
      'deviceSelect'
    ]) {
      expect((await gateway.submit(envelope(action))).resultCode,
          ControlResultCode.deniedByPolicy,
          reason: action);
    }
    expect(port.commands, isEmpty, reason: 'denied actions never reach G5');
    expect(
        RemoteControlPolicy.matrix.values.where((bool v) => v), hasLength(3));
  });

  test('enabledActions can only narrow the matrix, never widen it', () async {
    final RemoteControlGateway narrow = RemoteControlGateway(port,
        clock: () => DateTime.fromMicrosecondsSinceEpoch(nowMicros),
        enabledActions: <ControlAction>{
          ControlAction.stop,
          ControlAction.panic,
          ControlAction.start,
          ControlAction.deviceSelect,
        });
    expect(narrow.enabledActions,
        <ControlAction>{ControlAction.stop, ControlAction.panic},
        reason: 'START and device select stay denied even when listed');
    for (final String action in <String>[
      'deviceDisconnect',
      'start',
      'deviceSelect',
      'languageChange',
      'deviceConnect'
    ]) {
      expect((await narrow.submit(envelope(action))).resultCode,
          ControlResultCode.deniedByPolicy,
          reason: action);
    }
    expect(port.commands, isEmpty);
    expect((await narrow.submit(envelope('stop'))).resultCode,
        ControlResultCode.accepted);
    expect((await narrow.submit(envelope('panic'))).resultCode,
        ControlResultCode.accepted);
  });

  test('status carries only the generation, the clock and enabled actions',
      () {
    port.generation = 7;
    final RemoteControlGateway narrow = RemoteControlGateway(port,
        clock: () => DateTime.fromMicrosecondsSinceEpoch(nowMicros),
        enabledActions: <ControlAction>{
          ControlAction.panic,
          ControlAction.stop
        });
    expect(narrow.status(), <String, Object?>{
      'schemaVersion': 1,
      'sessionGeneration': 7,
      'observedAt': nowMicros,
      'enabledActions': <String>['stop', 'panic'],
    });
  });

  test(
      'duplicates are not re-executed; reused ids with new content are replays',
      () async {
    final Map<String, Object?> stop = envelope('stop', id: 'fixed-stop-1');
    expect((await gateway.submit(stop)).resultCode, ControlResultCode.accepted);
    expect(
        (await gateway.submit(stop)).resultCode, ControlResultCode.duplicate);
    expect(
        (await gateway.submit(envelope('panic', id: 'fixed-stop-1')))
            .resultCode,
        ControlResultCode.replayed);
    expect(port.commands, hasLength(1));

    final Map<String, Object?> panic = envelope('panic', id: 'fixed-panic');
    await gateway.submit(panic);
    expect(
        (await gateway.submit(panic)).resultCode, ControlResultCode.duplicate,
        reason: 'Panic stays deduplicable');
    expect(port.commands.whereType<PanicCommand>(), hasLength(1));
  });

  test('expired and future-dated commands are rejected, Panic included',
      () async {
    expect(
        (await gateway.submit(envelope('stop',
                issuedAt:
                    nowMicros - const Duration(seconds: 31).inMicroseconds)))
            .resultCode,
        ControlResultCode.expired);
    expect(
        (await gateway.submit(envelope('panic',
                issuedAt:
                    nowMicros - const Duration(seconds: 31).inMicroseconds)))
            .resultCode,
        ControlResultCode.expired);
    expect(
        (await gateway.submit(envelope('stop',
                issuedAt:
                    nowMicros + const Duration(seconds: 6).inMicroseconds)))
            .resultCode,
        ControlResultCode.notYetValid);
    expect(port.commands, isEmpty);
  });

  test('stale generation blocks STOP and disconnect but never PANIC', () async {
    port.generation = 3;
    expect((await gateway.submit(envelope('stop', generation: 2))).resultCode,
        ControlResultCode.staleGeneration);
    expect(
        (await gateway.submit(envelope('deviceDisconnect', generation: 2)))
            .resultCode,
        ControlResultCode.staleGeneration);
    expect((await gateway.submit(envelope('panic', generation: 2))).resultCode,
        ControlResultCode.accepted);
    expect(port.commands.single, isA<PanicCommand>());
  });

  test('ordinary rate limit; Panic bypasses it', () async {
    for (int i = 0; i < 5; i++) {
      expect((await gateway.submit(envelope('stop'))).resultCode,
          ControlResultCode.accepted);
    }
    expect((await gateway.submit(envelope('stop'))).resultCode,
        ControlResultCode.rateLimited);
    for (int i = 0; i < 10; i++) {
      expect((await gateway.submit(envelope('panic'))).resultCode,
          ControlResultCode.accepted);
    }
    nowMicros += const Duration(seconds: 11).inMicroseconds;
    expect((await gateway.submit(envelope('stop'))).resultCode,
        ControlResultCode.accepted);
  });

  test('unsupported schema and arbitrary execution fields are rejected',
      () async {
    expect((await gateway.submit(envelope('stop', schema: 2))).resultCode,
        ControlResultCode.unsupportedSchema);
    for (final String extra in <String>['payload', 'lua', 'exec', 'command']) {
      final Map<String, Object?> hostile = envelope('stop')..[extra] = 'x';
      expect((await gateway.submit(hostile)).resultCode,
          ControlResultCode.malformed,
          reason: extra);
    }
    expect(port.commands, isEmpty);
  });

  test('fuzz: 5000 mutated envelopes; only valid ones ever reach G5', () async {
    final Random random = Random(20260925);
    int reached = 0;
    int validSubmitted = 0;
    for (int i = 0; i < 5000; i++) {
      final Object? raw = _mutate(
          random,
          envelope(
              <String>[
                'stop',
                'panic',
                'deviceDisconnect',
                'start'
              ][random.nextInt(4)],
              id: 'fz-${i.toString().padLeft(6, '0')}'));
      final bool valid = _referenceValid(raw);
      if (valid) validSubmitted++;
      final int before = port.commands.length;
      final ControlCommandResult result = await gateway.submit(raw);
      final bool executed = port.commands.length > before;
      if (executed) reached++;
      if (!valid) {
        expect(executed, isFalse, reason: jsonEncode(raw));
        expect(<ControlResultCode>[
          ControlResultCode.malformed,
          ControlResultCode.unsupportedSchema
        ], contains(result.resultCode), reason: jsonEncode(raw));
        expect(result.commandId, isNull);
      }
      expect(result.toJson().keys.toSet(), <String>{
        'schemaVersion',
        'commandId',
        'action',
        'resultCode',
        'sessionGeneration',
        'observedAt'
      });
    }
    expect(validSubmitted, greaterThan(500));
    expect(reached, greaterThan(0));
  });

  test('composes with the real controller: remote STOP works, START denied',
      () async {
    final _Runtime rig = _Runtime();
    final RemoteControlGateway real = RemoteControlGateway(rig.control,
        clock: () => DateTime.fromMicrosecondsSinceEpoch(nowMicros));
    Map<String, Object?> env(String action) => <String, Object?>{
          'schemaVersion': 1,
          'commandId': 'real-${(++ids).toString().padLeft(6, '0')}',
          'issuedAt': nowMicros,
          'sessionGeneration': rig.control.sessionGeneration,
          'action': action,
        };

    expect((await real.submit(env('start'))).resultCode,
        ControlResultCode.deniedByPolicy);
    expect(rig.runtime.state, HorizonTranslationRuntimeState.idle);

    await rig.startLocal();
    expect(rig.control.sessionGeneration, 1);
    expect((await real.submit(env('stop'))).resultCode,
        ControlResultCode.accepted);
    expect(rig.runtime.state, HorizonTranslationRuntimeState.stopped);
    expect((await real.submit(env('stop'))).resultCode,
        ControlResultCode.rejectedByRuntime);
    await rig.dispose();
  });
}

/// Independent reference validator for the fuzz oracle.
bool _referenceValid(Object? raw) {
  if (raw is! Map) return false;
  const Set<String> keys = <String>{
    'schemaVersion',
    'commandId',
    'issuedAt',
    'sessionGeneration',
    'action'
  };
  if (raw.length != 5 || !raw.keys.every(keys.contains)) return false;
  final Object? id = raw['commandId'];
  return raw['schemaVersion'] == 1 &&
      id is String &&
      RegExp(r'^[A-Za-z0-9_-]{8,64}$').hasMatch(id) &&
      raw['issuedAt'] is int &&
      (raw['issuedAt'] as int) >= 0 &&
      raw['sessionGeneration'] is int &&
      (raw['sessionGeneration'] as int) >= 0 &&
      ControlAction.values.any((ControlAction a) => a.name == raw['action']);
}

Object? _mutate(Random random, Map<String, Object?> base) {
  final Map<String, Object?> m = Map<String, Object?>.of(base);
  const List<String> keys = <String>[
    'schemaVersion',
    'commandId',
    'issuedAt',
    'sessionGeneration',
    'action'
  ];
  final List<Object?> junk = <Object?>[
    null,
    true,
    -1,
    1.5,
    '',
    'x' * 200,
    'stop; rm -rf /',
    '")os.execute(',
    '\u0000',
    'panic\n',
    'PANIC',
    <Object?>[1, 2],
    <String, Object?>{'a': 1},
    2,
    99999999999,
    'id with spaces',
    'ok-id-123',
  ];
  switch (random.nextInt(8)) {
    case 0:
      return m; // valid
    case 1:
      m.remove(keys[random.nextInt(keys.length)]);
    case 2:
      m[<String>[
        'payload',
        'lua',
        'exec',
        'argv',
        'url',
        'text'
      ][random.nextInt(6)]] = junk[random.nextInt(junk.length)];
    case 3:
      m[keys[random.nextInt(keys.length)]] = junk[random.nextInt(junk.length)];
    case 4:
      m['action'] = <String>[
        'reboot',
        'eval',
        'shell',
        'start',
        'stop '
      ][random.nextInt(5)];
    case 5:
      return <Object?>[m];
    case 6:
      return junk[random.nextInt(junk.length)];
    case 7:
      m['schemaVersion'] = random.nextInt(4);
  }
  return m;
}

final class _Port implements RuntimeControlPort {
  final List<RuntimeCommand> commands = <RuntimeCommand>[];
  String? active;
  int generation = 0;

  @override
  Stream<CommandResult> get results => const Stream<CommandResult>.empty();
  @override
  LanguageState get language => const LanguageState(
      effective: null, pending: TranslationDirection.englishToSpanish);
  @override
  String? get activeSessionId => active;
  @override
  int get sessionGeneration => generation;
  @override
  Future<CommandResult> execute(RuntimeCommand command) async {
    commands.add(command);
    expect(command.origin, ControlOrigin.remote);
    return CommandResult(
      commandId: command.commandId,
      kind: command.kind,
      origin: command.origin,
      status: CommandStatus.accepted,
      observedAtMicros: 1,
    );
  }
}

/// Minimal real runtime + controller with inert SIMULATED providers.
final class _Runtime {
  _Runtime() {
    runtime = HorizonTranslationRuntime(
      input: _Input(),
      stt: _Stt(),
      translator: _Translator(),
      synthesizer: _Tts(),
    );
    control = HorizonRuntimeController(runtime: runtime);
  }

  late final HorizonTranslationRuntime runtime;
  late final HorizonRuntimeController control;

  Future<void> startLocal() async {
    final CommandResult result = await control.execute(const StartCommand(
      commandId: 'local-start',
      origin: ControlOrigin.local,
      consent: TranslationConsent(
        acceptedAtMicros: 1,
        localProcessingAllowed: true,
        modelDownloadAllowed: false,
        remoteProcessingAllowed: false,
      ),
    ));
    expect(result.status, CommandStatus.accepted);
  }

  Future<void> dispose() async {
    await control.dispose();
    await runtime.dispose();
  }
}

final class _Input implements AudioInputAdapter {
  @override
  String get adapterId => 'gw-input';
  @override
  String get sourceRevision => 'test';
  @override
  Stream<AudioFrame> get frames => const Stream.empty();
  @override
  Stream<AudioAdapterSnapshot> get snapshots => const Stream.empty();
  @override
  Stream<AudioDiagnostic> get diagnostics => const Stream.empty();
  @override
  Stream<AudioLatencyMeasurement> get latencyMeasurements =>
      const Stream.empty();
  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<void> start(AudioSessionDescriptor s, AudioFormat f) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

final class _Stt implements StreamingSttProvider {
  @override
  String get providerId => 'gw-stt';
  @override
  String get sourceRevision => 'test';
  @override
  Stream<ProviderSnapshot> get snapshots => const Stream.empty();
  @override
  Stream<LiveTranslationDiagnostic> get diagnostics => const Stream.empty();
  @override
  Stream<TranscriptSegment> get transcripts => const Stream.empty();
  @override
  Future<void> prepare(LiveTranslationConfig c, AudioFormat f) async {}
  @override
  Future<void> push(AudioFrame frame) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

final class _Translator implements TextTranslationProvider {
  @override
  String get providerId => 'gw-translator';
  @override
  String get sourceRevision => 'test';
  @override
  Stream<ProviderSnapshot> get snapshots => const Stream.empty();
  @override
  Stream<LiveTranslationDiagnostic> get diagnostics => const Stream.empty();
  @override
  Future<void> prepare(LiveTranslationConfig c) async {}
  @override
  Future<TranslationSegment> translate(TranscriptSegment t) =>
      throw UnimplementedError();
  @override
  Future<void> dispose() async {}
}

final class _Tts implements SpeechSynthesisProvider {
  @override
  String get providerId => 'gw-tts';
  @override
  String get sourceRevision => 'test';
  @override
  Stream<ProviderSnapshot> get snapshots => const Stream.empty();
  @override
  Stream<LiveTranslationDiagnostic> get diagnostics => const Stream.empty();
  @override
  Future<void> prepare(LiveTranslationConfig c) async {}
  @override
  Future<void> speak(TranslationSegment s) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}
