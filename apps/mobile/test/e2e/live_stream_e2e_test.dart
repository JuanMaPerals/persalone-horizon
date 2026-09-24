import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:persalone_contracts/persalone_contracts.dart';
import 'package:persalone_halo_adapter/persalone_halo_adapter.dart';
import 'package:persalone_translation_runtime/persalone_translation_runtime.dart';

// LIVE_STREAM_E2E: real G5 runtime -> RuntimeEventStream -> RuntimeEventServer
// (SSE, loopback) -> TCP proxy (to cut the network) -> the Engineering
// Console's real RuntimeStreamClient running in Node. Providers and device
// are SIMULATED (ScriptedHaloFixture); nothing here is HALO_REAL.
final String? _node = Platform.environment['HORIZON_E2E_NODE'];
final bool _required = Platform.environment['HORIZON_E2E_REQUIRED'] == '1';

String? get _skip {
  if (_node != null || _required) return null;
  return 'LIVE_STREAM_E2E not configured: set HORIZON_E2E_NODE';
}

void main() {
  test('Console client follows the live runtime stream and fails closed',
      skip: _skip, () async {
    if (_node == null)
      fail('HORIZON_E2E_REQUIRED=1 but HORIZON_E2E_NODE unset');
    final _Proxy proxy = await _Proxy.start();
    final _Probe probe = await _Probe.start(_node!, proxy.url);
    _Rig? a;
    _Rig? b;
    try {
      // 1. Runtime unavailable.
      await probe.waitFor(
          (s) => s['connection'] == 'UNAVAILABLE', 'unavailable');

      // 2. Runtime A comes up: LIVE with device + session state.
      a = await _Rig.start('live-a');
      proxy.target(a.server.uri.port);
      await probe.waitFor(
          (s) =>
              s['connection'] == 'LIVE' &&
              s['sessionState'] == 'listening' &&
              s['deviceState'] == 'ready',
          'A live');
      final Map<String, Object?> liveA = probe.latest;
      expect(liveA['streamId'], a.server.streamId);
      expect(liveA['deviceEnvironment'], 'SIMULATED');
      expect(liveA['deviceTruth'], 'SIMULATED');

      // 3. Caption state arrives live.
      await a.finalTurn(1);
      await probe.waitFor((s) => _delivered(s) == 1, 'caption 1');
      expect(probe.latest['captionEnvironment'], 'SIMULATED');
      expect(probe.latest['captionTruth'], 'SIMULATED');

      // 4. Network cut: DISCONNECTED/UNAVAILABLE with UNKNOWN state; events
      //    produced meanwhile are replayed on reconnect without duplicates.
      proxy.cut();
      await probe.waitFor(
          (s) => s['connection'] != 'LIVE' && s['connection'] != 'CONNECTING',
          'cut');
      await a.finalTurn(2);
      proxy.target(a.server.uri.port);
      await probe.waitFor(
          (s) => s['connection'] == 'LIVE' && _delivered(s) == 2, 'resumed');
      expect(probe.latest['sequenceGaps'], 0);
      expect(probe.latest['degraded'], isFalse);

      // 5. Stale session: runtime A dies, runtime B replaces it.
      await a.close();
      a = null;
      b = await _Rig.start('live-b');
      proxy.target(b.server.uri.port);
      await probe.waitFor(
          (s) =>
              s['streamId'] == b!.server.streamId && s['sessionId'] == 'live-b',
          'B live');
      expect(_delivered(probe.latest), 0,
          reason: 'B must not inherit A captions');

      // Invariant over the whole run: never a stale green state.
      for (final Map<String, Object?> s in probe.all) {
        if (s['connection'] != 'LIVE') {
          expect(s['sessionState'], 'UNKNOWN', reason: jsonEncode(s));
          expect(s['deviceState'], 'UNKNOWN', reason: jsonEncode(s));
          expect(s['captionEnvironment'], 'UNKNOWN', reason: jsonEncode(s));
        }
        if (s['streamId'] == b.server.streamId) {
          expect(s['sessionId'], isNot('live-a'), reason: jsonEncode(s));
        }
        expect(s['deviceEnvironment'], isNot('HALO_REAL'));
      }
    } finally {
      final String? artifacts = Platform.environment['HORIZON_E2E_ARTIFACTS'];
      if (artifacts != null) {
        Directory(artifacts).createSync(recursive: true);
        File('$artifacts/live_stream_console_snapshots.ndjson')
            .writeAsStringSync('${probe.all.map(jsonEncode).join('\n')}\n');
      }
      await probe.stop();
      await a?.close();
      await b?.close();
      await proxy.close();
    }
  }, timeout: const Timeout(Duration(seconds: 60)));
}

int _delivered(Map<String, Object?> s) =>
    ((s['captions'] ?? const <String, Object?>{})
        as Map<String, Object?>)['delivered'] as int? ??
    -1;

/// The G5 runtime with SIMULATED providers and the scripted Halo fixture,
/// publishing its redacted events on a loopback SSE server.
final class _Rig {
  _Rig._(this.runtime, this.events, this.server, this.fixture, this.stt,
      this.session);

  final HorizonTranslationRuntime runtime;
  final RuntimeEventStream events;
  final RuntimeEventServer server;
  final ScriptedHaloFixture fixture;
  final _Stt stt;
  final TranslationSession session;

  static Future<_Rig> start(String sessionId) async {
    final ScriptedHaloFixture fixture = ScriptedHaloFixture();
    final _Stt stt = _Stt();
    final HorizonTranslationRuntime runtime = HorizonTranslationRuntime(
      input: _Input(),
      stt: stt,
      translator: _Translator(),
      synthesizer: _Tts(),
      captions: HaloCaptionOutputAdapter(fixture),
    );
    final RuntimeEventStream events = RuntimeEventStream(
      runtime,
      deviceSnapshots: fixture.snapshots,
      deviceEnvironment: ExecutionEnvironment.simulated,
    );
    final RuntimeEventServer server = await RuntimeEventServer.start(
      events.events,
      heartbeat: const Duration(milliseconds: 100),
    );
    final Future<DeviceDiscovery> discovered = fixture.discoveries.first;
    await fixture.startDiscovery();
    await fixture.connect(await discovered);
    final TranslationSession session = TranslationSession(
      sessionId: sessionId,
      streamEpoch: 1,
      direction: TranslationDirection.englishToSpanish,
      privacyGeneration: 1,
    );
    await runtime.start(
      config: LiveTranslationConfig(
        session: session,
        sourceLocale: 'en-US',
        targetLocale: 'es-ES',
        consent: const TranslationConsent(
          acceptedAtMicros: 1,
          localProcessingAllowed: true,
          modelDownloadAllowed: false,
          remoteProcessingAllowed: false,
        ),
      ),
      audioSession: AudioSessionDescriptor(
          sessionId: sessionId, streamEpoch: 1, streamId: 'in'),
    );
    return _Rig._(runtime, events, server, fixture, stt, session);
  }

  Future<void> finalTurn(int sequence) async {
    stt.controller.add(TranscriptSegment(
      session: session,
      sequence: sequence,
      text: 'private text $sequence',
      stability: TranscriptStability.finalResult,
      observedAtMicros: sequence,
      truthLabel: TruthLabel.simulated,
    ));
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  Future<void> close() async {
    await runtime.stop();
    await server.close();
    await events.close();
    await runtime.dispose();
    await fixture.dispose();
  }
}

/// Loopback TCP proxy standing in for the network between runtime and
/// Console, so the test can cut and restore connectivity.
final class _Proxy {
  _Proxy._(this._server);

  final ServerSocket _server;
  final Set<Socket> _sockets = <Socket>{};
  int? _target;

  String get url =>
      'http://127.0.0.1:${_server.port}${RuntimeEventServer.path}';

  static Future<_Proxy> start() async {
    final _Proxy proxy =
        _Proxy._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));
    proxy._server.listen(proxy._accept);
    return proxy;
  }

  void target(int port) => _target = port;

  void cut() {
    _target = null;
    for (final Socket socket in List<Socket>.of(_sockets)) {
      socket.destroy();
    }
    _sockets.clear();
  }

  Future<void> _accept(Socket client) async {
    final int? port = _target;
    if (port == null) {
      client.destroy();
      return;
    }
    try {
      final Socket upstream =
          await Socket.connect(InternetAddress.loopbackIPv4, port);
      _sockets
        ..add(client)
        ..add(upstream);
      client.listen(upstream.add,
          onDone: upstream.destroy, onError: (Object _) => upstream.destroy());
      upstream.listen(client.add,
          onDone: client.destroy, onError: (Object _) => client.destroy());
    } on SocketException {
      client.destroy();
    }
  }

  Future<void> close() async {
    cut();
    await _server.close();
  }
}

/// The Engineering Console's real RuntimeStreamClient, run in Node.
final class _Probe {
  _Probe._(this._process);

  final Process _process;
  final List<Map<String, Object?>> all = <Map<String, Object?>>[];
  int _cursor = 0;

  Map<String, Object?> get latest => all.last;

  static Future<_Probe> start(String node, String url) async {
    final Process process = await Process.start(
      node,
      <String>[
        '--experimental-strip-types',
        '--no-warnings',
        '--import',
        './tools/ts-resolve.mjs',
        'tools/live-probe.ts',
        url,
        '600',
        '100',
      ],
      workingDirectory: '../engineering-console',
    );
    final _Probe probe = _Probe._(process);
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((String line) =>
            probe.all.add(jsonDecode(line) as Map<String, Object?>));
    unawaited(process.stderr.drain<void>());
    return probe;
  }

  /// Waits for a snapshot after the previous match that satisfies [test].
  Future<Map<String, Object?>> waitFor(
      bool Function(Map<String, Object?>) test, String label) async {
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 15));
    while (true) {
      for (int i = _cursor; i < all.length; i++) {
        if (test(all[i])) {
          _cursor = i + 1;
          return all[i];
        }
      }
      if (DateTime.now().isAfter(deadline)) {
        fail(
            'probe never reached "$label"; last: ${all.isEmpty ? '-' : jsonEncode(all.last)}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<void> stop() async {
    _process.kill();
    await _process.exitCode;
  }
}

final class _Input implements AudioInputAdapter {
  @override
  String get adapterId => 'live-input';
  @override
  String get sourceRevision => 'e2e';
  @override
  Stream<AudioFrame> get frames => const Stream.empty();
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
  Future<void> start(AudioSessionDescriptor s, AudioFormat f) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

final class _Stt implements StreamingSttProvider {
  final StreamController<TranscriptSegment> controller =
      StreamController<TranscriptSegment>.broadcast();
  @override
  String get providerId => 'live-stt';
  @override
  String get sourceRevision => 'e2e';
  @override
  Stream<ProviderSnapshot> get snapshots => const Stream.empty();
  @override
  Stream<LiveTranslationDiagnostic> get diagnostics => const Stream.empty();
  @override
  Stream<TranscriptSegment> get transcripts => controller.stream;
  @override
  Future<void> prepare(LiveTranslationConfig c, AudioFormat f) async {}
  @override
  Future<void> push(AudioFrame frame) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

final class _Translator implements TextTranslationProvider {
  @override
  String get providerId => 'live-translator';
  @override
  String get sourceRevision => 'e2e';
  @override
  Stream<ProviderSnapshot> get snapshots => const Stream.empty();
  @override
  Stream<LiveTranslationDiagnostic> get diagnostics => const Stream.empty();
  @override
  Future<void> prepare(LiveTranslationConfig c) async {}
  @override
  Future<TranslationSegment> translate(TranscriptSegment t) async =>
      TranslationSegment(
        session: t.session,
        sequence: t.sequence,
        sourceText: t.text,
        translatedText: 'private translation ${t.sequence}',
        observedAtMicros: t.observedAtMicros,
        truthLabel: TruthLabel.simulated,
      );
  @override
  Future<void> dispose() async {}
}

final class _Tts implements SpeechSynthesisProvider {
  @override
  String get providerId => 'live-tts';
  @override
  String get sourceRevision => 'e2e';
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
