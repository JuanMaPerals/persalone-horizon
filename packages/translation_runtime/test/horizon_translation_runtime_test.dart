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

    test(
        'fails closed and stops active resources after a mid-session STT failure',
        () async {
      final input = _FakeInput();
      final stt = _FakeStt()..failPush = true;
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
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(runtime.state, HorizonTranslationRuntimeState.failed);
      expect(input.stopCalls, 1);
      expect(stt.stopCalls, 1);
      expect(tts.stopCalls, 1);

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

    test(
        'never publishes or speaks an older final turn after a newer one '
        'when translation latencies are inverted', () async {
      final input = _FakeInput();
      final stt = _FakeStt();
      final translator = _FakeTranslator()
        ..gates[10] = Completer<void>()
        ..gates[11] = Completer<void>();
      final tts = _FakeTts();
      final runtime = HorizonTranslationRuntime(
        input: input,
        stt: stt,
        translator: translator,
        synthesizer: tts,
      );
      final published = <int>[];
      final translationsSub =
          runtime.translations.listen((t) => published.add(t.sequence));
      final diagnostics = <LiveTranslationDiagnostic>[];
      final diagnosticsSub = runtime.diagnostics.listen(diagnostics.add);
      final config = _config();

      await runtime.start(config: config, audioSession: _audioSession());
      stt.transcriptController.add(
          _transcript(config.session, 10, TranscriptStability.finalResult));
      await _drain();
      stt.transcriptController.add(
          _transcript(config.session, 11, TranscriptStability.finalResult));
      await _drain();
      expect(translator.translated.map((s) => s.sequence), [10, 11]);

      translator.gates[11]!.complete();
      await _drain();
      expect(tts.spoken.map((segment) => segment.sequence), [11]);

      translator.gates[10]!.complete();
      await _drain();

      expect(tts.spoken.map((segment) => segment.sequence), [11]);
      expect(published, [11]);
      expect(
        diagnostics.any((event) =>
            event.code ==
                LiveTranslationDiagnosticCode.staleCallbackDiscarded &&
            event.sequence == 10),
        isTrue,
      );
      await translationsSub.cancel();
      await diagnosticsSub.cancel();
      await runtime.dispose();
    });

    test(
        'keeps both overlapping final turns in order when translations '
        'complete in order', () async {
      final input = _FakeInput();
      final stt = _FakeStt();
      final translator = _FakeTranslator()
        ..gates[20] = Completer<void>()
        ..gates[21] = Completer<void>();
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
          _transcript(config.session, 20, TranscriptStability.finalResult));
      await _drain();
      stt.transcriptController.add(
          _transcript(config.session, 21, TranscriptStability.finalResult));
      await _drain();

      translator.gates[20]!.complete();
      await _drain();
      translator.gates[21]!.complete();
      await _drain();

      expect(tts.spoken.map((segment) => segment.sequence), [20, 21]);
      await runtime.dispose();
    });
  });

  group('HorizonTranslationRuntime captions', () {
    test('captions a delivered final turn before speaking it', () async {
      final h = _CaptionHarness(_FakeCaptions());
      await h.start();

      h.addFinal(1);
      await _drain();

      expect(h.captions.visible, 'translated');
      expect(h.deliveries.single.status, CaptionDeliveryStatus.delivered);
      expect(h.deliveries.single.environment, ExecutionEnvironment.simulated);
      expect(h.tts.spoken.map((s) => s.sequence), [1]);
      expect(h.codes, contains(LiveTranslationDiagnosticCode.captionDelivered));
      await h.dispose();
    });

    test('never captions partial hypotheses', () async {
      final h = _CaptionHarness(_FakeCaptions());
      await h.start();

      h.stt.transcriptController.add(
          _transcript(h.config.session, 2, TranscriptStability.partial));
      await _drain();

      expect(h.captions.shown, isEmpty);
      expect(h.deliveries, isEmpty);
      await h.dispose();
    });

    test('reports a blocked display without stopping translation or speech',
        () async {
      final h = _CaptionHarness(
          _FakeCaptions(status: CaptionDeliveryStatus.blocked));
      await h.start();

      h.addFinal(3);
      await _drain();

      expect(h.deliveries.single.status, CaptionDeliveryStatus.blocked);
      expect(h.deliveries.single.truthLabel, TruthLabel.blocked);
      expect(h.captions.visible, isNull);
      expect(h.tts.spoken.map((s) => s.sequence), [3]);
      expect(h.runtime.state, HorizonTranslationRuntimeState.listening);
      expect(
        h.diagnostics.any((d) =>
            d.code == LiveTranslationDiagnosticCode.captionBlocked &&
            d.detail == 'capabilityUnavailable'),
        isTrue,
      );
      await h.dispose();
    });

    test('rejects an adapter that reports a stronger environment than declared',
        () async {
      final h = _CaptionHarness(
          _FakeCaptions(reportedEnvironment: ExecutionEnvironment.haloReal));
      await h.start();

      h.addFinal(4);
      await _drain();

      expect(h.deliveries.single.status, CaptionDeliveryStatus.failed);
      expect(h.deliveries.single.environment, ExecutionEnvironment.simulated);
      expect(h.deliveries.single.reason, 'environmentMismatch');
      await h.dispose();
    });

    test('keeps the session alive when the caption adapter throws', () async {
      final h = _CaptionHarness(_FakeCaptions(throwOnShow: true));
      await h.start();

      h.addFinal(5);
      await _drain();

      expect(h.deliveries.single.status, CaptionDeliveryStatus.failed);
      expect(h.deliveries.single.reason, 'adapterError');
      expect(h.tts.spoken.map((s) => s.sequence), [5]);
      expect(h.runtime.state, HorizonTranslationRuntimeState.listening);
      await h.dispose();
    });

    test('never captions an older turn whose translation completes late',
        () async {
      final h = _CaptionHarness(_FakeCaptions());
      h.translator
        ..gates[10] = Completer<void>()
        ..gates[11] = Completer<void>();
      await h.start();

      h.addFinal(10);
      await _drain();
      h.addFinal(11);
      await _drain();
      h.translator.gates[11]!.complete();
      await _drain();
      h.translator.gates[10]!.complete();
      await _drain();

      expect(h.captions.shown, [11]);
      expect(h.tts.spoken.map((s) => s.sequence), [11]);
      await h.dispose();
    });

    test('clears the display on stop and discards a caption that lands after',
        () async {
      final captions = _FakeCaptions()..gates[30] = Completer<void>();
      final h = _CaptionHarness(captions);
      await h.start();

      h.addFinal(30);
      await _drain();
      await h.runtime.stop();
      expect(captions.cleared, [h.config.session.sessionId]);

      captions.gates[30]!.complete();
      await _drain();

      expect(captions.visible, isNull);
      expect(captions.cleared, hasLength(2));
      expect(h.deliveries, isEmpty);
      expect(h.tts.spoken, isEmpty);
      expect(
        h.diagnostics.any((d) =>
            d.code == LiveTranslationDiagnosticCode.staleCallbackDiscarded &&
            d.component == 'caption'),
        isTrue,
      );
      await h.dispose();
    });

    test('clears the display when the session fails', () async {
      final h = _CaptionHarness(_FakeCaptions());
      h.stt.failPush = true;
      await h.start();

      h.input.framesController.add(_frame());
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(h.runtime.state, HorizonTranslationRuntimeState.failed);
      expect(h.captions.cleared, [h.config.session.sessionId]);
      await h.dispose();
    });
  });
}

Future<void> _drain() => Future<void>.delayed(Duration.zero);

final class _CaptionHarness {
  _CaptionHarness(this.captions) {
    runtime = HorizonTranslationRuntime(
      input: input,
      stt: stt,
      translator: translator,
      synthesizer: tts,
      captions: captions,
    );
    _subscriptions
      ..add(runtime.captionDeliveries.listen(deliveries.add))
      ..add(runtime.diagnostics.listen(diagnostics.add));
  }

  final _FakeCaptions captions;
  final input = _FakeInput();
  final stt = _FakeStt();
  final translator = _FakeTranslator();
  final tts = _FakeTts();
  final config = _config();
  late final HorizonTranslationRuntime runtime;
  final deliveries = <CaptionDelivery>[];
  final diagnostics = <LiveTranslationDiagnostic>[];
  final _subscriptions = <StreamSubscription<Object>>[];

  Iterable<LiveTranslationDiagnosticCode> get codes =>
      diagnostics.map((d) => d.code);

  Future<void> start() =>
      runtime.start(config: config, audioSession: _audioSession());

  void addFinal(int sequence) => stt.transcriptController.add(
      _transcript(config.session, sequence, TranscriptStability.finalResult));

  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await runtime.dispose();
  }
}

final class _FakeCaptions implements CaptionOutputAdapter {
  _FakeCaptions({
    this.status = CaptionDeliveryStatus.delivered,
    this.reportedEnvironment,
    this.throwOnShow = false,
  });

  final CaptionDeliveryStatus status;
  final ExecutionEnvironment? reportedEnvironment;
  final bool throwOnShow;
  final gates = <int, Completer<void>>{};
  final shown = <int>[];
  final cleared = <String>[];
  String? visible;

  @override
  String get adapterId => 'fake-captions';
  @override
  ExecutionEnvironment get environment => ExecutionEnvironment.simulated;

  @override
  Future<CaptionDelivery> show(CaptionUpdate update) async {
    await gates[update.sequence]?.future;
    if (throwOnShow) {
      throw StateError('simulated display failure');
    }
    shown.add(update.sequence);
    final delivered = status == CaptionDeliveryStatus.delivered;
    if (delivered) {
      visible = update.text;
    }
    return CaptionDelivery(
      session: update.session,
      sequence: update.sequence,
      status: status,
      environment: reportedEnvironment ?? environment,
      truthLabel: delivered ? TruthLabel.simulated : TruthLabel.blocked,
      adapterId: adapterId,
      reason: delivered ? null : 'capabilityUnavailable',
    );
  }

  @override
  Future<void> clear(TranslationSession session) async {
    cleared.add(session.sessionId);
    visible = null;
  }
}

LiveTranslationConfig _config({bool localProcessingAllowed = true}) =>
    LiveTranslationConfig(
      session: const TranslationSession(
        sessionId: 'session-a',
        streamEpoch: 7,
        direction: TranslationDirection.englishToSpanish,
        privacyGeneration: 1,
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
  int stopCalls = 0;

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
  Future<void> stop() async {
    stopCalls += 1;
  }

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
  int stopCalls = 0;
  bool failPush = false;

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
  Future<void> push(AudioFrame frame) async {
    pushedFrames += 1;
    if (failPush) {
      throw StateError('simulated STT failure');
    }
  }

  @override
  Future<void> stop() async {
    stopCalls += 1;
  }

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
  final gates = <int, Completer<void>>{};
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
    await gates[finalTranscript.sequence]?.future;
    return TranslationSegment(
      session: finalTranscript.session,
      sequence: finalTranscript.sequence,
      sourceText: finalTranscript.text,
      translatedText: 'translated',
      observedAtMicros: 1,
      truthLabel: TruthLabel.simulated,
    );
  }

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
  }

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
