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

      final CapabilityState state = manifest.stateFor(Capability.microphoneCapture);

      expect(state.truthLabel, TruthLabel.blocked);
      expect(state.isUsable, isFalse);
    });
  });


  group('CapabilityObservation', () {
    test('active PREPARED capability is not usable', () {
      const CapabilityObservation observation = CapabilityObservation(
        capability: Capability.microphoneCapture,
        activation: CapabilityActivation.active,
        truthLabel: TruthLabel.prepared,
        sourceRevision: 'dreamlayer-v0.9.2-adaptation',
      );

      expect(observation.isOperational, isTrue);
      expect(observation.isUsable, isFalse);
    });

    test('MEASURED dormant capability is not usable', () {
      const CapabilityObservation observation = CapabilityObservation(
        capability: Capability.microphoneCapture,
        activation: CapabilityActivation.dormant,
        truthLabel: TruthLabel.measured,
        sourceRevision: 'fixture',
      );

      expect(observation.isOperational, isFalse);
      expect(observation.isUsable, isFalse);
    });

    test('only active MEASURED capability is usable', () {
      const CapabilityObservation observation = CapabilityObservation(
        capability: Capability.microphoneCapture,
        activation: CapabilityActivation.active,
        truthLabel: TruthLabel.measured,
        sourceRevision: 'fixture',
      );

      expect(observation.isUsable, isTrue);
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
