import 'dart:async';

import 'package:persalone_contracts/persalone_contracts.dart';

/// A controller handles only a high-level agent lifecycle. It intentionally has
/// no APIs for PCM, transcripts, translations, device identifiers, or provider
/// credentials.
abstract interface class AgentController {
  AgentManifest get manifest;

  Future<void> start(AgentSessionContext context);
  Future<void> stop(AgentSessionContext context);
  Future<void> dispose();
}

/// A truth-labelled availability result for a manifest permission. Implementors
/// may inspect canonical device/provider state but must not silently substitute
/// an undeclared capability.
final class AgentCapabilityAvailability {
  const AgentCapabilityAvailability({
    required this.permission,
    required this.truthLabel,
  });

  final AgentPermission permission;
  final TruthLabel truthLabel;
}

abstract interface class AgentCapabilityResolver {
  Future<AgentCapabilityAvailability> availabilityFor(
      AgentPermission permission);
}

/// A provider readiness query used only on lifecycle start, never in the audio
/// data path.
abstract interface class AgentProviderResolver {
  Future<ProviderReadiness> readinessFor(AgentProviderRequirement requirement);
}

final class _AgentEntry {
  _AgentEntry(this.controller, this.state);

  final AgentController controller;
  AgentLifecycleState state;
  AgentSessionContext? activeContext;
}

/// Fail-closed control-plane runtime for registered agents.
final class PersalOneAgentRuntime {
  PersalOneAgentRuntime({
    required AgentCapabilityResolver capabilityResolver,
    required AgentProviderResolver providerResolver,
    DateTime Function()? clock,
  })  : _capabilityResolver = capabilityResolver,
        _providerResolver = providerResolver,
        _clock = clock ?? DateTime.now;

  final AgentCapabilityResolver _capabilityResolver;
  final AgentProviderResolver _providerResolver;
  final DateTime Function() _clock;
  final Map<String, _AgentEntry> _entries = <String, _AgentEntry>{};
  final StreamController<AgentRegistration> _registrations =
      StreamController<AgentRegistration>.broadcast();
  final StreamController<AgentAuditEvent> _auditEvents =
      StreamController<AgentAuditEvent>.broadcast();
  final StreamController<AgentDiagnostic> _diagnostics =
      StreamController<AgentDiagnostic>.broadcast();
  bool _disposed = false;

  Stream<AgentRegistration> get registrations => _registrations.stream;
  Stream<AgentAuditEvent> get auditEvents => _auditEvents.stream;
  Stream<AgentDiagnostic> get diagnostics => _diagnostics.stream;

  int get _nowMicros => _clock().microsecondsSinceEpoch;

  Future<void> register(AgentController controller) async {
    _ensureNotDisposed();
    final manifest = controller.manifest;
    try {
      manifest.validate();
      if (_entries.containsKey(manifest.agentId)) {
        throw const RuntimeError(
          RuntimeErrorCode.invalidContract,
          'An agent with this identifier is already registered.',
        );
      }
      _entries[manifest.agentId] = _AgentEntry(
        controller,
        AgentLifecycleState.registered,
      );
      _emitRegistration(manifest, AgentLifecycleState.registered);
      _emitAudit(AgentAuditEventCode.agentRegistered, manifest.agentId, 0);
    } on RuntimeError catch (error) {
      _emitRegistration(
        manifest,
        AgentLifecycleState.failed,
        failureCode: error.code,
      );
      _emitDiagnostic(
        AgentDiagnosticCode.manifestInvalid,
        manifest.agentId,
        0,
        error.code,
      );
      _emitAudit(AgentAuditEventCode.registrationRejected, manifest.agentId, 0);
      rethrow;
    }
  }

  Future<AgentRegistration> registrationFor(String agentId) async {
    _ensureNotDisposed();
    final entry = _entries[agentId];
    if (entry == null) {
      throw const RuntimeError(
        RuntimeErrorCode.agentUnavailable,
        'Agent is not registered.',
      );
    }
    return AgentRegistration(
      manifest: entry.controller.manifest,
      state: entry.state,
      observedAtMicros: _nowMicros,
    );
  }

  Future<void> start(String agentId, AgentSessionContext context) async {
    _ensureNotDisposed();
    final entry = _entryFor(agentId, context.session.streamEpoch);
    final manifest = entry.controller.manifest;
    _validateLifecycleForStart(entry, context);
    _setState(entry, AgentLifecycleState.permissionRequired);
    _emitRegistration(manifest, AgentLifecycleState.permissionRequired);

    try {
      await _validateContext(manifest, context);
      await _validateCapabilities(manifest, context);
      await _validateProviders(manifest, context);
      _setState(entry, AgentLifecycleState.ready);
      _emitRegistration(manifest, AgentLifecycleState.ready);
      _setState(entry, AgentLifecycleState.starting);
      _emitRegistration(manifest, AgentLifecycleState.starting);
      _emitAudit(AgentAuditEventCode.agentStarting, agentId,
          context.session.streamEpoch);
      await entry.controller.start(context);
      _setState(entry, AgentLifecycleState.active, context: context);
      _emitRegistration(manifest, AgentLifecycleState.active);
      _emitAudit(AgentAuditEventCode.agentStarted, agentId,
          context.session.streamEpoch);
    } on RuntimeError catch (error) {
      _fail(entry, context, error.code);
      rethrow;
    } on Object {
      _fail(entry, context, RuntimeErrorCode.providerUnavailable);
      throw const RuntimeError(
        RuntimeErrorCode.providerUnavailable,
        'Agent controller failed without an exposed provider-safe error.',
        retryable: true,
      );
    }
  }

  Future<void> stop(String agentId, AgentSessionContext context) async {
    _ensureNotDisposed();
    final entry = _entryFor(agentId, context.session.streamEpoch);
    if (entry.state != AgentLifecycleState.active ||
        entry.activeContext == null ||
        !_matches(entry.activeContext!, context)) {
      _emitDiagnostic(
        AgentDiagnosticCode.staleCallbackDiscarded,
        agentId,
        context.session.streamEpoch,
        RuntimeErrorCode.staleStreamEpoch,
      );
      _emitAudit(
        AgentAuditEventCode.staleCallbackDiscarded,
        agentId,
        context.session.streamEpoch,
      );
      throw const RuntimeError(
        RuntimeErrorCode.staleStreamEpoch,
        'Stop request does not match the active agent session generation.',
      );
    }
    _setState(entry, AgentLifecycleState.stopping);
    _emitRegistration(entry.controller.manifest, AgentLifecycleState.stopping);
    _emitAudit(AgentAuditEventCode.agentStopping, agentId,
        context.session.streamEpoch);
    try {
      await entry.controller.stop(context);
      _setState(entry, AgentLifecycleState.stopped);
      _emitRegistration(entry.controller.manifest, AgentLifecycleState.stopped);
      _emitAudit(AgentAuditEventCode.agentStopped, agentId,
          context.session.streamEpoch);
    } on RuntimeError catch (error) {
      _fail(entry, context, error.code);
      rethrow;
    } on Object {
      _fail(entry, context, RuntimeErrorCode.providerUnavailable);
      throw const RuntimeError(
        RuntimeErrorCode.providerUnavailable,
        'Agent controller stop failed without an exposed provider-safe error.',
        retryable: true,
      );
    }
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    for (final entry in _entries.values) {
      await entry.controller.dispose();
      entry.state = AgentLifecycleState.disposed;
    }
    _entries.clear();
    await _registrations.close();
    await _auditEvents.close();
    await _diagnostics.close();
  }

  _AgentEntry _entryFor(String agentId, int streamEpoch) {
    final entry = _entries[agentId];
    if (entry == null) {
      _emitDiagnostic(
        AgentDiagnosticCode.agentUnavailable,
        agentId,
        streamEpoch,
        RuntimeErrorCode.agentUnavailable,
      );
      throw const RuntimeError(
        RuntimeErrorCode.agentUnavailable,
        'Agent is not registered.',
      );
    }
    return entry;
  }

  void _validateLifecycleForStart(
    _AgentEntry entry,
    AgentSessionContext context,
  ) {
    const permitted = <AgentLifecycleState>{
      AgentLifecycleState.registered,
      AgentLifecycleState.stopped,
      AgentLifecycleState.failed,
    };
    if (!permitted.contains(entry.state)) {
      _emitDiagnostic(
        AgentDiagnosticCode.lifecycleDenied,
        context.agentId,
        context.session.streamEpoch,
        RuntimeErrorCode.lifecycleInvalid,
      );
      _emitAudit(
        AgentAuditEventCode.lifecycleDenied,
        context.agentId,
        context.session.streamEpoch,
      );
      throw const RuntimeError(
        RuntimeErrorCode.lifecycleInvalid,
        'Agent lifecycle does not permit a new start operation.',
      );
    }
  }

  Future<void> _validateContext(
    AgentManifest manifest,
    AgentSessionContext context,
  ) async {
    if (context.agentId != manifest.agentId ||
        !context.grant.matches(context.session, manifest.agentId)) {
      _denyPermission(context, RuntimeErrorCode.staleStreamEpoch);
      throw const RuntimeError(
        RuntimeErrorCode.staleStreamEpoch,
        'Agent grant does not match its session or epoch.',
      );
    }
    if (!context.grant.isActiveAt(_nowMicros)) {
      _denyPermission(context, RuntimeErrorCode.permissionGrantExpired);
      throw const RuntimeError(
        RuntimeErrorCode.permissionGrantExpired,
        'Agent permission grant has expired or is not yet active.',
      );
    }
    if (!manifest.requestedPermissions.containsAll(context.grant.permissions) ||
        !context.grant.permissions.containsAll(manifest.requestedPermissions)) {
      _denyPermission(context, RuntimeErrorCode.policyDenied);
      throw const RuntimeError(
        RuntimeErrorCode.policyDenied,
        'Agent grant must exactly authorize the declared manifest permissions.',
      );
    }
  }

  Future<void> _validateCapabilities(
    AgentManifest manifest,
    AgentSessionContext context,
  ) async {
    for (final permission in manifest.requestedPermissions) {
      final availability =
          await _capabilityResolver.availabilityFor(permission);
      if (availability.permission != permission ||
          availability.truthLabel == TruthLabel.blocked ||
          availability.truthLabel == TruthLabel.failed ||
          ((availability.truthLabel == TruthLabel.simulated ||
                  availability.truthLabel == TruthLabel.prepared) &&
              context.executionMode != AgentExecutionMode.validation)) {
        _emitDiagnostic(
          AgentDiagnosticCode.capabilityBlocked,
          manifest.agentId,
          context.session.streamEpoch,
          RuntimeErrorCode.capabilityUnavailable,
        );
        _emitAudit(
          AgentAuditEventCode.capabilityBlocked,
          manifest.agentId,
          context.session.streamEpoch,
        );
        throw const RuntimeError(
          RuntimeErrorCode.capabilityUnavailable,
          'A declared agent capability is unavailable for this session mode.',
        );
      }
    }
  }

  Future<void> _validateProviders(
    AgentManifest manifest,
    AgentSessionContext context,
  ) async {
    for (final requirement in manifest.providerRequirements) {
      final readiness = await _providerResolver.readinessFor(requirement);
      if (readiness != ProviderReadiness.ready) {
        _emitDiagnostic(
          AgentDiagnosticCode.providerUnavailable,
          manifest.agentId,
          context.session.streamEpoch,
          RuntimeErrorCode.providerUnavailable,
        );
        _emitAudit(
          AgentAuditEventCode.providerRequirementFailed,
          manifest.agentId,
          context.session.streamEpoch,
        );
        throw const RuntimeError(
          RuntimeErrorCode.providerUnavailable,
          'A declared agent provider requirement is not ready.',
          retryable: true,
        );
      }
    }
  }

  void _denyPermission(
      AgentSessionContext context, RuntimeErrorCode failureCode) {
    _emitDiagnostic(
      AgentDiagnosticCode.permissionDenied,
      context.agentId,
      context.session.streamEpoch,
      failureCode,
    );
    _emitAudit(
      AgentAuditEventCode.permissionDenied,
      context.agentId,
      context.session.streamEpoch,
    );
  }

  void _fail(
    _AgentEntry entry,
    AgentSessionContext context,
    RuntimeErrorCode failureCode,
  ) {
    _setState(entry, AgentLifecycleState.failed);
    _emitRegistration(
      entry.controller.manifest,
      AgentLifecycleState.failed,
      failureCode: failureCode,
    );
    _emitDiagnostic(
      AgentDiagnosticCode.controllerFailed,
      context.agentId,
      context.session.streamEpoch,
      failureCode,
    );
    _emitAudit(AgentAuditEventCode.agentFailed, context.agentId,
        context.session.streamEpoch);
  }

  void _setState(
    _AgentEntry entry,
    AgentLifecycleState state, {
    AgentSessionContext? context,
  }) {
    entry.state = state;
    if (context != null) {
      entry.activeContext = context;
    } else if (state == AgentLifecycleState.stopped ||
        state == AgentLifecycleState.failed) {
      entry.activeContext = null;
    }
  }

  bool _matches(AgentSessionContext first, AgentSessionContext second) =>
      first.agentId == second.agentId &&
      first.session.sessionId == second.session.sessionId &&
      first.session.streamEpoch == second.session.streamEpoch &&
      first.session.privacyGeneration == second.session.privacyGeneration &&
      first.grant.issuedAtMicros == second.grant.issuedAtMicros &&
      first.grant.expiresAtMicros == second.grant.expiresAtMicros;

  void _emitRegistration(
    AgentManifest manifest,
    AgentLifecycleState state, {
    RuntimeErrorCode? failureCode,
  }) {
    if (!_registrations.isClosed) {
      _registrations.add(AgentRegistration(
        manifest: manifest,
        state: state,
        observedAtMicros: _nowMicros,
        failureCode: failureCode,
      ));
    }
  }

  void _emitAudit(AgentAuditEventCode code, String agentId, int streamEpoch) {
    if (!_auditEvents.isClosed) {
      _auditEvents.add(AgentAuditEvent(
        code: code,
        agentId: agentId,
        streamEpoch: streamEpoch,
        observedAtMicros: _nowMicros,
      ));
    }
  }

  void _emitDiagnostic(
    AgentDiagnosticCode code,
    String agentId,
    int streamEpoch,
    RuntimeErrorCode failureCode,
  ) {
    if (!_diagnostics.isClosed) {
      _diagnostics.add(AgentDiagnostic(
        code: code,
        agentId: agentId,
        streamEpoch: streamEpoch,
        observedAtMicros: _nowMicros,
        failureCode: failureCode,
      ));
    }
  }

  void _ensureNotDisposed() {
    if (_disposed) {
      throw const RuntimeError(
        RuntimeErrorCode.sessionClosed,
        'Agent runtime has been disposed.',
      );
    }
  }
}
