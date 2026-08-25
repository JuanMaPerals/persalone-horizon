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

/// Terminal evidence for the high-level owner. It deliberately omits session
/// identifiers, PCM, transcripts, translations, device IDs, provider detail and
/// credentials.
final class HorizonTranslationRuntimeTerminalEvent {
  const HorizonTranslationRuntimeTerminalEvent({
    required this.startGeneration,
    required this.failureCode,
  });

  final int startGeneration;
  final RuntimeErrorCode failureCode;
}

/// A redacted runtime snapshot for UI and evidence. It intentionally excludes
/// PCM, transcripts, translations, device IDs and provider credentials.
final class HorizonTranslationRuntimeSnapshot {
  const HorizonTranslationRuntimeSnapshot({
    required this.state,
    required this.sessionId,
    required this.streamEpoch,
    required this.turnGeneration,
    required this.observedAtMicros,
    this.failureCode,
  });

  final HorizonTranslationRuntimeState state;
  final String? sessionId;
  final int? streamEpoch;
  final int? turnGeneration;
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
  final StreamController<HorizonTranslationRuntimeTerminalEvent>
      _terminalEvents =
      StreamController<HorizonTranslationRuntimeTerminalEvent>.broadcast();

  StreamSubscription<AudioFrame>? _frameSubscription;
  StreamSubscription<TranscriptSegment>? _transcriptSubscription;
  final List<StreamSubscription<LiveTranslationDiagnostic>>
      _providerDiagnosticSubscriptions = [];
  HorizonTranslationRuntimeState _state = HorizonTranslationRuntimeState.idle;
  LiveTranslationConfig? _config;
  int _nextTurnGeneration = 0;
  int? _ownerStartGeneration;
  Future<void>? _terminalFuture;
  bool _terminal = false;
  bool _disposed = false;

  Stream<HorizonTranslationRuntimeSnapshot> get snapshots => _snapshots.stream;
  Stream<LiveTranslationDiagnostic> get diagnostics => _diagnostics.stream;
  Stream<TranscriptSegment> get transcripts => _transcripts.stream;
  Stream<TranslationSegment> get translations => _translations.stream;
  Stream<HorizonTranslationRuntimeTerminalEvent> get terminalEvents =>
      _terminalEvents.stream;
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

    final activeConfig = _withTurn(
      config,
      _advanceGenerationFrom(config.session.turnGeneration),
    );
    _terminal = false;
    _terminalFuture = null;
    _ownerStartGeneration = config.session.turnGeneration;
    _config = activeConfig;
    final token = activeConfig.session.executionToken;
    _setState(HorizonTranslationRuntimeState.preparing);
    _bindProviderDiagnostics(token);
    try {
      await _stt.prepare(activeConfig, format);
      _assertCurrent(token);
      await _translator.prepare(activeConfig);
      _assertCurrent(token);
      await _synthesizer.prepare(activeConfig);
      _assertCurrent(token);

      final permissionGranted = await _input.requestPermission();
      _assertCurrent(token);
      if (!permissionGranted) {
        throw const RuntimeError(
          RuntimeErrorCode.policyDenied,
          'Microphone permission was not granted for this session.',
        );
      }

      _transcriptSubscription = _stt.transcripts.listen(
        (segment) {
          unawaited(_onTranscript(segment));
        },
        onError: (Object error, StackTrace stackTrace) {
          unawaited(_fail(error, stackTrace));
        },
      );
      await _input.start(audioSession, format);
      _assertCurrent(token);
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
      await _fail(error, stackTrace);
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
    if (_state == HorizonTranslationRuntimeState.failed) {
      await _terminalFuture;
      return;
    }
    await _terminate(HorizonTranslationRuntimeState.stopped);
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
    await _terminalEvents.close();
    _state = HorizonTranslationRuntimeState.disposed;
  }

  Future<void> _onFrame(AudioFrame frame) async {
    final config = _config;
    if (config == null) {
      _discardStale('runtime', frame.sequence);
      return;
    }
    final token = config.session.executionToken;
    if (!_isCurrent(token)) {
      _discardStale('runtime', frame.sequence, token: token);
      return;
    }
    if (frame.direction != AudioDirection.input ||
        frame.session.sessionId != token.sessionId ||
        frame.session.streamEpoch != token.streamEpoch) {
      _emitDiagnostic(
        LiveTranslationDiagnosticCode.frameRejected,
        component: 'runtime',
        sequence: frame.sequence,
        turnGeneration: token.turnGeneration,
      );
      return;
    }
    try {
      await _stt.push(frame);
      if (!_isCurrent(token)) {
        _discardStale('runtime', frame.sequence, token: token);
      }
    } on Object catch (error, stackTrace) {
      if (_isCurrent(token)) {
        await _fail(error, stackTrace);
      } else {
        _discardStale('runtime', frame.sequence, token: token);
      }
    }
  }

  Future<void> _onTranscript(TranscriptSegment segment) async {
    final config = _config;
    if (config == null ||
        !_matchesSessionBase(segment.session, config.session)) {
      _discardStale('stt', segment.sequence);
      return;
    }

    final token = segment.stability == TranscriptStability.finalResult &&
            segment.text.trim().isNotEmpty
        ? _advanceTurn()
        : config.session.executionToken;
    try {
      if (segment.stability == TranscriptStability.finalResult &&
          segment.text.trim().isNotEmpty) {
        await _stt.beginTurn(token);
        if (!_isCurrent(token)) {
          _discardStale('stt', segment.sequence, token: token);
          return;
        }
      }
      final capturedSegment = _withToken(segment, token);
      _transcripts.add(capturedSegment);
      _emitDiagnostic(
        capturedSegment.stability == TranscriptStability.partial
            ? LiveTranslationDiagnosticCode.transcriptPartial
            : LiveTranslationDiagnosticCode.transcriptFinal,
        component: 'stt',
        sequence: capturedSegment.sequence,
        turnGeneration: token.turnGeneration,
      );
      if (capturedSegment.stability == TranscriptStability.finalResult &&
          capturedSegment.text.trim().isNotEmpty) {
        unawaited(_translateAndSpeak(capturedSegment, token));
      }
    } on Object catch (error, stackTrace) {
      if (_isCurrent(token)) {
        await _fail(error, stackTrace);
      } else {
        _discardStale('stt', segment.sequence, token: token);
      }
    }
  }

  Future<void> _translateAndSpeak(
    TranscriptSegment transcript,
    TranslationExecutionToken token,
  ) async {
    if (!_isCurrent(token)) {
      _discardStale('runtime', transcript.sequence, token: token);
      return;
    }
    try {
      // A new accepted final increments [turnGeneration] before this await, so
      // all work for an earlier turn becomes stale before it can speak.
      await _synthesizer.stop();
      if (!_isCurrent(token)) {
        _discardStale('tts', transcript.sequence, token: token);
        return;
      }
      final translation = await _translator.translate(transcript);
      if (!_isCurrent(token) ||
          !translation.session.executionToken.matches(token)) {
        _discardStale('translation', transcript.sequence, token: token);
        return;
      }
      _translations.add(translation);
      _emitDiagnostic(
        LiveTranslationDiagnosticCode.translationCompleted,
        component: 'translation',
        sequence: translation.sequence,
        turnGeneration: token.turnGeneration,
      );
      if (!_isCurrent(token)) {
        _discardStale('tts', translation.sequence, token: token);
        return;
      }
      await _synthesizer.speak(translation);
      if (!_isCurrent(token)) {
        _discardStale('tts', translation.sequence, token: token);
        return;
      }
      // Completion is emitted only by the platform TTS progress callback. A
      // successful speak call merely confirms that Android accepted the queue.
    } on Object catch (error, stackTrace) {
      if (_isCurrent(token)) {
        _emitDiagnostic(
          LiveTranslationDiagnosticCode.synthesisFailed,
          component: 'runtime',
          sequence: transcript.sequence,
          turnGeneration: token.turnGeneration,
        );
        await _fail(error, stackTrace);
      } else {
        _discardStale('runtime', transcript.sequence, token: token);
      }
    }
  }

  Future<void> _terminate(
    HorizonTranslationRuntimeState terminalState, {
    RuntimeErrorCode? failureCode,
  }) {
    final inFlight = _terminalFuture;
    if (inFlight != null) {
      return inFlight;
    }

    _terminal = true;
    _setState(HorizonTranslationRuntimeState.stopping);
    _invalidateActiveTurn();
    _terminalFuture = _runTerminalTeardown(
      terminalState: terminalState,
      failureCode: failureCode,
    );
    return _terminalFuture!;
  }

  Future<void> _runTerminalTeardown({
    required HorizonTranslationRuntimeState terminalState,
    RuntimeErrorCode? failureCode,
  }) async {
    var secondaryFailures = 0;

    Future<void> attempt(Future<void> Function() action) async {
      try {
        await action();
      } on Object {
        secondaryFailures += 1;
      }
    }

    final frameSubscription = _frameSubscription;
    _frameSubscription = null;
    final transcriptSubscription = _transcriptSubscription;
    _transcriptSubscription = null;
    final diagnosticSubscriptions =
        List<StreamSubscription<LiveTranslationDiagnostic>>.of(
      _providerDiagnosticSubscriptions,
    );
    _providerDiagnosticSubscriptions.clear();

    if (frameSubscription != null) {
      await attempt(frameSubscription.cancel);
    }
    if (transcriptSubscription != null) {
      await attempt(transcriptSubscription.cancel);
    }
    for (final subscription in diagnosticSubscriptions) {
      await attempt(subscription.cancel);
    }
    await attempt(_input.stop);
    await attempt(_stt.stop);
    await attempt(_synthesizer.stop);

    if (secondaryFailures > 0) {
      _emitDiagnostic(
        LiveTranslationDiagnosticCode.terminalTeardownDegraded,
        component: 'runtime',
      );
    }
    if (!_disposed) {
      _setState(terminalState, failureCode: failureCode);
      if (terminalState == HorizonTranslationRuntimeState.failed &&
          failureCode != null &&
          _ownerStartGeneration != null &&
          !_terminalEvents.isClosed) {
        _terminalEvents.add(HorizonTranslationRuntimeTerminalEvent(
          startGeneration: _ownerStartGeneration!,
          failureCode: failureCode,
        ));
      }
    }
  }

  void _bindProviderDiagnostics(TranslationExecutionToken token) {
    if (_providerDiagnosticSubscriptions.isNotEmpty) {
      return;
    }
    for (final provider in [
      _stt.diagnostics,
      _translator.diagnostics,
      _synthesizer.diagnostics
    ]) {
      _providerDiagnosticSubscriptions.add(provider.listen(
        (diagnostic) {
          final current = _config?.session.executionToken;
          final isCurrent = current != null &&
              (diagnostic.turnGeneration != null
                  ? diagnostic.turnGeneration == current.turnGeneration
                  : current.matches(token));
          if (!isCurrent) {
            _discardStale(
              'provider',
              diagnostic.sequence ?? 0,
              token: token,
            );
            return;
          }
          _diagnostics.add(diagnostic);
        },
      ));
    }
  }

  bool _isCurrent(TranslationExecutionToken token) {
    final config = _config;
    return !_terminal &&
        config != null &&
        config.session.executionToken.matches(token);
  }

  bool _matchesSessionBase(
          TranslationSession first, TranslationSession second) =>
      first.sessionId == second.sessionId &&
      first.streamEpoch == second.streamEpoch &&
      first.privacyGeneration == second.privacyGeneration;

  void _assertCurrent(TranslationExecutionToken token) {
    if (!_isCurrent(token)) {
      throw const RuntimeError(
        RuntimeErrorCode.staleStreamEpoch,
        'A lifecycle operation completed after its execution token was inactive.',
      );
    }
  }

  TranslationExecutionToken _advanceTurn() {
    final config = _config;
    if (config == null) {
      throw const RuntimeError(
        RuntimeErrorCode.sessionClosed,
        'No active translation session can advance a turn.',
      );
    }
    final nextTurn = _advanceGenerationFrom(config.session.turnGeneration);
    _config = _withTurn(config, nextTurn);
    return _config!.session.executionToken;
  }

  void _invalidateActiveTurn() {
    final config = _config;
    if (config == null) {
      return;
    }
    _config = _withTurn(
      config,
      _advanceGenerationFrom(config.session.turnGeneration),
    );
    _config = null;
  }

  int _advanceGenerationFrom(int requestedGeneration) {
    _nextTurnGeneration = _nextTurnGeneration >= requestedGeneration
        ? _nextTurnGeneration + 1
        : requestedGeneration + 1;
    return _nextTurnGeneration;
  }

  LiveTranslationConfig _withTurn(LiveTranslationConfig config, int turn) =>
      LiveTranslationConfig(
        session: TranslationSession(
          sessionId: config.session.sessionId,
          streamEpoch: config.session.streamEpoch,
          direction: config.session.direction,
          privacyGeneration: config.session.privacyGeneration,
          turnGeneration: turn,
        ),
        sourceLocale: config.sourceLocale,
        targetLocale: config.targetLocale,
        consent: config.consent,
      );

  TranscriptSegment _withToken(
    TranscriptSegment segment,
    TranslationExecutionToken token,
  ) =>
      TranscriptSegment(
        session: TranslationSession(
          sessionId: token.sessionId,
          streamEpoch: token.streamEpoch,
          direction: segment.session.direction,
          privacyGeneration: token.privacyGeneration,
          turnGeneration: token.turnGeneration,
        ),
        sequence: segment.sequence,
        text: segment.text,
        stability: segment.stability,
        observedAtMicros: segment.observedAtMicros,
        truthLabel: segment.truthLabel,
        confidence: segment.confidence,
      );

  void _discardStale(
    String component,
    int sequence, {
    TranslationExecutionToken? token,
  }) {
    _emitDiagnostic(
      LiveTranslationDiagnosticCode.staleCallbackDiscarded,
      component: component,
      sequence: sequence,
      turnGeneration: token?.turnGeneration,
    );
  }

  Future<void> _fail(Object error, StackTrace stackTrace) async {
    if (_disposed) {
      return;
    }
    final errorCode = error is RuntimeError
        ? error.code
        : RuntimeErrorCode.providerUnavailable;
    await _terminate(
      HorizonTranslationRuntimeState.failed,
      failureCode: errorCode,
    );
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
        turnGeneration: config?.session.turnGeneration,
        observedAtMicros: _nowMicros,
        failureCode: failureCode,
      ));
    }
  }

  void _emitDiagnostic(
    LiveTranslationDiagnosticCode code, {
    required String component,
    int? sequence,
    int? turnGeneration,
  }) {
    if (!_diagnostics.isClosed) {
      _diagnostics.add(LiveTranslationDiagnostic(
        code: code,
        component: component,
        observedAtMicros: _nowMicros,
        sequence: sequence,
        turnGeneration: turnGeneration,
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
