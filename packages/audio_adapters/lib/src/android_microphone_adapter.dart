import 'dart:async';
import 'dart:typed_data';

import 'package:persalone_contracts/persalone_contracts.dart';

import 'android_host_audio_bridge.dart';

/// Android host microphone adapter. The Android implementation reads PCM from
/// `AudioRecord`; this Dart class only maps it to the canonical runtime port.
final class AndroidMicrophoneAdapter implements AudioInputAdapter {
  AndroidMicrophoneAdapter({
    required AndroidHostAudioBridge bridge,
    int Function()? nowMicros,
  })  : _bridge = bridge,
        _nowMicros = nowMicros ?? _defaultNowMicros;

  static const String revision = 'android-host-audio/1';

  /// Capture configuration reported by the platform when capture started
  /// (source, echo canceller); null until the platform reports it.
  AndroidCaptureConfig? get captureConfig => _captureConfig;
  AndroidCaptureConfig? _captureConfig;
  final StreamController<AndroidCaptureConfig> _captureConfigs =
      StreamController<AndroidCaptureConfig>.broadcast();
  Stream<AndroidCaptureConfig> get captureConfigs => _captureConfigs.stream;
  static final Stopwatch _clock = Stopwatch()..start();

  final AndroidHostAudioBridge _bridge;
  final int Function() _nowMicros;
  final StreamController<AudioAdapterSnapshot> _snapshots =
      StreamController<AudioAdapterSnapshot>.broadcast();
  final StreamController<AudioDiagnostic> _diagnostics =
      StreamController<AudioDiagnostic>.broadcast();
  final StreamController<AudioLatencyMeasurement> _latency =
      StreamController<AudioLatencyMeasurement>.broadcast();
  final StreamController<AudioFrame> _frames =
      StreamController<AudioFrame>.broadcast();

  StreamSubscription<Map<Object?, Object?>>? _eventsSubscription;
  AudioAdapterState _state = AudioAdapterState.idle;
  AudioSessionDescriptor? _session;
  AudioFormat? _format;
  bool _permissionGranted = false;
  bool _disposed = false;

  @override
  String get adapterId => 'android-microphone-adapter';

  @override
  String get sourceRevision => revision;

  @override
  Stream<AudioAdapterSnapshot> get snapshots => _snapshots.stream;

  @override
  Stream<AudioDiagnostic> get diagnostics => _diagnostics.stream;

  @override
  Stream<AudioLatencyMeasurement> get latencyMeasurements => _latency.stream;

  @override
  Stream<AudioFrame> get frames => _frames.stream;

  @override
  Future<bool> requestPermission() async {
    _ensureNotDisposed();
    _emitDiagnostic(AudioDiagnosticCode.permissionRequested);
    final bool granted = await _bridge.requestMicrophonePermission();
    _permissionGranted = granted;
    _emitDiagnostic(
      granted
          ? AudioDiagnosticCode.permissionGranted
          : AudioDiagnosticCode.permissionDenied,
    );
    if (!granted) {
      _transition(
        AudioAdapterState.permissionRequired,
        failureReason: 'Android microphone permission was not granted.',
      );
    }
    return granted;
  }

  @override
  Future<void> start(AudioSessionDescriptor session, AudioFormat format) async {
    _ensureNotDisposed();
    if (!_permissionGranted) {
      _transition(AudioAdapterState.permissionRequired);
      throw const RuntimeError(
        RuntimeErrorCode.consentRequired,
        'Microphone permission is required before Android capture can start.',
      );
    }
    if (_state == AudioAdapterState.streaming) {
      throw const RuntimeError(
        RuntimeErrorCode.deviceNotReady,
        'Android microphone capture is already streaming.',
      );
    }
    _session = session;
    _format = format;
    _transition(AudioAdapterState.starting);
    try {
      _eventsSubscription = _bridge.inputEvents.listen(
        _onNativeEvent,
        onError: _onNativeError,
      );
      await _bridge.startInput(format);
      _transition(AudioAdapterState.streaming);
      _emitDiagnostic(AudioDiagnosticCode.captureStarted);
    } catch (error) {
      await _eventsSubscription?.cancel();
      _eventsSubscription = null;
      _transition(
        AudioAdapterState.failed,
        failureReason: 'Android microphone capture failed to start.',
      );
      _emitDiagnostic(
        AudioDiagnosticCode.captureReadError,
        detail: error.runtimeType.toString(),
      );
      rethrow;
    }
  }

  @override
  Future<void> stop() async {
    _ensureNotDisposed();
    if (_state != AudioAdapterState.streaming &&
        _state != AudioAdapterState.starting) {
      return;
    }
    _transition(AudioAdapterState.stopping);
    await _bridge.stopInput();
    await _eventsSubscription?.cancel();
    _eventsSubscription = null;
    _transition(AudioAdapterState.stopped);
    _emitDiagnostic(AudioDiagnosticCode.captureStopped);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    if (_state == AudioAdapterState.streaming ||
        _state == AudioAdapterState.starting) {
      await stop();
    }
    _disposed = true;
    _transition(AudioAdapterState.disposed);
    await _snapshots.close();
    await _diagnostics.close();
    await _latency.close();
    await _frames.close();
    await _captureConfigs.close();
  }

  void _onNativeEvent(Map<Object?, Object?> event) {
    final String type = event['type'] as String? ?? 'unknown';
    switch (type) {
      case 'frame':
        _onFrame(event);
      case 'input_drop':
        _emitDiagnostic(
          AudioDiagnosticCode.inputDropped,
          sequence: _asInt(event['sequence']),
          value: _asInt(event['droppedFrames']),
        );
      case 'capture_timestamp':
        _emitDiagnostic(AudioDiagnosticCode.captureTimestampAvailable);
        _latency.add(
          AudioLatencyMeasurement(
            stage: AudioLatencyStage.inputCapture,
            adapterId: adapterId,
            observedAtMicros: _nowMicros(),
            truthLabel: TruthLabel.prepared,
            method: 'AudioRecord.getTimestamp(TIMEBASE_MONOTONIC)',
            framePosition: _asInt(event['framePosition']),
          ),
        );
      case 'capture_timestamp_unavailable':
        _emitDiagnostic(AudioDiagnosticCode.captureTimestampUnavailable);
      case 'route_changed':
        _emitDiagnostic(AudioDiagnosticCode.routeChanged);
      case 'capture_started':
        final AndroidCaptureConfig config = AndroidCaptureConfig.fromEvent(event);
        _captureConfig = config;
        if (!_captureConfigs.isClosed) _captureConfigs.add(config);
      case 'capture_stopped':
        // Already reported by stop(); nothing to add.
        break;
      case 'capture_error':
        _emitDiagnostic(
          AudioDiagnosticCode.captureReadError,
          detail: event['code'] as String?,
        );
      default:
        _emitDiagnostic(
          AudioDiagnosticCode.captureReadError,
          detail: 'unknown_native_event',
        );
    }
  }

  void _onFrame(Map<Object?, Object?> event) {
    final AudioSessionDescriptor? session = _session;
    final AudioFormat? format = _format;
    final Object? rawPcm = event['pcm'];
    if (session == null || format == null || rawPcm is! Uint8List) {
      _emitDiagnostic(
        AudioDiagnosticCode.captureReadError,
        detail: 'invalid_frame_event',
      );
      return;
    }
    final int bytes = rawPcm.length;
    if (bytes == 0 || bytes % format.bytesPerFrame != 0) {
      _emitDiagnostic(
        AudioDiagnosticCode.captureReadError,
        detail: 'invalid_pcm_frame',
      );
      return;
    }
    final int durationMicros = _asInt(event['durationMicros']) ??
        ((bytes ~/ format.bytesPerFrame) * 1000000 ~/ format.sampleRateHz);
    final int sequence = _asInt(event['sequence']) ?? 0;
    _frames.add(
      AudioFrame(
        schemaVersion: CapabilityManifest.currentSchemaVersion,
        session: session,
        direction: AudioDirection.input,
        sequence: sequence,
        codec: AudioCodec.pcmS16le,
        format: format,
        capturedAtMicros: _asInt(event['capturedAtMicros']) ?? _nowMicros(),
        receivedAtMicros: _nowMicros(),
        durationMicros: durationMicros,
        discontinuity: event['discontinuity'] == true,
        payload: rawPcm,
      ),
    );
    _emitDiagnostic(AudioDiagnosticCode.inputFrame, sequence: sequence);
  }

  void _onNativeError(Object error, StackTrace stackTrace) {
    _transition(
      AudioAdapterState.failed,
      failureReason: 'Android microphone event stream failed.',
    );
    _emitDiagnostic(
      AudioDiagnosticCode.captureReadError,
      detail: error.runtimeType.toString(),
    );
  }

  void _transition(AudioAdapterState next, {String? failureReason}) {
    _state = next;
    _snapshots.add(
      AudioAdapterSnapshot(
        state: next,
        adapterId: adapterId,
        sourceRevision: sourceRevision,
        truthLabel: TruthLabel.prepared,
        observedAtMicros: _nowMicros(),
        format: _format,
        failureReason: failureReason,
      ),
    );
  }

  void _emitDiagnostic(
    AudioDiagnosticCode code, {
    int? sequence,
    int? value,
    String? detail,
  }) {
    _diagnostics.add(
      AudioDiagnostic(
        code: code,
        adapterId: adapterId,
        observedAtMicros: _nowMicros(),
        sequence: sequence,
        value: value,
        detail: detail,
      ),
    );
  }

  void _ensureNotDisposed() {
    if (_disposed) {
      throw const RuntimeError(
        RuntimeErrorCode.sessionClosed,
        'Android microphone adapter has been disposed.',
      );
    }
  }

  static int? _asInt(Object? value) => value is int ? value : null;

  static int _defaultNowMicros() => _clock.elapsedMicroseconds;
}

/// Platform capture configuration for A/B validation. Coded values only.
final class AndroidCaptureConfig {
  const AndroidCaptureConfig({
    required this.audioSource,
    required this.echoCancelerAvailable,
    required this.echoCancelerEnabled,
    required this.noiseSuppressorAvailable,
  });

  factory AndroidCaptureConfig.fromEvent(Map<Object?, Object?> event) {
    final Object? source = event['audioSource'];
    return AndroidCaptureConfig(
      audioSource: source == 'voiceRecognition' || source == 'voiceCommunication'
          ? source! as String
          : 'unknown',
      echoCancelerAvailable: event['aecAvailable'] == true,
      echoCancelerEnabled: event['aecEnabled'] == true,
      noiseSuppressorAvailable: event['nsAvailable'] == true,
    );
  }

  /// `voiceRecognition`, `voiceCommunication`, or `unknown`.
  final String audioSource;
  final bool echoCancelerAvailable;
  final bool echoCancelerEnabled;
  final bool noiseSuppressorAvailable;

  Map<String, Object> toJson() => <String, Object>{
        'audioSource': audioSource,
        'aecAvailable': echoCancelerAvailable,
        'aecEnabled': echoCancelerEnabled,
        'nsAvailable': noiseSuppressorAvailable,
      };
}
