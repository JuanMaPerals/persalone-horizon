import 'dart:async';
import 'dart:typed_data';

import 'package:persalone_audio_adapters/persalone_audio_adapters.dart';
import 'package:persalone_contracts/persalone_contracts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const AudioSessionDescriptor session = AudioSessionDescriptor(
    sessionId: 'test-session',
    streamEpoch: 1,
    streamId: 'input-1',
  );

  group('AndroidMicrophoneAdapter', () {
    test('requires runtime microphone permission before capture', () async {
      final _FakeBridge bridge = _FakeBridge(permissionGranted: false);
      final AndroidMicrophoneAdapter adapter = AndroidMicrophoneAdapter(
        bridge: bridge,
        nowMicros: () => 100,
      );
      addTearDown(adapter.dispose);

      expect(await adapter.requestPermission(), isFalse);
      expect(
        adapter.start(session, AudioFormat.voice16kMono),
        throwsA(
          isA<RuntimeError>().having(
            (RuntimeError error) => error.code,
            'code',
            RuntimeErrorCode.consentRequired,
          ),
        ),
      );
    });

    test('maps real-channel PCM events to canonical input frames', () async {
      final _FakeBridge bridge = _FakeBridge(permissionGranted: true);
      final AndroidMicrophoneAdapter adapter = AndroidMicrophoneAdapter(
        bridge: bridge,
        nowMicros: () => 200,
      );
      addTearDown(adapter.dispose);

      expect(await adapter.requestPermission(), isTrue);
      await adapter.start(session, AudioFormat.voice16kMono);
      final Future<AudioFrame> frameFuture = adapter.frames.first;
      bridge.emitInput(<Object?, Object?>{
        'type': 'frame',
        'pcm': Uint8List.fromList(<int>[0, 0, 1, 0]),
        'sequence': 4,
        'capturedAtMicros': 150,
        'durationMicros': 125,
        'discontinuity': false,
      });

      final AudioFrame frame = await frameFuture;
      expect(frame.direction, AudioDirection.input);
      expect(frame.sequence, 4);
      expect(frame.codec, AudioCodec.pcmS16le);
      expect(frame.payload, Uint8List.fromList(<int>[0, 0, 1, 0]));
      expect(frame.capturedAtMicros, 150);
      expect(bridge.startedInput, isTrue);
    });

    test('exposes dropped-frame diagnostics without carrying PCM', () async {
      final _FakeBridge bridge = _FakeBridge(permissionGranted: true);
      final AndroidMicrophoneAdapter adapter = AndroidMicrophoneAdapter(
        bridge: bridge,
        nowMicros: () => 300,
      );
      addTearDown(adapter.dispose);

      await adapter.requestPermission();
      await adapter.start(session, AudioFormat.voice16kMono);
      final Future<AudioDiagnostic> diagnostic = adapter.diagnostics
          .where((AudioDiagnostic event) =>
              event.code == AudioDiagnosticCode.inputDropped)
          .first;
      bridge.emitInput(<Object?, Object?>{
        'type': 'input_drop',
        'sequence': 6,
        'droppedFrames': 2,
      });

      expect((await diagnostic).value, 2);
    });

    test('platform capture_started reports the A/B source, not an error',
        () async {
      final _FakeBridge bridge = _FakeBridge(permissionGranted: true);
      final AndroidMicrophoneAdapter adapter = AndroidMicrophoneAdapter(
        bridge: bridge,
        nowMicros: () => 400,
      );
      addTearDown(adapter.dispose);
      final List<AudioDiagnostic> diagnostics = <AudioDiagnostic>[];
      adapter.diagnostics.listen(diagnostics.add);
      await adapter.requestPermission();
      await adapter.start(session, AudioFormat.voice16kMono);
      final Future<AndroidCaptureConfig> reported = adapter.captureConfigs.first;
      bridge
        ..emitInput(<Object?, Object?>{
          'type': 'capture_started',
          'audioSource': 'voiceCommunication',
          'aecAvailable': true,
          'aecEnabled': true,
          'nsAvailable': false,
          'sampleRateHz': 16000,
        })
        ..emitInput(<Object?, Object?>{'type': 'capture_stopped'});

      final AndroidCaptureConfig config = await reported;
      expect(config.audioSource, 'voiceCommunication');
      expect(config.echoCancelerEnabled, isTrue);
      expect(adapter.captureConfig?.toJson(), <String, Object>{
        'audioSource': 'voiceCommunication',
        'aecAvailable': true,
        'aecEnabled': true,
        'nsAvailable': false,
      });
      await Future<void>.delayed(Duration.zero);
      expect(
        diagnostics.where(
            (d) => d.code == AudioDiagnosticCode.captureReadError),
        isEmpty,
        reason: 'capture_started/stopped were misreported as read errors',
      );
    });

    test('an unknown source label is recorded as unknown, never guessed', () {
      final AndroidCaptureConfig config = AndroidCaptureConfig.fromEvent(
          <Object?, Object?>{'type': 'capture_started', 'audioSource': 'raw'});
      expect(config.audioSource, 'unknown');
      expect(config.echoCancelerEnabled, isFalse);
    });
  });
}

final class _FakeBridge implements AndroidHostAudioBridge {
  _FakeBridge({required this.permissionGranted});

  final bool permissionGranted;
  final StreamController<Map<Object?, Object?>> _input =
      StreamController<Map<Object?, Object?>>.broadcast();
  final StreamController<Map<Object?, Object?>> _output =
      StreamController<Map<Object?, Object?>>.broadcast();
  bool startedInput = false;

  @override
  Stream<Map<Object?, Object?>> get inputEvents => _input.stream;

  @override
  Stream<Map<Object?, Object?>> get outputEvents => _output.stream;

  @override
  Future<bool> requestMicrophonePermission() async => permissionGranted;

  @override
  Future<void> startInput(AudioFormat format) async {
    startedInput = true;
  }

  @override
  Future<void> stopInput() async {
    startedInput = false;
  }

  @override
  Future<void> startOutput(AudioFormat format) async {}

  @override
  Future<void> stopOutput() async {}

  @override
  Future<Map<Object?, Object?>> writeOutput(
    Uint8List pcm, {
    required int capturedAtMicros,
    required int durationMicros,
  }) async {
    return const <Object?, Object?>{};
  }

  void emitInput(Map<Object?, Object?> event) {
    _input.add(event);
  }
}
