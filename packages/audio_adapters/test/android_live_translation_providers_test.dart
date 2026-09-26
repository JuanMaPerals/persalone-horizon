import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:persalone_audio_adapters/persalone_audio_adapters.dart';
import 'package:persalone_contracts/persalone_contracts.dart';

void main() {
  group('AndroidSpeechRecognizerProvider', () {
    test('blocks explicitly when Android reports recognition unavailable',
        () async {
      final bridge = _FakeLiveTranslationBridge(sttReady: false);
      final provider = AndroidSpeechRecognizerProvider(bridge: bridge);
      addTearDown(provider.dispose);

      await expectLater(
        provider.prepare(_config(), AudioFormat.voice16kMono),
        throwsA(
          isA<RuntimeError>().having(
            (error) => error.code,
            'code',
            RuntimeErrorCode.recognitionUnavailable,
          ),
        ),
      );
    });

    test(
        'maps a current partial platform event without exposing it in diagnostics',
        () async {
      final bridge = _FakeLiveTranslationBridge();
      final provider = AndroidSpeechRecognizerProvider(bridge: bridge);
      addTearDown(provider.dispose);
      final config = _config();

      await provider.prepare(config, AudioFormat.voice16kMono);
      final transcript = provider.transcripts.first;
      bridge.sttController.add(<Object?, Object?>{
        'type': 'partial',
        'sessionId': config.session.sessionId,
        'streamEpoch': config.session.streamEpoch,
        'sequence': 3,
        'text': 'private test text',
        'observedAtMicros': 10,
      });

      final segment = await transcript;
      expect(segment.sequence, 3);
      expect(segment.stability, TranscriptStability.partial);
      expect(segment.truthLabel, TruthLabel.prepared);
    });

    test('rejects a frame from another active epoch', () async {
      final bridge = _FakeLiveTranslationBridge();
      final provider = AndroidSpeechRecognizerProvider(bridge: bridge);
      addTearDown(provider.dispose);
      await provider.prepare(_config(), AudioFormat.voice16kMono);

      await expectLater(
        provider.push(_frame(streamEpoch: 8)),
        throwsA(
          isA<RuntimeError>().having(
            (error) => error.code,
            'code',
            RuntimeErrorCode.staleStreamEpoch,
          ),
        ),
      );
      expect(bridge.pushedPcm, isEmpty);
    });

    test('attaches the platform end of speech to the next final result',
        () async {
      final bridge = _FakeLiveTranslationBridge();
      final provider = AndroidSpeechRecognizerProvider(bridge: bridge);
      addTearDown(provider.dispose);
      final config = _config();
      await provider.prepare(config, AudioFormat.voice16kMono);
      final codes = <LiveTranslationDiagnosticCode>[];
      provider.diagnostics.listen((d) => codes.add(d.code));
      final segments = <TranscriptSegment>[];
      provider.transcripts.listen(segments.add);
      Map<Object?, Object?> event(String type, int at, {int? sequence}) =>
          <Object?, Object?>{
            'type': type,
            'sessionId': config.session.sessionId,
            'streamEpoch': config.session.streamEpoch,
            'observedAtMicros': at,
            if (sequence != null) 'sequence': sequence,
            if (sequence != null) 'text': 'private test text',
          };

      bridge.sttController
        ..add(event('speechStarted', 100))
        ..add(event('speechEnded', 800))
        ..add(event('partial', 850, sequence: 1))
        ..add(event('final', 1300, sequence: 2))
        ..add(event('final', 2000, sequence: 3));
      await Future<void>.delayed(Duration.zero);

      expect(segments.map((s) => s.speechEndedAtMicros),
          <int?>[null, 800, null],
          reason: 'partials never carry it; it is used by one final only');
      expect(codes, containsAllInOrder(<LiveTranslationDiagnosticCode>[
        LiveTranslationDiagnosticCode.speechStarted,
        LiveTranslationDiagnosticCode.speechEnded,
      ]));
    });

    test('a new utterance discards an older end of speech', () async {
      final bridge = _FakeLiveTranslationBridge();
      final provider = AndroidSpeechRecognizerProvider(bridge: bridge);
      addTearDown(provider.dispose);
      final config = _config();
      await provider.prepare(config, AudioFormat.voice16kMono);
      final segment = provider.transcripts.first;
      for (final e in <Map<Object?, Object?>>[
        {'type': 'speechEnded', 'observedAtMicros': 500},
        {'type': 'speechStarted', 'observedAtMicros': 900},
        {'type': 'final', 'observedAtMicros': 1500, 'sequence': 1, 'text': 'x'},
      ]) {
        bridge.sttController.add(<Object?, Object?>{
          ...e,
          'sessionId': config.session.sessionId,
          'streamEpoch': config.session.streamEpoch,
        });
      }
      expect((await segment).speechEndedAtMicros, isNull);
    });

    test('speech boundaries from another epoch are discarded', () async {
      final bridge = _FakeLiveTranslationBridge();
      final provider = AndroidSpeechRecognizerProvider(bridge: bridge);
      addTearDown(provider.dispose);
      final config = _config();
      await provider.prepare(config, AudioFormat.voice16kMono);
      final segment = provider.transcripts.first;
      bridge.sttController
        ..add(<Object?, Object?>{
          'type': 'speechEnded',
          'sessionId': config.session.sessionId,
          'streamEpoch': config.session.streamEpoch + 1,
          'observedAtMicros': 700,
        })
        ..add(<Object?, Object?>{
          'type': 'final',
          'sessionId': config.session.sessionId,
          'streamEpoch': config.session.streamEpoch,
          'observedAtMicros': 1500,
          'sequence': 1,
          'text': 'x',
        });
      expect((await segment).speechEndedAtMicros, isNull);
    });
  });

  group('MlKitOnDeviceTranslatorProvider', () {
    test('fails closed when the model is not prepared or downloadable',
        () async {
      final bridge = _FakeLiveTranslationBridge(modelReady: false);
      final provider = MlKitOnDeviceTranslatorProvider(bridge: bridge);
      addTearDown(provider.dispose);

      await expectLater(
        provider.prepare(_config(modelDownloadAllowed: false)),
        throwsA(
          isA<RuntimeError>().having(
            (error) => error.code,
            'code',
            RuntimeErrorCode.translationModelUnavailable,
          ),
        ),
      );
      expect(bridge.lastAllowModelDownload, isFalse);
    });

    test('translates only a final segment for the current session', () async {
      final bridge =
          _FakeLiveTranslationBridge(translatedText: 'traducción privada');
      final provider = MlKitOnDeviceTranslatorProvider(bridge: bridge);
      addTearDown(provider.dispose);
      final config = _config();
      await provider.prepare(config);

      final result = await provider.translate(_finalTranscript(config.session));
      expect(result.translatedText, 'traducción privada');
      expect(result.truthLabel, TruthLabel.prepared);
    });
  });

  group('AndroidTextToSpeechProvider', () {
    test('blocks when Android cannot prepare a target locale voice', () async {
      final bridge = _FakeLiveTranslationBridge(ttsReady: false);
      final provider = AndroidTextToSpeechProvider(bridge: bridge);
      addTearDown(provider.dispose);

      await expectLater(
        provider.prepare(_config()),
        throwsA(
          isA<RuntimeError>().having(
            (error) => error.code,
            'code',
            RuntimeErrorCode.speechSynthesisUnavailable,
          ),
        ),
      );
    });

    test('queues synthesis with a session-scoped utterance id', () async {
      final bridge = _FakeLiveTranslationBridge();
      final provider = AndroidTextToSpeechProvider(bridge: bridge);
      addTearDown(provider.dispose);
      final config = _config();
      await provider.prepare(config);

      await provider.speak(
        TranslationSegment(
          session: config.session,
          sequence: 9,
          sourceText: 'private source',
          translatedText: 'private target',
          observedAtMicros: 1,
          truthLabel: TruthLabel.simulated,
        ),
      );
      expect(bridge.lastUtteranceId, '7-9');
      expect(bridge.lastSequence, 9);
    });

    TranslationSegment segment(TranslationSession session, int sequence) =>
        TranslationSegment(
          session: session,
          sequence: sequence,
          sourceText: 'private source',
          translatedText: 'private target',
          observedAtMicros: 1,
          truthLabel: TruthLabel.simulated,
        );

    test('declares the Android monotonic clock shared with the recognizer',
        () {
      final bridge = _FakeLiveTranslationBridge();
      final tts = AndroidTextToSpeechProvider(bridge: bridge);
      final stt = AndroidSpeechRecognizerProvider(bridge: bridge);
      addTearDown(tts.dispose);
      addTearDown(stt.dispose);
      expect(tts.monotonicClockDomain, 'android.clock_monotonic');
      expect(tts.monotonicClockDomain, stt.monotonicClockDomain);
    });

    test('reports the selected output path from prepare', () async {
      final measured = AndroidTextToSpeechProvider(
          bridge: _FakeLiveTranslationBridge());
      final engine = AndroidTextToSpeechProvider(
          bridge: _FakeLiveTranslationBridge(measuredOutput: false));
      addTearDown(measured.dispose);
      addTearDown(engine.dispose);
      await measured.prepare(_config());
      await engine.prepare(_config());
      expect(measured.measuredOutput, isTrue);
      expect(engine.measuredOutput, isFalse);
      expect(engine.outputReason, 'noStreamedAudio');
    });

    test('maps a native presentation to the spoken segment, without text',
        () async {
      final bridge = _FakeLiveTranslationBridge();
      final provider = AndroidTextToSpeechProvider(bridge: bridge);
      addTearDown(provider.dispose);
      final config = _config();
      await provider.prepare(config);
      final reports = <SpeechPresentation>[];
      provider.presentations.listen(reports.add);

      await provider.speak(segment(config.session, 9));
      bridge.ttsController.add(<Object?, Object?>{
        'type': 'presented',
        'utteranceId': '7-9',
        'queuedAtMicros': 1000,
        'firstFramePresentedAtMicros': 1200,
        'audiblePresentedAtMicros': 1350,
        'sampleRateHz': 24000,
      });
      // A second report for the same utterance is ignored.
      bridge.ttsController.add(<Object?, Object?>{
        'type': 'presented',
        'utteranceId': '7-9',
        'queuedAtMicros': 1000,
        'firstFramePresentedAtMicros': 1200,
      });
      await pumpEventQueue();

      expect(reports, hasLength(1));
      final report = reports.single;
      expect(report.status, SpeechPresentationStatus.presented);
      expect(report.sequence, 9);
      expect(report.session.streamEpoch, 7);
      expect(report.queuedAtMicros, 1000);
      expect(report.firstFramePresentedAtMicros, 1200);
      expect(report.audiblePresentedAtMicros, 1350);
    });

    test('an all-silent utterance is presented without an audible time',
        () async {
      final bridge = _FakeLiveTranslationBridge();
      final provider = AndroidTextToSpeechProvider(bridge: bridge);
      addTearDown(provider.dispose);
      final config = _config();
      await provider.prepare(config);
      final reports = <SpeechPresentation>[];
      provider.presentations.listen(reports.add);

      await provider.speak(segment(config.session, 2));
      bridge.ttsController.add(<Object?, Object?>{
        'type': 'presented',
        'utteranceId': '7-2',
        'queuedAtMicros': 1000,
        'firstFramePresentedAtMicros': 1200,
      });
      await pumpEventQueue();
      expect(reports.single.status, SpeechPresentationStatus.presented);
      expect(reports.single.audiblePresentedAtMicros, isNull);
    });

    test('refuses non-causal or non-integer times instead of repairing them',
        () async {
      final bridge = _FakeLiveTranslationBridge();
      final provider = AndroidTextToSpeechProvider(bridge: bridge);
      addTearDown(provider.dispose);
      final config = _config();
      await provider.prepare(config);
      final reports = <SpeechPresentation>[];
      provider.presentations.listen(reports.add);

      final List<Map<Object?, Object?>> hostile = <Map<Object?, Object?>>[
        {'firstFramePresentedAtMicros': 900, 'queuedAtMicros': 1000},
        {
          'queuedAtMicros': 1000,
          'firstFramePresentedAtMicros': 1200,
          'audiblePresentedAtMicros': 1100,
        },
        {'queuedAtMicros': 1000.5, 'firstFramePresentedAtMicros': 1200},
        {'queuedAtMicros': 1000},
      ];
      for (int i = 0; i < hostile.length; i++) {
        await provider.speak(segment(config.session, 20 + i));
        bridge.ttsController.add(<Object?, Object?>{
          'type': 'presented',
          'utteranceId': '7-${20 + i}',
          ...hostile[i],
        });
      }
      await pumpEventQueue();

      expect(reports, hasLength(hostile.length));
      for (final report in reports) {
        expect(report.status, SpeechPresentationStatus.unavailable);
        expect(report.reason, 'malformedPresentation');
        expect(report.queuedAtMicros, isNull);
      }
    });

    test('engine playback and stops are reported unavailable with a code',
        () async {
      final bridge = _FakeLiveTranslationBridge(measuredOutput: false);
      final provider = AndroidTextToSpeechProvider(bridge: bridge);
      addTearDown(provider.dispose);
      final config = _config();
      await provider.prepare(config);
      final reports = <SpeechPresentation>[];
      provider.presentations.listen(reports.add);

      await provider.speak(segment(config.session, 3));
      bridge.ttsController.add(<Object?, Object?>{
        'type': 'presentation_unavailable',
        'utteranceId': '7-3',
        'reason': 'enginePlayback',
      });
      await provider.speak(segment(config.session, 4));
      bridge.ttsController.add(<Object?, Object?>{
        'type': 'presentation_unavailable',
        'utteranceId': '7-4',
        'reason': 'free text is not a code',
      });
      // Unknown utterances produce nothing.
      bridge.ttsController.add(<Object?, Object?>{
        'type': 'presentation_unavailable',
        'utteranceId': '7-99',
        'reason': 'stopped',
      });
      await pumpEventQueue();

      expect(reports.map((r) => r.reason),
          <String>['enginePlayback', 'unspecified']);
      expect(reports.map((r) => r.status),
          everyElement(SpeechPresentationStatus.unavailable));
    });

    test('completion carries the sequence echoed by the platform', () async {
      final bridge = _FakeLiveTranslationBridge();
      final provider = AndroidTextToSpeechProvider(bridge: bridge);
      addTearDown(provider.dispose);
      await provider.prepare(_config());
      final diagnostics = <LiveTranslationDiagnostic>[];
      provider.diagnostics.listen(diagnostics.add);

      bridge.ttsController.add(<Object?, Object?>{
        'type': 'completed',
        'utteranceId': '7-5',
        'sequence': 5,
      });
      await pumpEventQueue();
      final completed = diagnostics.where((d) =>
          d.code == LiveTranslationDiagnosticCode.synthesisCompleted);
      expect(completed.single.sequence, 5);
    });
  });
}

LiveTranslationConfig _config({bool modelDownloadAllowed = true}) =>
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
        localProcessingAllowed: true,
        modelDownloadAllowed: modelDownloadAllowed,
        remoteProcessingAllowed: false,
      ),
    );

AudioFrame _frame({required int streamEpoch}) => AudioFrame(
      schemaVersion: 'v1',
      session: AudioSessionDescriptor(
        sessionId: 'session-a',
        streamEpoch: streamEpoch,
        streamId: 'input-a',
      ),
      direction: AudioDirection.input,
      sequence: 1,
      codec: AudioCodec.pcmS16le,
      format: AudioFormat.voice16kMono,
      capturedAtMicros: 1,
      receivedAtMicros: 1,
      durationMicros: 20_000,
      payload: Uint8List(320),
    );

TranscriptSegment _finalTranscript(TranslationSession session) =>
    TranscriptSegment(
      session: session,
      sequence: 1,
      text: 'private test text',
      stability: TranscriptStability.finalResult,
      observedAtMicros: 1,
      truthLabel: TruthLabel.simulated,
    );

final class _FakeLiveTranslationBridge implements AndroidLiveTranslationBridge {
  _FakeLiveTranslationBridge({
    this.sttReady = true,
    this.modelReady = true,
    this.ttsReady = true,
    this.measuredOutput = true,
    this.translatedText = 'translated',
  });

  final bool sttReady;
  final bool modelReady;
  final bool ttsReady;
  final bool measuredOutput;
  final String translatedText;
  final sttController = StreamController<Map<Object?, Object?>>.broadcast();
  final ttsController = StreamController<Map<Object?, Object?>>.broadcast();
  final pushedPcm = <Uint8List>[];
  bool? lastAllowModelDownload;
  String? lastUtteranceId;
  int? lastSequence;

  @override
  Stream<Map<Object?, Object?>> get sttEvents => sttController.stream;
  @override
  Stream<Map<Object?, Object?>> get ttsEvents => ttsController.stream;
  @override
  Future<Map<Object?, Object?>> prepareStt({
    required String sessionId,
    required int streamEpoch,
    required String locale,
    required int sampleRateHz,
    required int channels,
  }) async =>
      <Object?, Object?>{'ready': sttReady};
  @override
  Future<void> pushSttPcm(Uint8List pcm) async {
    pushedPcm.add(pcm);
  }

  @override
  Future<void> stopStt() async {}
  @override
  Future<Map<Object?, Object?>> prepareTranslation({
    required String sourceLocale,
    required String targetLocale,
    required bool allowModelDownload,
  }) async {
    lastAllowModelDownload = allowModelDownload;
    return <Object?, Object?>{'modelReady': modelReady};
  }

  @override
  Future<Map<Object?, Object?>> translate({
    required String sourceText,
    required String sourceLocale,
    required String targetLocale,
  }) async =>
      <Object?, Object?>{'translatedText': translatedText};
  @override
  Future<void> disposeTranslation() async {}
  @override
  Future<Map<Object?, Object?>> prepareTts({required String locale}) async =>
      <Object?, Object?>{
        'ready': ttsReady,
        'measuredOutput': measuredOutput,
        'outputReason': measuredOutput ? 'streamedAudio' : 'noStreamedAudio',
      };
  @override
  Future<void> speak({
    required String text,
    required String utteranceId,
    required int sequence,
  }) async {
    lastUtteranceId = utteranceId;
    lastSequence = sequence;
  }

  @override
  Future<void> stopTts() async {}
}
