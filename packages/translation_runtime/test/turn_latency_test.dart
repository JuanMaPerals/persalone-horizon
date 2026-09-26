import 'dart:async';

import 'package:persalone_contracts/persalone_contracts.dart';
import 'package:persalone_translation_runtime/persalone_translation_runtime.dart';
import 'package:test/test.dart';

// Latency is measured on the runtime's monotonic clock only. These tests pin
// which intervals exist, what they span, and when nothing may be reported.
void main() {
  late _Clock clock;
  late _Translator translator;
  late _Captions captions;
  late _Stt stt;
  late HorizonTranslationRuntime runtime;
  late List<TurnLatencySample> samples;

  setUp(() async {
    clock = _Clock();
    translator = _Translator(clock);
    captions = _Captions(clock);
    stt = _Stt();
    runtime = HorizonTranslationRuntime(
      input: _Input(),
      stt: stt,
      translator: translator,
      synthesizer: _Tts(clock),
      captions: captions,
      // Wall clock deliberately jumps backwards: latency must not use it.
      clock: () => DateTime.fromMicrosecondsSinceEpoch(clock.wall -= 1000000),
      monotonicMicros: () => clock.now,
    );
    samples = <TurnLatencySample>[];
    runtime.latencies.listen(samples.add);
    await runtime.start(config: _config, audioSession: _audio);
  });

  tearDown(() => runtime.dispose());

  test('exact intervals of a delivered turn on the monotonic clock', () async {
    translator.costMicros = 120000;
    captions.costMicros = 35000;
    await _final(stt, 1);
    expect(_byStage(samples), <TurnLatencyStage, int>{
      TurnLatencyStage.finalToTranslation: 120000,
      TurnLatencyStage.translationToCaption: 35000,
      TurnLatencyStage.finalToCaption: 155000,
      TurnLatencyStage.finalToSpeechQueued: 155000 + 4000,
    });
    expect(
      samples
          .where((s) => s.stage != TurnLatencyStage.finalToTranslation &&
              s.stage != TurnLatencyStage.finalToSpeechQueued)
          .map((s) => s.environment),
      everyElement(ExecutionEnvironment.emulated),
    );
    expect(
        samples
            .firstWhere((s) => s.stage == TurnLatencyStage.finalToTranslation)
            .environment,
        isNull,
        reason: 'the runtime cannot know where the translator ran');
  });

  test('blocked or failed captions never produce a caption interval',
      () async {
    captions.status = CaptionDeliveryStatus.blocked;
    await _final(stt, 1);
    captions.status = CaptionDeliveryStatus.failed;
    await _final(stt, 2);
    captions.throwOnShow = true;
    await _final(stt, 3);
    expect(
      samples.map((s) => s.stage),
      isNot(anyElement(anyOf(TurnLatencyStage.finalToCaption,
          TurnLatencyStage.translationToCaption))),
    );
  });

  test('a stale turn (overtaken by a newer one) reports nothing', () async {
    translator.gates[1] = Completer<void>();
    await _final(stt, 1);
    await _final(stt, 2);
    translator.gates[1]!.complete();
    await _drain();
    expect(samples.map((s) => s.turn).toSet(), <int>{2});
  });

  test('a turn finishing after stop reports nothing', () async {
    translator.gates[1] = Completer<void>();
    await _final(stt, 1);
    await runtime.stop();
    translator.gates[1]!.complete();
    await _drain();
    expect(samples, isEmpty);
  });

  test('a clock that runs backwards yields no sample, never a negative one',
      () async {
    translator.costMicros = -50000;
    await _final(stt, 1);
    expect(samples.map((s) => s.stage),
        isNot(contains(TurnLatencyStage.finalToTranslation)));
    expect(samples.map((s) => s.micros), everyElement(greaterThanOrEqualTo(0)));
  });

  test('partial transcripts start no measurement', () async {
    stt.controller.add(_segment(1, TranscriptStability.partial));
    await _drain();
    expect(samples, isEmpty);
  });
}

Map<TurnLatencyStage, int> _byStage(List<TurnLatencySample> samples) =>
    <TurnLatencyStage, int>{
      for (final TurnLatencySample s in samples) s.stage: s.micros,
    };

Future<void> _drain() async {
  for (int i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> _final(_Stt stt, int sequence) async {
  stt.controller.add(_segment(sequence, TranscriptStability.finalResult));
  await _drain();
}

TranscriptSegment _segment(int sequence, TranscriptStability stability) =>
    TranscriptSegment(
      session: _session,
      sequence: sequence,
      text: 'hello',
      stability: stability,
      observedAtMicros: sequence,
      truthLabel: TruthLabel.simulated,
    );

const TranslationSession _session = TranslationSession(
  sessionId: 'latency',
  streamEpoch: 1,
  direction: TranslationDirection.englishToSpanish,
  privacyGeneration: 1,
);

const AudioSessionDescriptor _audio =
    AudioSessionDescriptor(sessionId: 'latency', streamEpoch: 1, streamId: 'in');

const LiveTranslationConfig _config = LiveTranslationConfig(
  session: _session,
  sourceLocale: 'en-US',
  targetLocale: 'es-ES',
  consent: TranslationConsent(
    acceptedAtMicros: 1,
    localProcessingAllowed: true,
    modelDownloadAllowed: false,
    remoteProcessingAllowed: false,
  ),
);

final class _Clock {
  int now = 5000000;
  int wall = 1700000000000000;
}

final class _Translator implements TextTranslationProvider {
  _Translator(this.clock);
  final _Clock clock;
  int costMicros = 1000;
  final Map<int, Completer<void>> gates = <int, Completer<void>>{};
  @override
  String get providerId => 'latency-translator';
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
    await gates[t.sequence]?.future;
    clock.now += costMicros;
    return TranslationSegment(
      session: t.session,
      sequence: t.sequence,
      sourceText: t.text,
      translatedText: 'hola',
      observedAtMicros: t.observedAtMicros,
      truthLabel: TruthLabel.simulated,
    );
  }

  @override
  Future<void> dispose() async {}
}

final class _Captions implements CaptionOutputAdapter {
  _Captions(this.clock);
  final _Clock clock;
  int costMicros = 1000;
  CaptionDeliveryStatus status = CaptionDeliveryStatus.delivered;
  bool throwOnShow = false;
  @override
  String get adapterId => 'latency-captions';
  @override
  ExecutionEnvironment get environment => ExecutionEnvironment.emulated;
  @override
  Future<CaptionDelivery> show(CaptionUpdate update) async {
    clock.now += costMicros;
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
      reason: status == CaptionDeliveryStatus.delivered ? null : 'blocked',
    );
  }

  @override
  Future<void> clear(TranslationSession session) async {}
}

final class _Tts implements SpeechSynthesisProvider {
  _Tts(this.clock);
  final _Clock clock;
  @override
  String get providerId => 'latency-tts';
  @override
  String get sourceRevision => 'test';
  @override
  Stream<ProviderSnapshot> get snapshots => const Stream.empty();
  @override
  Stream<LiveTranslationDiagnostic> get diagnostics => const Stream.empty();
  @override
  Future<void> prepare(LiveTranslationConfig c) async {}
  @override
  Future<void> speak(TranslationSegment s) async => clock.now += 4000;
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

final class _Stt implements StreamingSttProvider {
  final StreamController<TranscriptSegment> controller =
      StreamController<TranscriptSegment>.broadcast();
  @override
  Stream<TranscriptSegment> get transcripts => controller.stream;
  @override
  String get providerId => 'latency-stt';
  @override
  String get sourceRevision => 'test';
  @override
  Stream<ProviderSnapshot> get snapshots => const Stream.empty();
  @override
  Stream<LiveTranslationDiagnostic> get diagnostics => const Stream.empty();
  @override
  Future<void> prepare(LiveTranslationConfig c, AudioFormat f) async {}
  @override
  Future<void> push(AudioFrame frame) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

final class _Input implements AudioInputAdapter {
  @override
  String get adapterId => 'latency-input';
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
