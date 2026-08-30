import 'dart:async';

import 'package:flutter/services.dart';
import 'package:persalone_contracts/persalone_contracts.dart';

import 'android_live_translation_bridge.dart';

/// Android [TextToSpeech] implementation. Audio remains inside Android's local
/// synthesis pipeline; no PCM, utterance text or voice identifier is emitted in
/// diagnostics.
final class AndroidTextToSpeechProvider implements SpeechSynthesisProvider {
  AndroidTextToSpeechProvider({
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
  StreamSubscription<Map<Object?, Object?>>? _events;
  LiveTranslationConfig? _config;
  bool _disposed = false;

  @override
  String get providerId => 'android-text-to-speech';

  @override
  String get sourceRevision => 'android.platform.TextToSpeech';

  @override
  Stream<ProviderSnapshot> get snapshots => _snapshots.stream;

  @override
  Stream<LiveTranslationDiagnostic> get diagnostics => _diagnostics.stream;

  int get _nowMicros => _clock().microsecondsSinceEpoch;

  @override
  Future<void> prepare(LiveTranslationConfig config) async {
    _ensureNotDisposed();
    if (!config.consent.localProcessingAllowed) {
      throw const RuntimeError(
        RuntimeErrorCode.consentRequired,
        'Android speech synthesis requires explicit local session consent.',
      );
    }
    _config = config;
    _emitSnapshot(ProviderReadiness.preparing, TruthLabel.prepared);
    try {
      final result = await _bridge.prepareTts(locale: config.targetLocale);
      if (result['ready'] != true) {
        throw const RuntimeError(
          RuntimeErrorCode.speechSynthesisUnavailable,
          'Android speech synthesis is unavailable for the requested locale.',
          retryable: true,
        );
      }
      await _events?.cancel();
      _events = _bridge.ttsEvents.listen(
        _handleEvent,
        onError: (Object error, StackTrace stackTrace) => _emitUnavailable(),
      );
      _emitSnapshot(ProviderReadiness.ready, TruthLabel.prepared);
      _emitDiagnostic(LiveTranslationDiagnosticCode.providerReady);
    } on PlatformException catch (error) {
      _emitUnavailable();
      throw RuntimeError(
        RuntimeErrorCode.speechSynthesisUnavailable,
        'Android speech synthesis preparation failed: ${error.code}.',
        retryable: true,
      );
    } on RuntimeError {
      _emitUnavailable();
      rethrow;
    }
  }

  @override
  Future<void> speak(TranslationSegment segment) async {
    final config = _config;
    if (config == null || !_matches(segment.session, config.session)) {
      throw const RuntimeError(
        RuntimeErrorCode.staleStreamEpoch,
        'Speech synthesis rejected an inactive translation session.',
      );
    }
    final utteranceId = '${segment.session.streamEpoch}-${segment.sequence}';
    try {
      _emitDiagnostic(LiveTranslationDiagnosticCode.synthesisStarted,
          sequence: segment.sequence);
      await _bridge.speak(
        text: segment.translatedText,
        utteranceId: utteranceId,
      );
    } on PlatformException catch (error) {
      _emitUnavailable();
      throw RuntimeError(
        RuntimeErrorCode.speechSynthesisUnavailable,
        'Android speech synthesis failed: ${error.code}.',
        retryable: true,
      );
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _bridge.stopTts();
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
    _config = null;
    await _events?.cancel();
    _events = null;
    await stop();
    await _snapshots.close();
    await _diagnostics.close();
  }

  void _handleEvent(Map<Object?, Object?> event) {
    final type = event['type'];
    final sequence = event['sequence'];
    final typedSequence = sequence is int ? sequence : null;
    switch (type) {
      case 'started':
        _emitDiagnostic(LiveTranslationDiagnosticCode.synthesisStarted,
            sequence: typedSequence);
      case 'completed':
        _emitDiagnostic(LiveTranslationDiagnosticCode.synthesisCompleted,
            sequence: typedSequence);
      case 'error':
        _emitUnavailable();
    }
  }

  bool _matches(TranslationSession first, TranslationSession second) =>
      first.sessionId == second.sessionId &&
      first.streamEpoch == second.streamEpoch &&
      first.privacyGeneration == second.privacyGeneration;

  void _emitUnavailable() {
    _emitSnapshot(ProviderReadiness.unavailable, TruthLabel.failed,
        failureReason: 'speech_synthesis_unavailable');
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
        'Android TTS provider has been disposed.',
      );
    }
  }
}
