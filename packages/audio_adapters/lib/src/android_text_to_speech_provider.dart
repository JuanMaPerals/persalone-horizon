import 'dart:async';

import 'package:flutter/services.dart';
import 'package:persalone_contracts/persalone_contracts.dart';

import 'android_live_translation_bridge.dart';

/// Android [TextToSpeech] implementation. Audio stays on the device; no PCM,
/// utterance text or voice identifier is emitted in diagnostics.
///
/// When the platform streams synthesized audio to the app, the native side
/// plays it through an AudioTrack it owns and reports when the first
/// non-silent frame was presented (AudioTrack timestamps, CLOCK_MONOTONIC).
/// Otherwise the engine plays it itself and every utterance is reported as
/// `unavailable` with the reason, never estimated.
final class AndroidTextToSpeechProvider
    implements SpeechSynthesisProvider, SpeechPresentationReporter {
  AndroidTextToSpeechProvider({
    AndroidLiveTranslationBridge? bridge,
    DateTime Function()? clock,
  })  : _bridge = bridge ?? MethodChannelAndroidLiveTranslationBridge(),
        _clock = clock ?? DateTime.now;

  /// System.nanoTime / AudioTimestamp / SpeechRecognizer callbacks.
  static const String clockDomain = 'android.clock_monotonic';
  static const int _maxPendingUtterances = 16;

  final AndroidLiveTranslationBridge _bridge;
  final DateTime Function() _clock;
  final StreamController<ProviderSnapshot> _snapshots =
      StreamController<ProviderSnapshot>.broadcast();
  final StreamController<LiveTranslationDiagnostic> _diagnostics =
      StreamController<LiveTranslationDiagnostic>.broadcast();
  final StreamController<SpeechPresentation> _presentations =
      StreamController<SpeechPresentation>.broadcast();

  /// utteranceId -> segment identity, until its presentation is reported.
  final Map<String, (TranslationSession, int)> _utterances =
      <String, (TranslationSession, int)>{};
  StreamSubscription<Map<Object?, Object?>>? _events;
  LiveTranslationConfig? _config;
  bool _disposed = false;
  bool? _measuredOutput;
  String? _outputReason;

  @override
  String get providerId => 'android-text-to-speech';

  @override
  String get sourceRevision => 'android.platform.TextToSpeech';

  @override
  Stream<ProviderSnapshot> get snapshots => _snapshots.stream;

  @override
  Stream<LiveTranslationDiagnostic> get diagnostics => _diagnostics.stream;

  @override
  Stream<SpeechPresentation> get presentations => _presentations.stream;

  @override
  String get monotonicClockDomain => clockDomain;

  /// Whether the last prepare selected the observable output path; null
  /// before a successful prepare.
  bool? get measuredOutput => _measuredOutput;

  /// Coded reason reported by the platform for the selected output path.
  String? get outputReason => _outputReason;

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
      _measuredOutput = result['measuredOutput'] == true;
      final Object? reason = result['outputReason'];
      _outputReason = reason is String ? reason : null;
      _utterances.clear();
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
    _utterances.remove(utteranceId);
    while (_utterances.length >= _maxPendingUtterances) {
      _utterances.remove(_utterances.keys.first);
    }
    _utterances[utteranceId] = (segment.session, segment.sequence);
    try {
      _emitDiagnostic(LiveTranslationDiagnosticCode.synthesisStarted,
          sequence: segment.sequence);
      await _bridge.speak(
        text: segment.translatedText,
        utteranceId: utteranceId,
        sequence: segment.sequence,
      );
    } on PlatformException catch (error) {
      _utterances.remove(utteranceId);
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
    _utterances.clear();
    await _events?.cancel();
    _events = null;
    await stop();
    await _snapshots.close();
    await _diagnostics.close();
    await _presentations.close();
  }

  void _handleEvent(Map<Object?, Object?> event) {
    final type = event['type'];
    final sequence = event['sequence'];
    final typedSequence = sequence is int ? sequence : null;
    switch (type) {
      case 'started':
        _emitDiagnostic(LiveTranslationDiagnosticCode.synthesisStarted,
            sequence: typedSequence);
      // Measured path: sent after the last frame was presented, so the
      // self-echo window covers actual playback, not just synthesis.
      case 'completed':
        _emitDiagnostic(LiveTranslationDiagnosticCode.synthesisCompleted,
            sequence: typedSequence);
      case 'presented':
        _reportPresentation(event);
      case 'presentation_unavailable':
        _reportUnavailable(event['utteranceId'], event['reason']);
      case 'error':
        _emitUnavailable();
    }
  }

  void _reportPresentation(Map<Object?, Object?> event) {
    final Object? queued = event['queuedAtMicros'];
    final Object? first = event['firstFramePresentedAtMicros'];
    final Object? audible = event['audiblePresentedAtMicros'];
    // Every time must be a platform monotonic integer, in causal order;
    // anything else is refused rather than repaired.
    if (queued is! int ||
        first is! int ||
        (audible != null && audible is! int) ||
        first < queued ||
        (audible is int && audible < first)) {
      _reportUnavailable(event['utteranceId'], 'malformedPresentation');
      return;
    }
    final (TranslationSession, int)? utterance =
        _takeUtterance(event['utteranceId']);
    if (utterance == null) return;
    _addPresentation(SpeechPresentation(
      session: utterance.$1,
      sequence: utterance.$2,
      status: SpeechPresentationStatus.presented,
      queuedAtMicros: queued,
      firstFramePresentedAtMicros: first,
      audiblePresentedAtMicros: audible as int?,
    ));
  }

  void _reportUnavailable(Object? utteranceId, Object? reason) {
    final (TranslationSession, int)? utterance = _takeUtterance(utteranceId);
    if (utterance == null) return;
    _addPresentation(SpeechPresentation(
      session: utterance.$1,
      sequence: utterance.$2,
      status: SpeechPresentationStatus.unavailable,
      reason: reason is String && _codedReason.hasMatch(reason)
          ? reason
          : 'unspecified',
    ));
  }

  static final RegExp _codedReason = RegExp(r'^[A-Za-z][A-Za-z0-9_]{0,47}$');

  (TranslationSession, int)? _takeUtterance(Object? utteranceId) =>
      utteranceId is String ? _utterances.remove(utteranceId) : null;

  void _addPresentation(SpeechPresentation presentation) {
    if (!_presentations.isClosed) _presentations.add(presentation);
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
