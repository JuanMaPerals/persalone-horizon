import 'dart:async';

import 'package:flutter/services.dart';
import 'package:persalone_contracts/persalone_contracts.dart';

import 'android_live_translation_bridge.dart';

/// Android implementation of [StreamingSttProvider]. It never opens a second
/// microphone: the runtime forwards canonical G3 frames through [push].
final class AndroidSpeechRecognizerProvider implements StreamingSttProvider {
  AndroidSpeechRecognizerProvider({
    AndroidLiveTranslationBridge? bridge,
    DateTime Function()? clock,
  })  : _bridge = bridge ?? MethodChannelAndroidLiveTranslationBridge(),
        _clock = clock ?? DateTime.now;

  final AndroidLiveTranslationBridge _bridge;
  final DateTime Function() _clock;
  final StreamController<ProviderSnapshot> _snapshots =
      StreamController<ProviderSnapshot>.broadcast();
  final StreamController<LiveTranslationDiagnostic> _diagnostics =
      StreamController<LiveTranslationDiagnostic>.broadcast();
  final StreamController<TranscriptSegment> _transcripts =
      StreamController<TranscriptSegment>.broadcast();
  StreamSubscription<Map<Object?, Object?>>? _events;
  LiveTranslationConfig? _config;
  bool _disposed = false;

  @override
  String get providerId => 'android-speech-recognizer-pfd';

  @override
  String get sourceRevision => 'android-platform-speech-recognizer';

  @override
  Stream<ProviderSnapshot> get snapshots => _snapshots.stream;

  @override
  Stream<LiveTranslationDiagnostic> get diagnostics => _diagnostics.stream;

  @override
  Stream<TranscriptSegment> get transcripts => _transcripts.stream;

  int get _nowMicros => _clock().microsecondsSinceEpoch;

  @override
  Future<void> prepare(LiveTranslationConfig config, AudioFormat format) async {
    _ensureNotDisposed();
    if (!config.consent.localProcessingAllowed) {
      throw const RuntimeError(
        RuntimeErrorCode.consentRequired,
        'Android speech recognition requires local session consent.',
      );
    }
    if (format.sampleRateHz != 16000 ||
        format.channels != 1 ||
        format.bytesPerSample != 2) {
      throw const RuntimeError(
        RuntimeErrorCode.invalidContract,
        'Android STT accepts only canonical 16 kHz mono PCM.',
      );
    }
    _config = config;
    _emitSnapshot(ProviderReadiness.preparing, TruthLabel.prepared);
    try {
      final result = await _bridge.prepareStt(
        sessionId: config.session.sessionId,
        streamEpoch: config.session.streamEpoch,
        locale: config.sourceLocale,
        sampleRateHz: format.sampleRateHz,
        channels: format.channels,
      );
      if (result['ready'] != true) {
        throw const RuntimeError(
          RuntimeErrorCode.recognitionUnavailable,
          'Android recognition is unavailable for the requested locale or audio source.',
          retryable: true,
        );
      }
      await _events?.cancel();
      _events = _bridge.sttEvents.listen(
        _handleEvent,
        onError: (Object error, StackTrace stackTrace) {
          _emitUnavailable();
        },
      );
      _emitSnapshot(ProviderReadiness.ready, TruthLabel.prepared);
      _emitDiagnostic(LiveTranslationDiagnosticCode.providerReady);
    } on PlatformException {
      _emitUnavailable();
      rethrow;
    } on RuntimeError {
      _emitUnavailable();
      rethrow;
    }
  }

  @override
  Future<void> push(AudioFrame frame) async {
    final config = _config;
    if (config == null || !_matches(frame, config.session)) {
      _emitDiagnostic(LiveTranslationDiagnosticCode.frameRejected,
          sequence: frame.sequence);
      throw const RuntimeError(
        RuntimeErrorCode.staleStreamEpoch,
        'STT rejected a frame from an inactive session generation.',
      );
    }
    if (frame.direction != AudioDirection.input ||
        frame.codec != AudioCodec.pcmS16le) {
      throw const RuntimeError(
        RuntimeErrorCode.invalidContract,
        'STT accepts input PCM frames only.',
      );
    }
    try {
      await _bridge.pushSttPcm(frame.payload);
    } on PlatformException catch (error) {
      _emitUnavailable();
      throw RuntimeError(
        RuntimeErrorCode.recognitionUnavailable,
        'Android failed to accept a live PCM frame: ${error.code}.',
        retryable: true,
      );
    }
  }

  @override
  Future<void> stop() async {
    _config = null;
    await _events?.cancel();
    _events = null;
    try {
      await _bridge.stopStt();
    } on PlatformException {
      _emitUnavailable();
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await stop();
    await _snapshots.close();
    await _diagnostics.close();
    await _transcripts.close();
  }

  void _handleEvent(Map<Object?, Object?> event) {
    final config = _config;
    if (config == null) {
      return;
    }
    final type = event['type'];
    if (type == 'error') {
      _emitUnavailable();
      return;
    }
    if (type != 'partial' && type != 'final') {
      return;
    }
    final eventSessionId = event['sessionId'];
    final eventEpoch = event['streamEpoch'];
    if (eventSessionId != config.session.sessionId ||
        eventEpoch is! int ||
        eventEpoch != config.session.streamEpoch) {
      _emitDiagnostic(LiveTranslationDiagnosticCode.staleCallbackDiscarded);
      return;
    }
    final text = event['text'];
    final sequence = event['sequence'];
    if (text is! String || sequence is! int) {
      _emitDiagnostic(LiveTranslationDiagnosticCode.providerUnavailable);
      return;
    }
    final observedAt = event['observedAtMicros'];
    final confidence = event['confidence'];
    _transcripts.add(TranscriptSegment(
      session: config.session,
      sequence: sequence,
      text: text,
      stability: type == 'partial'
          ? TranscriptStability.partial
          : TranscriptStability.finalResult,
      observedAtMicros: observedAt is int ? observedAt : _nowMicros,
      confidence: confidence is num ? confidence.toDouble() : null,
      truthLabel: TruthLabel.prepared,
    ));
  }

  bool _matches(AudioFrame frame, TranslationSession session) =>
      frame.session.sessionId == session.sessionId &&
      frame.session.streamEpoch == session.streamEpoch;

  void _emitUnavailable() {
    _emitSnapshot(ProviderReadiness.unavailable, TruthLabel.failed,
        failureReason: 'recognition_unavailable');
    _emitDiagnostic(LiveTranslationDiagnosticCode.providerUnavailable);
  }

  void _emitSnapshot(
    ProviderReadiness readiness,
    TruthLabel truthLabel, {
    String? failureReason,
  }) {
    if (!_snapshots.isClosed) {
      _snapshots.add(ProviderSnapshot(
        providerId: providerId,
        sourceRevision: sourceRevision,
        readiness: readiness,
        truthLabel: truthLabel,
        observedAtMicros: _nowMicros,
        failureReason: failureReason,
      ));
    }
  }

  void _emitDiagnostic(LiveTranslationDiagnosticCode code, {int? sequence}) {
    if (!_diagnostics.isClosed) {
      _diagnostics.add(LiveTranslationDiagnostic(
        code: code,
        component: providerId,
        observedAtMicros: _nowMicros,
        sequence: sequence,
      ));
    }
  }

  void _ensureNotDisposed() {
    if (_disposed) {
      throw const RuntimeError(
        RuntimeErrorCode.sessionClosed,
        'Android STT provider has been disposed.',
      );
    }
  }
}
