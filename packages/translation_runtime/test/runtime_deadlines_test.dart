import 'dart:async';

import 'package:persalone_contracts/persalone_contracts.dart';
import 'package:persalone_translation_runtime/persalone_translation_runtime.dart';
import 'package:test/test.dart';

// A component that never answers must not stall a session, Stop or Panic.
// Every fake below can hang any call forever; the runtime must stop waiting
// at its deadline, keep running the other safety actions, report the cause,
// and ignore the late result if it ever arrives.
const Duration _limit = Duration(milliseconds: 40);
const RuntimeDeadlines _deadlines = RuntimeDeadlines(
  prepare: _limit,
  inputStart: _limit,
  translate: _limit,
  caption: _limit,
  speak: _limit,
  cleanup: _limit,
);

void main() {
  late _Rig r;

  setUp(() => r = _Rig());
  tearDown(() => r.dispose());

  group('Panic and Stop are bounded', () {
    test('a TTS stop that never returns: Panic still stops mic, STT, display',
        () async {
      await r.listen();
      r.tts.hang.add('stop');

      final Stopwatch clock = Stopwatch()..start();
      final List<String> failed = await r.runtime.panic();
      clock.stop();

      expect(failed, <String>['tts']);
      expect(r.input.running, isFalse);
      expect(r.stt.stopCalls, greaterThan(0));
      expect(r.captions.cleared, 1);
      expect(r.runtime.state, HorizonTranslationRuntimeState.stopped);
      expect(clock.elapsed, lessThan(const Duration(seconds: 2)));
      await r.settle();
      expect(r.deadline('tts', 'cleanup'), isTrue);
      expect(r.codes, contains(LiveTranslationDiagnosticCode.cleanupFailed));
    });

    test('every component hung: Panic returns within its summed bound',
        () async {
      await r.listen();
      r.input.hang.add('stop');
      r.stt.hang.add('stop');
      r.tts.hang.add('stop');
      r.captions.hang.add('clear');

      final Stopwatch clock = Stopwatch()..start();
      final List<String> failed = await r.runtime.panic();
      clock.stop();

      expect(failed, containsAll(<String>['input', 'stt', 'tts', 'captions']));
      expect(r.runtime.state, HorizonTranslationRuntimeState.stopped);
      expect(clock.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('a hung microphone stop: Stop completes and the rest still stops',
        () async {
      await r.listen();
      r.input.hang.add('stop');

      await r.runtime.stop();

      expect(r.runtime.state, HorizonTranslationRuntimeState.stopped);
      expect(r.stt.stopCalls, greaterThan(0));
      expect(r.tts.stopCalls, greaterThan(0));
      expect(r.captions.cleared, 1);
      await r.settle();
      expect(r.deadline('input', 'cleanup'), isTrue);
      expect(
          r.diagnostics.where((d) =>
              d.code == LiveTranslationDiagnosticCode.cleanupFailed &&
              d.detail == 'input'),
          isNotEmpty);
    });

    test('a throwing component during Stop no longer skips the others',
        () async {
      await r.listen();
      r.input.throwOnStop = true;

      await r.runtime.stop();

      expect(r.runtime.state, HorizonTranslationRuntimeState.stopped);
      expect(r.stt.stopCalls, greaterThan(0));
      expect(r.tts.stopCalls, greaterThan(0));
      expect(r.captions.cleared, 1);
    });

    test('dispose: a provider that never returns cannot keep the others alive',
        () async {
      r.translator.hang.add('dispose');
      unawaited(r.runtime.dispose());
      await r.until(() =>
          r.runtime.state == HorizonTranslationRuntimeState.disposed &&
          r.stt.disposeCalls == 1 &&
          r.tts.disposeCalls == 1);
    });
  });

  group('session calls are bounded', () {
    for (final (String who, String what) in <(String, String)>[
      ('stt', 'prepare'),
      ('translation', 'prepare'),
      ('tts', 'prepare'),
      ('input', 'start'),
    ]) {
      test('$who $what never returns: start fails, nothing keeps listening',
          () async {
        r.component(who).hang.add(what);

        await expectLater(r.start(), throwsA(anything));

        expect(r.runtime.state, HorizonTranslationRuntimeState.failed);
        expect(r.snapshots.last.failureCode,
            RuntimeErrorCode.providerUnavailable);
        expect(r.deadline(who, what), isTrue);
        expect(r.input.running, isFalse);
      });
    }

    test('a late prepare completion never resurrects the session', () async {
      final Completer<void> late = Completer<void>();
      r.stt.prepareGate = late;
      await expectLater(r.start(), throwsA(anything));
      late.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(r.runtime.state, HorizonTranslationRuntimeState.failed);
      expect(r.input.startCalls, 0);
    });

    test('a translation that never returns fails the session; its late '
        'result is never shown or spoken', () async {
      await r.listen();
      final Completer<void> late = Completer<void>();
      r.translator.translateGate = late;
      r.finalTurn(1);
      await r.until(
          () => r.runtime.state == HorizonTranslationRuntimeState.failed);

      expect(r.deadline('translation', 'translate'), isTrue);
      expect(r.input.running, isFalse);
      late.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(r.captions.shown, isEmpty);
      expect(r.tts.spoken, isEmpty);
    });

    test('a caption that never renders is a failed delivery; speech goes on',
        () async {
      await r.listen();
      r.captions.hang.add('show');
      final List<CaptionDelivery> deliveries = <CaptionDelivery>[];
      final StreamSubscription<CaptionDelivery> sub =
          r.runtime.captionDeliveries.listen(deliveries.add);
      addTearDown(sub.cancel);

      r.finalTurn(1);
      await r.until(() => r.tts.spoken.isNotEmpty);

      expect(deliveries.single.status, CaptionDeliveryStatus.failed);
      expect(deliveries.single.reason, 'deadlineExceeded');
      expect(r.deadline('caption', 'show'), isTrue);
      expect(r.runtime.state, HorizonTranslationRuntimeState.listening);
    });

    test('a caption finishing after Panic is cleared within its deadline',
        () async {
      await r.listen();
      final Completer<void> rendering = Completer<void>();
      r.captions.showGate = rendering;
      r.finalTurn(1);
      await r.until(() => r.captions.showStarted == 1);
      r.captions.hang.add('clear');

      await r.runtime.panic();
      rendering.complete();

      // The late caption is from a closed session: the runtime tries to clear
      // it, and a display that never answers does not hold the turn forever.
      await r.until(() => r.deadline('caption', 'clear'));
      expect(r.tts.spoken, isEmpty);
    });

    test('a speak call that never returns fails the session', () async {
      await r.listen();
      r.tts.hang.add('speak');
      r.finalTurn(1);
      await r.until(
          () => r.runtime.state == HorizonTranslationRuntimeState.failed);
      expect(r.deadline('tts', 'speak'), isTrue);
      expect(r.input.running, isFalse);
    });

    test('a barge-in stop that never returns fails the session', () async {
      await r.listen();
      r.tts.hang.add('stop');
      r.finalTurn(1);
      await r.until(
          () => r.runtime.state == HorizonTranslationRuntimeState.failed);
      expect(r.deadline('tts', 'stop'), isTrue);
      expect(r.translator.started, 0);
    });
  });

  test('default deadlines are finite and cleanup stays short', () {
    const RuntimeDeadlines defaults = RuntimeDeadlines();
    for (final Duration d in <Duration>[
      defaults.prepare,
      defaults.inputStart,
      defaults.translate,
      defaults.caption,
      defaults.speak,
      defaults.cleanup,
    ]) {
      expect(d, greaterThan(Duration.zero));
    }
    expect(defaults.cleanup, lessThanOrEqualTo(const Duration(seconds: 5)),
        reason: 'Panic waits at most one cleanup deadline per component');
  });
}

final class _Rig {
  _Rig() {
    runtime = HorizonTranslationRuntime(
      input: input,
      stt: stt,
      translator: translator,
      synthesizer: tts,
      captions: captions,
      deadlines: _deadlines,
    );
    _diagnosticSub = runtime.diagnostics.listen(diagnostics.add);
    _snapshotSub = runtime.snapshots.listen(snapshots.add);
  }

  final _Input input = _Input();
  final _Stt stt = _Stt();
  final _Translator translator = _Translator();
  final _Tts tts = _Tts();
  final _Captions captions = _Captions();
  late final HorizonTranslationRuntime runtime;
  final List<LiveTranslationDiagnostic> diagnostics =
      <LiveTranslationDiagnostic>[];
  final List<HorizonTranslationRuntimeSnapshot> snapshots =
      <HorizonTranslationRuntimeSnapshot>[];
  late final StreamSubscription<LiveTranslationDiagnostic> _diagnosticSub;
  late final StreamSubscription<HorizonTranslationRuntimeSnapshot>
      _snapshotSub;

  Iterable<LiveTranslationDiagnosticCode> get codes =>
      diagnostics.map((LiveTranslationDiagnostic d) => d.code);

  bool deadline(String component, String operation) => diagnostics.any(
      (LiveTranslationDiagnostic d) =>
          d.code == LiveTranslationDiagnosticCode.deadlineExceeded &&
          d.component == component &&
          d.detail == operation);

  _Hangs component(String name) => switch (name) {
        'stt' => stt,
        'translation' => translator,
        'tts' => tts,
        'input' => input,
        _ => captions,
      };

  Future<void> start() => runtime.start(
        config: _config,
        audioSession: const AudioSessionDescriptor(
            sessionId: 'deadline-session', streamEpoch: 1, streamId: 'in'),
      );

  Future<void> listen() async {
    await start();
    expect(runtime.state, HorizonTranslationRuntimeState.listening);
  }

  void finalTurn(int sequence) => stt.controller.add(TranscriptSegment(
        session: _config.session,
        sequence: sequence,
        text: 'private words',
        stability: TranscriptStability.finalResult,
        observedAtMicros: sequence,
        truthLabel: TruthLabel.simulated,
      ));

  /// Diagnostics are delivered asynchronously on a broadcast stream.
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 10));

  Future<void> until(bool Function() condition) async {
    final DateTime end = DateTime.now().add(const Duration(seconds: 5));
    while (!condition()) {
      if (DateTime.now().isAfter(end)) fail('condition not reached');
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }

  Future<void> dispose() async {
    for (final _Hangs c in <_Hangs>[input, stt, translator, tts, captions]) {
      c.hang.clear();
    }
    input.throwOnStop = false;
    await runtime.dispose();
    await _diagnosticSub.cancel();
    await _snapshotSub.cancel();
  }
}

const LiveTranslationConfig _config = LiveTranslationConfig(
  session: TranslationSession(
    sessionId: 'deadline-session',
    streamEpoch: 1,
    direction: TranslationDirection.englishToSpanish,
    privacyGeneration: 1,
  ),
  sourceLocale: 'en-US',
  targetLocale: 'es-ES',
  consent: TranslationConsent(
    acceptedAtMicros: 1,
    localProcessingAllowed: true,
    modelDownloadAllowed: false,
    remoteProcessingAllowed: false,
  ),
);

/// Calls listed in [hang] never complete.
mixin _Hangs {
  final Set<String> hang = <String>{};

  Future<void> gate(String call) async {
    if (hang.contains(call)) await Completer<void>().future;
  }
}

final class _Input with _Hangs implements AudioInputAdapter {
  final StreamController<AudioFrame> controller =
      StreamController<AudioFrame>.broadcast();
  bool running = false;
  bool throwOnStop = false;
  int startCalls = 0;

  @override
  String get adapterId => 'deadline-input';
  @override
  String get sourceRevision => 'test';
  @override
  Stream<AudioFrame> get frames => controller.stream;
  @override
  Stream<AudioAdapterSnapshot> get snapshots => const Stream.empty();
  @override
  Stream<AudioDiagnostic> get diagnostics => const Stream.empty();
  @override
  Stream<AudioLatencyMeasurement> get latencyMeasurements =>
      const Stream.empty();
  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<void> start(AudioSessionDescriptor s, AudioFormat f) async {
    startCalls++;
    await gate('start');
    running = true;
  }

  @override
  Future<void> stop() async {
    await gate('stop');
    if (throwOnStop) throw StateError('mic stop failed');
    running = false;
  }

  @override
  Future<void> dispose() async {}
}

final class _Stt with _Hangs implements StreamingSttProvider {
  final StreamController<TranscriptSegment> controller =
      StreamController<TranscriptSegment>.broadcast();
  Completer<void>? prepareGate;
  int stopCalls = 0;

  @override
  String get providerId => 'deadline-stt';
  @override
  String get sourceRevision => 'test';
  @override
  Stream<ProviderSnapshot> get snapshots => const Stream.empty();
  @override
  Stream<LiveTranslationDiagnostic> get diagnostics => const Stream.empty();
  @override
  Stream<TranscriptSegment> get transcripts => controller.stream;
  @override
  Future<void> prepare(LiveTranslationConfig c, AudioFormat f) async {
    await gate('prepare');
    await prepareGate?.future;
  }

  @override
  Future<void> push(AudioFrame frame) async {}
  @override
  Future<void> stop() async {
    stopCalls++;
    await gate('stop');
  }

  int disposeCalls = 0;

  @override
  Future<void> dispose() {
    disposeCalls++;
    return gate('dispose');
  }
}

final class _Translator with _Hangs implements TextTranslationProvider {
  Completer<void>? translateGate;
  int started = 0;

  @override
  String get providerId => 'deadline-translator';
  @override
  String get sourceRevision => 'test';
  @override
  Stream<ProviderSnapshot> get snapshots => const Stream.empty();
  @override
  Stream<LiveTranslationDiagnostic> get diagnostics => const Stream.empty();
  @override
  Future<void> prepare(LiveTranslationConfig c) => gate('prepare');
  @override
  Future<TranslationSegment> translate(TranscriptSegment t) async {
    started++;
    await gate('translate');
    await translateGate?.future;
    return TranslationSegment(
      session: t.session,
      sequence: t.sequence,
      sourceText: t.text,
      translatedText: 'palabras privadas',
      observedAtMicros: t.observedAtMicros,
      truthLabel: TruthLabel.simulated,
    );
  }

  @override
  Future<void> dispose() => gate('dispose');
}

final class _Tts with _Hangs implements SpeechSynthesisProvider {
  final List<TranslationSegment> spoken = <TranslationSegment>[];
  int stopCalls = 0;

  @override
  String get providerId => 'deadline-tts';
  @override
  String get sourceRevision => 'test';
  @override
  Stream<ProviderSnapshot> get snapshots => const Stream.empty();
  @override
  Stream<LiveTranslationDiagnostic> get diagnostics => const Stream.empty();
  @override
  Future<void> prepare(LiveTranslationConfig c) => gate('prepare');
  @override
  Future<void> speak(TranslationSegment segment) async {
    await gate('speak');
    spoken.add(segment);
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    await gate('stop');
  }

  int disposeCalls = 0;

  @override
  Future<void> dispose() {
    disposeCalls++;
    return gate('dispose');
  }
}

final class _Captions with _Hangs implements CaptionOutputAdapter {
  final List<CaptionUpdate> shown = <CaptionUpdate>[];
  Completer<void>? showGate;
  int showStarted = 0;
  int cleared = 0;

  @override
  String get adapterId => 'deadline-captions';
  @override
  ExecutionEnvironment get environment => ExecutionEnvironment.simulated;
  @override
  Future<CaptionDelivery> show(CaptionUpdate update) async {
    showStarted++;
    await gate('show');
    await showGate?.future;
    shown.add(update);
    return CaptionDelivery(
      session: update.session,
      sequence: update.sequence,
      status: CaptionDeliveryStatus.delivered,
      environment: environment,
      truthLabel: TruthLabel.simulated,
      adapterId: adapterId,
    );
  }

  @override
  Future<void> clear(TranslationSession session) async {
    await gate('clear');
    cleared++;
  }
}
