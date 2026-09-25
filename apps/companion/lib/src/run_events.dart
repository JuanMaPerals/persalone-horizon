import 'dart:async';

import 'package:persalone_contracts/persalone_contracts.dart';

/// Projects app runs onto the canonical redacted `horizon.runtime-event.v1`
/// stream (RuntimeEvent factories from contracts), so Studio and the twin
/// consume the same contract and fail-closed client as the G5 runtime.
/// Events carry identifiers, coded states and labels only — never caption
/// text.
final class RunEventSource {
  final StreamController<RuntimeEvent> _events =
      StreamController<RuntimeEvent>.broadcast(sync: true);
  int _seq = 0;

  Stream<RuntimeEvent> get events => _events.stream;

  static int _now() => DateTime.now().microsecondsSinceEpoch;

  void _emit(RuntimeEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  /// A display-only app has no language pair; the session descriptor needs
  /// one, but `direction` is never emitted on the wire.
  static TranslationSession session(String runId, int generation) => TranslationSession(
        sessionId: runId,
        streamEpoch: generation,
        direction: TranslationDirection.englishToSpanish,
        privacyGeneration: generation,
      );

  void sessionState(String runId, int generation, RuntimeSessionState state) =>
      _emit(RuntimeEvent.sessionState(
        streamSequence: ++_seq,
        observedAtMicros: _now(),
        state: state,
        sessionId: runId,
        streamEpoch: generation,
      ));

  void device(DeviceAdapterSnapshot snapshot, ExecutionEnvironment environment) =>
      _emit(RuntimeEvent.deviceState(
        streamSequence: ++_seq,
        snapshot: snapshot,
        environment: environment,
      ));

  void captionShown(String runId, int generation, int turn, String resultValue,
      ExecutionEnvironment environment) {
    final RegExpMatch? m =
        RegExp(r'^page:\d+/(\d+)(?:;folded:(\d+))?(?:;replaced:(\d+))?$').firstMatch(resultValue);
    int count(int g) => int.tryParse(m?.group(g) ?? '0') ?? 0;
    _emit(RuntimeEvent.caption(
      streamSequence: ++_seq,
      observedAtMicros: _now(),
      delivery: CaptionDelivery(
        session: session(runId, generation),
        sequence: turn,
        status: CaptionDeliveryStatus.delivered,
        environment: environment,
        truthLabel: TruthLabel.prepared,
        adapterId: 'halo-caption:halo-device-adapter',
        pageCount: m == null ? 1 : count(1),
        foldedGlyphs: count(2),
        replacedGlyphs: count(3),
        reason: count(3) > 0 ? 'glyphsReplaced' : count(2) > 0 ? 'glyphsFolded' : null,
      ),
    ));
  }

  void diagnostic(LiveTranslationDiagnosticCode code, String component,
          {String? runId, int? generation, int? sequence, String? detail}) =>
      _emit(RuntimeEvent.diagnostic(
        streamSequence: ++_seq,
        diagnostic: LiveTranslationDiagnostic(
          code: code,
          component: component,
          observedAtMicros: _now(),
          sequence: sequence,
          detail: detail,
        ),
        sessionId: runId,
        streamEpoch: generation,
      ));

  Future<void> close() => _events.close();
}
