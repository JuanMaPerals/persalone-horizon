import 'dart:async';
import 'dart:typed_data';

import 'package:persalone_contracts/persalone_contracts.dart';
import 'package:persalone_translation_runtime/persalone_translation_runtime.dart';
import 'package:test/test.dart';

void main() {
  group('HorizonTranslationRuntime', () {
    test(
        'fails closed before touching providers when session consent is absent',
        () async {
      final input = _FakeInput();
      final stt = _FakeStt();
      final translator = _FakeTranslator();
      final tts = _FakeTts();
      final runtime = HorizonTranslationRuntime(
        input: input,
        stt: stt,
        translator: translator,
        synthesizer: tts,
      );

      await expectLater(
        runtime.start(
          config: _config(localProcessingAllowed: false),
          audioSession: _audioSession(),
        ),
        throwsA(
          isA<RuntimeError>().having(
            (error) => error.code,
            'code',
            RuntimeErrorCode.consentRequired,
          ),
        ),
      );

      expect(input.requestPermissionCalls, 0);
      expect(stt.prepareCalls, 0);
      expect(translator.prepareCalls, 0);
      expect(tts.prepareCalls, 0);
      await runtime.dispose();
    });

    test(
        'forwards input to STT but translates and synthesizes final segments only',
        () async {
      final input = _FakeInput();
      final stt = _FakeStt();
      final translator = _FakeTranslator();
      final tts = _FakeTts();
      final runtime = HorizonTranslationRuntime(
        input: input,
        stt: stt,
        translator: translator,
        synthesizer: tts,
      );
      final config = _config();

      await runtime.start(config: config, audioSession: _audioSession());
      input.framesController.add(_frame());
      stt.transcriptController
          .add(_transcript(config.session, 1, TranscriptStability.partial));
      await _drain();
      expect(stt.pushedFrames, 1);
      expect(translator.translated, isEmpty);
      expect(tts.spoken, isEmpty);

      stt.transcriptController
          .add(_transcript(config.session, 2, TranscriptStability.finalResult));
      await _drain();
      expect(translator.translated, hasLength(1));
      expect(tts.spoken, hasLength(1));
      expect(tts.stopCalls, 1);
      await runtime.dispose();
    });

    test('discards a late transcript from another stream epoch', () async {
      final input = _FakeInput();
      final stt = _FakeStt();
      final translator = _FakeTranslator();
      final tts = _FakeTts();
      final runtime = HorizonTranslationRuntime(
        input: input,
        stt: stt,
        translator: translator,
        synthesizer: tts,
      );
      final diagnostics = <LiveTranslationDiagnostic>[];
      final subscription = runtime.diagnostics.listen(diagnostics.add);
      final config = _config();

      await runtime.start(config: config, audioSession: _audioSession());
      stt.transcriptController.add(_transcript(
        TranslationSession(
          sessionId: config.session.sessionId,
          streamEpoch: config.session.streamEpoch + 1,
          direction: config.session.direction,
          privacyGeneration: config.session.privacyGeneration,
        ),
        3,
        TranscriptStability.finalResult,
      ));
      await _drain();

      expect(translator.translated, isEmpty);
      expect(tts.spoken, isEmpty);
      expect(
        diagnostics.any((event) =>
            event.code == LiveTranslationDiagnosticCode.staleCallbackDiscarded),
        isTrue,
      );
      await subscription.cancel();
      await runtime.dispose();
    });

    test('discards turn N when N+1 resolves first', () async {
      final input = _FakeInput();
      final stt = _FakeStt();
      final translator = _FakeTranslator()..holdResults = true;
      final tts = _FakeTts();
      final runtime = HorizonTranslationRuntime(
        input: input,
        stt: stt,
        translator: translator,
        synthesizer: tts,
      );
      final diagnostics = <LiveTranslationDiagnostic>[];
      final translations = <TranslationSegment>[];
      final subscription = runtime.diagnostics.listen(diagnostics.add);
      final translationSubscription =
          runtime.translations.listen(translations.add);
      final config = _config();
      await runtime.start(config: config, audioSession: _audioSession());

      stt.transcriptController.add(
          _transcript(config.session, 10, TranscriptStability.finalResult));
      await _drain();
      stt.transcriptController.add(
          _transcript(config.session, 11, TranscriptStability.finalResult));
      await _drain();
      expect(translator.pending, hasLength(2));

      translator.complete(0);
      await _drain();
      expect(runtime.state, HorizonTranslationRuntimeState.listening);
      expect(translations, isEmpty);
      expect(tts.spoken, isEmpty);

      translator.complete(1);
      await _drain();
      expect(translations.map((segment) => segment.sequence), <int>[11]);
      expect(tts.spoken.map((segment) => segment.sequence), <int>[11]);
      expect(
        diagnostics.any(
          (event) =>
              event.code ==
                  LiveTranslationDiagnosticCode.staleCallbackDiscarded &&
              event.turnGeneration != null &&
              event.detail == null,
        ),
        isTrue,
      );
      await subscription.cancel();
      await translationSubscription.cancel();
      await runtime.dispose();
    });

    test('allows only the newest of three overlapping final transcripts',
        () async {
      final input = _FakeInput();
      final stt = _FakeStt();
      final translator = _FakeTranslator()..holdResults = true;
      final tts = _FakeTts();
      final runtime = HorizonTranslationRuntime(
        input: input,
        stt: stt,
        translator: translator,
        synthesizer: tts,
      );
      final translations = <TranslationSegment>[];
      final subscription = runtime.translations.listen(translations.add);
      final config = _config();
      await runtime.start(config: config, audioSession: _audioSession());
      for (final sequence in <int>[20, 21, 22]) {
        stt.transcriptController.add(_transcript(
            config.session, sequence, TranscriptStability.finalResult));
        await _drain();
      }
      expect(translator.pending, hasLength(3));

      translator.complete(1);
      translator.complete(0);
      await _drain();
      expect(translations, isEmpty);
      expect(tts.spoken, isEmpty);
      translator.complete(2);
      await _drain();

      expect(translations.map((segment) => segment.sequence), <int>[22]);
      expect(tts.spoken.map((segment) => segment.sequence), <int>[22]);
      await subscription.cancel();
      await runtime.dispose();
    });

    test('discards late TTS completion after barge-in advances the turn',
        () async {
      final input = _FakeInput();
      final stt = _FakeStt();
      final translator = _FakeTranslator();
      final tts = _FakeTts()..holdSpeak = true;
      final runtime = HorizonTranslationRuntime(
        input: input,
        stt: stt,
        translator: translator,
        synthesizer: tts,
      );
      final diagnostics = <LiveTranslationDiagnostic>[];
      final subscription = runtime.diagnostics.listen(diagnostics.add);
      final config = _config();
      await runtime.start(config: config, audioSession: _audioSession());
      stt.transcriptController.add(
          _transcript(config.session, 30, TranscriptStability.finalResult));
      await _drain();
      expect(tts.pendingSpeaks, hasLength(1));
      stt.transcriptController.add(
          _transcript(config.session, 31, TranscriptStability.finalResult));
      await _drain();

      tts.completeSpeak(0);
      await _drain();
      expect(runtime.state, HorizonTranslationRuntimeState.listening);
      expect(
        diagnostics.where(
          (event) =>
              event.code ==
              LiveTranslationDiagnosticCode.staleCallbackDiscarded,
        ),
        isNotEmpty,
      );
      await subscription.cancel();
      await runtime.dispose();
    });

    test('discards pending translation after stop', () async {
      final input = _FakeInput();
      final stt = _FakeStt();
      final translator = _FakeTranslator()..holdResults = true;
      final tts = _FakeTts();
      final runtime = HorizonTranslationRuntime(
        input: input,
        stt: stt,
        translator: translator,
        synthesizer: tts,
      );
      final translations = <TranslationSegment>[];
      final subscription = runtime.translations.listen(translations.add);
      final config = _config();
      await runtime.start(config: config, audioSession: _audioSession());
      stt.transcriptController.add(
          _transcript(config.session, 40, TranscriptStability.finalResult));
      await _drain();
      await runtime.stop();
      translator.complete(0);
      await _drain();

      expect(runtime.state, HorizonTranslationRuntimeState.stopped);
      expect(translations, isEmpty);
      expect(tts.spoken, isEmpty);
      await subscription.cancel();
      await runtime.dispose();
    });

    test('discards prior turn after restart of the same session', () async {
      final input = _FakeInput();
      final stt = _FakeStt();
      final translator = _FakeTranslator()..holdResults = true;
      final tts = _FakeTts();
      final runtime = HorizonTranslationRuntime(
        input: input,
        stt: stt,
        translator: translator,
        synthesizer: tts,
      );
      final translations = <TranslationSegment>[];
      final subscription = runtime.translations.listen(translations.add);
      final config = _config();
      await runtime.start(config: config, audioSession: _audioSession());
      stt.transcriptController.add(
          _transcript(config.session, 45, TranscriptStability.finalResult));
      await _drain();
      await runtime.stop();
      await runtime.start(config: config, audioSession: _audioSession());
      translator.complete(0);
      await _drain();

      expect(runtime.state, HorizonTranslationRuntimeState.listening);
      expect(translations, isEmpty);
      expect(tts.spoken, isEmpty);
      await subscription.cancel();
      await runtime.dispose();
    });

    test('discards prior privacy generation after restart', () async {
      final input = _FakeInput();
      final stt = _FakeStt();
      final translator = _FakeTranslator()..holdResults = true;
      final tts = _FakeTts();
      final runtime = HorizonTranslationRuntime(
        input: input,
        stt: stt,
        translator: translator,
        synthesizer: tts,
      );
      final translations = <TranslationSegment>[];
      final subscription = runtime.translations.listen(translations.add);
      final config = _config();
      await runtime.start(config: config, audioSession: _audioSession());
      stt.transcriptController.add(
          _transcript(config.session, 50, TranscriptStability.finalResult));
      await _drain();
      await runtime.stop();
      await runtime.start(
        config: _config(privacyGeneration: 2),
        audioSession: _audioSession(),
      );
      translator.complete(0);
      await _drain();

      expect(runtime.state, HorizonTranslationRuntimeState.listening);
      expect(translations, isEmpty);
      expect(tts.spoken, isEmpty);
      await subscription.cancel();
      await runtime.dispose();
    });

    test('invalidates pending work after translation failure', () async {
      final input = _FakeInput();
      final stt = _FakeStt();
      final translator = _FakeTranslator()..holdResults = true;
      final tts = _FakeTts();
      final runtime = HorizonTranslationRuntime(
        input: input,
        stt: stt,
        translator: translator,
        synthesizer: tts,
      );
      final config = _config();
      await runtime.start(config: config, audioSession: _audioSession());
      stt.transcriptController.add(
          _transcript(config.session, 60, TranscriptStability.finalResult));
      await _drain();
      translator.fail(0);
      await _drain();

      expect(runtime.state, HorizonTranslationRuntimeState.failed);
      expect(tts.spoken, isEmpty);
      await runtime.dispose();
    });

    test('stops current synthesis before each new final turn for barge-in',
        () async {
      final input = _FakeInput();
      final stt = _FakeStt();
      final translator = _FakeTranslator();
      final tts = _FakeTts();
      final runtime = HorizonTranslationRuntime(
        input: input,
        stt: stt,
        translator: translator,
        synthesizer: tts,
      );
      final config = _config();

      await runtime.start(config: config, audioSession: _audioSession());
      stt.transcriptController
          .add(_transcript(config.session, 4, TranscriptStability.finalResult));
      await _drain();
      stt.transcriptController
          .add(_transcript(config.session, 5, TranscriptStability.finalResult));
      await _drain();

      expect(tts.stopCalls, 2);
      expect(tts.spoken.map((segment) => segment.sequence), [4, 5]);
      await runtime.dispose();
    });
  });
}

Future<void> _drain([int turns = 3]) async {
  for (var index = 0; index < turns; index += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

LiveTranslationConfig _config({
  bool localProcessingAllowed = true,
  int privacyGeneration = 1,
}) =>
    LiveTranslationConfig(
      session: TranslationSession(
        sessionId: 'session-a',
        streamEpoch: 7,
        direction: TranslationDirection.englishToSpanish,
        privacyGeneration: privacyGeneration,
      ),
      sourceLocale: 'en-US',
      targetLocale: 'es-ES',
      consent: TranslationConsent(
        acceptedAtMicros: 1,
        localProcessingAllowed: localProcessingAllowed,
        modelDownloadAllowed: true,
        remoteProcessingAllowed: false,
      ),
    );

AudioSessionDescriptor _audioSession() => const AudioSessionDescriptor(
      sessionId: 'session-a',
      streamEpoch: 7,
      streamId: 'input-a',
    );

AudioFrame _frame() => AudioFrame(
      schemaVersion: 'v1',
      session: _audioSession(),
      direction: AudioDirection.input,
      sequence: 1,
      codec: AudioCodec.pcmS16le,
      format: AudioFormat.voice16kMono,
      capturedAtMicros: 1,
      receivedAtMicros: 1,
      durationMicros: 20_000,
      payload: Uint8List(320),
    );

TranscriptSegment _transcript(
  TranslationSession session,
  int sequence,
  TranscriptStability stability,
) =>
    TranscriptSegment(
      session: session,
      sequence: sequence,
      text: 'private runtime text',
      stability: stability,
      observedAtMicros: 1,
      truthLabel: TruthLabel.simulated,
    );

final class _FakeInput implements AudioInputAdapter {
  final framesController = StreamController<AudioFrame>.broadcast();
  final _snapshots = StreamController<AudioAdapterSnapshot>.broadcast();
  final _diagnostics = StreamController<AudioDiagnostic>.broadcast();
  final _latencies = StreamController<AudioLatencyMeasurement>.broadcast();
  int requestPermissionCalls = 0;

  @override
  String get adapterId => 'fake-input';
  @override
  String get sourceRevision => 'test';
  @override
  Stream<AudioFrame> get frames => framesController.stream;
  @override
  Stream<AudioAdapterSnapshot> get snapshots => _snapshots.stream;
  @override
  Stream<AudioDiagnostic> get diagnostics => _diagnostics.stream;
  @override
  Stream<AudioLatencyMeasurement> get latencyMeasurements => _latencies.stream;
  @override
  Future<bool> requestPermission() async {
    requestPermissionCalls += 1;
    return true;
  }

  @override
  Future<void> start(
      AudioSessionDescriptor session, AudioFormat format) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {
    await framesController.close();
    await _snapshots.close();
    await _diagnostics.close();
    await _latencies.close();
  }
}

final class _FakeStt implements StreamingSttProvider {
  final transcriptController = StreamController<TranscriptSegment>.broadcast();
  final _snapshots = StreamController<ProviderSnapshot>.broadcast();
  final _diagnostics = StreamController<LiveTranslationDiagnostic>.broadcast();
  int prepareCalls = 0;
  int pushedFrames = 0;
  final begunTurns = <TranslationExecutionToken>[];

  @override
  String get providerId => 'fake-stt';
  @override
  String get sourceRevision => 'test';
  @override
  Stream<ProviderSnapshot> get snapshots => _snapshots.stream;
  @override
  Stream<LiveTranslationDiagnostic> get diagnostics => _diagnostics.stream;
  @override
  Stream<TranscriptSegment> get transcripts => transcriptController.stream;
  @override
  Future<void> prepare(LiveTranslationConfig config, AudioFormat format) async {
    prepareCalls += 1;
  }

  @override
  Future<void> beginTurn(TranslationExecutionToken token) async {
    begunTurns.add(token);
  }

  @override
  Future<void> push(AudioFrame frame) async {
    pushedFrames += 1;
  }

  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {
    await transcriptController.close();
    await _snapshots.close();
    await _diagnostics.close();
  }
}

final class _FakeTranslator implements TextTranslationProvider {
  final _snapshots = StreamController<ProviderSnapshot>.broadcast();
  final _diagnostics = StreamController<LiveTranslationDiagnostic>.broadcast();
  final translated = <TranscriptSegment>[];
  final pending = <Completer<TranslationSegment>>[];
  bool holdResults = false;
  int prepareCalls = 0;

  @override
  String get providerId => 'fake-translator';
  @override
  String get sourceRevision => 'test';
  @override
  Stream<ProviderSnapshot> get snapshots => _snapshots.stream;
  @override
  Stream<LiveTranslationDiagnostic> get diagnostics => _diagnostics.stream;
  @override
  Future<void> prepare(LiveTranslationConfig config) async {
    prepareCalls += 1;
  }

  @override
  Future<TranslationSegment> translate(
      TranscriptSegment finalTranscript) async {
    translated.add(finalTranscript);
    final result = _resultFor(finalTranscript);
    if (!holdResults) {
      return result;
    }
    final completion = Completer<TranslationSegment>();
    pending.add(completion);
    return completion.future;
  }

  void complete(int index) =>
      pending[index].complete(_resultFor(translated[index]));

  void fail(int index) => pending[index].completeError(
        const RuntimeError(
          RuntimeErrorCode.providerUnavailable,
          'Controlled translation provider failure.',
        ),
      );

  TranslationSegment _resultFor(TranscriptSegment transcript) =>
      TranslationSegment(
        session: transcript.session,
        sequence: transcript.sequence,
        sourceText: transcript.text,
        translatedText: 'translated',
        observedAtMicros: 1,
        truthLabel: TruthLabel.simulated,
      );

  @override
  Future<void> dispose() async {
    await _snapshots.close();
    await _diagnostics.close();
  }
}

final class _FakeTts implements SpeechSynthesisProvider {
  final _snapshots = StreamController<ProviderSnapshot>.broadcast();
  final _diagnostics = StreamController<LiveTranslationDiagnostic>.broadcast();
  final spoken = <TranslationSegment>[];
  final pendingSpeaks = <Completer<void>>[];
  bool holdSpeak = false;
  int prepareCalls = 0;
  int stopCalls = 0;

  @override
  String get providerId => 'fake-tts';
  @override
  String get sourceRevision => 'test';
  @override
  Stream<ProviderSnapshot> get snapshots => _snapshots.stream;
  @override
  Stream<LiveTranslationDiagnostic> get diagnostics => _diagnostics.stream;
  @override
  Future<void> prepare(LiveTranslationConfig config) async {
    prepareCalls += 1;
  }

  @override
  Future<void> speak(TranslationSegment segment) async {
    spoken.add(segment);
    if (holdSpeak) {
      final completion = Completer<void>();
      pendingSpeaks.add(completion);
      await completion.future;
    }
  }

  void completeSpeak(int index) => pendingSpeaks[index].complete();

  @override
  Future<void> stop() async {
    stopCalls += 1;
  }

  @override
  Future<void> dispose() async {
    await _snapshots.close();
    await _diagnostics.close();
  }
}
