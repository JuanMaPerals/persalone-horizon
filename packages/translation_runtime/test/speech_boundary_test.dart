import 'dart:async';

import 'package:persalone_contracts/persalone_contracts.dart';
import 'package:persalone_translation_runtime/persalone_translation_runtime.dart';
import 'package:test/test.dart';

// End-of-speech latency and self-echo suspicion (physical validation pack).
void main() {
  late _Clock clock;
  late _Stt stt;
  late _Tts tts;
  late HorizonTranslationRuntime runtime;
  late List<TurnLatencySample> latencies;
  late List<LiveTranslationDiagnostic> diagnostics;

  setUp(() async {
    clock = _Clock();
    stt = _Stt();
    tts = _Tts();
    runtime = HorizonTranslationRuntime(
      input: _Input(),
      stt: stt,
      translator: _Translator(),
      synthesizer: tts,
      monotonicMicros: () => clock.now,
    );
    latencies = <TurnLatencySample>[];
    diagnostics = <LiveTranslationDiagnostic>[];
    runtime.latencies.listen(latencies.add);
    runtime.diagnostics.listen(diagnostics.add);
    await runtime.start(config: _config, audioSession: _audio);
  });

  tearDown(() => runtime.dispose());

  List<String?> echoes() => diagnostics
      .where((d) => d.code == LiveTranslationDiagnosticCode.selfEchoSuspected)
      .map((d) => d.detail)
      .toList();

  group('speechEndToFinal', () {
    test('measured on the provider clock when end of speech is reported',
        () async {
      await stt.say(1, 'hello there', observedAt: 9000000, endedAt: 8350000);
      final TurnLatencySample sample = latencies
          .singleWhere((s) => s.stage == TurnLatencyStage.speechEndToFinal);
      expect(sample.micros, 650000);
      expect(sample.turn, 1);
      expect(sample.environment, isNull);
    });

    test('absent end of speech stays UNKNOWN (no sample)', () async {
      await stt.say(1, 'hello there', observedAt: 9000000);
      expect(latencies.map((s) => s.stage),
          isNot(contains(TurnLatencyStage.speechEndToFinal)));
    });

    test('an end of speech after the result is never reported negative',
        () async {
      await stt.say(1, 'hello there', observedAt: 9000000, endedAt: 9100000);
      expect(latencies.map((s) => s.stage),
          isNot(contains(TurnLatencyStage.speechEndToFinal)));
    });
  });

  group('self-echo suspicion', () {
    test('silent when the synthesizer never reported speaking', () async {
      await stt.say(1, 'hello there');
      await stt.say(2, 'how are you');
      expect(echoes(), isEmpty);
    });

    test('a final turn while speaking the translation is flagged', () async {
      tts.reportsProgress = true;
      await stt.say(1, 'hello there');
      expect(tts.speaking, isTrue);
      clock.now += 400000;
      await stt.say(2, 'unrelated words here');
      expect(echoes(), <String>['duringTts']);
    });

    test('the heard words match what was spoken: textOverlap', () async {
      tts.reportsProgress = true;
      await stt.say(1, 'hello there');
      // The translator returns "hola <text>"; hearing it back is echo-like.
      await stt.say(2, 'hola hello there');
      expect(echoes(), <String>['duringTts.textOverlap']);
    });

    test('shortly after speech ended: afterTts; later: nothing', () async {
      tts.reportsProgress = true;
      await stt.say(1, 'hello there');
      tts.complete();
      await _drain();
      clock.now += HorizonTranslationRuntime.selfEchoTailMicros - 1;
      await stt.say(2, 'something else');
      expect(echoes(), <String>['afterTts']);

      tts.complete();
      await _drain();
      clock.now += HorizonTranslationRuntime.selfEchoTailMicros + 1;
      await stt.say(3, 'much later words');
      expect(echoes(), <String>['afterTts']);
    });

    test('a missing completion does not keep suspecting forever', () async {
      tts.reportsProgress = true;
      await stt.say(1, 'hello there');
      clock.now += HorizonTranslationRuntime.maxSpeakingMicros +
          HorizonTranslationRuntime.selfEchoTailMicros +
          1;
      await stt.say(2, 'next turn words');
      expect(echoes(), isEmpty);
    });

    test('suspicion never carries text and never blocks the turn', () async {
      tts.reportsProgress = true;
      await stt.say(1, 'hello there');
      await stt.say(2, 'hola hello there');
      final LiveTranslationDiagnostic d = diagnostics.singleWhere(
          (d) => d.code == LiveTranslationDiagnosticCode.selfEchoSuspected);
      expect(d.detail, isNot(contains('hello')));
      expect(tts.spoken, <int>[1, 2]);
    });

    test('word overlap ignores case, punctuation and 1-letter words', () {
      expect(HorizonTranslationRuntime.tokenOverlap('Hola, ¿qué tal?', 'hola que tal'),
          closeTo(2 / 3, 1e-9));
      expect(HorizonTranslationRuntime.tokenOverlap('a b', 'a b'), 0);
      expect(HorizonTranslationRuntime.tokenOverlap('hola amigo', null), 0);
    });
  });
}

Future<void> _drain() async {
  for (int i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

const TranslationSession _session = TranslationSession(
  sessionId: 'boundary',
  streamEpoch: 1758700000000000,
  direction: TranslationDirection.englishToSpanish,
  privacyGeneration: 1,
);

const AudioSessionDescriptor _audio = AudioSessionDescriptor(
    sessionId: 'boundary', streamEpoch: 1758700000000000, streamId: 'in');

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
  int now = 1000000;
}

final class _Stt implements StreamingSttProvider {
  final StreamController<TranscriptSegment> _c =
      StreamController<TranscriptSegment>.broadcast();

  Future<void> say(int sequence, String text,
      {int observedAt = 5000000, int? endedAt}) async {
    _c.add(TranscriptSegment(
      session: _session,
      sequence: sequence,
      text: text,
      stability: TranscriptStability.finalResult,
      observedAtMicros: observedAt,
      truthLabel: TruthLabel.simulated,
      speechEndedAtMicros: endedAt,
    ));
    await _drain();
  }

  @override
  Stream<TranscriptSegment> get transcripts => _c.stream;
  @override
  String get providerId => 'boundary-stt';
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

final class _Translator implements TextTranslationProvider {
  @override
  String get providerId => 'boundary-translator';
  @override
  String get sourceRevision => 'test';
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
        translatedText: 'hola ${t.text}',
        observedAtMicros: t.observedAtMicros,
        truthLabel: TruthLabel.simulated,
      );
  @override
  Future<void> dispose() async {}
}

/// Mirrors the Android provider: `synthesisStarted` when the platform starts
/// speaking, `synthesisCompleted` when it finishes.
final class _Tts implements SpeechSynthesisProvider {
  final StreamController<LiveTranslationDiagnostic> _d =
      StreamController<LiveTranslationDiagnostic>.broadcast();
  bool reportsProgress = false;
  bool speaking = false;
  final List<int> spoken = <int>[];

  void complete() {
    speaking = false;
    _d.add(const LiveTranslationDiagnostic(
      code: LiveTranslationDiagnosticCode.synthesisCompleted,
      component: 'tts',
      observedAtMicros: 0,
    ));
  }

  @override
  String get providerId => 'boundary-tts';
  @override
  String get sourceRevision => 'test';
  @override
  Stream<ProviderSnapshot> get snapshots => const Stream.empty();
  @override
  Stream<LiveTranslationDiagnostic> get diagnostics => _d.stream;
  @override
  Future<void> prepare(LiveTranslationConfig c) async {}
  @override
  Future<void> speak(TranslationSegment s) async {
    spoken.add(s.sequence);
    if (reportsProgress) {
      speaking = true;
      _d.add(LiveTranslationDiagnostic(
        code: LiveTranslationDiagnosticCode.synthesisStarted,
        component: 'tts',
        observedAtMicros: 0,
        sequence: s.sequence,
      ));
    }
  }

  // Barge-in stop does not emit completion on Android.
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

final class _Input implements AudioInputAdapter {
  @override
  String get adapterId => 'boundary-input';
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
