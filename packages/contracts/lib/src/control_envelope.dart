/// Wire-level control contract for a future authenticated remote channel.
/// There is no transport here: this only defines what a remote command may
/// say and how it is validated. There is no payload or execution field.
const int controlSchemaVersion = 1;

enum ControlAction {
  stop,
  panic,
  deviceDisconnect,
  start,
  languageChange,
  deviceConnect,
  deviceSelect,
}

enum ControlResultCode {
  accepted,
  deniedByPolicy,
  duplicate,
  replayed,
  expired,
  notYetValid,
  staleGeneration,
  unsupportedSchema,
  malformed,
  rateLimited,
  rejectedByRuntime,
}

/// Remote v1 matrix. Only actions that can make the system safer are allowed.
abstract final class RemoteControlPolicy {
  static const Map<ControlAction, bool> matrix = <ControlAction, bool>{
    ControlAction.stop: true,
    ControlAction.panic: true,
    ControlAction.deviceDisconnect: true,
    ControlAction.start: false,
    ControlAction.languageChange: false,
    ControlAction.deviceConnect: false,
    ControlAction.deviceSelect: false,
  };

  static bool allows(ControlAction action) => matrix[action] ?? false;
}

final class ControlEnvelopeError implements Exception {
  const ControlEnvelopeError(this.code);

  final ControlResultCode code;

  @override
  String toString() => 'ControlEnvelopeError(${code.name})';
}

/// One remote command. Exactly these five fields; anything else is rejected.
final class ControlCommandEnvelope {
  const ControlCommandEnvelope({
    required this.schemaVersion,
    required this.commandId,
    required this.issuedAtMicros,
    required this.sessionGeneration,
    required this.action,
  });

  static const Set<String> _keys = <String>{
    'schemaVersion',
    'commandId',
    'issuedAt',
    'sessionGeneration',
    'action',
  };
  static final RegExp _commandId = RegExp(r'^[A-Za-z0-9_-]{8,64}$');

  final int schemaVersion;
  final String commandId;
  final int issuedAtMicros;
  final int sessionGeneration;
  final ControlAction action;

  /// Strict parser for an untrusted decoded JSON value.
  static ControlCommandEnvelope parse(Object? raw) {
    if (raw is! Map)
      throw const ControlEnvelopeError(ControlResultCode.malformed);
    final Map<Object?, Object?> json = raw;
    if (json['schemaVersion'] is int &&
        json['schemaVersion'] != controlSchemaVersion) {
      throw const ControlEnvelopeError(ControlResultCode.unsupportedSchema);
    }
    if (json.length != _keys.length || !json.keys.every(_keys.contains)) {
      throw const ControlEnvelopeError(ControlResultCode.malformed);
    }
    final Object? schema = json['schemaVersion'];
    final Object? commandId = json['commandId'];
    final Object? issuedAt = json['issuedAt'];
    final Object? generation = json['sessionGeneration'];
    final Object? action = json['action'];
    if (schema is! int ||
        commandId is! String ||
        !_commandId.hasMatch(commandId) ||
        issuedAt is! int ||
        issuedAt < 0 ||
        generation is! int ||
        generation < 0 ||
        action is! String) {
      throw const ControlEnvelopeError(ControlResultCode.malformed);
    }
    final ControlAction? parsed = ControlAction.values
        .where((ControlAction a) => a.name == action)
        .firstOrNull;
    if (parsed == null) {
      throw const ControlEnvelopeError(ControlResultCode.malformed);
    }
    return ControlCommandEnvelope(
      schemaVersion: schema,
      commandId: commandId,
      issuedAtMicros: issuedAt,
      sessionGeneration: generation,
      action: parsed,
    );
  }

  /// Canonical content used to tell an exact duplicate from a replay that
  /// reuses the id with different content.
  String get fingerprint =>
      '$schemaVersion|$commandId|$issuedAtMicros|$sessionGeneration|${action.name}';
}

/// Redacted outcome: validated id (null when the id itself was invalid),
/// enums and numbers only.
final class ControlCommandResult {
  const ControlCommandResult({
    required this.resultCode,
    required this.observedAtMicros,
    required this.sessionGeneration,
    this.commandId,
    this.action,
  });

  final String? commandId;
  final ControlAction? action;
  final ControlResultCode resultCode;
  final int sessionGeneration;
  final int observedAtMicros;

  Map<String, Object?> toJson() => <String, Object?>{
        'schemaVersion': controlSchemaVersion,
        'commandId': commandId,
        'action': action?.name,
        'resultCode': resultCode.name,
        'sessionGeneration': sessionGeneration,
        'observedAt': observedAtMicros,
      };
}
