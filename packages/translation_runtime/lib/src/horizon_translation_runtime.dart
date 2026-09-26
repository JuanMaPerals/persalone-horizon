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
    CaptionOutputAdapter? captions,
    DateTime Function()? clock,
  })  : _input = input,
        _stt = stt,
        _translator = translator,
        _synthesizer = synthesizer,
        _captions = captions,
        _clock = clock ?? DateTime.now;

  final AudioInputAdapter _input;
  final StreamingSttProvider _stt;
  final TextTranslationProvider _translator;
  final SpeechSynthesisProvider _synthesizer;
  final CaptionOutputAdapter? _captions;
  final DateTime Function() _clock;

  final StreamController<HorizonTranslationRuntimeSnapshot> _snapshots =
      StreamController<HorizonTranslationRuntimeSnapshot>.broadcast();
  final StreamController<LiveTranslationDiagnostic> _diagnostics =
      StreamController<LiveTranslationDiagnostic>.broadcast();
  final StreamController<TranscriptSegment> _transcripts =
      StreamController<TranscriptSegment>.broadcast();
  final StreamController<TranslationSegment> _translations =
      StreamController<TranslationSegment>.broadcast();
  final StreamController<CaptionDelivery> _captionDeliveries =
      StreamController<CaptionDelivery>.broadcast();

  StreamSubscription<AudioFrame>? _frameSubscription;
  StreamSubscription<TranscriptSegment>? _transcriptSubscription;
  final List<StreamSubscription<LiveTranslationDiagnostic>>
      _providerDiagnosticSubscriptions = [];
  HorizonTranslationRuntimeState _state = HorizonTranslationRuntimeState.idle;
  LiveTranslationConfig? _config;
  bool _disposed = false;
  int _turnCounter = 0;
  int _lastDeliveredTurn = 0;
  TranslationSession? _lastSession;
  Future<List<String>>? _panicInFlight;

  Stream<HorizonTranslationRuntimeSnapshot> get snapshots => _snapshots.stream;
  Stream<LiveTranslationDiagnostic> get diagnostics => _diagnostics.stream;
  Stream<TranscriptSegment> get transcripts => _transcripts.stream;
  Stream<TranslationSegment> get translations => _translations.stream;
  Stream<CaptionDelivery> get captionDeliveries => _captionDeliveries.stream;
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
    _lastSession = config.session;
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
          unawaited(_fail(error, stackTrace));
        },
      );
      await _input.start(audioSession, format);
      _assertCurrent(config.session);
      _frameSubscription = _input.frames.listen(
        (AudioFrame frame) {
          unawaited(_onFrame(frame));
        },
        onError: (Object error, StackTrace stackTrace) {
          unawaited(_fail(error, stackTrace));
        },
      );
      _setState(HorizonTranslationRuntimeState.listening);
    } on Object catch (error, stackTrace) {
      if (_isCurrent(config.session)) {
        await _fail(error, stackTrace);
      } else if (_config == null) {
        // Stop or Panic superseded this start while a provider call was in
        // flight; that call (e.g. microphone start) may have completed after
        // their cleanup ran, so tear down again. A newer session owns the
        // resources otherwise and is left untouched.
        await _stopActiveResourcesAfterFailure(config.session);
      }
      rethrow;
    }
  }

  /// Emergency stop. Valid from every state and idempotent: it invalidates
  /// all in-flight session and turn work first (late translations, captions
  /// and TTS become stale), then stops microphone, STT and TTS and clears the
  /// display best-effort. Outstanding translation calls cannot be aborted in
  /// the provider; their results are discarded. Returns the components whose
  /// cleanup threw; the remaining safety actions still ran.
  Future<List<String>> panic() =>
      _panicInFlight ??= _runPanic().whenComplete(() => _panicInFlight = null);

  Future<List<String>> _runPanic() async {
    if (_disposed) {
      return const <String>[];
    }
    final TranslationSession? session = _config?.session ?? _lastSession;
    _config = null;
    final List<String> failed = await _stopActiveResourcesAfterFailure(session);
    if (_state != HorizonTranslationRuntimeState.idle) {
      _setState(HorizonTranslationRuntimeState.stopped);
    }
    _emitDiagnostic(
      failed.isEmpty
          ? LiveTranslationDiagnosticCode.panicExecuted
          : LiveTranslationDiagnosticCode.cleanupFailed,
      component: 'runtime',
      detail: failed.isEmpty ? null : failed.join('.'),
    );
    return failed;
  }

  Future<void> stop() async {
    if (_disposed ||
        _state == HorizonTranslationRuntimeState.idle ||
        _state == HorizonTranslationRuntimeState.stopped ||
        _state == HorizonTranslationRuntimeState.disposed) {
      return;
    }
    _setState(HorizonTranslationRuntimeState.stopping);
    final session = _config?.session;
    _config = null;
    await _stopActiveResources(session);
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
    await _captionDeliveries.close();
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
        await _fail(error, stackTrace);
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
    final turn = ++_turnCounter;
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
      // Translations may complete out of order; a turn older than one already
      // delivered must never replace its caption or be spoken after it.
      if (!_isCurrent(session) ||
          !_matches(translation.session, session) ||
          turn < _lastDeliveredTurn) {
        _discardStale('translation', transcript.sequence);
        return;
      }
      _lastDeliveredTurn = turn;
      _translations.add(translation);
      _emitDiagnostic(
        LiveTranslationDiagnosticCode.translationCompleted,
        component: 'translation',
        sequence: translation.sequence,
      );
      final captions = _captions;
      if (captions != null) {
        await _deliverCaption(captions, translation);
        if (!_isCurrent(session) || turn != _lastDeliveredTurn) {
          _discardStale('tts', translation.sequence);
          return;
        }
      }
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
        await _fail(error, stackTrace);
      } else {
        _discardStale('runtime', transcript.sequence);
      }
    }
  }

  Future<void> _deliverCaption(
    CaptionOutputAdapter captions,
    TranslationSegment translation,
  ) async {
    final session = translation.session;
    CaptionDelivery delivery;
    try {
      delivery = await captions.show(CaptionUpdate(
        session: session,
        sequence: translation.sequence,
        text: translation.translatedText,
        observedAtMicros: _nowMicros,
        truthLabel: translation.truthLabel,
      ));
      // An adapter cannot report a different execution path than it declares.
      if (delivery.environment != captions.environment) {
        delivery = _failedCaption(captions, translation, 'environmentMismatch');
      }
    } on Object {
      delivery = _failedCaption(captions, translation, 'adapterError');
    }
    if (!_isCurrent(session)) {
      // The session stopped while the destination was rendering; do not leave
      // a caption from a closed conversation on the display.
      _discardStale('caption', translation.sequence);
      try {
        await captions.clear(session);
      } on Object {
        // Teardown already ran; a failed late clear is reported as stale only.
      }
      return;
    }
    if (!_captionDeliveries.isClosed) {
      _captionDeliveries.add(delivery);
    }
    _emitDiagnostic(
      switch (delivery.status) {
        CaptionDeliveryStatus.delivered =>
          LiveTranslationDiagnosticCode.captionDelivered,
        CaptionDeliveryStatus.blocked =>
          LiveTranslationDiagnosticCode.captionBlocked,
        CaptionDeliveryStatus.failed =>
          LiveTranslationDiagnosticCode.captionFailed,
      },
      component: 'caption',
      sequence: translation.sequence,
      detail: delivery.reason,
    );
  }

  CaptionDelivery _failedCaption(
    CaptionOutputAdapter captions,
    TranslationSegment translation,
    String reason,
  ) =>
      CaptionDelivery(
        session: translation.session,
        sequence: translation.sequence,
        status: CaptionDeliveryStatus.failed,
        environment: captions.environment,
        truthLabel: TruthLabel.failed,
        adapterId: captions.adapterId,
        reason: reason,
      );

  Future<void> _stopActiveResources(TranslationSession? session) async {
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
    final captions = _captions;
    if (session != null && captions != null) {
      try {
        await captions.clear(session);
      } on Object {
        // A disconnected display must not prevent the session from stopping.
        _emitDiagnostic(
          LiveTranslationDiagnosticCode.captionFailed,
          component: 'caption',
          detail: 'clearFailed',
        );
      }
    }
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

  Future<void> _fail(Object error, StackTrace stackTrace) async {
    if (_disposed ||
        _state == HorizonTranslationRuntimeState.failed ||
        _state == HorizonTranslationRuntimeState.stopping ||
        _state == HorizonTranslationRuntimeState.stopped) {
      return;
    }
    final errorCode = error is RuntimeError
        ? error.code
        : RuntimeErrorCode.providerUnavailable;

    // Publish the failure while the session identity is still available, then
    // invalidate it before any asynchronous teardown. Late frames/transcripts
    // are therefore stale immediately and cannot continue translation or TTS.
    _setState(HorizonTranslationRuntimeState.failed, failureCode: errorCode);
    final session = _config?.session;
    _config = null;
    await _stopActiveResourcesAfterFailure(session);
  }

  /// Best-effort teardown: every step runs even if an earlier one throws, so one
  /// broken component cannot leave the microphone, TTS or display active.
  /// Returns the components whose cleanup threw.
  Future<List<String>> _stopActiveResourcesAfterFailure(
    TranslationSession? session,
  ) async {
    final frameSubscription = _frameSubscription;
    _frameSubscription = null;
    final transcriptSubscription = _transcriptSubscription;
    _transcriptSubscription = null;
    final diagnosticSubscriptions =
        List<StreamSubscription<LiveTranslationDiagnostic>>.from(
      _providerDiagnosticSubscriptions,
    );
    _providerDiagnosticSubscriptions.clear();

    final List<String> failed = <String>[];
    Future<void> bestEffort(
        String component, Future<void> Function() operation) async {
      try {
        await operation();
      } on Object {
        failed.add(component);
      }
    }

    if (frameSubscription != null) {
      await bestEffort('frames', frameSubscription.cancel);
    }
    if (transcriptSubscription != null) {
      await bestEffort('transcripts', transcriptSubscription.cancel);
    }
    for (final subscription in diagnosticSubscriptions) {
      await bestEffort('diagnostics', subscription.cancel);
    }
    await bestEffort('input', _input.stop);
    await bestEffort('stt', _stt.stop);
    await bestEffort('tts', _synthesizer.stop);
    final captions = _captions;
    if (session != null && captions != null) {
      await bestEffort('captions', () => captions.clear(session));
    }
    return failed;
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
    String? detail,
  }) {
    if (!_diagnostics.isClosed) {
      _diagnostics.add(LiveTranslationDiagnostic(
        code: code,
        component: component,
        observedAtMicros: _nowMicros,
        sequence: sequence,
        detail: detail,
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
