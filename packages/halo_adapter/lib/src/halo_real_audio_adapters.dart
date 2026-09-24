import 'dart:async';
import 'dart:typed_data';

import 'package:persalone_contracts/persalone_contracts.dart';

import 'halo_audio_transport.dart';
import 'lc3/lc3_decoder_service.dart';
import 'lc3/lc3_encoder_service.dart';
import 'lc3/lc3_packet_pacer.dart';

const int _lc3SampleRate = 16000;
const int _lc3Bitrate = 32000;
const int _lc3FrameDurationUs = 10000;

abstract base class _HaloRealAudioBase {
  _HaloRealAudioBase(this.transport, this.adapterId);

  static const String revision =
      'brilliant_sdk@462dff4795cffb85248ab1d2f92d4f319adb03d3';
  static final Stopwatch clock = Stopwatch()..start();

  final HaloAudioTransport transport;
  final String adapterId;
  final StreamController<AudioAdapterSnapshot> snapshotController =
      StreamController<AudioAdapterSnapshot>.broadcast();
  final StreamController<AudioDiagnostic> diagnosticController =
      StreamController<AudioDiagnostic>.broadcast();
  final StreamController<AudioLatencyMeasurement> latencyController =
      StreamController<AudioLatencyMeasurement>.broadcast();
  bool disposed = false;

  void snapshot(AudioAdapterState state, {String? failureReason}) {
    snapshotController.add(AudioAdapterSnapshot(
      state: state,
      adapterId: adapterId,
      sourceRevision: revision,
      truthLabel: TruthLabel.prepared,
      observedAtMicros: clock.elapsedMicroseconds,
      format: AudioFormat.voice16kMono,
      failureReason: failureReason,
    ));
  }

  void diagnostic(AudioDiagnosticCode code, {int? sequence, String? detail}) {
    diagnosticController.add(AudioDiagnostic(
      code: code,
      adapterId: adapterId,
      observedAtMicros: clock.elapsedMicroseconds,
      sequence: sequence,
      detail: detail,
    ));
  }

  void requireFormat(AudioFormat format) {
    if (format.sampleRateHz != 16000 ||
        format.channels != 1 ||
        format.bytesPerSample != 2) {
      throw const RuntimeError(
        RuntimeErrorCode.invalidContract,
        'HALO_REAL requires PCM16 mono at 16 kHz.',
      );
    }
  }

  Future<void> closeBase() async {
    if (disposed) return;
    disposed = true;
    await snapshotController.close();
    await diagnosticController.close();
    await latencyController.close();
  }
}

final class HaloRealMicrophoneAdapter extends _HaloRealAudioBase
    implements AudioInputAdapter {
  HaloRealMicrophoneAdapter({required HaloAudioTransport transport})
      : super(transport, 'halo-real-microphone');

  final StreamController<AudioFrame> _frames =
      StreamController<AudioFrame>.broadcast();
  Lc3DecoderService? _decoder;
  StreamSubscription<Uint8List>? _encodedSubscription;
  StreamSubscription<Uint8List>? _pcmSubscription;
  AudioSessionDescriptor? _session;
  int _sequence = 0;

  @override
  String get sourceRevision => _HaloRealAudioBase.revision;
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
    diagnostic(AudioDiagnosticCode.permissionGranted);
    return true;
  }

  @override
  Future<void> start(AudioSessionDescriptor session, AudioFormat format) async {
    requireFormat(format);
    if (_session != null) {
      throw const RuntimeError(
        RuntimeErrorCode.deviceNotReady,
        'Halo microphone is already streaming.',
      );
    }
    snapshot(AudioAdapterState.starting);
    try {
      final Lc3DecoderService decoder = Lc3DecoderService();
      await decoder.init(
        sampleRateHz: _lc3SampleRate,
        pcmSampleRateHz: format.sampleRateHz,
        frameDurationUs: _lc3FrameDurationUs,
        bitrate: _lc3Bitrate,
      );
      _decoder = decoder;
      _session = session;
      _sequence = 0;
      _pcmSubscription = decoder.outputStream.listen(_onPcm, onError: _onError);
      _encodedSubscription =
          transport.encodedMicrophoneAudio.listen(decoder.sendLc3Chunk, onError: _onError);
      await transport.startMicrophone(
        gain: 10,
        echoCancellation: true,
        voiceMode: true,
      );
      diagnostic(AudioDiagnosticCode.captureStarted);
      snapshot(AudioAdapterState.streaming);
    } catch (error) {
      await _teardown();
      snapshot(AudioAdapterState.failed, failureReason: 'Halo microphone start failed.');
      rethrow;
    }
  }

  void _onPcm(Uint8List pcm) {
    final AudioSessionDescriptor? session = _session;
    if (session == null) return;
    final int now = _HaloRealAudioBase.clock.elapsedMicroseconds;
    final int sequence = _sequence++;
    _frames.add(AudioFrame(
      schemaVersion: CapabilityManifest.currentSchemaVersion,
      session: session,
      direction: AudioDirection.input,
      sequence: sequence,
      codec: AudioCodec.pcmS16le,
      format: AudioFormat.voice16kMono,
      capturedAtMicros: now,
      receivedAtMicros: now,
      durationMicros: pcm.length * 1000000 ~/ (16000 * 2),
      payload: pcm,
    ));
    diagnostic(AudioDiagnosticCode.inputFrame, sequence: sequence);
  }

  void _onError(Object error, StackTrace stackTrace) {
    diagnostic(AudioDiagnosticCode.captureReadError, detail: 'Halo microphone stream failed.');
    snapshot(AudioAdapterState.failed, failureReason: 'Halo microphone stream failed.');
    unawaited(_teardown());
  }

  Future<void> _teardown() async {
    _session = null;
    await _encodedSubscription?.cancel();
    _encodedSubscription = null;
    await _pcmSubscription?.cancel();
    _pcmSubscription = null;
    _decoder?.dispose();
    _decoder = null;
    try {
      await transport.stopMicrophone().timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  @override
  Future<void> stop() async {
    if (_session == null && _decoder == null) return;
    snapshot(AudioAdapterState.stopping);
    await _teardown();
    diagnostic(AudioDiagnosticCode.captureStopped);
    snapshot(AudioAdapterState.stopped);
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _frames.close();
    await closeBase();
  }
}

final class HaloRealSpeakerAdapter extends _HaloRealAudioBase
    implements AudioOutputAdapter {
  HaloRealSpeakerAdapter({required HaloAudioTransport transport})
      : super(transport, 'halo-real-speaker');

  Lc3EncoderService? _encoder;
  Lc3PacketPacer? _pacer;
  StreamSubscription<Uint8List>? _encodedSubscription;
  bool _started = false;

  @override
  String get sourceRevision => _HaloRealAudioBase.revision;
  @override
  Stream<AudioAdapterSnapshot> get snapshots => snapshotController.stream;
  @override
  Stream<AudioDiagnostic> get diagnostics => diagnosticController.stream;
  @override
  Stream<AudioLatencyMeasurement> get latencyMeasurements =>
      latencyController.stream;

  @override
  Future<void> start(AudioSessionDescriptor session, AudioFormat format) async {
    requireFormat(format);
    if (_started) {
      throw const RuntimeError(
        RuntimeErrorCode.deviceNotReady,
        'Halo speaker is already streaming.',
      );
    }
    snapshot(AudioAdapterState.starting);
    try {
      final Lc3EncoderService encoder = Lc3EncoderService();
      await encoder.init(
        sampleRateHz: _lc3SampleRate,
        pcmSampleRateHz: format.sampleRateHz,
        frameDurationUs: _lc3FrameDurationUs,
        targetBitrate: _lc3Bitrate,
      );
      final Lc3PacketPacer pacer = Lc3PacketPacer(
        intervalMs: _lc3FrameDurationUs ~/ 1000,
        maxBufferDelayFrames: 20,
        sendAudio: (Uint8List data) => transport.sendEncodedSpeakerAudio(data),
      );
      _encoder = encoder;
      _pacer = pacer;
      _encodedSubscription = encoder.outputStream.listen(
        pacer.onNewPacketReceived,
        onError: _onError,
      );
      await transport.startSpeaker(volume: 100);
      _started = true;
      diagnostic(AudioDiagnosticCode.playbackStarted);
      snapshot(AudioAdapterState.streaming);
    } catch (error) {
      await _teardown();
      snapshot(AudioAdapterState.failed, failureReason: 'Halo speaker start failed.');
      rethrow;
    }
  }

  @override
  Future<void> enqueue(AudioFrame frame) async {
    if (!_started || _encoder == null) {
      throw const RuntimeError(
        RuntimeErrorCode.deviceNotReady,
        'Halo speaker is not streaming.',
      );
    }
    requireFormat(frame.format);
    if (frame.codec != AudioCodec.pcmS16le ||
        frame.direction != AudioDirection.output) {
      throw const RuntimeError(
        RuntimeErrorCode.invalidContract,
        'Halo speaker accepts only output PCM16 frames.',
      );
    }
    _encoder!.sendPcmChunk(frame.payload);
    diagnostic(AudioDiagnosticCode.outputFrameQueued, sequence: frame.sequence);
  }

  void _onError(Object error, StackTrace stackTrace) {
    snapshot(AudioAdapterState.failed, failureReason: 'Halo speaker stream failed.');
    unawaited(_teardown());
  }

  Future<void> _teardown() async {
    _started = false;
    await _encodedSubscription?.cancel();
    _encodedSubscription = null;
    _pacer?.dispose();
    _pacer = null;
    _encoder?.dispose();
    _encoder = null;
    try {
      await transport.stopSpeaker().timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  @override
  Future<void> stop() async {
    if (!_started && _encoder == null) return;
    snapshot(AudioAdapterState.stopping);
    await _teardown();
    diagnostic(AudioDiagnosticCode.playbackStopped);
    snapshot(AudioAdapterState.stopped);
  }

  @override
  Future<void> dispose() async {
    await stop();
    await closeBase();
  }
}