import 'package:persalone_contracts/persalone_contracts.dart';
import 'package:test/test.dart';

void main() {
  group('CapabilityManifest', () {
    test('blocks undeclared capabilities by default', () {
      const CapabilityManifest manifest = CapabilityManifest(
        schemaVersion: CapabilityManifest.currentSchemaVersion,
        adapterId: 'fixture',
        states: <Capability, CapabilityState>{},
      );

      final CapabilityState state =
          manifest.stateFor(Capability.microphoneCapture);

      expect(state.truthLabel, TruthLabel.blocked);
      expect(state.isUsable, isFalse);
    });
  });

  group('TranslationExecutionToken and utterance codec', () {
    const token = TranslationExecutionToken(
      sessionId: 'session-1',
      streamEpoch: 2,
      privacyGeneration: 3,
      turnGeneration: 4,
    );

    test('round-trips an opaque utterance identity without content', () {
      final encoded = OpaqueUtteranceIdentityCodec.encode(
        token: token,
        nonce: 99,
      );
      final decoded = OpaqueUtteranceIdentityCodec.decode(encoded);

      expect(decoded.matchesToken(token), isTrue);
      expect(decoded.nonce, 99);
      expect(encoded, isNot(contains('session-1')));
    });

    test('rejects malformed utterance identity fail-closed', () {
      expect(
        () => OpaqueUtteranceIdentityCodec.decode('invalid'),
        throwsA(
          isA<RuntimeError>().having(
            (RuntimeError error) => error.code,
            'code',
            RuntimeErrorCode.invalidContract,
          ),
        ),
      );
    });

    test('keeps transcript sequence distinct from turn generation', () {
      const session = TranslationSession(
        sessionId: 'session-1',
        streamEpoch: 2,
        direction: TranslationDirection.englishToSpanish,
        privacyGeneration: 3,
        turnGeneration: 4,
      );
      final encoded = OpaqueUtteranceIdentityCodec.encode(
        token: session.executionToken,
        nonce: 500,
      );
      final decoded = OpaqueUtteranceIdentityCodec.decode(encoded);

      expect(decoded.turnGeneration, 4);
      expect(decoded.nonce, 500);
    });
  });

  group('TranslationSession', () {
    test('rejects a frame from an older stream epoch', () {
      const TranslationSession session = TranslationSession(
        sessionId: 'session-1',
        streamEpoch: 2,
        direction: TranslationDirection.englishToSpanish,
        privacyGeneration: 1,
      );
      const AudioFrameMetadata frame = AudioFrameMetadata(
        sessionId: 'session-1',
        streamId: 'capture',
        streamEpoch: 1,
        sequence: 7,
        capturedAtMicros: 1,
        sampleRateHz: 16000,
        channels: 1,
        durationMicros: 20000,
        codec: 'pcm_s16le',
      );

      expect(
        () => session.validateFrame(frame),
        throwsA(
          isA<RuntimeError>().having(
            (RuntimeError error) => error.code,
            'code',
            RuntimeErrorCode.staleStreamEpoch,
          ),
        ),
      );
    });
  });
}
