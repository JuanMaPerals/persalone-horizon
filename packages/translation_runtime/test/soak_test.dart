import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:persalone_contracts/persalone_contracts.dart';
import 'package:persalone_translation_runtime/persalone_translation_runtime.dart';
import 'package:test/test.dart';

// Soak: many sessions and reconnects, checking that nothing accumulates
// (subscriptions, clients, memory) and that ordering guarantees hold under
// churn. HORIZON_SOAK_CYCLES raises the iteration count for long local runs.
final int _cycles =
    int.tryParse(Platform.environment['HORIZON_SOAK_CYCLES'] ?? '') ?? 200;

void main() {
  test('runtime lifecycle soak: start/turns/stop|panic leaves nothing behind',
      () async {
    final _Providers p = _Providers();
    final HorizonTranslationRuntime runtime = HorizonTranslationRuntime(
      input: p.input,
      stt: p.stt,
      translator: p.translator,
      synthesizer: p.tts,
      captions: p.captions,
    );
    final HorizonRuntimeController controller =
        HorizonRuntimeController(runtime: runtime);
    final List<CaptionDelivery> deliveries = <CaptionDelivery>[];
    final List<TurnLatencySample> latencies = <TurnLatencySample>[];
    final StreamSubscription<CaptionDelivery> deliveriesSub =
        runtime.captionDeliveries.listen(deliveries.add);
    final StreamSubscription<TurnLatencySample> latencySub =
        runtime.latencies.listen(latencies.add);

    int accepted = 0;
    int panics = 0;
    int stops = 0;
    int lateTurns = 0;
    int? rssAfterWarmup;
    final Map<String, int> failures = <String, int>{};
    void failure(String code) => failures[code] = (failures[code] ?? 0) + 1;

    for (int cycle = 1; cycle <= _cycles; cycle++) {
      final CommandResult start = await controller.execute(StartCommand(
        commandId: 'start-$cycle',
        origin: ControlOrigin.local,
        consent: _consent,
      ));
      if (start.status != CommandStatus.accepted) {
        failure('startRejected');
        continue;
      }
      accepted++;
      final String session = controller.activeSessionId!;
      final int epoch = p.input.lastEpoch!;
      p.captions.failEvery = cycle % 5 == 0;
      for (int turn = 1; turn <= 3; turn++) {
        p.stt.finalTurn(session, epoch, turn);
        await _drain();
      }
      // Every third cycle ends while a translation is still in flight.
      Completer<void>? gate;
      if (cycle % 3 == 0) {
        gate = Completer<void>();
        p.translator.gates[4] = gate;
        p.stt.finalTurn(session, epoch, 4);
        await _drain();
      }
      final CommandResult end = cycle.isEven
          ? await controller.execute(PanicCommand(
              commandId: 'panic-$cycle', origin: ControlOrigin.local))
          : await controller.execute(StopCommand(
              commandId: 'stop-$cycle',
              origin: ControlOrigin.local,
              sessionId: session));
      cycle.isEven ? panics++ : stops++;
      if (end.status != CommandStatus.accepted) failure('endRejected');
      if (gate != null) {
        final int before = deliveries.length;
        gate.complete();
        p.translator.gates.remove(4);
        await _drain();
        if (deliveries.length != before) failure('lateCaptionShown');
        lateTurns++;
      }
      if (p.input.listeners != 0) failure('inputListenerLeak');
      if (p.stt.listeners != 0) failure('sttListenerLeak');
      if (controller.activeSessionId != null) failure('sessionStillActive');
      if (cycle == 20) rssAfterWarmup = ProcessInfo.currentRss;
    }
    final int rssEnd = ProcessInfo.currentRss;
    await deliveriesSub.cancel();
    await latencySub.cancel();
    await controller.dispose();
    await runtime.dispose();

    final int growthMb = ((rssEnd - (rssAfterWarmup ?? rssEnd)) / 1048576).round();
    // ignore: avoid_print
    print('SOAK_RUNTIME ${jsonEncode(<String, Object?>{
          'cycles': _cycles,
          'accepted': accepted,
          'stops': stops,
          'panics': panics,
          'lateTurnsDiscarded': lateTurns,
          'captions': deliveries.length,
          'latencySamples': latencies.length,
          'failures': failures,
          'rssGrowthAfterWarmupMb': growthMb,
        })}');
    expect(failures, isEmpty);
    expect(accepted, _cycles);
    expect(controller.sessionGeneration, _cycles);
    expect(p.input.maxListeners, 1, reason: 'never two frame subscriptions');
    expect(p.stt.maxListeners, 1, reason: 'never two transcript subscriptions');
    expect(growthMb, lessThan(64), reason: 'memory must not grow per session');
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('SSE soak: reconnect storm with resume has no gaps or duplicates',
      () async {
    final StreamController<RuntimeEvent> events =
        StreamController<RuntimeEvent>.broadcast(sync: true);
    final RuntimeEventServer server = await RuntimeEventServer.start(
      events.stream,
      heartbeat: const Duration(milliseconds: 20),
      replayCapacity: 4096,
      clientQueueLimit: 512,
    );
    int seq = 0;
    void emit(int count) {
      for (int i = 0; i < count; i++) {
        events.add(RuntimeEvent.sessionState(
          streamSequence: ++seq,
          observedAtMicros: seq,
          state: RuntimeSessionState.listening,
          sessionId: 'soak',
          streamEpoch: 1,
        ));
      }
    }

    final HttpClient http = HttpClient();
    final List<int> received = <int>[];
    String? lastEventId;
    int resets = 0;
    int fulls = 0;
    int maxReleaseMs = 0;
    final int reconnects = _cycles;
    for (int cycle = 0; cycle < reconnects; cycle++) {
      emit(3); // produced while no client is connected
      final HttpClientRequest request = await http.getUrl(server.uri);
      request.headers.set('accept', 'text/event-stream');
      if (lastEventId != null) request.headers.set('last-event-id', lastEventId);
      final HttpClientResponse response = await request.close();
      final StreamIterator<String> lines = StreamIterator<String>(response
          .transform(utf8.decoder)
          .transform(const LineSplitter()));
      String? event;
      String? id;
      bool helloSeen = false;
      int target = seq + 2;
      bool emittedLive = false;
      while (await lines.moveNext()) {
        final String line = lines.current;
        if (line.startsWith('event: ')) event = line.substring(7);
        if (line.startsWith('id: ')) id = line.substring(4);
        if (line.startsWith('data: ') && event == 'hello') {
          helloSeen = true;
          final Map<String, Object?> hello =
              jsonDecode(line.substring(6)) as Map<String, Object?>;
          if (hello['replay'] == 'reset') resets++;
          if (hello['replay'] == 'full') fulls++;
        }
        if (line.startsWith('data: ') && event == 'runtime') {
          final int s = (jsonDecode(line.substring(6))
              as Map<String, Object?>)['seq']! as int;
          received.add(s);
          lastEventId = id;
          if (!emittedLive && s == seq) {
            emittedLive = true;
            emit(2); // live frames while connected
          }
          if (s >= target && emittedLive) break;
        }
        if (line.isEmpty) event = null;
      }
      expect(helloSeen, isTrue,
          reason: 'cycle $cycle status ${response.statusCode} '
              'clients ${server.clientCount}');
      await lines.cancel(); // abrupt client disconnect
      // A dead peer is only noticed when a write fails (next heartbeat), so
      // its slot is held briefly; it must be released, never leaked.
      final Stopwatch release = Stopwatch()..start();
      await _eventually(() => server.clientCount == 0);
      if (release.elapsedMilliseconds > maxReleaseMs) {
        maxReleaseMs = release.elapsedMilliseconds;
      }
    }
    await _eventually(() => server.clientCount == 0);
    http.close(force: true);
    await server.close();
    await events.close();

    final Set<int> unique = received.toSet();
    // ignore: avoid_print
    print('SOAK_SSE ${jsonEncode(<String, Object?>{
          'reconnects': reconnects,
          'eventsEmitted': seq,
          'eventsReceived': received.length,
          'duplicates': received.length - unique.length,
          'resets': resets,
          'fullReplays': fulls,
          'maxSlotReleaseMs': maxReleaseMs,
        })}');
    expect(received.length, unique.length, reason: 'no duplicate on resume');
    expect(unique, List<int>.generate(seq, (int i) => i + 1).toSet(),
        reason: 'no gap across reconnects');
    expect(fulls, 1, reason: 'only the first connection starts from scratch');
    expect(resets, 0, reason: 'every reconnect resumes inside the window');
    expect(maxReleaseMs, lessThan(1000),
        reason: 'a dead client frees its slot within a few heartbeats');
  }, timeout: const Timeout(Duration(minutes: 10)));
}

Future<void> _drain() async {
  for (int i = 0; i < 12; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> _eventually(bool Function() condition) async {
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('condition not reached');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

const TranslationConsent _consent = TranslationConsent(
  acceptedAtMicros: 1,
  localProcessingAllowed: true,
  modelDownloadAllowed: false,
  remoteProcessingAllowed: false,
);

final class _Providers {
  final _Input input = _Input();
  final _Stt stt = _Stt();
  final _Translator translator = _Translator();
  final _Tts tts = _Tts();
  final _Captions captions = _Captions();
}

final class _Input implements AudioInputAdapter {
  _Input() {
    _frames = StreamController<AudioFrame>.broadcast(
      onListen: () {
        listeners++;
        if (listeners > maxListeners) maxListeners = listeners;
      },
      onCancel: () => listeners--,
    );
  }
  late final StreamController<AudioFrame> _frames;
  int listeners = 0;
  int maxListeners = 0;
  int? lastEpoch;
  @override
  String get adapterId => 'soak-input';
  @override
  String get sourceRevision => 'soak';
  @override
  Stream<AudioFrame> get frames => _frames.stream;
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
  Future<void> start(AudioSessionDescriptor s, AudioFormat f) async =>
      lastEpoch = s.streamEpoch;
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

final class _Stt implements StreamingSttProvider {
  _Stt() {
    _transcripts = StreamController<TranscriptSegment>.broadcast(
      onListen: () {
        listeners++;
        if (listeners > maxListeners) maxListeners = listeners;
      },
      onCancel: () => listeners--,
    );
  }
  late final StreamController<TranscriptSegment> _transcripts;
  int listeners = 0;
  int maxListeners = 0;
  LiveTranslationConfig? _config;

  void finalTurn(String sessionId, int epoch, int sequence) {
    final LiveTranslationConfig? config = _config;
    if (config == null) return;
    _transcripts.add(TranscriptSegment(
      session: config.session,
      sequence: sequence,
      text: 'soak turn $sequence',
      stability: TranscriptStability.finalResult,
      observedAtMicros: sequence,
      truthLabel: TruthLabel.simulated,
    ));
  }

  @override
  Stream<TranscriptSegment> get transcripts => _transcripts.stream;
  @override
  String get providerId => 'soak-stt';
  @override
  String get sourceRevision => 'soak';
  @override
  Stream<ProviderSnapshot> get snapshots => const Stream.empty();
  @override
  Stream<LiveTranslationDiagnostic> get diagnostics => const Stream.empty();
  @override
  Future<void> prepare(LiveTranslationConfig c, AudioFormat f) async =>
      _config = c;
  @override
  Future<void> push(AudioFrame frame) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

final class _Translator implements TextTranslationProvider {
  final Map<int, Completer<void>> gates = <int, Completer<void>>{};
  @override
  String get providerId => 'soak-translator';
  @override
  String get sourceRevision => 'soak';
  @override
  Stream<ProviderSnapshot> get snapshots => const Stream.empty();
  @override
  Stream<LiveTranslationDiagnostic> get diagnostics => const Stream.empty();
  @override
  Future<void> prepare(LiveTranslationConfig c) async {}
  @override
  Future<TranslationSegment> translate(TranscriptSegment t) async {
    await gates[t.sequence]?.future;
    return TranslationSegment(
      session: t.session,
      sequence: t.sequence,
      sourceText: t.text,
      translatedText: 'traducido ${t.sequence}',
      observedAtMicros: t.observedAtMicros,
      truthLabel: TruthLabel.simulated,
    );
  }

  @override
  Future<void> dispose() async {}
}

final class _Tts implements SpeechSynthesisProvider {
  @override
  String get providerId => 'soak-tts';
  @override
  String get sourceRevision => 'soak';
  @override
  Stream<ProviderSnapshot> get snapshots => const Stream.empty();
  @override
  Stream<LiveTranslationDiagnostic> get diagnostics => const Stream.empty();
  @override
  Future<void> prepare(LiveTranslationConfig c) async {}
  @override
  Future<void> speak(TranslationSegment s) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

final class _Captions implements CaptionOutputAdapter {
  bool failEvery = false;
  @override
  String get adapterId => 'soak-captions';
  @override
  ExecutionEnvironment get environment => ExecutionEnvironment.simulated;
  @override
  Future<CaptionDelivery> show(CaptionUpdate update) async {
    if (failEvery && update.sequence == 2) {
      throw StateError('display unavailable');
    }
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
  Future<void> clear(TranslationSession session) async {}
}
