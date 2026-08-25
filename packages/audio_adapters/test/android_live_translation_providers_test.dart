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
        'turnGeneration': config.session.turnGeneration,
        'sequence': 3,
        'text': 'private test text',
        'observedAtMicros': 10,
      });

      final segment = await transcript;
      expect(segment.sequence, 3);
      expect(segment.stability, TranscriptStability.partial);
      expect(segment.truthLabel, TruthLabel.prepared);
    });

    test('discards a stale-generation platform event without transcript text',
        () async {
      final bridge = _FakeLiveTranslationBridge();
      final provider = AndroidSpeechRecognizerProvider(bridge: bridge);
      addTearDown(provider.dispose);
      final transcripts = <TranscriptSegment>[];
      final diagnostics = <LiveTranslationDiagnostic>[];
      final transcriptSubscription =
          provider.transcripts.listen(transcripts.add);
      final diagnosticSubscription =
          provider.diagnostics.listen(diagnostics.add);
      addTearDown(transcriptSubscription.cancel);
      addTearDown(diagnosticSubscription.cancel);
      final config = _config();
      await provider.prepare(config, AudioFormat.voice16kMono);

      bridge.sttController.add(<Object?, Object?>{
        'type': 'final',
        'sessionId': config.session.sessionId,
        'streamEpoch': config.session.streamEpoch,
        'turnGeneration': config.session.turnGeneration + 1,
        'sequence': 4,
        'text': 'private stale text',
        'observedAtMicros': 10,
      });
      await Future<void>.delayed(Duration.zero);

      expect(transcripts, isEmpty);
      expect(
        diagnostics.any(
          (event) =>
              event.code ==
                  LiveTranslationDiagnosticCode.staleCallbackDiscarded &&
              event.detail == null,
        ),
        isTrue,
      );
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

    test('queues synthesis with an opaque execution-token utterance id',
        () async {
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
      final identity = OpaqueUtteranceIdentityCodec.decode(
        bridge.lastUtteranceId!,
      );
      expect(identity.matchesToken(config.session.executionToken), isTrue);
      expect(identity.nonce, 9);
      expect(bridge.lastUtteranceId, isNot(contains('private source')));
      expect(bridge.lastUtteranceId, isNot(contains('private target')));
    });

    test('discards malformed and stale Android utterance callbacks', () async {
      final bridge = _FakeLiveTranslationBridge();
      final provider = AndroidTextToSpeechProvider(bridge: bridge);
      addTearDown(provider.dispose);
      final diagnostics = <LiveTranslationDiagnostic>[];
      final subscription = provider.diagnostics.listen(diagnostics.add);
      addTearDown(subscription.cancel);
      final config = _config();
      await provider.prepare(config);
      final segment = TranslationSegment(
        session: config.session,
        sequence: 9,
        sourceText: 'private source',
        translatedText: 'private target',
        observedAtMicros: 1,
        truthLabel: TruthLabel.simulated,
      );
      await provider.speak(segment);

      bridge.ttsController.add(<Object?, Object?>{
        'type': 'completed',
        'utteranceId': 'not-a-valid-identity',
      });
      final wrongGeneration = OpaqueUtteranceIdentityCodec.encode(
        token: const TranslationExecutionToken(
          sessionId: 'session-a',
          streamEpoch: 7,
          privacyGeneration: 1,
          turnGeneration: 99,
        ),
        nonce: 9,
      );
      bridge.ttsController.add(<Object?, Object?>{
        'type': 'completed',
        'utteranceId': wrongGeneration,
      });
      await Future<void>.delayed(Duration.zero);

      expect(
        diagnostics.where(
          (event) =>
              event.code ==
              LiveTranslationDiagnosticCode.staleCallbackDiscarded,
        ),
        hasLength(2),
      );
      expect(
        diagnostics.any(
          (event) =>
              event.code == LiveTranslationDiagnosticCode.synthesisCompleted,
        ),
        isFalse,
      );
      expect(diagnostics.every((event) => event.detail == null), isTrue);
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
    this.translatedText = 'translated',
  });

  final bool sttReady;
  final bool modelReady;
  final bool ttsReady;
  final String translatedText;
  final sttController = StreamController<Map<Object?, Object?>>.broadcast();
  final ttsController = StreamController<Map<Object?, Object?>>.broadcast();
  final pushedPcm = <Uint8List>[];
  bool? lastAllowModelDownload;
  String? lastUtteranceId;

  @override
  Stream<Map<Object?, Object?>> get sttEvents => sttController.stream;
  @override
  Stream<Map<Object?, Object?>> get ttsEvents => ttsController.stream;
  @override
  Future<Map<Object?, Object?>> prepareStt({
    required String sessionId,
    required int streamEpoch,
    required int turnGeneration,
    required String locale,
    required int sampleRateHz,
    required int channels,
  }) async =>
      <Object?, Object?>{'ready': sttReady};
  @override
  Future<void> beginSttTurn({required int turnGeneration}) async {}

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
      <Object?, Object?>{'ready': ttsReady};
  @override
  Future<void> speak(
      {required String text, required String utteranceId}) async {
    lastUtteranceId = utteranceId;
  }

  @override
  Future<void> stopTts() async {}
}
