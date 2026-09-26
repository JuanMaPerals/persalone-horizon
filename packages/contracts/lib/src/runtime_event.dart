import 'caption.dart';
import 'device_adapter.dart';
import 'live_translation.dart';
import 'runtime_error.dart';
import 'truth_label.dart';
import 'turn_latency.dart';

/// Wire schema of the redacted runtime event stream. Bump on breaking change.
const String runtimeEventSchema = 'horizon.runtime-event.v1';

enum RuntimeEventKind { sessionState, caption, diagnostic, deviceState, latency }

/// Session lifecycle as observed on the stream; mirrors the G5 runtime states
/// without making contracts depend on the runtime package.
enum RuntimeSessionState {
  idle,
  preparing,
  listening,
  stopping,
  stopped,
  failed,
  disposed,
}

/// One read-only, redacted runtime event. It carries identifiers, coded
/// states and labels only: never audio, transcript, translation, voice,
/// device or account data. Execution environment and truth stay separate.
final class RuntimeEvent {
  const RuntimeEvent._({
    required this.kind,
    required this.streamSequence,
    required this.observedAtMicros,
    this.sessionId,
    this.streamEpoch,
    this.sessionState,
    this.failureCode,
    this.turnSequence,
    this.captionStatus,
    this.environment,
    this.truthLabel,
    this.adapterId,
    this.diagnosticCode,
    this.component,
    this.detail,
    this.deviceState,
    this.latencyStage,
    this.latencyMicros,
  });

  factory RuntimeEvent.sessionState({
    required int streamSequence,
    required int observedAtMicros,
    required RuntimeSessionState state,
    String? sessionId,
    int? streamEpoch,
    RuntimeErrorCode? failureCode,
  }) =>
      RuntimeEvent._(
        kind: RuntimeEventKind.sessionState,
        streamSequence: streamSequence,
        observedAtMicros: observedAtMicros,
        sessionId: sessionId,
        streamEpoch: streamEpoch,
        sessionState: state,
        failureCode: failureCode,
      );

  factory RuntimeEvent.caption({
    required int streamSequence,
    required int observedAtMicros,
    required CaptionDelivery delivery,
  }) =>
      RuntimeEvent._(
        kind: RuntimeEventKind.caption,
        streamSequence: streamSequence,
        observedAtMicros: observedAtMicros,
        sessionId: delivery.session.sessionId,
        streamEpoch: delivery.session.streamEpoch,
        turnSequence: delivery.sequence,
        captionStatus: delivery.status,
        environment: delivery.environment,
        truthLabel: delivery.truthLabel,
        adapterId: redactToken(delivery.adapterId),
        detail: _optionalToken(delivery.reason),
      );

  factory RuntimeEvent.diagnostic({
    required int streamSequence,
    required LiveTranslationDiagnostic diagnostic,
    String? sessionId,
    int? streamEpoch,
  }) =>
      RuntimeEvent._(
        kind: RuntimeEventKind.diagnostic,
        streamSequence: streamSequence,
        observedAtMicros: diagnostic.observedAtMicros,
        sessionId: sessionId,
        streamEpoch: streamEpoch,
        turnSequence: diagnostic.sequence,
        diagnosticCode: diagnostic.code,
        component: redactToken(diagnostic.component),
        detail: _optionalToken(diagnostic.detail),
      );

  /// Device link state. [environment] is declared by the composition root from
  /// the transport actually used; a fixture is never HALO_REAL.
  factory RuntimeEvent.deviceState({
    required int streamSequence,
    required DeviceAdapterSnapshot snapshot,
    required ExecutionEnvironment environment,
  }) =>
      RuntimeEvent._(
        kind: RuntimeEventKind.deviceState,
        streamSequence: streamSequence,
        observedAtMicros: snapshot.observedAtMicros,
        deviceState: snapshot.state,
        adapterId: redactToken(snapshot.adapterId),
        environment: environment,
        truthLabel: snapshot.truthLabel,
      );

  /// One measured turn interval (monotonic clock). The wire truth is always
  /// MEASURED; [environment] says what was measured, or null when unknown.
  factory RuntimeEvent.latency({
    required int streamSequence,
    required int observedAtMicros,
    required TurnLatencySample sample,
    String? sessionId,
    int? streamEpoch,
  }) =>
      RuntimeEvent._(
        kind: RuntimeEventKind.latency,
        streamSequence: streamSequence,
        observedAtMicros: observedAtMicros,
        sessionId: sessionId,
        streamEpoch: streamEpoch,
        turnSequence: sample.turn,
        latencyStage: sample.stage,
        latencyMicros: sample.micros,
        environment: sample.environment,
      );

  final RuntimeEventKind kind;
  final int streamSequence;
  final int observedAtMicros;
  final String? sessionId;
  final int? streamEpoch;
  final RuntimeSessionState? sessionState;
  final RuntimeErrorCode? failureCode;
  final int? turnSequence;
  final CaptionDeliveryStatus? captionStatus;
  final ExecutionEnvironment? environment;
  final TruthLabel? truthLabel;
  final String? adapterId;
  final LiveTranslationDiagnosticCode? diagnosticCode;
  final String? component;
  final String? detail;
  final DeviceConnectionState? deviceState;
  final TurnLatencyStage? latencyStage;
  final int? latencyMicros;

  static final RegExp _token = RegExp(r'^[A-Za-z0-9_.:-]{1,64}$');

  /// Free-form fields are reduced to short coded tokens; anything else
  /// (sentences, text, identifiers with spaces) becomes `redacted`.
  static String redactToken(String value) =>
      _token.hasMatch(value) ? value : 'redacted';

  static String? _optionalToken(String? value) =>
      value == null ? null : redactToken(value);

  static String environmentWire(ExecutionEnvironment value) => switch (value) {
        ExecutionEnvironment.simulated => 'SIMULATED',
        ExecutionEnvironment.emulated => 'EMULATED',
        ExecutionEnvironment.pcReal => 'PC_REAL',
        ExecutionEnvironment.haloReal => 'HALO_REAL',
      };

  Map<String, Object?> toJson() => <String, Object?>{
        'schema': runtimeEventSchema,
        'seq': streamSequence,
        'atMicros': observedAtMicros,
        'kind': kind.name,
        'session': sessionId == null
            ? null
            : <String, Object?>{
                'id': redactToken(sessionId!),
                'epoch': streamEpoch
              },
        ...switch (kind) {
          RuntimeEventKind.sessionState => <String, Object?>{
              'state': sessionState!.name,
              'failureCode': failureCode?.name,
            },
          RuntimeEventKind.caption => <String, Object?>{
              'turn': turnSequence,
              'status': captionStatus!.name,
              'environment': environmentWire(environment!),
              'truth': truthLabel!.name.toUpperCase(),
              'adapter': adapterId,
              'reason': detail,
            },
          RuntimeEventKind.deviceState => <String, Object?>{
              'state': deviceState!.name,
              'adapter': adapterId,
              'environment': environmentWire(environment!),
              'truth': truthLabel!.name.toUpperCase(),
            },
          RuntimeEventKind.latency => <String, Object?>{
              'turn': turnSequence,
              'stage': latencyStage!.name,
              'micros': latencyMicros,
              'environment':
                  environment == null ? null : environmentWire(environment!),
              'truth': 'MEASURED',
            },
          RuntimeEventKind.diagnostic => <String, Object?>{
              'code': diagnosticCode!.name,
              'component': component,
              'turn': turnSequence,
              'detail': detail,
            },
        },
      };
}
