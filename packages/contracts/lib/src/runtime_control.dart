import 'live_translation.dart';
import 'runtime_error.dart';
import 'session.dart';

/// Where a command was issued. Remote origins are restricted to actions that
/// can only make the system safer (see [RuntimeCommand.remoteAllowed]).
enum ControlOrigin { local, remote }

enum RuntimeCommandKind {
  start,
  stop,
  panic,
  setLanguage,
  deviceSelect,
  deviceDisconnect,
}

/// Closed set of runtime commands. There is no generic or free-form command:
/// every payload is an identifier or an enum, never text, Lua or a URL.
sealed class RuntimeCommand {
  const RuntimeCommand({required this.commandId, required this.origin});

  final String commandId;
  final ControlOrigin origin;

  RuntimeCommandKind get kind;

  /// Remote v1 matrix: STOP, PANIC and DEVICE disconnect only.
  bool get remoteAllowed => switch (kind) {
        RuntimeCommandKind.stop ||
        RuntimeCommandKind.panic ||
        RuntimeCommandKind.deviceDisconnect =>
          true,
        RuntimeCommandKind.start ||
        RuntimeCommandKind.setLanguage ||
        RuntimeCommandKind.deviceSelect =>
          false,
      };
}

/// Starts a session in the pending language. Consent is given on the device
/// for this session only.
final class StartCommand extends RuntimeCommand {
  const StartCommand({
    required super.commandId,
    required super.origin,
    required this.consent,
  });

  final TranslationConsent consent;

  @override
  RuntimeCommandKind get kind => RuntimeCommandKind.start;
}

final class StopCommand extends RuntimeCommand {
  const StopCommand({
    required super.commandId,
    required super.origin,
    required this.sessionId,
  });

  final String sessionId;

  @override
  RuntimeCommandKind get kind => RuntimeCommandKind.stop;
}

/// Always accepted; valid from every state; idempotent.
final class PanicCommand extends RuntimeCommand {
  const PanicCommand({required super.commandId, required super.origin});

  @override
  RuntimeCommandKind get kind => RuntimeCommandKind.panic;
}

/// Applies to the next session only; rejected while a session is active.
final class SetLanguageCommand extends RuntimeCommand {
  const SetLanguageCommand({
    required super.commandId,
    required super.origin,
    required this.direction,
  });

  final TranslationDirection direction;

  @override
  RuntimeCommandKind get kind => RuntimeCommandKind.setLanguage;
}

/// Connects a device previously surfaced by discovery (redacted id).
final class DeviceSelectCommand extends RuntimeCommand {
  const DeviceSelectCommand({
    required super.commandId,
    required super.origin,
    required this.deviceId,
  });

  final String deviceId;

  @override
  RuntimeCommandKind get kind => RuntimeCommandKind.deviceSelect;
}

final class DeviceDisconnectCommand extends RuntimeCommand {
  const DeviceDisconnectCommand({
    required super.commandId,
    required super.origin,
  });

  @override
  RuntimeCommandKind get kind => RuntimeCommandKind.deviceDisconnect;
}

enum CommandStatus { accepted, rejected }

enum CommandRejection {
  remoteNotAllowed,
  sessionActive,
  noActiveSession,
  sessionMismatch,
  consentRequired,
  deviceUnavailable,
  duplicateCommand,
  runtimeRejected,

  /// A command queued before a Panic is never executed after it.
  supersededByPanic,
}

/// Redacted outcome of one command: identifiers, enums and component tokens
/// only. [failedCleanup] lists components whose Panic cleanup threw; the
/// remaining safety actions still ran.
final class CommandResult {
  const CommandResult({
    required this.commandId,
    required this.kind,
    required this.origin,
    required this.status,
    required this.observedAtMicros,
    this.rejection,
    this.runtimeError,
    this.failedCleanup = const <String>[],
  });

  final String commandId;
  final RuntimeCommandKind kind;
  final ControlOrigin origin;
  final CommandStatus status;
  final int observedAtMicros;
  final CommandRejection? rejection;
  final RuntimeErrorCode? runtimeError;
  final List<String> failedCleanup;
}

/// Language that governs the active session versus the one queued for the
/// next session. They are never merged.
final class LanguageState {
  const LanguageState({required this.effective, required this.pending});

  /// Direction of the active session, or null when no session is active.
  final TranslationDirection? effective;
  final TranslationDirection pending;
}

/// Domain-level control surface. It has no transport: local UI calls it
/// directly; any future remote channel must go through [ControlOrigin.remote].
abstract interface class RuntimeControlPort {
  Stream<CommandResult> get results;
  LanguageState get language;

  /// Identifier of the active session, or null when none is active.
  String? get activeSessionId;
  Future<CommandResult> execute(RuntimeCommand command);
}
