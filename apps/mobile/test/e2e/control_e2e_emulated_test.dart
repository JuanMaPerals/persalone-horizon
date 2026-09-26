import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:persalone_contracts/persalone_contracts.dart';
import 'package:persalone_halo_adapter/persalone_halo_adapter.dart';
import 'package:persalone_translation_runtime/persalone_translation_runtime.dart';
import 'package:persalone_mobile/live_stream_config.dart';
import 'package:persalone_mobile/studio_remote_control.dart';

import 'emulator_halo_transport.dart';

// CONTROL_E2E_EMULATED: RuntimeControlPort -> G5 -> captions -> bounded Lua
// -> official halo-emulator framebuffer. Providers SIMULATED (fault
// injectable), HUD EMULATED. No network surface; never HALO_REAL.
final String? _python = Platform.environment['HORIZON_E2E_PYTHON'];
final bool _required = Platform.environment['HORIZON_E2E_REQUIRED'] == '1';
final String? _artifacts = Platform.environment['HORIZON_E2E_ARTIFACTS'];
const String _bridge = '../../tooling/e2e/halo_emulator_bridge.py';

String? get _skip => _python != null || _required
    ? null
    : 'CONTROL_E2E_EMULATED not configured: set HORIZON_E2E_PYTHON';

void main() {
  late _Rig r;

  setUp(() async {
    if (_python == null) {
      fail('HORIZON_E2E_REQUIRED=1 but HORIZON_E2E_PYTHON is not set');
    }
    r = await _Rig.create(_python!);
  });

  tearDown(() async => r.dispose());

  test('Panic in preparing: late mic start is torn down, display stays black',
      skip: _skip, () async {
    r.input.startGate = Completer<void>();
    final Future<CommandResult> start = r.start();
    await r.until(() => r.input.startCalls == 1);

    expect((await r.panic()).status, CommandStatus.accepted);
    r.input.startGate!.complete();
    expect((await start).runtimeError, RuntimeErrorCode.staleStreamEpoch);

    expect(r.input.running, isFalse);
    expect(r.runtime.state, HorizonTranslationRuntimeState.stopped);
    expect((await r.frame('panic_preparing')).lit, 0);
  });

  test('Panic in listening: caption removed, framebuffer black', skip: _skip,
      () async {
    await r.startListening();
    r.translator.outputs[1] = 'LISTENING';
    r.finalTurn(1);
    await r.until(() => r.deliveries.length == 1);
    expect((await r.frame()).lit, greaterThan(0));

    final CommandResult panic = await r.panic();
    expect(panic.failedCleanup, isEmpty);
    expect(r.input.running, isFalse);
    expect(r.tts.stopCalls, greaterThan(0));
    expect((await r.frame('panic_listening')).lit, 0);
  });

  test('Panic with a pending translation: it never reaches the HUD',
      skip: _skip, () async {
    await r.startListening();
    r.translator
      ..outputs[1] = 'PENDING TURN'
      ..gates[1] = Completer<void>();
    r.finalTurn(1);
    await r.until(() => r.translator.started == 1);

    await r.panic();
    r.translator.gates[1]!.complete();
    await r.settle();

    expect(r.transport.sentDisplayCommands, isEmpty);
    expect(r.tts.spoken, isEmpty);
    expect((await r.frame('panic_pending_translation')).lit, 0);
  });

  test('Panic during TTS: speech stopped, no later turn spoken', skip: _skip,
      () async {
    await r.startListening();
    r.translator.outputs[1] = 'SPEAKING';
    r.tts.speakGate = Completer<void>();
    r.finalTurn(1);
    await r.until(() => r.tts.spoken.length == 1);
    final int stopsBefore = r.tts.stopCalls;

    await r.panic();
    r.tts.speakGate!.complete();
    r.finalTurn(2);
    await r.settle();

    expect(r.tts.stopCalls, greaterThan(stopsBefore));
    expect(r.tts.spoken.map((TranslationSegment s) => s.sequence), <int>[1]);
    expect((await r.frame('panic_tts')).lit, 0);
  });

  test('repeated Panic is idempotent and deduplicated by commandId',
      skip: _skip, () async {
    await r.startListening();
    r.translator.outputs[1] = 'REPEAT';
    r.finalTurn(1);
    await r.until(() => r.deliveries.length == 1);

    final List<CommandResult> results = await Future.wait(
        <Future<CommandResult>>[r.panic(), r.panic(), r.panic()]);
    expect(results.map((c) => c.status), everyElement(CommandStatus.accepted));
    const PanicCommand fixed =
        PanicCommand(commandId: 'same', origin: ControlOrigin.local);
    await r.control.execute(fixed);
    expect((await r.control.execute(fixed)).rejection,
        CommandRejection.duplicateCommand);
    expect((await r.frame()).lit, 0);
  });

  test('Stop + Panic concurrently: both accepted, display black', skip: _skip,
      () async {
    await r.startListening();
    r.translator.outputs[1] = 'STOP PANIC';
    r.finalTurn(1);
    await r.until(() => r.deliveries.length == 1);
    final Completer<void> stopGate = r.input.stopGate = Completer<void>();
    final Future<CommandResult> stop = r.control.execute(StopCommand(
        commandId: r.id(),
        origin: ControlOrigin.local,
        sessionId: r.control.activeSessionId!));
    await r.until(() => r.input.stopCalls == 1);

    final CommandResult panic = await r.panic();
    stopGate.complete();

    expect(panic.status, CommandStatus.accepted);
    expect((await stop).status, CommandStatus.accepted);
    expect(r.runtime.state, HorizonTranslationRuntimeState.stopped);
    expect((await r.frame('stop_panic')).lit, 0);
  });

  test('late callback after Panic: transcript ignored, HUD untouched',
      skip: _skip, () async {
    await r.startListening();
    await r.panic();
    final int clears = r.transport.clears;
    r.translator.outputs[9] = 'LATE';
    r.finalTurn(9);
    await r.settle();
    expect(r.translator.started, 0);
    expect(r.transport.sentDisplayCommands, isEmpty);
    expect(r.transport.clears, clears);
    expect((await r.frame()).lit, 0);
  });

  test('HUD disconnected: Panic reports captions and still stops mic and TTS',
      skip: _skip, () async {
    await r.startListening();
    await r.transport.crash();

    final CommandResult panic = await r.panic();
    expect(panic.failedCleanup, <String>['captions']);
    expect(r.input.running, isFalse);
    expect(r.tts.stopCalls, greaterThan(0));
    expect(r.runtime.state, HorizonTranslationRuntimeState.stopped);
  });

  test('TTS, mic and display cleanup failures do not block each other',
      skip: _skip, () async {
    await r.startListening();
    r.translator.outputs[1] = 'FAULTY';
    r.finalTurn(1);
    await r.until(() => r.deliveries.length == 1);
    r.tts.throwOnStop = true;
    r.input.throwOnStop = true;
    r.transport.failClear = true;

    final CommandResult panic = await r.panic();
    expect(panic.status, CommandStatus.accepted);
    expect(
        panic.failedCleanup, containsAll(<String>['input', 'tts', 'captions']));
    expect(r.stt.stopCalls, greaterThan(0), reason: 'STT still stopped');
    expect(r.runtime.state, HorizonTranslationRuntimeState.stopped);
  });

  test('clean restart after Panic: only the new turn is ever displayed',
      skip: _skip, () async {
    await r.startListening();
    r.translator
      ..outputs[1] = 'OLD TURN'
      ..outputs[2] = 'NEW TURN';
    r.finalTurn(1);
    await r.until(() => r.deliveries.length == 1);
    await r.panic();
    expect((await r.frame()).lit, 0);

    expect((await r.start()).status, CommandStatus.accepted);
    r.finalTurn(2);
    await r.until(() => r.deliveries.length == 2);
    await r.settle();

    final EmulatorFrame shown = await r.frame('restart_after_panic');
    final EmulatorHaloTransport reference =
        EmulatorHaloTransport(python: _python!, bridgeScript: _bridge);
    await reference.connect(const HaloTransportDiscovery(
        reconnectId: 'reference', displayName: 'reference'));
    await reference.executeDisplayCommand(
        HaloCaptionComposer.compose('NEW TURN').command(0, powerOn: true));
    final EmulatorFrame expected = await reference.frame();
    await reference.dispose();
    expect(shown.sha256, expected.sha256,
        reason: 'the old turn must never reappear');
    expect(r.transport.sentDisplayCommands.last, contains('NEW TURN'));
    expect(r.transport.sentDisplayCommands.where((c) => c.contains('OLD TURN')),
        hasLength(1));
  });

  // Studio -> authenticated loopback channel -> RemoteControlGateway -> the
  // same controller the phone's buttons use. The token is read from the
  // app-private file, as an operator does with `adb run-as`.
  group('remote over the authenticated channel', () {
    late StudioRemoteControl remote;
    late Directory tokens;
    late String token;

    setUp(() async {
      tokens = Directory.systemTemp.createTempSync('control-e2e-');
      remote = await StudioRemoteControl.start(r.control,
          config: const LiveStreamConfig(port: 0, allowedOrigins: <String>{}),
          tokenDirectory: tokens);
      token = remote.tokenFile.readAsStringSync();
    });

    tearDown(() async {
      await remote.close();
      tokens.deleteSync(recursive: true);
    });

    Future<(int, Map<String, Object?>)> send(String action,
        {String? bearer, int? generation}) async {
      final HttpClient client = HttpClient();
      try {
        final HttpClientRequest request = await client.postUrl(
            remote.server.uri.replace(path: '/v1/control/commands'));
        request.headers
          ..contentType = ContentType.json
          ..set('authorization', 'Bearer ${bearer ?? token}');
        request.write(jsonEncode(<String, Object?>{
          'schemaVersion': 1,
          'commandId': 'studio-${r.id()}',
          'issuedAt': DateTime.now().microsecondsSinceEpoch,
          'sessionGeneration': generation ?? r.control.sessionGeneration,
          'action': action,
        }));
        final HttpClientResponse response = await request.close();
        final Object? body = jsonDecode(await utf8.decodeStream(response));
        return (
          response.statusCode,
          (body! as Map<Object?, Object?>).cast<String, Object?>()
        );
      } finally {
        client.close(force: true);
      }
    }

    test('remote PANIC: caption removed, mic and TTS stopped', skip: _skip,
        () async {
      await r.startListening();
      r.translator.outputs[1] = 'REMOTE PANIC';
      r.finalTurn(1);
      await r.until(() => r.deliveries.length == 1);
      expect((await r.frame()).lit, greaterThan(0));

      final (int status, Map<String, Object?> body) = await send('panic');
      expect(status, HttpStatus.ok);
      expect(body['resultCode'], 'accepted');
      expect(r.input.running, isFalse);
      expect(r.tts.stopCalls, greaterThan(0));
      expect(r.runtime.state, HorizonTranslationRuntimeState.stopped);
      expect((await r.frame('remote_panic')).lit, 0);
    });

    test('remote STOP ends the session; a stale generation is refused',
        skip: _skip, () async {
      await r.startListening();
      final int first = r.control.sessionGeneration;
      expect((await send('stop')).$2['resultCode'], 'accepted');
      expect(r.runtime.state, HorizonTranslationRuntimeState.stopped);

      await r.startListening();
      expect((await send('stop', generation: first)).$2['resultCode'],
          'staleGeneration',
          reason: 'a STOP aimed at the previous session never ends this one');
      expect(r.control.activeSessionId, isNotNull);
    });

    test('remote START is denied and a wrong token changes nothing',
        skip: _skip, () async {
      expect((await send('start')).$2['resultCode'], 'deniedByPolicy');
      expect(r.control.activeSessionId, isNull);

      await r.startListening();
      final (int status, _) = await send('panic', bearer: 'not-the-token');
      expect(status, HttpStatus.unauthorized);
      expect(r.input.running, isTrue, reason: 'no unauthenticated Panic');
      expect(
          (await send('deviceDisconnect')).$2['resultCode'], 'deniedByPolicy');
    });
  });
}

final class _Rig {
  _Rig._(this.transport, this.device, this.runtime, this.control);

  final EmulatorHaloTransport transport;
  final HaloDeviceAdapter device;
  final HorizonTranslationRuntime runtime;
  final HorizonRuntimeController control;
  late final _Input input;
  late final _Stt stt;
  late final _Translator translator;
  late final _Tts tts;
  final List<CaptionDelivery> deliveries = <CaptionDelivery>[];
  late final StreamSubscription<CaptionDelivery> _sub;
  int _ids = 0;

  static Future<_Rig> create(String python) async {
    final EmulatorHaloTransport transport =
        EmulatorHaloTransport(python: python, bridgeScript: _bridge);
    final HaloDeviceAdapter device = HaloDeviceAdapter(transport: transport);
    final Future<DeviceDiscovery> discovered = device.discoveries.first;
    await device.startDiscovery();
    await device.connect(await discovered);
    final _Input input = _Input();
    final _Stt stt = _Stt();
    final _Translator translator = _Translator();
    final _Tts tts = _Tts();
    final HorizonTranslationRuntime runtime = HorizonTranslationRuntime(
      input: input,
      stt: stt,
      translator: translator,
      synthesizer: tts,
      captions: HaloCaptionOutputAdapter(device),
    );
    final HorizonRuntimeController control =
        HorizonRuntimeController(runtime: runtime, device: device);
    final _Rig r = _Rig._(transport, device, runtime, control)
      ..input = input
      ..stt = stt
      ..translator = translator
      ..tts = tts;
    r._sub = runtime.captionDeliveries.listen(r.deliveries.add);
    return r;
  }

  String id() => 'e2e-${++_ids}';

  Future<CommandResult> start() => control.execute(StartCommand(
        commandId: id(),
        origin: ControlOrigin.local,
        consent: const TranslationConsent(
          acceptedAtMicros: 1,
          localProcessingAllowed: true,
          modelDownloadAllowed: false,
          remoteProcessingAllowed: false,
        ),
      ));

  Future<void> startListening() async {
    expect((await start()).status, CommandStatus.accepted);
  }

  Future<CommandResult> panic() => control
      .execute(PanicCommand(commandId: id(), origin: ControlOrigin.local));

  void finalTurn(int sequence) {
    final LiveTranslationConfig? config = stt.lastConfig;
    stt.controller.add(TranscriptSegment(
      session: config?.session ??
          const TranslationSession(
              sessionId: 'none',
              streamEpoch: 0,
              direction: TranslationDirection.englishToSpanish,
              privacyGeneration: 0),
      sequence: sequence,
      text: 'private source $sequence',
      stability: TranscriptStability.finalResult,
      observedAtMicros: sequence,
      truthLabel: TruthLabel.simulated,
    ));
  }

  Future<EmulatorFrame> frame([String? name]) {
    final String? dir = _artifacts;
    String? png;
    if (dir != null && name != null) {
      Directory(dir).createSync(recursive: true);
      png = '$dir/control_e2e_$name.png';
    }
    return transport.frame(png: png);
  }

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 60));

  Future<void> until(bool Function() condition) async {
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) fail('E2E condition not reached');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  Future<void> dispose() async {
    await _sub.cancel();
    input.throwOnStop = false;
    tts.throwOnStop = false;
    transport.failClear = false;
    await control.dispose();
    await runtime.dispose();
    await device.dispose();
    await transport.dispose();
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
  String get adapterId => 'e2e-input';
  @override
  String get sourceRevision => 'e2e';
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
  int stopCalls = 0;

  @override
  String get providerId => 'e2e-stt';
  @override
  String get sourceRevision => 'e2e';
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
  Future<void> stop() async => stopCalls++;
  @override
  Future<void> dispose() async {}
}

final class _Translator implements TextTranslationProvider {
  final Map<int, String> outputs = <int, String>{};
  final Map<int, Completer<void>> gates = <int, Completer<void>>{};
  int started = 0;

  @override
  String get providerId => 'e2e-translator';
  @override
  String get sourceRevision => 'e2e';
  @override
  Stream<ProviderSnapshot> get snapshots => const Stream.empty();
  @override
  Stream<LiveTranslationDiagnostic> get diagnostics => const Stream.empty();
  @override
  Future<void> prepare(LiveTranslationConfig c) async {}
  @override
  Future<TranslationSegment> translate(TranscriptSegment t) async {
    started++;
    await gates[t.sequence]?.future;
    return TranslationSegment(
      session: t.session,
      sequence: t.sequence,
      sourceText: t.text,
      translatedText: outputs[t.sequence] ?? 'TRANSLATED',
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
  bool throwOnStop = false;
  int stopCalls = 0;

  @override
  String get providerId => 'e2e-tts';
  @override
  String get sourceRevision => 'e2e';
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
  Future<void> stop() async {
    stopCalls++;
    if (throwOnStop) throw StateError('tts stop failed');
  }

  @override
  Future<void> dispose() async {}
}
