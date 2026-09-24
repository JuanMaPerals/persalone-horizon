import 'dart:async';

import 'package:persalone_contracts/persalone_contracts.dart';

/// Shared fail-closed base for future Halo audio adapters. It proves contract
/// compatibility without claiming that Halo microphone or speaker paths work.
abstract base class _PreparedHaloAudioAdapter {
  _PreparedHaloAudioAdapter({required this.adapterId});

  static const String revision =
      'halo-firmware@78bb15368f78ffe94b1b77b5f592ebe7a3f001a3;'
      'brilliant_sdk@462dff4795cffb85248ab1d2f92d4f319adb03d3';
  static final Stopwatch _clock = Stopwatch()..start();

  final String adapterId;
  final StreamController<AudioAdapterSnapshot> snapshotController =
      StreamController<AudioAdapterSnapshot>.broadcast();
  final StreamController<AudioDiagnostic> diagnosticController =
      StreamController<AudioDiagnostic>.broadcast();
  final StreamController<AudioLatencyMeasurement> latencyController =
      StreamController<AudioLatencyMeasurement>.broadcast();
  bool disposed = false;

  void blocked(String reason) {
    diagnosticController.add(
      AudioDiagnostic(
        code: AudioDiagnosticCode.capabilityBlocked,
        adapterId: adapterId,
        observedAtMicros: _clock.elapsedMicroseconds,
        detail: reason,
      ),
    );
    snapshotController.add(
      AudioAdapterSnapshot(
        state: AudioAdapterState.failed,
        adapterId: adapterId,
        sourceRevision: revision,
        truthLabel: TruthLabel.prepared,
        observedAtMicros: _clock.elapsedMicroseconds,
        failureReason: reason,
      ),
    );
  }

  Future<void> close() async {
    if (disposed) {
      return;
    }
    disposed = true;
    await snapshotController.close();
    await diagnosticController.close();
    await latencyController.close();
  }

  Never unsupported(String operation) {
    const String reason =
        'Halo physical audio validation is required before this operation.';
    blocked(reason);
    throw RuntimeError(RuntimeErrorCode.capabilityUnavailable, operation);
  }
}

/// Contract-compatible placeholder for the physical Halo microphone.
final class PreparedHaloMicrophoneAdapter extends _PreparedHaloAudioAdapter
    implements AudioInputAdapter {
  PreparedHaloMicrophoneAdapter() : super(adapterId: 'halo-microphone-adapter');

  final StreamController<AudioFrame> _frames =
      StreamController<AudioFrame>.broadcast();

  @override
  String get sourceRevision => _PreparedHaloAudioAdapter.revision;

  @override
  Stream<AudioAdapterSnapshot> get snapshots => snapshotController.stream;

  @override
  Stream<AudioDiagnostic> get diagnostics => diagnosticController.stream;

  @override
  Stream<AudioLatencyMeasurement> get latencyMeasurements =>
      latencyController.stream;

  @override
  Stream<AudioFrame> get frames => _frames.stream;

  @override
  Future<bool> requestPermission() async {
    blocked('Halo microphone is not physically available.');
    return false;
  }

  @override
  Future<void> start(AudioSessionDescriptor session, AudioFormat format) async {
    unsupported('Halo microphone capture is blocked pending physical validation.');
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
    await _frames.close();
    await close();
  }
}

/// Contract-compatible placeholder for the physical Halo speaker.
final class PreparedHaloSpeakerAdapter extends _PreparedHaloAudioAdapter
    implements AudioOutputAdapter {
  PreparedHaloSpeakerAdapter() : super(adapterId: 'halo-speaker-adapter');

  @override
  String get sourceRevision => _PreparedHaloAudioAdapter.revision;

  @override
  Stream<AudioAdapterSnapshot> get snapshots => snapshotController.stream;

  @override
  Stream<AudioDiagnostic> get diagnostics => diagnosticController.stream;

  @override
  Stream<AudioLatencyMeasurement> get latencyMeasurements =>
      latencyController.stream;

  @override
  Future<void> start(AudioSessionDescriptor session, AudioFormat format) async {
    unsupported('Halo speaker playback is blocked pending physical validation.');
  }

  @override
  Future<void> enqueue(AudioFrame frame) async {
    unsupported('Halo speaker playback is blocked pending physical validation.');
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() => close();
}