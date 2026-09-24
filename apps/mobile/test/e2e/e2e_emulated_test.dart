import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:persalone_contracts/persalone_contracts.dart';
import 'package:persalone_halo_adapter/persalone_halo_adapter.dart';
import 'package:persalone_translation_runtime/persalone_translation_runtime.dart';

import 'emulator_halo_transport.dart';

// E2E_EMULATED: real G5 runtime + real caption/device adapters + bounded Lua
// builder, executed by the official halo-emulator (Lua 5.4, 256x256
// framebuffer). Layer labels: providers=SIMULATED, HUD=EMULATED. Nothing here
// is HALO_REAL or hardware evidence.
final String? _python = Platform.environment['HORIZON_E2E_PYTHON'];
final bool _required = Platform.environment['HORIZON_E2E_REQUIRED'] == '1';
final String? _artifacts = Platform.environment['HORIZON_E2E_ARTIFACTS'];
const String _bridge = '../../tooling/e2e/halo_emulator_bridge.py';

String? get _skip {
  if (_python != null) return null;
  if (_required) return null; // fail loudly in CI instead of skipping
  return 'E2E_EMULATED not configured: set HORIZON_E2E_PYTHON';
}

void main() {
  late _Harness h;

  setUp(() async {
    if (_python == null) {
      fail('HORIZON_E2E_REQUIRED=1 but HORIZON_E2E_PYTHON is not set');
    }
    h = await _Harness.start(_python!);
  });

  tearDown(() async => h.dispose());

  test('positive: a final turn reaches the emulated Halo framebuffer',
      skip: _skip, () async {
    final EmulatorFrame boot = await h.transport.frame();
    expect(boot.suspended, isTrue, reason: 'emulator boots like hardware');
    expect(boot.lit, 0);

    h.translator.outputs[1] = 'HELLO WORLD';
    h.addFinal(1);
    await h.waitForDeliveries(1);

    final CaptionDelivery delivery = h.deliveries.single;
    expect(delivery.status, CaptionDeliveryStatus.delivered);
    expect(delivery.environment, ExecutionEnvironment.emulated);
    expect(delivery.truthLabel, TruthLabel.prepared);
    expect(h.translations.single.truthLabel, TruthLabel.simulated);

    final EmulatorFrame shown = await h.transport.frame(png: _png('positive'));
    expect(shown.suspended, isFalse, reason: 'first caption wakes display');
    expect(shown.lower, greaterThan(0));
    expect(shown.upper, 0);
    expect(shown.outside, 0);
    expect(shown.bbox![1],
        greaterThanOrEqualTo(HaloCaptionComposer.lineTops.first - 1));
    expect(h.tts.spoken.map((TranslationSegment s) => s.sequence), <int>[1]);
    expect(
      h.deliveries.where((CaptionDelivery d) =>
          d.environment == ExecutionEnvironment.haloReal),
      isEmpty,
    );

    // The read-only runtime event stream reports the same layer labels.
    await h.settle();
    final List<Map<String, Object?>> events = h.eventLines
        .map((String l) => jsonDecode(l) as Map<String, Object?>)
        .toList();
    final Map<String, Object?> caption =
        events.singleWhere((Map<String, Object?> e) => e['kind'] == 'caption');
    expect(caption['environment'], 'EMULATED');
    expect(caption['truth'], 'PREPARED');
    expect(
      events
          .where((Map<String, Object?> e) => e['kind'] == 'sessionState')
          .map((Map<String, Object?> e) => e['state']),
      containsAllInOrder(<String>['preparing', 'listening']),
    );
    final String wire = h.eventLines.join('\n');
    expect(wire, isNot(contains('HELLO WORLD')));
    expect(wire, isNot(contains('HALO_REAL')));
    _ndjson('positive', h.eventLines);
  });

  test('stale turn: an older translation never reaches the framebuffer',
      skip: _skip, () async {
    h.translator
      ..outputs[10] = 'OLD TURN'
      ..outputs[11] = 'NEW TURN'
      ..gates[10] = Completer<void>()
      ..gates[11] = Completer<void>();

    h.addFinal(10);
    h.addFinal(11);
    await h.settle();
    h.translator.gates[11]!.complete();
    await h.waitForDeliveries(1);
    h.translator.gates[10]!.complete();
    await h.settle();

    expect(h.transport.sentDisplayCommands, hasLength(1));
    expect(h.transport.sentDisplayCommands.single, contains('NEW TURN'));
    final EmulatorFrame shown = await h.transport.frame(png: _png('stale'));

    final EmulatorHaloTransport reference = await _referenceRender('NEW TURN');
    final EmulatorFrame expected = await reference.frame();
    await reference.dispose();
    expect(shown.sha256, expected.sha256);
  });

  test('Stop clears the emulated display', skip: _skip, () async {
    h.translator.outputs[1] = 'STOP ME';
    h.addFinal(1);
    await h.waitForDeliveries(1);
    expect((await h.transport.frame()).lit, greaterThan(0));

    await h.runtime.stop();

    final EmulatorFrame cleared = await h.transport.frame(png: _png('stop'));
    expect(cleared.lit, 0);
  });

  test('fail-closed session failure clears the emulated display', skip: _skip,
      () async {
    h.translator.outputs[1] = 'BEFORE FAILURE';
    h.addFinal(1);
    await h.waitForDeliveries(1);
    expect((await h.transport.frame()).lit, greaterThan(0));

    h.stt.failPush = true;
    h.input.frames$.add(_frame());
    await h.waitUntil(
        () => h.runtime.state == HorizonTranslationRuntimeState.failed);
    await h.settle();

    final EmulatorFrame cleared =
        await h.transport.frame(png: _png('fail_closed'));
    expect(cleared.lit, 0);
  });

  test('emulator crash is reported and a reconnect restores captions',
      skip: _skip, () async {
    h.translator
      ..outputs[1] = 'FIRST'
      ..outputs[2] = 'LOST'
      ..outputs[3] = 'AFTER RESTART';
    h.addFinal(1);
    await h.waitForDeliveries(1);

    await h.transport.crash();
    h.addFinal(2);
    await h.waitForDeliveries(2);
    expect(h.deliveries[1].status, CaptionDeliveryStatus.failed);
    expect(h.deliveries[1].reason, RuntimeErrorCode.protocolRejected.name);
    expect(h.runtime.state, HorizonTranslationRuntimeState.listening);
    expect(h.tts.spoken.map((TranslationSegment s) => s.sequence), <int>[1, 2]);

    await h.device.reconnect();
    expect(h.transport.bridgeStarts, 2);
    expect((await h.transport.frame()).suspended, isTrue);

    h.addFinal(3);
    await h.waitForDeliveries(3);
    expect(h.deliveries[2].status, CaptionDeliveryStatus.delivered);
    expect(h.transport.sentDisplayCommands.last,
        startsWith('local d=frame.display d.power_save(false)'));
    final EmulatorFrame restored =
        await h.transport.frame(png: _png('restart'));
    expect(restored.suspended, isFalse);
    expect(restored.lower, greaterThan(0));
  });

  test('adversarial payloads stay text and never execute on the device',
      skip: _skip, () async {
    h.translator
      ..outputs[1] = '")PWNED=1 frame.display.clear() os.exit()--'
      ..outputs[2] = 'x\n)PWNED=2 --'
      ..outputs[3] = 'A' * (HaloCaptionComposer.maxInputChars + 1);

    h.addFinal(1);
    await h.waitForDeliveries(1);
    expect(h.deliveries[0].status, CaptionDeliveryStatus.delivered);
    expect(await h.transport.globalIsNil('PWNED'), isTrue);
    final EmulatorFrame drawn =
        await h.transport.frame(png: _png('adversarial'));
    expect(drawn.lower, greaterThan(0), reason: 'payload rendered as text');

    h.addFinal(2);
    await h.waitForDeliveries(2);
    expect(h.deliveries[1].status, CaptionDeliveryStatus.delivered);
    expect(await h.transport.globalIsNil('PWNED'), isTrue);

    final EmulatorFrame beforeOversize = await h.transport.frame();
    final int sentBefore = h.transport.sentDisplayCommands.length;
    h.addFinal(3);
    await h.waitForDeliveries(3);
    expect(h.deliveries[2].status, CaptionDeliveryStatus.failed);
    expect(h.deliveries[2].reason, RuntimeErrorCode.invalidContract.name);
    expect(h.transport.sentDisplayCommands, hasLength(sentBefore));
    expect((await h.transport.frame()).sha256, beforeOversize.sha256);
    expect(
      h.transport.sentDisplayCommands.every(HaloBoundedDisplay.isAcceptable),
      isTrue,
    );
  });
}

void _ndjson(String name, List<String> lines) {
  final String? dir = _artifacts;
  if (dir == null) return;
  Directory(dir).createSync(recursive: true);
  File('$dir/runtime_events_$name.v1.ndjson')
      .writeAsStringSync('${lines.join('\n')}\n');
}

String? _png(String name) {
  final String? dir = _artifacts;
  if (dir == null) return null;
  Directory(dir).createSync(recursive: true);
  return '$dir/e2e_emulated_$name.png';
}

Future<EmulatorHaloTransport> _referenceRender(String text) async {
  final EmulatorHaloTransport transport =
      EmulatorHaloTransport(python: _python!, bridgeScript: _bridge);
  await transport.connect(const HaloTransportDiscovery(
      reconnectId: 'reference', displayName: 'reference'));
  await transport.executeDisplayCommand(
      HaloCaptionComposer.compose(text).command(0, powerOn: true));
  return transport;
}

AudioFrame _frame() => AudioFrame(
      schemaVersion: 'v1',
      session: _audioSession,
      direction: AudioDirection.input,
      sequence: 1,
      codec: AudioCodec.pcmS16le,
      format: AudioFormat.voice16kMono,
      capturedAtMicros: 1,
      receivedAtMicros: 1,
      durationMicros: 20000,
      payload: Uint8List(320),
    );

const TranslationSession _session = TranslationSession(
  sessionId: 'e2e-emulated',
  streamEpoch: 1,
  direction: TranslationDirection.englishToSpanish,
  privacyGeneration: 1,
);

const AudioSessionDescriptor _audioSession = AudioSessionDescriptor(
  sessionId: 'e2e-emulated',
  streamEpoch: 1,
  streamId: 'e2e-input',
);

final class _Harness {
  _Harness._(this.transport, this.device, this.runtime, this.input, this.stt,
      this.translator, this.tts);

  final EmulatorHaloTransport transport;
  final HaloDeviceAdapter device;
  final HorizonTranslationRuntime runtime;
  final _SimInput input;
  final _SimStt stt;
  final _SimTranslator translator;
  final _SimTts tts;
  final List<CaptionDelivery> deliveries = <CaptionDelivery>[];
  final List<TranslationSegment> translations = <TranslationSegment>[];
  final List<String> eventLines = <String>[];
  late final RuntimeEventStream eventStream = RuntimeEventStream(runtime);
  final List<StreamSubscription<Object>> _subs = <StreamSubscription<Object>>[];

  static Future<_Harness> start(String python) async {
    final EmulatorHaloTransport transport =
        EmulatorHaloTransport(python: python, bridgeScript: _bridge);
    final HaloDeviceAdapter device = HaloDeviceAdapter(transport: transport);
    final Future<DeviceDiscovery> discovered = device.discoveries.first;
    await device.startDiscovery();
    await device.connect(await discovered);
    final _SimInput input = _SimInput();
    final _SimStt stt = _SimStt();
    final _SimTranslator translator = _SimTranslator();
    final _SimTts tts = _SimTts();
    final HorizonTranslationRuntime runtime = HorizonTranslationRuntime(
      input: input,
      stt: stt,
      translator: translator,
      synthesizer: tts,
      captions: HaloCaptionOutputAdapter(device),
    );
    final _Harness h =
        _Harness._(transport, device, runtime, input, stt, translator, tts);
    h._subs
      ..add(runtime.captionDeliveries.listen(h.deliveries.add))
      ..add(runtime.translations.listen(h.translations.add))
      ..add(h.eventStream.events.listen((RuntimeEvent e) =>
          h.eventLines.add(RuntimeEventStream.encodeLine(e))));
    await runtime.start(
      config: const LiveTranslationConfig(
        session: _session,
        sourceLocale: 'en-US',
        targetLocale: 'es-ES',
        consent: TranslationConsent(
          acceptedAtMicros: 1,
          localProcessingAllowed: true,
          modelDownloadAllowed: false,
          remoteProcessingAllowed: false,
        ),
      ),
      audioSession: _audioSession,
    );
    return h;
  }

  void addFinal(int sequence) => stt.transcripts$.add(TranscriptSegment(
        session: _session,
        sequence: sequence,
        text: 'simulated source $sequence',
        stability: TranscriptStability.finalResult,
        observedAtMicros: sequence,
        truthLabel: TruthLabel.simulated,
      ));

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 50));

  Future<void> waitForDeliveries(int count) =>
      waitUntil(() => deliveries.length >= count);

  Future<void> waitUntil(bool Function() condition) async {
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('Timed out waiting for the E2E condition.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<void> dispose() async {
    for (final StreamSubscription<Object> sub in _subs) {
      await sub.cancel();
    }
    await eventStream.close();
    await runtime.dispose();
    await device.dispose();
    await transport.dispose();
  }
}

// SIMULATED providers: deterministic stand-ins for mic, STT, translation and
// TTS. Their outputs carry TruthLabel.simulated.
final class _SimInput implements AudioInputAdapter {
  final StreamController<AudioFrame> frames$ =
      StreamController<AudioFrame>.broadcast();
  @override
  String get adapterId => 'sim-input';
  @override
  String get sourceRevision => 'e2e';
  @override
  Stream<AudioFrame> get frames => frames$.stream;
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
  Future<void> start(
      AudioSessionDescriptor session, AudioFormat format) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

final class _SimStt implements StreamingSttProvider {
  final StreamController<TranscriptSegment> transcripts$ =
      StreamController<TranscriptSegment>.broadcast();
  bool failPush = false;
  @override
  String get providerId => 'sim-stt';
  @override
  String get sourceRevision => 'e2e';
  @override
  Stream<ProviderSnapshot> get snapshots => const Stream.empty();
  @override
  Stream<LiveTranslationDiagnostic> get diagnostics => const Stream.empty();
  @override
  Stream<TranscriptSegment> get transcripts => transcripts$.stream;
  @override
  Future<void> prepare(
      LiveTranslationConfig config, AudioFormat format) async {}
  @override
  Future<void> push(AudioFrame frame) async {
    if (failPush) throw StateError('simulated STT failure');
  }

  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

final class _SimTranslator implements TextTranslationProvider {
  final Map<int, String> outputs = <int, String>{};
  final Map<int, Completer<void>> gates = <int, Completer<void>>{};
  @override
  String get providerId => 'sim-translator';
  @override
  String get sourceRevision => 'e2e';
  @override
  Stream<ProviderSnapshot> get snapshots => const Stream.empty();
  @override
  Stream<LiveTranslationDiagnostic> get diagnostics => const Stream.empty();
  @override
  Future<void> prepare(LiveTranslationConfig config) async {}
  @override
  Future<TranslationSegment> translate(TranscriptSegment transcript) async {
    await gates[transcript.sequence]?.future;
    return TranslationSegment(
      session: transcript.session,
      sequence: transcript.sequence,
      sourceText: transcript.text,
      translatedText: outputs[transcript.sequence] ?? 'TRANSLATED',
      observedAtMicros: transcript.observedAtMicros,
      truthLabel: TruthLabel.simulated,
    );
  }

  @override
  Future<void> dispose() async {}
}

final class _SimTts implements SpeechSynthesisProvider {
  final List<TranslationSegment> spoken = <TranslationSegment>[];
  @override
  String get providerId => 'sim-tts';
  @override
  String get sourceRevision => 'e2e';
  @override
  Stream<ProviderSnapshot> get snapshots => const Stream.empty();
  @override
  Stream<LiveTranslationDiagnostic> get diagnostics => const Stream.empty();
  @override
  Future<void> prepare(LiveTranslationConfig config) async {}
  @override
  Future<void> speak(TranslationSegment segment) async => spoken.add(segment);
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}
