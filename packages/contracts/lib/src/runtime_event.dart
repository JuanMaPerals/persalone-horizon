import 'caption.dart';
import 'live_translation.dart';
import 'runtime_error.dart';
import 'truth_label.dart';

/// Wire schema of the redacted runtime event stream. Bump on breaking change.
const String runtimeEventSchema = 'horizon.runtime-event.v1';

enum RuntimeEventKind { sessionState, caption, diagnostic }

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
          RuntimeEventKind.diagnostic => <String, Object?>{
              'code': diagnosticCode!.name,
              'component': component,
              'turn': turnSequence,
              'detail': detail,
            },
        },
      };
}
