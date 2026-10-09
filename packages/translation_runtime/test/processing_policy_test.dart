import 'dart:async';
import 'dart:io';

import 'package:persalone_contracts/persalone_contracts.dart';
import 'package:persalone_translation_runtime/persalone_translation_runtime.dart';
import 'package:test/test.dart';

import 'support/no_egress.dart';

// The runtime is the single processing-policy boundary: a session whose
// providers would process content off the device without remote consent is
// refused before any microphone permission, capture or provider preparation.
void main() {
  late NoEgress guard;
  setUpAll(() => IOOverrides.global = guard = NoEgress());
  tearDownAll(() => IOOverrides.global = null);

  group('ProcessingPolicy.allows', () {
    TranslationConsent consent({required bool local, required bool remote}) =>
        TranslationConsent(
          acceptedAtMicros: 1,
          localProcessingAllowed: local,
          modelDownloadAllowed: false,
          remoteProcessingAllowed: remote,
        );

    test('on-device needs local consent only', () {
      expect(
          ProcessingPolicy.allows(consent(local: true, remote: false),
              ProcessingLocation.onDevice),
          isTrue);
      expect(
          ProcessingPolicy.allows(consent(local: false, remote: true),
              ProcessingLocation.onDevice),
          isFalse);
    });

    test('anything off the device needs remote consent (and local)', () {
      for (final ProcessingLocation off in <ProcessingLocation>[
        ProcessingLocation.privateCompute,
        ProcessingLocation.cloud,
      ]) {
        expect(
            ProcessingPolicy.allows(
                consent(local: true, remote: false), off),
            isFalse,
            reason: off.name);
        expect(
            ProcessingPolicy.allows(
                consent(local: false, remote: true), off),
            isFalse,
            reason: off.name);
        expect(
            ProcessingPolicy.allows(consent(local: true, remote: true), off),
            isTrue,
            reason: off.name);
      }
    });
  });

  group('runtime.start', () {
    for (final (String component, ProcessingLocation location) in <(
      String,
      ProcessingLocation
    )>[
      ('stt', ProcessingLocation.cloud),
      ('translation', ProcessingLocation.cloud),
      ('tts', ProcessingLocation.privateCompute),
    ]) {
      test('$component at ${location.name} without remote consent is refused '
          'before anything runs', () async {
        final _Rig r = _Rig(<String, ProcessingLocation>{component: location});
        addTearDown(r.dispose);

        await expectLater(
          r.start(remote: false),
          throwsA(isA<RuntimeError>()
              .having((e) => e.code, 'code', RuntimeErrorCode.policyDenied)),
        );
        await r.settle();

        expect(r.input.permissionRequests, 0);
        expect(r.input.started, isFalse);
        expect(r.prepared, isEmpty, reason: 'no provider is even prepared');
        expect(
            r.diagnostics.where((d) =>
                d.code == LiveTranslationDiagnosticCode.consentDenied &&
                d.component == component &&
                d.detail == location.name),
            hasLength(1));
      });
    }

    test('the same providers run once remote processing is consented',
        () async {
      final _Rig r = _Rig(<String, ProcessingLocation>{
        'translation': ProcessingLocation.cloud,
      });
      addTearDown(r.dispose);
      await r.start(remote: true);
      expect(r.runtime.state, HorizonTranslationRuntimeState.listening);
    });

    test('an all-on-device session needs no remote consent', () async {
      final _Rig r = _Rig(const <String, ProcessingLocation>{});
      addTearDown(r.dispose);
      await r.start(remote: false);
      expect(r.runtime.state, HorizonTranslationRuntimeState.listening);
    });
  });

  test('the test guard refuses any connection off the machine', () async {
    await expectLater(
        Socket.connect('203.0.113.7', 443), throwsA(isA<SocketException>()));
    expect(guard.attempts, contains('203.0.113.7:443'));
    final ServerSocket local = await ServerSocket.bind('127.0.0.1', 0);
    addTearDown(local.close);
    final Socket ok = await Socket.connect('127.0.0.1', local.port);
    ok.destroy();
  });
}

final class _Rig {
  _Rig(Map<String, ProcessingLocation> locations) {
    stt = _Stt(locations['stt'] ?? ProcessingLocation.onDevice, prepared);
    translator = _Translator(
        locations['translation'] ?? ProcessingLocation.onDevice, prepared);
    tts = _Tts(locations['tts'] ?? ProcessingLocation.onDevice, prepared);
    runtime = HorizonTranslationRuntime(
        input: input, stt: stt, translator: translator, synthesizer: tts);
    _sub = runtime.diagnostics.listen(diagnostics.add);
  }

  final List<String> prepared = <String>[];
  final _Input input = _Input();
  late final _Stt stt;
  late final _Translator translator;
  late final _Tts tts;
  late final HorizonTranslationRuntime runtime;
  final List<LiveTranslationDiagnostic> diagnostics =
      <LiveTranslationDiagnostic>[];
  late final StreamSubscription<LiveTranslationDiagnostic> _sub;

  Future<void> start({required bool remote}) => runtime.start(
        config: LiveTranslationConfig(
          session: const TranslationSession(
            sessionId: 'policy-session',
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
            remoteProcessingAllowed: remote,
          ),
        ),
        audioSession: const AudioSessionDescriptor(
            sessionId: 'policy-session', streamEpoch: 1, streamId: 'in'),
      );

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  Future<void> dispose() async {
    await runtime.dispose();
    await _sub.cancel();
  }
}

final class _Input implements AudioInputAdapter {
  int permissionRequests = 0;
  bool started = false;

  @override
  String get adapterId => 'policy-input';
  @override
  String get sourceRevision => 'test';
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
  Future<bool> requestPermission() async {
    permissionRequests++;
    return true;
  }

  @override
  Future<void> start(AudioSessionDescriptor s, AudioFormat f) async =>
      started = true;
  @override
  Future<void> stop() async => started = false;
  @override
  Future<void> dispose() async {}
}

final class _Stt implements StreamingSttProvider {
  _Stt(this.processingLocation, this._prepared);

  @override
  final ProcessingLocation processingLocation;
  final List<String> _prepared;

  @override
  String get providerId => 'policy-stt';
  @override
  String get sourceRevision => 'test';
  @override
  Stream<ProviderSnapshot> get snapshots => const Stream.empty();
  @override
  Stream<LiveTranslationDiagnostic> get diagnostics => const Stream.empty();
  @override
  Stream<TranscriptSegment> get transcripts => const Stream.empty();
  @override
  Future<void> prepare(LiveTranslationConfig c, AudioFormat f) async =>
      _prepared.add('stt');
  @override
  Future<void> push(AudioFrame frame) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

final class _Translator implements TextTranslationProvider {
  _Translator(this.processingLocation, this._prepared);

  @override
  final ProcessingLocation processingLocation;
  final List<String> _prepared;

  @override
  String get providerId => 'policy-translator';
  @override
  String get sourceRevision => 'test';
  @override
  Stream<ProviderSnapshot> get snapshots => const Stream.empty();
  @override
  Stream<LiveTranslationDiagnostic> get diagnostics => const Stream.empty();
  @override
  Future<void> prepare(LiveTranslationConfig c) async =>
      _prepared.add('translation');
  @override
  Future<TranslationSegment> translate(TranscriptSegment t) async =>
      throw UnimplementedError();
  @override
  Future<void> dispose() async {}
}

final class _Tts implements SpeechSynthesisProvider {
  _Tts(this.processingLocation, this._prepared);

  @override
  final ProcessingLocation processingLocation;
  final List<String> _prepared;

  @override
  String get providerId => 'policy-tts';
  @override
  String get sourceRevision => 'test';
  @override
  Stream<ProviderSnapshot> get snapshots => const Stream.empty();
  @override
  Stream<LiveTranslationDiagnostic> get diagnostics => const Stream.empty();
  @override
  Future<void> prepare(LiveTranslationConfig c) async => _prepared.add('tts');
  @override
  Future<void> speak(TranslationSegment segment) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}
