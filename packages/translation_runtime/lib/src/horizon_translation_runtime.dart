import 'dart:async';

import 'package:persalone_contracts/persalone_contracts.dart';

enum HorizonTranslationRuntimeState {
  idle,
  preparing,
  listening,
  stopping,
  stopped,
  failed,
  disposed,
}

/// A redacted runtime snapshot for UI and evidence. It intentionally excludes
/// PCM, transcripts, translations, device IDs and provider credentials.
final class HorizonTranslationRuntimeSnapshot {
  const HorizonTranslationRuntimeSnapshot({
    required this.state,
    required this.sessionId,
    required this.streamEpoch,
    required this.observedAtMicros,
    this.failureCode,
  });

  final HorizonTranslationRuntimeState state;
  final String? sessionId;
  final int? streamEpoch;
  final int observedAtMicros;
  final RuntimeErrorCode? failureCode;
}

/// Provider-neutral live translation orchestration.
///
/// The runtime owns one input adapter and feeds its canonical PCM frames only to
/// [StreamingSttProvider]. Final STT segments drive translation and synthesis.
/// Every asynchronous continuation is tied to a session/epoch and is discarded
/// when a later session stops or replaces it. This prevents late callbacks from
/// speaking a prior conversation after barge-in or cancellation.
final class HorizonTranslationRuntime {
  HorizonTranslationRuntime({
    required AudioInputAdapter input,
    required StreamingSttProvider stt,
    required TextTranslationProvider translator,
    required SpeechSynthesisProvider synthesizer,
    DateTime Function()? clock,
  })  : _input = input,
        _stt = stt,
        _translator = translator,
        _synthesizer = synthesizer,
        _clock = clock ?? DateTime.now;

  final AudioInputAdapter _input;
  final StreamingSttProvider _stt;
  final TextTranslationProvider _translator;
  final SpeechSynthesisProvider _synthesizer;
  final DateTime Function() _clock;

  final StreamController<HorizonTranslationRuntimeSnapshot> _snapshots =
      StreamController<HorizonTranslationRuntimeSnapshot>.broadcast();
  final StreamController<LiveTranslationDiagnostic> _diagnostics =
      StreamController<LiveTranslationDiagnostic>.broadcast();
  final StreamController<TranscriptSegment> _transcripts =
      StreamController<TranscriptSegment>.broadcast();
  final StreamController<TranslationSegment> _translations =
      StreamController<TranslationSegment>.broadcast();

  StreamSubscription<AudioFrame>? _frameSubscription;
  StreamSubscription<TranscriptSegment>? _transcriptSubscription;
  final List<StreamSubscription<LiveTranslationDiagnostic>>
      _providerDiagnosticSubscriptions = [];
  HorizonTranslationRuntimeState _state = HorizonTranslationRuntimeState.idle;
  LiveTranslationConfig? _config;
  bool _disposed = false;

  Stream<HorizonTranslationRuntimeSnapshot> get snapshots => _snapshots.stream;
  Stream<LiveTranslationDiagnostic> get diagnostics => _diagnostics.stream;
  Stream<TranscriptSegment> get transcripts => _transcripts.stream;
  Stream<TranslationSegment> get translations => _translations.stream;
  HorizonTranslationRuntimeState get state => _state;

  int get _nowMicros => _clock().microsecondsSinceEpoch;

  Future<void> start({
    required LiveTranslationConfig config,
    required AudioSessionDescriptor audioSession,
    AudioFormat format = AudioFormat.voice16kMono,
  }) async {
    _ensureNotDisposed();
    if (_state == HorizonTranslationRuntimeState.preparing ||
        _state == HorizonTranslationRuntimeState.listening ||
        _state == HorizonTranslationRuntimeState.stopping) {
      throw const RuntimeError(
        RuntimeErrorCode.policyDenied,
        'The translation runtime already has an active lifecycle operation.',
      );
    }
    if (!config.consent.localProcessingAllowed) {
      _emitDiagnostic(
        LiveTranslationDiagnosticCode.consentDenied,
        component: 'runtime',
      );
      throw const RuntimeError(
        RuntimeErrorCode.consentRequired,
        'Local live translation requires explicit session consent.',
      );
    }
    if (config.session.sessionId != audioSession.sessionId ||
        config.session.streamEpoch != audioSession.streamEpoch) {
      throw const RuntimeError(
        RuntimeErrorCode.invalidContract,
        'Audio session must match the translation session and epoch.',
      );
    }
    if (format.sampleRateHz != AudioFormat.voice16kMono.sampleRateHz ||
        format.channels != AudioFormat.voice16kMono.channels ||
        format.bytesPerSample != AudioFormat.voice16kMono.bytesPerSample) {
      throw const RuntimeError(
        RuntimeErrorCode.invalidContract,
        'G5 currently accepts only canonical 16 kHz mono signed PCM.',
      );
    }

    _config = config;
    _setState(HorizonTranslationRuntimeState.preparing);
    _bindProviderDiagnostics();
    try {
      await _stt.prepare(config, format);
      _assertCurrent(config.session);
      await _translator.prepare(config);
      _assertCurrent(config.session);
      await _synthesizer.prepare(config);
      _assertCurrent(config.session);

      final permissionGranted = await _input.requestPermission();
      _assertCurrent(config.session);
      if (!permissionGranted) {
        throw const RuntimeError(
          RuntimeErrorCode.policyDenied,
          'Microphone permission was not granted for this session.',
        );
      }

      _transcriptSubscription = _stt.transcripts.listen(
        _onTranscript,
        onError: (Object error, StackTrace stackTrace) {
          _fail(error, stackTrace);
        },
      );
      await _input.start(audioSession, format);
      _assertCurrent(config.session);
      _frameSubscription = _input.frames.listen(
        (AudioFrame frame) {
          unawaited(_onFrame(frame));
        },
        onError: (Object error, StackTrace stackTrace) {
          _fail(error, stackTrace);
        },
      );
      _setState(HorizonTranslationRuntimeState.listening);
    } on Object catch (error, stackTrace) {
      await _stopActiveResources();
      _fail(error, stackTrace);
      rethrow;
    }
  }

  Future<void> stop() async {
    if (_disposed ||
        _state == HorizonTranslationRuntimeState.idle ||
        _state == HorizonTranslationRuntimeState.stopped ||
        _state == HorizonTranslationRuntimeState.disposed) {
      return;
    }
    _setState(HorizonTranslationRuntimeState.stopping);
    _config = null;
    await _stopActiveResources();
    _setState(HorizonTranslationRuntimeState.stopped);
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    await stop();
    _disposed = true;
    await _stt.dispose();
    await _translator.dispose();
    await _synthesizer.dispose();
    await _snapshots.close();
    await _diagnostics.close();
    await _transcripts.close();
    await _translations.close();
    _state = HorizonTranslationRuntimeState.disposed;
  }

  Future<void> _onFrame(AudioFrame frame) async {
    final config = _config;
    if (config == null || !_isCurrent(config.session)) {
      _emitDiagnostic(
        LiveTranslationDiagnosticCode.staleCallbackDiscarded,
        component: 'runtime',
        sequence: frame.sequence,
      );
      return;
    }
    if (frame.direction != AudioDirection.input ||
        frame.session.sessionId != config.session.sessionId ||
        frame.session.streamEpoch != config.session.streamEpoch) {
      _emitDiagnostic(
        LiveTranslationDiagnosticCode.frameRejected,
        component: 'runtime',
        sequence: frame.sequence,
      );
      return;
    }
    try {
      await _stt.push(frame);
    } on Object catch (error, stackTrace) {
      if (_isCurrent(config.session)) {
        _fail(error, stackTrace);
      } else {
        _emitDiagnostic(
          LiveTranslationDiagnosticCode.staleCallbackDiscarded,
          component: 'runtime',
          sequence: frame.sequence,
        );
      }
    }
  }

  void _onTranscript(TranscriptSegment segment) {
    final config = _config;
    if (config == null || !_matches(segment.session, config.session)) {
      _emitDiagnostic(
        LiveTranslationDiagnosticCode.staleCallbackDiscarded,
        component: 'stt',
        sequence: segment.sequence,
      );
      return;
    }
    _transcripts.add(segment);
    _emitDiagnostic(
      segment.stability == TranscriptStability.partial
          ? LiveTranslationDiagnosticCode.transcriptPartial
          : LiveTranslationDiagnosticCode.transcriptFinal,
      component: 'stt',
      sequence: segment.sequence,
    );
    if (segment.stability == TranscriptStability.finalResult &&
        segment.text.trim().isNotEmpty) {
      unawaited(_translateAndSpeak(segment));
    }
  }

  Future<void> _translateAndSpeak(TranscriptSegment transcript) async {
    final session = transcript.session;
    if (!_isCurrent(session)) {
      _discardStale('runtime', transcript.sequence);
      return;
    }
    try {
      // A new final turn interrupts prior synthesis before its own translation
      // can be spoken. This is the G5 barge-in boundary.
      await _synthesizer.stop();
      if (!_isCurrent(session)) {
        _discardStale('tts', transcript.sequence);
        return;
      }
      final translation = await _translator.translate(transcript);
      if (!_isCurrent(session) || !_matches(translation.session, session)) {
        _discardStale('translation', transcript.sequence);
        return;
      }
      _translations.add(translation);
      _emitDiagnostic(
        LiveTranslationDiagnosticCode.translationCompleted,
        component: 'translation',
        sequence: translation.sequence,
      );
      await _synthesizer.speak(translation);
      if (!_isCurrent(session)) {
        _discardStale('tts', translation.sequence);
        return;
      }
      // Completion is emitted only by the platform TTS progress callback. A
      // successful speak call merely confirms that Android accepted the queue.
    } on Object catch (error, stackTrace) {
      if (_isCurrent(session)) {
        _emitDiagnostic(
          LiveTranslationDiagnosticCode.synthesisFailed,
          component: 'runtime',
          sequence: transcript.sequence,
        );
        _fail(error, stackTrace);
      } else {
        _discardStale('runtime', transcript.sequence);
      }
    }
  }

  Future<void> _stopActiveResources() async {
    await _frameSubscription?.cancel();
    _frameSubscription = null;
    await _transcriptSubscription?.cancel();
    _transcriptSubscription = null;
    for (final subscription in _providerDiagnosticSubscriptions) {
      await subscription.cancel();
    }
    _providerDiagnosticSubscriptions.clear();
    await _input.stop();
    await _stt.stop();
    await _synthesizer.stop();
  }

  void _bindProviderDiagnostics() {
    if (_providerDiagnosticSubscriptions.isNotEmpty) {
      return;
    }
    for (final provider in [
      _stt.diagnostics,
      _translator.diagnostics,
      _synthesizer.diagnostics
    ]) {
      _providerDiagnosticSubscriptions.add(provider.listen(_diagnostics.add));
    }
  }

  bool _isCurrent(TranslationSession session) {
    final config = _config;
    return config != null && _matches(session, config.session);
  }

  bool _matches(TranslationSession first, TranslationSession second) =>
      first.sessionId == second.sessionId &&
      first.streamEpoch == second.streamEpoch &&
      first.privacyGeneration == second.privacyGeneration;

  void _assertCurrent(TranslationSession session) {
    if (!_isCurrent(session)) {
      throw const RuntimeError(
        RuntimeErrorCode.staleStreamEpoch,
        'A lifecycle operation completed after its session was no longer current.',
      );
    }
  }

  void _discardStale(String component, int sequence) {
    _emitDiagnostic(
      LiveTranslationDiagnosticCode.staleCallbackDiscarded,
      component: component,
      sequence: sequence,
    );
  }

  void _fail(Object error, StackTrace stackTrace) {
    if (_disposed) {
      return;
    }
    final errorCode = error is RuntimeError
        ? error.code
        : RuntimeErrorCode.providerUnavailable;
    _setState(HorizonTranslationRuntimeState.failed, failureCode: errorCode);
  }

  void _setState(
    HorizonTranslationRuntimeState state, {
    RuntimeErrorCode? failureCode,
  }) {
    _state = state;
    final config = _config;
    if (!_snapshots.isClosed) {
      _snapshots.add(HorizonTranslationRuntimeSnapshot(
        state: state,
        sessionId: config?.session.sessionId,
        streamEpoch: config?.session.streamEpoch,
        observedAtMicros: _nowMicros,
        failureCode: failureCode,
      ));
    }
  }

  void _emitDiagnostic(
    LiveTranslationDiagnosticCode code, {
    required String component,
    int? sequence,
  }) {
    if (!_diagnostics.isClosed) {
      _diagnostics.add(LiveTranslationDiagnostic(
        code: code,
        component: component,
        observedAtMicros: _nowMicros,
        sequence: sequence,
      ));
    }
  }

  void _ensureNotDisposed() {
    if (_disposed) {
      throw const RuntimeError(
        RuntimeErrorCode.sessionClosed,
        'The translation runtime has been disposed.',
      );
    }
  }
}
