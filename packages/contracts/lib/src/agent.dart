import 'runtime_error.dart';
import 'session.dart';

/// Permission categories that an agent must declare before a session can grant
/// them. A declaration is never an authorization by itself.
enum AgentPermission {
  liveTranslationControl,
  microphoneCapture,
  speakerPlayback,
  localSpeechRecognition,
  localTextTranslation,
  modelDownload,
  localSpeechSynthesis,
  readDiagnostics,
}

/// Persistence boundary requested by an agent. No policy enables implicit
/// persistence; the initial HORIZON Translate agent uses [none].
enum AgentMemoryPolicy { none, sessionEphemeral }

/// Explicit operator intent for a session. [validation] may exercise a
/// PREPARED capability but must not be represented as physical evidence.
enum AgentExecutionMode { standard, validation }

enum AgentLifecycleState {
  discovered,
  registered,
  permissionRequired,
  ready,
  starting,
  active,
  stopping,
  stopped,
  failed,
  disposed,
}

/// Abstract provider categories. They deliberately do not name Android APIs,
/// cloud endpoints, credentials or implementation classes.
enum AgentProviderCategory {
  localSpeechRecognition,
  localTextTranslation,
  localSpeechSynthesis,
}

/// A provider constraint declared by an agent before it can run.
final class AgentProviderRequirement {
  const AgentProviderRequirement({
    required this.category,
    required this.localOnly,
    this.minimumRevision,
  });

  final AgentProviderCategory category;
  final bool localOnly;
  final String? minimumRevision;
}

/// A versioned, static declaration for one installed agent. It must be checked
/// before registration and never contains a provider credential or executable
/// payload.
final class AgentManifest {
  const AgentManifest({
    required this.schemaVersion,
    required this.agentId,
    required this.displayName,
    required this.version,
    required this.requestedPermissions,
    required this.providerRequirements,
    required this.memoryPolicy,
  });

  static const String currentSchemaVersion = 'persalone.agent/1';

  final String schemaVersion;
  final String agentId;
  final String displayName;
  final String version;
  final Set<AgentPermission> requestedPermissions;
  final List<AgentProviderRequirement> providerRequirements;
  final AgentMemoryPolicy memoryPolicy;

  void validate() {
    if (schemaVersion != currentSchemaVersion ||
        agentId.trim().isEmpty ||
        displayName.trim().isEmpty ||
        version.trim().isEmpty ||
        requestedPermissions.isEmpty) {
      throw const RuntimeError(
        RuntimeErrorCode.invalidContract,
        'Agent manifest is incomplete or uses an unsupported schema version.',
      );
    }
    final categories =
        providerRequirements.map((requirement) => requirement.category).toSet();
    if (categories.length != providerRequirements.length) {
      throw const RuntimeError(
        RuntimeErrorCode.invalidContract,
        'Agent manifest contains duplicate provider requirement categories.',
      );
    }
  }
}

/// Explicit, non-persistent authorization for a single agent session and epoch.
final class AgentPermissionGrant {
  const AgentPermissionGrant({
    required this.agentId,
    required this.sessionId,
    required this.streamEpoch,
    required this.privacyGeneration,
    required this.permissions,
    required this.issuedAtMicros,
    required this.expiresAtMicros,
  });

  final String agentId;
  final String sessionId;
  final int streamEpoch;
  final int privacyGeneration;
  final Set<AgentPermission> permissions;
  final int issuedAtMicros;
  final int expiresAtMicros;

  bool isActiveAt(int nowMicros) =>
      nowMicros >= issuedAtMicros && nowMicros < expiresAtMicros;

  bool matches(TranslationSession session, String expectedAgentId) =>
      agentId == expectedAgentId &&
      sessionId == session.sessionId &&
      streamEpoch == session.streamEpoch &&
      privacyGeneration == session.privacyGeneration;
}

/// Control-plane context. It deliberately carries no PCM, transcript,
/// translation, device identifier or provider payload.
final class AgentSessionContext {
  const AgentSessionContext({
    required this.agentId,
    required this.session,
    required this.grant,
    required this.executionMode,
  });

  final String agentId;
  final TranslationSession session;
  final AgentPermissionGrant grant;
  final AgentExecutionMode executionMode;
}

enum AgentAuditEventCode {
  agentRegistered,
  registrationRejected,
  permissionDenied,
  providerRequirementFailed,
  capabilityBlocked,
  lifecycleDenied,
  agentStarting,
  agentStarted,
  agentStopping,
  agentStopped,
  agentFailed,
  staleCallbackDiscarded,
}

/// Censored audit event. Session identity is represented only by its epoch;
/// raw session IDs and all user data are prohibited from this contract.
final class AgentAuditEvent {
  const AgentAuditEvent({
    required this.code,
    required this.agentId,
    required this.streamEpoch,
    required this.observedAtMicros,
  });

  final AgentAuditEventCode code;
  final String agentId;
  final int streamEpoch;
  final int observedAtMicros;
}

enum AgentDiagnosticCode {
  manifestInvalid,
  agentUnavailable,
  permissionDenied,
  capabilityBlocked,
  providerUnavailable,
  lifecycleDenied,
  controllerFailed,
  staleCallbackDiscarded,
}

/// Safe diagnostic for UI and review. [failureCode] is typed; no free-text
/// detail is accepted so audit channels cannot accidentally carry user content.
final class AgentDiagnostic {
  const AgentDiagnostic({
    required this.code,
    required this.agentId,
    required this.streamEpoch,
    required this.observedAtMicros,
    required this.failureCode,
  });

  final AgentDiagnosticCode code;
  final String agentId;
  final int streamEpoch;
  final int observedAtMicros;
  final RuntimeErrorCode failureCode;
}

/// Registration snapshot is evidence of discovery/validation only; it is not
/// evidence that a controller executed or that hardware is connected.
final class AgentRegistration {
  const AgentRegistration({
    required this.manifest,
    required this.state,
    required this.observedAtMicros,
    this.failureCode,
  });

  final AgentManifest manifest;
  final AgentLifecycleState state;
  final int observedAtMicros;
  final RuntimeErrorCode? failureCode;
}
