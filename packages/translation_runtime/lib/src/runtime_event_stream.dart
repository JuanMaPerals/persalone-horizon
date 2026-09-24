import 'dart:async';
import 'dart:convert';

import 'package:persalone_contracts/persalone_contracts.dart';

import 'horizon_translation_runtime.dart';

/// Projects the runtime's existing snapshot, caption and diagnostic streams
/// into one ordered, redacted [RuntimeEvent] stream (read-only). It never
/// reads transcripts or translations, so no text can reach consumers.
final class RuntimeEventStream {
  /// [deviceSnapshots] and [deviceEnvironment] come from the composition root,
  /// which knows the transport behind the device adapter.
  RuntimeEventStream(
    HorizonTranslationRuntime runtime, {
    int Function()? nowMicros,
    Stream<DeviceAdapterSnapshot>? deviceSnapshots,
    ExecutionEnvironment deviceEnvironment = ExecutionEnvironment.simulated,
  }) : _nowMicros = nowMicros ?? _wallClockMicros {
    _subscriptions
      ..add(runtime.snapshots.listen(_onSnapshot))
      ..add(runtime.captionDeliveries.listen(_onCaption))
      ..add(runtime.diagnostics.listen(_onDiagnostic))
      ..add(runtime.latencies.listen(_onLatency));
    if (deviceSnapshots != null) {
      _subscriptions.add(deviceSnapshots.listen(
        (DeviceAdapterSnapshot snapshot) => _emit(RuntimeEvent.deviceState(
          streamSequence: ++_sequence,
          snapshot: snapshot,
          environment: deviceEnvironment,
        )),
      ));
    }
  }

  final int Function() _nowMicros;
  final StreamController<RuntimeEvent> _events =
      StreamController<RuntimeEvent>.broadcast();
  final List<StreamSubscription<Object>> _subscriptions =
      <StreamSubscription<Object>>[];
  int _sequence = 0;
  String? _sessionId;
  int? _streamEpoch;

  Stream<RuntimeEvent> get events => _events.stream;

  /// One NDJSON line of the `horizon.runtime-event.v1` wire format.
  static String encodeLine(RuntimeEvent event) => jsonEncode(event.toJson());

  Future<void> close() async {
    for (final StreamSubscription<Object> subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _events.close();
  }

  void _onSnapshot(HorizonTranslationRuntimeSnapshot snapshot) {
    // A stopped or failed snapshot no longer carries the session identity;
    // keep the last known one so consumers can attribute the transition.
    if (snapshot.sessionId != null) {
      _sessionId = snapshot.sessionId;
      _streamEpoch = snapshot.streamEpoch;
    }
    _emit(RuntimeEvent.sessionState(
      streamSequence: ++_sequence,
      observedAtMicros: snapshot.observedAtMicros,
      state: RuntimeSessionState.values.byName(snapshot.state.name),
      sessionId: _sessionId,
      streamEpoch: _streamEpoch,
      failureCode: snapshot.failureCode,
    ));
  }

  void _onCaption(CaptionDelivery delivery) {
    _emit(RuntimeEvent.caption(
      streamSequence: ++_sequence,
      observedAtMicros: _nowMicros(),
      delivery: delivery,
    ));
  }

  void _onDiagnostic(LiveTranslationDiagnostic diagnostic) {
    _emit(RuntimeEvent.diagnostic(
      streamSequence: ++_sequence,
      diagnostic: diagnostic,
      sessionId: _sessionId,
      streamEpoch: _streamEpoch,
    ));
  }

  void _onLatency(TurnLatencySample sample) {
    _emit(RuntimeEvent.latency(
      streamSequence: ++_sequence,
      observedAtMicros: _nowMicros(),
      sample: sample,
      sessionId: _sessionId,
      streamEpoch: _streamEpoch,
    ));
  }

  void _emit(RuntimeEvent event) {
    if (!_events.isClosed) {
      _events.add(event);
    }
  }

  static int _wallClockMicros() => DateTime.now().microsecondsSinceEpoch;
}
