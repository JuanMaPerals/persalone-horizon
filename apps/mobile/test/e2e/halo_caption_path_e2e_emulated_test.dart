import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:persalone_contracts/persalone_contracts.dart';
import 'package:persalone_mobile/halo_caption_path.dart';
import 'package:persalone_translation_runtime/persalone_translation_runtime.dart';

import 'emulator_halo_transport.dart';

// The production caption composition root (HaloCaptionPath), fed by the real
// G5 runtime, drawing on the official halo-emulator. Software readiness only:
// the environment is EMULATED because the transport says so; HALO_REAL needs
// the Brilliant transport and a physical Halo.
final String? _python = Platform.environment['HORIZON_E2E_PYTHON'];
final bool _required = Platform.environment['HORIZON_E2E_REQUIRED'] == '1';
const String _bridge = '../../tooling/e2e/halo_emulator_bridge.py';

String? get _skip => _python != null || _required
    ? null
    : 'HALO_CAPTION_PATH_E2E not configured: set HORIZON_E2E_PYTHON';

const TranslationSession _session = TranslationSession(
  sessionId: 'halo-path',
  streamEpoch: 1,
  direction: TranslationDirection.englishToSpanish,
  privacyGeneration: 1,
);

void main() {
  test('disabled builds compose nothing, so no HALO_REAL label can appear', () {
    bool built = false;
    final HaloCaptionPath? path = HaloCaptionPath.compose(
      enabled: false,
      transport: () {
        built = true;
        throw StateError('must not be built');
      },
      permission: null,
    );
    expect(path, isNull);
    expect(built, isFalse);
  });

  test('an unconnected Halo blocks captions instead of faking a delivery',
      skip: _skip, () async {
    final EmulatorHaloTransport transport =
        EmulatorHaloTransport(python: _python!, bridgeScript: _bridge);
    // The official emulator needs no Bluetooth permission.
    final HaloCaptionPath path = HaloCaptionPath.compose(
        enabled: true, transport: () => transport, permission: null)!;
    addTearDown(() async {
      await path.dispose();
      await transport.dispose();
    });
    final CaptionDelivery delivery = await path.captions.show(CaptionUpdate(
      session: _session,
      sequence: 1,
      text: 'Hola',
      observedAtMicros: 1,
      truthLabel: TruthLabel.simulated,
    ));
    expect(delivery.status, isNot(CaptionDeliveryStatus.delivered));
    expect(delivery.truthLabel,
        anyOf(TruthLabel.blocked, TruthLabel.failed));
  });

  test('G5 turn -> HaloCaptionPath -> official emulator; Panic clears it',
      skip: _skip, () async {
    final EmulatorHaloTransport transport =
        EmulatorHaloTransport(python: _python!, bridgeScript: _bridge);
    final HaloCaptionPath path = HaloCaptionPath.compose(
        enabled: true, transport: () => transport, permission: null)!;
    final _Stt stt = _Stt();
    final HorizonTranslationRuntime runtime = HorizonTranslationRuntime(
      input: _Input(),
      stt: stt,
      translator: _Translator(),
      synthesizer: _Tts(),
      captions: path.captions,
    );
    final List<CaptionDelivery> deliveries = <CaptionDelivery>[];
    final StreamSubscription<CaptionDelivery> sub =
        runtime.captionDeliveries.listen(deliveries.add);
    addTearDown(() async {
      await sub.cancel();
      await runtime.dispose();
      await path.dispose();
      await transport.dispose();
    });

    await path.connectFirst();
    expect(path.environment, ExecutionEnvironment.emulated);
    await runtime.start(
      config: const LiveTranslationConfig(
        session: _session,
        sourceLocale: 'en-US',
        targetLocale: 'es-ES',
        consent: TranslationConsent(
          acceptedAtMicros: 1,
          localProcessingAllowed: true,
          modelDownloadAllowed: false,
          remoteProcessingAllowed: false,
        ),
      ),
      audioSession: const AudioSessionDescriptor(
          sessionId: 'halo-path', streamEpoch: 1, streamId: 'in'),
    );

    stt.controller.add(const TranscriptSegment(
      session: _session,
      sequence: 1,
      text: 'good morning',
      stability: TranscriptStability.finalResult,
      observedAtMicros: 1,
      truthLabel: TruthLabel.simulated,
    ));
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 20));
    while (deliveries.isEmpty) {
      if (DateTime.now().isAfter(deadline)) fail('no caption delivery');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final CaptionDelivery delivery = deliveries.single;
    expect(delivery.status, CaptionDeliveryStatus.delivered);
    expect(delivery.environment, ExecutionEnvironment.emulated);
    expect(delivery.truthLabel, TruthLabel.prepared,
        reason: 'a device acknowledgement is never HARDWARE_OBSERVED');
    expect(await _litPixels(transport), greaterThan(0));

    final List<String> failed = await runtime.panic();
    expect(failed, isEmpty);
    expect(await _litPixels(transport), 0,
        reason: 'Panic clears the display through the same path');
  }, timeout: const Timeout(Duration(minutes: 2)));
}

Future<int> _litPixels(EmulatorHaloTransport transport) async {
  final EmulatorFrame frame = await transport.frame();
  return frame.lit;
}

final class _Stt implements StreamingSttProvider {
  final StreamController<TranscriptSegment> controller =
      StreamController<TranscriptSegment>.broadcast();
  @override
  Stream<TranscriptSegment> get transcripts => controller.stream;
  @override
  String get providerId => 'path-stt';
  @override
  String get sourceRevision => 'test';
  @override
  Stream<ProviderSnapshot> get snapshots => const Stream.empty();
  @override
  Stream<LiveTranslationDiagnostic> get diagnostics => const Stream.empty();
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
  String get providerId => 'path-translator';
  @override
  String get sourceRevision => 'test';
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
        translatedText: 'buenos dias',
        observedAtMicros: t.observedAtMicros,
        truthLabel: TruthLabel.simulated,
      );
  @override
  Future<void> dispose() async {}
}

final class _Tts implements SpeechSynthesisProvider {
  @override
  String get providerId => 'path-tts';
  @override
  String get sourceRevision => 'test';
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

final class _Input implements AudioInputAdapter {
  @override
  String get adapterId => 'path-input';
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
  Future<bool> requestPermission() async => true;
  @override
  Future<void> start(AudioSessionDescriptor s, AudioFormat f) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}
