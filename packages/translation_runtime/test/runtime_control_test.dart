import 'dart:async';

import 'package:persalone_contracts/persalone_contracts.dart';
import 'package:persalone_translation_runtime/persalone_translation_runtime.dart';
import 'package:test/test.dart';

const TranslationConsent _consent = TranslationConsent(
  acceptedAtMicros: 1,
  localProcessingAllowed: true,
  modelDownloadAllowed: false,
  remoteProcessingAllowed: false,
);

void main() {
  late _Rig r;
  setUp(() => r = _Rig());
  tearDown(() async => r.dispose());

  group('Panic from every state', () {
    test('during preparing: a microphone started late is torn down again',
        () async {
      r.input.startGate = Completer<void>();
      final Future<CommandResult> start = r.start();
      await r.until(() => r.input.startCalls == 1);

      final CommandResult panic = await r.panic();
      r.input.startGate!.complete();
      final CommandResult started = await start;

      expect(panic.status, CommandStatus.accepted);
      expect(started.status, CommandStatus.rejected);
      expect(started.runtimeError, RuntimeErrorCode.staleStreamEpoch);
      expect(r.input.running, isFalse,
          reason: 'mic started after Panic must be stopped');
      expect(r.runtime.state, HorizonTranslationRuntimeState.stopped);
      expect(r.control.activeSessionId, isNull);
    });

    test('during listening: mic, STT and TTS stop and the display clears',
        () async {
      await r.startListening();
      final CommandResult panic = await r.panic();

      expect(panic.failedCleanup, isEmpty);
      expect(r.input.running, isFalse);
      expect(r.stt.stopCalls, greaterThan(0));
      expect(r.tts.stopCalls, greaterThan(0));
      expect(r.captions.cleared, isNotEmpty);
      expect(r.runtime.state, HorizonTranslationRuntimeState.stopped);
      await r.settle();
      expect(r.codes, contains(LiveTranslationDiagnosticCode.panicExecuted));
    });

    test('during translating: the late translation is discarded', () async {
      await r.startListening();
      r.translator.gate = Completer<void>();
      r.finalTurn(1);
      await r.until(() => r.translator.started == 1);

      await r.panic();
      r.translator.gate!.complete();
      await r.settle();

      expect(r.captions.shown, isEmpty);
      expect(r.tts.spoken, isEmpty);
      expect(r.codes,
          contains(LiveTranslationDiagnosticCode.staleCallbackDiscarded));
    });

    test('during speaking: TTS is stopped and nothing else is spoken',
        () async {
      await r.startListening();
      r.tts.speakGate = Completer<void>();
      r.finalTurn(1);
      await r.until(() => r.tts.spoken.length == 1);
      final int stopsBefore = r.tts.stopCalls;

      await r.panic();
      r.tts.speakGate!.complete();
      r.finalTurn(2);
      await r.settle();

      expect(r.tts.stopCalls, greaterThan(stopsBefore));
      expect(r.tts.spoken.map((s) => s.sequence), <int>[1]);
    });

    test('from idle and after stop it is still accepted and harmless',
        () async {
      expect((await r.panic()).status, CommandStatus.accepted);
      expect(r.runtime.state, HorizonTranslationRuntimeState.idle);
      await r.startListening();
      await r.control.execute(StopCommand(
          commandId: r.id(),
          origin: ControlOrigin.local,
          sessionId: r.control.activeSessionId!));
      expect((await r.panic()).status, CommandStatus.accepted);
      expect(r.runtime.state, HorizonTranslationRuntimeState.stopped);
    });
  });

  group('Panic races and failures', () {
    test('duplicate Panic: concurrent calls share one teardown; ids dedupe',
        () async {
      await r.startListening();
      final List<CommandResult> both =
          await Future.wait(<Future<CommandResult>>[r.panic(), r.panic()]);
      expect(both.map((c) => c.status), everyElement(CommandStatus.accepted));
      expect(r.input.stopCalls, 1, reason: 'in-flight Panic is shared');

      const PanicCommand same =
          PanicCommand(commandId: 'fixed-id', origin: ControlOrigin.local);
      expect((await r.control.execute(same)).status, CommandStatus.accepted);
      final CommandResult repeated = await r.control.execute(same);
      expect(repeated.rejection, CommandRejection.duplicateCommand);
    });

    test('Stop + Panic race: both complete and everything ends stopped',
        () async {
      await r.startListening();
      final Completer<void> stopGate = r.input.stopGate = Completer<void>();
      final Future<CommandResult> stop = r.control.execute(StopCommand(
          commandId: r.id(),
          origin: ControlOrigin.local,
          sessionId: r.control.activeSessionId!));
      await r.until(() => r.input.stopCalls == 1);

      final CommandResult panic = await r.panic();
      stopGate.complete();
      final CommandResult stopped = await stop;

      expect(panic.status, CommandStatus.accepted);
      expect(stopped.status, CommandStatus.accepted);
      expect(r.tts.stopCalls, greaterThan(0));
      expect(r.captions.cleared, isNotEmpty);
      expect(r.runtime.state, HorizonTranslationRuntimeState.stopped);
    });

    test('a Start queued before Panic never runs after it', () async {
      await r.startListening();
      final Completer<void> stopGate = r.input.stopGate = Completer<void>();
      final Future<CommandResult> stop = r.control.execute(StopCommand(
          commandId: r.id(),
          origin: ControlOrigin.local,
          sessionId: r.control.activeSessionId!));
      final Future<CommandResult> queuedStart = r.start();
      await r.until(() => r.input.stopCalls == 1);

      await r.panic();
      stopGate.complete();
      await stop;

      expect((await queuedStart).rejection, CommandRejection.supersededByPanic);
      expect(r.input.running, isFalse);
    });

    test('stale callback after Panic: late transcript is ignored', () async {
      await r.startListening();
      await r.panic();
      r.finalTurn(7);
      await r.settle();
      expect(r.translator.started, 0);
      expect(r.captions.shown, isEmpty);
    });

    test('adapter exceptions during cleanup do not stop other safety actions',
        () async {
      await r.startListening();
      r.input.throwOnStop = true;
      r.stt.throwOnStop = true;

      final CommandResult panic = await r.panic();

      expect(panic.status, CommandStatus.accepted);
      expect(panic.failedCleanup, containsAll(<String>['input', 'stt']));
      expect(r.tts.stopCalls, greaterThan(0));
      expect(r.captions.cleared, isNotEmpty);
      expect(r.runtime.state, HorizonTranslationRuntimeState.stopped);
      await r.settle();
      expect(r.codes, contains(LiveTranslationDiagnosticCode.cleanupFailed));
    });

    test('disconnected display: cleanup reports captions and still stops mic',
        () async {
      await r.startListening();
      r.captions.throwOnClear = true;
      final CommandResult panic = await r.panic();
      expect(panic.failedCleanup, <String>['captions']);
      expect(r.input.running, isFalse);
      expect(r.tts.stopCalls, greaterThan(0));
    });

    test('clean restart after Panic works with a new session', () async {
      await r.startListening();
      final String first = r.control.activeSessionId!;
      r.input.throwOnStop = true;
      await r.panic();
      r.input.throwOnStop = false;

      final CommandResult restarted = await r.start();
      expect(restarted.status, CommandStatus.accepted);
      expect(r.runtime.state, HorizonTranslationRuntimeState.listening);
      expect(r.control.activeSessionId, isNot(first));
      r.finalTurn(1);
      await r.until(() => r.captions.shown.length == 1);
      expect(r.tts.spoken, hasLength(1));
    });
  });

  group('control policy', () {
    test('remote may only STOP, PANIC and disconnect the device', () async {
      final List<RuntimeCommand> forbidden = <RuntimeCommand>[
        StartCommand(
            commandId: r.id(), origin: ControlOrigin.remote, consent: _consent),
        SetLanguageCommand(
            commandId: r.id(),
            origin: ControlOrigin.remote,
            direction: TranslationDirection.spanishToEnglish),
        DeviceSelectCommand(
            commandId: r.id(), origin: ControlOrigin.remote, deviceId: 'd1'),
      ];
      for (final RuntimeCommand command in forbidden) {
        expect((await r.control.execute(command)).rejection,
            CommandRejection.remoteNotAllowed);
      }
      expect(r.input.startCalls, 0);
      expect(r.control.language.pending, TranslationDirection.englishToSpanish);

      await r.startListening();
      expect(
          (await r.control.execute(StopCommand(
                  commandId: r.id(),
                  origin: ControlOrigin.remote,
                  sessionId: r.control.activeSessionId!)))
              .status,
          CommandStatus.accepted);
      expect(
          (await r.control.execute(PanicCommand(
                  commandId: r.id(), origin: ControlOrigin.remote)))
              .status,
          CommandStatus.accepted);
      expect(
          (await r.control.execute(DeviceDisconnectCommand(
                  commandId: r.id(), origin: ControlOrigin.remote)))
              .status,
          CommandStatus.accepted);
      expect(r.device.disconnectCalls, 1);
    });

    test('language: pending for next session, effective only while active',
        () async {
      expect(
          (await r.setLanguage(TranslationDirection.spanishToEnglish)).status,
          CommandStatus.accepted);
      expect(r.control.language.effective, isNull);
      expect(r.control.language.pending, TranslationDirection.spanishToEnglish);

      await r.startListening();
      expect(
          r.control.language.effective, TranslationDirection.spanishToEnglish);
      expect(r.stt.lastConfig!.sourceLocale, 'es-ES');

      final CommandResult during =
          await r.setLanguage(TranslationDirection.englishToSpanish);
      expect(during.rejection, CommandRejection.sessionActive);
      expect(
          r.control.language.effective, TranslationDirection.spanishToEnglish);
      expect(r.control.language.pending, TranslationDirection.spanishToEnglish);

      await r.panic();
      expect(r.control.language.effective, isNull);
      expect(
          (await r.setLanguage(TranslationDirection.englishToSpanish)).status,
          CommandStatus.accepted);
    });

    test('stop validates the session and start requires local consent',
        () async {
      expect(
          (await r.control.execute(StopCommand(
                  commandId: r.id(),
                  origin: ControlOrigin.local,
                  sessionId: 'nope')))
              .rejection,
          CommandRejection.noActiveSession);
      expect(
          (await r.control.execute(StartCommand(
                  commandId: r.id(),
                  origin: ControlOrigin.local,
                  consent: const TranslationConsent(
                    acceptedAtMicros: 1,
                    localProcessingAllowed: false,
                    modelDownloadAllowed: false,
                    remoteProcessingAllowed: false,
                  ))))
              .rejection,
          CommandRejection.consentRequired);
      await r.startListening();
      expect(
          (await r.control.execute(StopCommand(
                  commandId: r.id(),
                  origin: ControlOrigin.local,
                  sessionId: 'another-session')))
              .rejection,
          CommandRejection.sessionMismatch);
      expect((await r.start()).rejection, CommandRejection.sessionActive);
    });

    test('results carry ids, enums and component tokens only', () async {
      final List<CommandResult> results = <CommandResult>[];
      final StreamSubscription<CommandResult> sub =
          r.control.results.listen(results.add);
      await r.startListening();
      r.captions.throwOnClear = true;
      await r.panic();
      await r.settle();
      await sub.cancel();
      final CommandResult panic =
          results.lastWhere((c) => c.kind == RuntimeCommandKind.panic);
      expect(panic.failedCleanup, <String>['captions']);
      expect(panic.failedCleanup.join(), matches(RegExp(r'^[a-z.]*$')));
    });
  });
}

final class _Rig {
  _Rig() {
    runtime = HorizonTranslationRuntime(
      input: input,
      stt: stt,
      translator: translator,
      synthesizer: tts,
      captions: captions,
    );
    control = HorizonRuntimeController(runtime: runtime, device: device);
    _sub = runtime.diagnostics.listen(diagnostics.add);
  }

  final _Input input = _Input();
  final _Stt stt = _Stt();
  final _Translator translator = _Translator();
  final _Tts tts = _Tts();
  final _Captions captions = _Captions();
  final _Device device = _Device();
  late final HorizonTranslationRuntime runtime;
  late final HorizonRuntimeController control;
  final List<LiveTranslationDiagnostic> diagnostics =
      <LiveTranslationDiagnostic>[];
  late final StreamSubscription<LiveTranslationDiagnostic> _sub;
  int _ids = 0;

  Iterable<LiveTranslationDiagnosticCode> get codes =>
      diagnostics.map((d) => d.code);

  String id() => 'cmd-${++_ids}';

  Future<CommandResult> start() => control.execute(StartCommand(
      commandId: id(), origin: ControlOrigin.local, consent: _consent));

  Future<void> startListening() async {
    expect((await start()).status, CommandStatus.accepted);
    expect(runtime.state, HorizonTranslationRuntimeState.listening);
  }

  Future<CommandResult> panic() => control
      .execute(PanicCommand(commandId: id(), origin: ControlOrigin.local));

  Future<CommandResult> setLanguage(TranslationDirection direction) =>
      control.execute(SetLanguageCommand(
          commandId: id(), origin: ControlOrigin.local, direction: direction));

  void finalTurn(int sequence) {
    final String? session = control.activeSessionId;
    final TranslationSession s = TranslationSession(
      sessionId: session ?? 'none',
      streamEpoch: stt.lastConfig?.session.streamEpoch ?? 0,
      direction: stt.lastConfig?.session.direction ??
          TranslationDirection.englishToSpanish,
      privacyGeneration: stt.lastConfig?.session.privacyGeneration ?? 0,
    );
    stt.controller.add(TranscriptSegment(
      session: s,
      sequence: sequence,
      text: 'private',
      stability: TranscriptStability.finalResult,
      observedAtMicros: sequence,
      truthLabel: TruthLabel.simulated,
    ));
  }

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 20));

  Future<void> until(bool Function() condition) async {
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) fail('condition not reached');
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }

  Future<void> dispose() async {
    await _sub.cancel();
    await control.dispose();
    input.throwOnStop = false;
    stt.throwOnStop = false;
    captions.throwOnClear = false;
    await runtime.dispose();
  }
}

final class _Input implements AudioInputAdapter {
  final StreamController<AudioFrame> controller =
      StreamController<AudioFrame>.broadcast();
  Completer<void>? startGate;
  Completer<void>? stopGate;
  bool throwOnStop = false;
  bool running = false;
  int startCalls = 0;
  int stopCalls = 0;

  @override
  String get adapterId => 'ctl-input';
  @override
  String get sourceRevision => 'test';
  @override
  Stream<AudioFrame> get frames => controller.stream;
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
  Future<void> start(AudioSessionDescriptor s, AudioFormat f) async {
    startCalls++;
    await startGate?.future;
    running = true;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    final Completer<void>? gate = stopGate;
    stopGate = null;
    await gate?.future;
    if (throwOnStop) throw StateError('mic stop failed');
    running = false;
  }

  @override
  Future<void> dispose() async {}
}

final class _Stt implements StreamingSttProvider {
  final StreamController<TranscriptSegment> controller =
      StreamController<TranscriptSegment>.broadcast();
  LiveTranslationConfig? lastConfig;
  bool throwOnStop = false;
  int stopCalls = 0;

  @override
  String get providerId => 'ctl-stt';
  @override
  String get sourceRevision => 'test';
  @override
  Stream<ProviderSnapshot> get snapshots => const Stream.empty();
  @override
  Stream<LiveTranslationDiagnostic> get diagnostics => const Stream.empty();
  @override
  Stream<TranscriptSegment> get transcripts => controller.stream;
  @override
  Future<void> prepare(LiveTranslationConfig c, AudioFormat f) async =>
      lastConfig = c;
  @override
  Future<void> push(AudioFrame frame) async {}
  @override
  Future<void> stop() async {
    stopCalls++;
    if (throwOnStop) throw StateError('stt stop failed');
  }

  @override
  Future<void> dispose() async {}
}

final class _Translator implements TextTranslationProvider {
  Completer<void>? gate;
  int started = 0;

  @override
  String get providerId => 'ctl-translator';
  @override
  String get sourceRevision => 'test';
  @override
  Stream<ProviderSnapshot> get snapshots => const Stream.empty();
  @override
  Stream<LiveTranslationDiagnostic> get diagnostics => const Stream.empty();
  @override
  Future<void> prepare(LiveTranslationConfig c) async {}
  @override
  Future<TranslationSegment> translate(TranscriptSegment t) async {
    started++;
    await gate?.future;
    return TranslationSegment(
      session: t.session,
      sequence: t.sequence,
      sourceText: t.text,
      translatedText: 'private translation',
      observedAtMicros: t.observedAtMicros,
      truthLabel: TruthLabel.simulated,
    );
  }

  @override
  Future<void> dispose() async {}
}

final class _Tts implements SpeechSynthesisProvider {
  final List<TranslationSegment> spoken = <TranslationSegment>[];
  Completer<void>? speakGate;
  int stopCalls = 0;

  @override
  String get providerId => 'ctl-tts';
  @override
  String get sourceRevision => 'test';
  @override
  Stream<ProviderSnapshot> get snapshots => const Stream.empty();
  @override
  Stream<LiveTranslationDiagnostic> get diagnostics => const Stream.empty();
  @override
  Future<void> prepare(LiveTranslationConfig c) async {}
  @override
  Future<void> speak(TranslationSegment segment) async {
    spoken.add(segment);
    await speakGate?.future;
  }

  @override
  Future<void> stop() async => stopCalls++;
  @override
  Future<void> dispose() async {}
}

final class _Captions implements CaptionOutputAdapter {
  final List<int> shown = <int>[];
  final List<String> cleared = <String>[];
  bool throwOnClear = false;

  @override
  String get adapterId => 'ctl-captions';
  @override
  ExecutionEnvironment get environment => ExecutionEnvironment.simulated;
  @override
  Future<CaptionDelivery> show(CaptionUpdate update) async {
    shown.add(update.sequence);
    return CaptionDelivery(
      session: update.session,
      sequence: update.sequence,
      status: CaptionDeliveryStatus.delivered,
      environment: environment,
      truthLabel: TruthLabel.simulated,
      adapterId: adapterId,
    );
  }

  @override
  Future<void> clear(TranslationSession session) async {
    if (throwOnClear) throw StateError('display disconnected');
    cleared.add(session.sessionId);
  }
}

final class _Device implements DeviceAdapterPort {
  int disconnectCalls = 0;
  final StreamController<DeviceDiscovery> _discoveries =
      StreamController<DeviceDiscovery>.broadcast();

  @override
  String get adapterId => 'ctl-device';
  @override
  String get sourceRevision => 'test';
  @override
  Stream<DeviceAdapterSnapshot> get snapshots => const Stream.empty();
  @override
  Stream<AdapterDiagnostic> get diagnostics => const Stream.empty();
  @override
  Stream<DeviceDiscovery> get discoveries => _discoveries.stream;
  @override
  Future<void> startDiscovery() async {}
  @override
  Future<void> stopDiscovery() async {}
  @override
  Future<void> connect(DeviceDiscovery device) async {}
  @override
  Future<void> reconnect() async {}
  @override
  Future<void> disconnect() async => disconnectCalls++;
  @override
  Future<CapabilityManifest> capabilityManifest() => throw UnimplementedError();
  @override
  Future<DeviceIdentity> readIdentity() => throw UnimplementedError();
  @override
  Future<BatterySnapshot> readBattery() => throw UnimplementedError();
  @override
  Future<HaloLuaResult> executeAllowedLua(HaloLuaQuery query, {String? text}) =>
      throw UnimplementedError();
  @override
  Future<void> sendUserData(UserDataMessage message) =>
      throw UnimplementedError();
  @override
  Future<void> dispose() async {}
}
