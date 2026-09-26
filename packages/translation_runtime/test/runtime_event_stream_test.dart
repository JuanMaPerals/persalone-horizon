import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:persalone_contracts/persalone_contracts.dart';
import 'package:persalone_translation_runtime/persalone_translation_runtime.dart';
import 'package:test/test.dart';

// Goldens are produced by the real G5 runtime here and consumed by the
// Engineering Console tests, so the Console never parses a hand-written trace.
const String _goldenDir = '../../apps/engineering-console/tests/fixtures';
const String _privateSource = 'PRIVATE SOURCE TEXT';
const String _privateTranslation = 'PRIVATE TRANSLATED TEXT';

void main() {
  test('stop session: states, captions and environment on the v1 stream',
      () async {
    final _Scenario s = await _Scenario.start();
    await s.finalTurn(1, CaptionDeliveryStatus.delivered);
    await s.finalTurn(2, CaptionDeliveryStatus.blocked);
    await s.runtime.stop();
    final List<String> lines = await s.finish();

    final List<Map<String, Object?>> events = _decode(lines);
    expect(_states(events),
        <String>['preparing', 'listening', 'stopping', 'stopped']);
    expect(_captions(events), <String>['delivered', 'blocked']);
    expect(
      events.where((e) => e['kind'] == 'caption').map((e) => e['environment']),
      everyElement('SIMULATED'),
    );
    expect(events.last['session'], isNotNull,
        reason: 'stopped keeps the last known session identity');
    _expectRedactedAndOrdered(lines, events);
    _golden('runtime-events.stop.v1.ndjson', lines);
  });

  test('failure session: caption error and fail-closed state are visible',
      () async {
    final _Scenario s = await _Scenario.start();
    await s.finalTurn(1, CaptionDeliveryStatus.delivered);
    s.captions.throwOnShow = true;
    await s.finalTurn(2, CaptionDeliveryStatus.failed);
    s.stt.failPush = true;
    s.input.controller.add(_frame());
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final List<String> lines = await s.finish();

    final List<Map<String, Object?>> events = _decode(lines);
    expect(_states(events).last, 'failed');
    final Map<String, Object?> failed = events.lastWhere(
        (e) => e['kind'] == 'sessionState' && e['state'] == 'failed');
    expect(failed['failureCode'], RuntimeErrorCode.providerUnavailable.name);
    expect(_captions(events), <String>['delivered', 'failed']);
    expect(
      events.firstWhere(
          (e) => e['kind'] == 'caption' && e['status'] == 'failed')['reason'],
      'adapterError',
    );
    expect(
      events.where(
          (e) => e['kind'] == 'diagnostic' && e['code'] == 'captionFailed'),
      isNotEmpty,
    );
    _expectRedactedAndOrdered(lines, events);
    _golden('runtime-events.failure.v1.ndjson', lines);
  });

  test('device snapshots carry the declared environment, never inferred',
      () async {
    final StreamController<DeviceAdapterSnapshot> device =
        StreamController<DeviceAdapterSnapshot>();
    final _Scenario s = await _Scenario.start(deviceSnapshots: device.stream);
    device.add(const DeviceAdapterSnapshot(
      state: DeviceConnectionState.ready,
      adapterId: 'halo device adapter with spaces',
      sourceRevision: 'r',
      truthLabel: TruthLabel.prepared,
      observedAtMicros: 5,
    ));
    await Future<void>.delayed(Duration.zero);
    final List<Map<String, Object?>> events = _decode(await s.finish());
    final Map<String, Object?> deviceEvent =
        events.singleWhere((e) => e['kind'] == 'deviceState');
    expect(deviceEvent['state'], 'ready');
    expect(deviceEvent['environment'], 'EMULATED');
    expect(deviceEvent['truth'], 'PREPARED');
    expect(deviceEvent['adapter'], 'redacted');
    expect(deviceEvent['session'], isNull);
    await device.close();
  });

  test('latency: measured turn intervals on the v1 stream, no text', () async {
    final _Scenario s = await _Scenario.start();
    for (int turn = 1; turn <= 24; turn++) {
      await s.finalTurn(
          turn,
          turn == 7
              ? CaptionDeliveryStatus.blocked
              : CaptionDeliveryStatus.delivered);
    }
    await s.runtime.stop();
    final List<String> lines = await s.finish();

    final List<Map<String, Object?>> events = _decode(lines);
    final List<Map<String, Object?>> latency =
        events.where((e) => e['kind'] == 'latency').toList();
    Iterable<Map<String, Object?>> stage(String name) =>
        latency.where((e) => e['stage'] == name);
    expect(stage('finalToTranslation'), hasLength(24));
    expect(stage('finalToSpeechQueued'), hasLength(24));
    // A blocked caption was never shown: no caption interval for turn 7.
    expect(stage('finalToCaption'), hasLength(23));
    expect(stage('finalToCaption').map((e) => e['turn']), isNot(contains(7)));
    expect(stage('finalToCaption').map((e) => e['environment']),
        everyElement('SIMULATED'));
    expect(stage('finalToTranslation').map((e) => e['environment']),
        everyElement(isNull));
    expect(latency.map((e) => e['truth']), everyElement('MEASURED'));
    for (final Map<String, Object?> e in latency) {
      expect(e['micros'], isA<int>());
      expect(e['micros']! as int, greaterThan(0));
    }
    _expectRedactedAndOrdered(lines, events);
    _golden('runtime-events.latency.v1.ndjson', lines);
  });

  test('validation run: end of speech, self-echo and glyph limit, no text',
      () async {
    final _Scenario s = await _Scenario.start();
    s.tts.reportsProgress = true;
    s.captions.deliveredReason = 'glyphsReplaced';
    await s.finalTurn(1, CaptionDeliveryStatus.delivered, endedAt: 400);
    // Heard while the device is still speaking turn 1's translation.
    await s.finalTurn(2, CaptionDeliveryStatus.delivered,
        endedAt: 1500, text: _privateTranslation);
    await s.runtime.stop();
    final List<String> lines = await s.finish();

    final List<Map<String, Object?>> events = _decode(lines);
    final List<Map<String, Object?>> endToFinal = events
        .where((e) => e['kind'] == 'latency' && e['stage'] == 'speechEndToFinal')
        .toList();
    expect(endToFinal.map((e) => e['micros']), <int>[600, 500]);
    final List<Object?> echo = events
        .where((e) => e['code'] == 'selfEchoSuspected')
        .map((e) => e['detail'])
        .toList();
    expect(echo, <String>['duringTts.textOverlap']);
    expect(
        events
            .where((e) => e['kind'] == 'caption')
            .map((e) => e['reason']),
        everyElement('glyphsReplaced'));
    _expectRedactedAndOrdered(lines, events);
    _golden('runtime-events.validation.v1.ndjson', lines);
  });

  test('free-form diagnostic detail is reduced to a coded token', () {
    const LiveTranslationDiagnostic diagnostic = LiveTranslationDiagnostic(
      code: LiveTranslationDiagnosticCode.providerUnavailable,
      component: 'stt provider with spaces',
      observedAtMicros: 1,
      detail: 'Model failed for "hola amigo"',
    );
    final Map<String, Object?> json =
        RuntimeEvent.diagnostic(streamSequence: 1, diagnostic: diagnostic)
            .toJson();
    expect(json['component'], 'redacted');
    expect(json['detail'], 'redacted');
    expect(jsonEncode(json), isNot(contains('hola')));
  });
}

void _expectRedactedAndOrdered(
    List<String> lines, List<Map<String, Object?>> events) {
  for (final String line in lines) {
    expect(line, isNot(contains(_privateSource)));
    expect(line, isNot(contains(_privateTranslation)));
  }
  expect(events.map((e) => e['schema']).toSet(), <Object?>{runtimeEventSchema});
  expect(events.map((e) => e['seq']),
      List<int>.generate(events.length, (int i) => i + 1));
}

List<Map<String, Object?>> _decode(List<String> lines) =>
    lines.map((String l) => (jsonDecode(l) as Map<String, Object?>)).toList();

List<Object?> _states(List<Map<String, Object?>> events) => events
    .where((e) => e['kind'] == 'sessionState')
    .map((e) => e['state'])
    .toList();

List<Object?> _captions(List<Map<String, Object?>> events) => events
    .where((e) => e['kind'] == 'caption')
    .map((e) => e['status'])
    .toList();

void _golden(String name, List<String> lines) {
  final File file = File('$_goldenDir/$name');
  final String content = '${lines.join('\n')}\n';
  if (Platform.environment['HORIZON_UPDATE_GOLDEN'] == '1') {
    file.createSync(recursive: true);
    file.writeAsStringSync(content);
  }
  expect(file.existsSync(), isTrue,
      reason: 'run with HORIZON_UPDATE_GOLDEN=1 to create $name');
  expect(file.readAsStringSync(), content,
      reason: 'golden drift: regenerate with HORIZON_UPDATE_GOLDEN=1');
}

AudioFrame _frame() => AudioFrame(
      schemaVersion: 'v1',
      session: const AudioSessionDescriptor(
          sessionId: 'session-golden', streamEpoch: 3, streamId: 'in'),
      direction: AudioDirection.input,
      sequence: 1,
      codec: AudioCodec.pcmS16le,
      format: AudioFormat.voice16kMono,
      capturedAtMicros: 1,
      receivedAtMicros: 1,
      durationMicros: 20000,
      payload: Uint8List(320),
    );

final class _Scenario {
  _Scenario._(this.runtime, this.stream, this.input, this.stt, this.captions,
      this.tts);

  final HorizonTranslationRuntime runtime;
  final RuntimeEventStream stream;
  final _Input input;
  final _Stt stt;
  final _Captions captions;
  final _Tts tts;
  final List<String> _lines = <String>[];
  late final StreamSubscription<RuntimeEvent> _sub;

  static const TranslationSession session = TranslationSession(
    sessionId: 'session-golden',
    streamEpoch: 3,
    direction: TranslationDirection.englishToSpanish,
    privacyGeneration: 1,
  );

  static Future<_Scenario> start(
      {Stream<DeviceAdapterSnapshot>? deviceSnapshots}) async {
    int runtimeTick = 1000;
    int captionTick = 900000;
    int monotonicTick = 0;
    final _Input input = _Input();
    final _Stt stt = _Stt();
    final _Captions captions = _Captions();
    final _Tts tts = _Tts();
    final HorizonTranslationRuntime runtime = HorizonTranslationRuntime(
      input: input,
      stt: stt,
      translator: _Translator(),
      synthesizer: tts,
      captions: captions,
      clock: () => DateTime.fromMicrosecondsSinceEpoch(runtimeTick += 10),
      // Deterministic monotonic clock: each reading advances 1.5 ms.
      monotonicMicros: () => monotonicTick += 1500,
    );
    final RuntimeEventStream stream = RuntimeEventStream(
      runtime,
      nowMicros: () => captionTick += 10,
      deviceSnapshots: deviceSnapshots,
      deviceEnvironment: ExecutionEnvironment.emulated,
    );
    final _Scenario s =
        _Scenario._(runtime, stream, input, stt, captions, tts);
    s._sub = stream.events.listen(
        (RuntimeEvent e) => s._lines.add(RuntimeEventStream.encodeLine(e)));
    await runtime.start(
      config: const LiveTranslationConfig(
        session: session,
        sourceLocale: 'en-US',
        targetLocale: 'es-ES',
        consent: TranslationConsent(
          acceptedAtMicros: 1,
          localProcessingAllowed: true,
          modelDownloadAllowed: false,
          remoteProcessingAllowed: false,
        ),
      ),
      audioSession: const AudioSessionDescriptor(
          sessionId: 'session-golden', streamEpoch: 3, streamId: 'in'),
    );
    return s;
  }

  Future<void> finalTurn(int sequence, CaptionDeliveryStatus status,
      {int? endedAt, String text = _privateSource}) async {
    captions.status = status;
    stt.controller.add(TranscriptSegment(
      session: session,
      sequence: sequence,
      text: text,
      stability: TranscriptStability.finalResult,
      observedAtMicros: endedAt == null ? sequence : sequence * 1000,
      truthLabel: TruthLabel.simulated,
      speechEndedAtMicros: endedAt,
    ));
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  Future<List<String>> finish() async {
    await Future<void>.delayed(Duration.zero);
    await _sub.cancel();
    await stream.close();
    await runtime.dispose();
    return _lines;
  }
}

final class _Input implements AudioInputAdapter {
  final StreamController<AudioFrame> controller =
      StreamController<AudioFrame>.broadcast();
  @override
  String get adapterId => 'golden-input';
  @override
  String get sourceRevision => 'golden';
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
  Future<void> start(AudioSessionDescriptor s, AudioFormat f) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

final class _Stt implements StreamingSttProvider {
  final StreamController<TranscriptSegment> controller =
      StreamController<TranscriptSegment>.broadcast();
  bool failPush = false;
  @override
  Stream<TranscriptSegment> get transcripts => controller.stream;
  @override
  String get providerId => 'golden-stt';
  @override
  String get sourceRevision => 'golden';
  @override
  Stream<ProviderSnapshot> get snapshots => const Stream.empty();
  @override
  Stream<LiveTranslationDiagnostic> get diagnostics => const Stream.empty();
  @override
  Future<void> prepare(LiveTranslationConfig c, AudioFormat f) async {}
  @override
  Future<void> push(AudioFrame frame) async {
    if (failPush) throw StateError('simulated STT failure');
  }

  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

final class _Translator implements TextTranslationProvider {
  @override
  String get providerId => 'golden-translator';
  @override
  String get sourceRevision => 'golden';
  @override
  Stream<ProviderSnapshot> get snapshots => const Stream.empty();
  @override
  Stream<LiveTranslationDiagnostic> get diagnostics => const Stream.empty();
  @override
  Future<void> prepare(LiveTranslationConfig c) async {}
  @override
  Future<TranslationSegment> translate(TranscriptSegment t) async =>
      TranslationSegment(
        session: t.session,
        sequence: t.sequence,
        sourceText: t.text,
        translatedText: _privateTranslation,
        observedAtMicros: t.observedAtMicros,
        truthLabel: TruthLabel.simulated,
      );
  @override
  Future<void> dispose() async {}
}

final class _Tts implements SpeechSynthesisProvider {
  final StreamController<LiveTranslationDiagnostic> _diagnostics =
      StreamController<LiveTranslationDiagnostic>.broadcast();

  /// Emits synthesisStarted like the Android provider when true.
  bool reportsProgress = false;
  @override
  String get providerId => 'golden-tts';
  @override
  String get sourceRevision => 'golden';
  @override
  Stream<ProviderSnapshot> get snapshots => const Stream.empty();
  @override
  Stream<LiveTranslationDiagnostic> get diagnostics => _diagnostics.stream;
  @override
  Future<void> prepare(LiveTranslationConfig c) async {}
  @override
  Future<void> speak(TranslationSegment s) async {
    if (reportsProgress) {
      _diagnostics.add(LiveTranslationDiagnostic(
        code: LiveTranslationDiagnosticCode.synthesisStarted,
        component: 'golden-tts',
        observedAtMicros: 0,
        sequence: s.sequence,
      ));
    }
  }
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

final class _Captions implements CaptionOutputAdapter {
  CaptionDeliveryStatus status = CaptionDeliveryStatus.delivered;
  String? deliveredReason;
  bool throwOnShow = false;
  @override
  String get adapterId => 'golden-captions';
  @override
  ExecutionEnvironment get environment => ExecutionEnvironment.simulated;
  @override
  Future<CaptionDelivery> show(CaptionUpdate update) async {
    if (throwOnShow) throw StateError('display unavailable');
    return CaptionDelivery(
      session: update.session,
      sequence: update.sequence,
      status: status,
      environment: environment,
      truthLabel: status == CaptionDeliveryStatus.delivered
          ? TruthLabel.simulated
          : TruthLabel.blocked,
      adapterId: adapterId,
      reason: status == CaptionDeliveryStatus.delivered
          ? deliveredReason
          : 'capabilityUnavailable',
    );
  }

  @override
  Future<void> clear(TranslationSession session) async {}
}
