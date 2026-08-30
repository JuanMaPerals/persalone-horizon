import 'dart:async';

import 'package:persalone_contracts/persalone_contracts.dart';

/// A controller handles only a high-level agent lifecycle. It intentionally has
/// no APIs for PCM, transcripts, translations, device identifiers, or provider
/// credentials.
abstract interface class AgentController {
  AgentManifest get manifest;

  /// Emits only terminal lifecycle evidence; it never exposes G5 data-plane
  /// content or provider-specific payloads to the authorization runtime.
  Stream<AgentControllerTerminalEvent> get terminalEvents;

  /// A monotonically advancing, controller-owned lifecycle generation. It is
  /// assigned before a start may acquire capability resources.
  int? get activeStartGeneration;

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
  _AgentEntry(this.controller, this.manifest, this.state);

  final AgentController controller;

  /// Immutable registration-time declaration. Lifecycle behavior must never
  /// consult [AgentController.manifest] after registration.
  final AgentManifest manifest;
  AgentLifecycleState state;
  AgentSessionContext? activeContext;
  int? activeStartGeneration;
  Future<void>? terminalFuture;
  StreamSubscription<AgentControllerTerminalEvent>? terminalSubscription;
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
    // Read this potentially mutable controller boundary exactly once.
    final capturedManifest = controller.manifest;
    try {
      capturedManifest.validate();
      final manifest = _snapshotManifest(capturedManifest);
      if (_entries.containsKey(manifest.agentId)) {
        throw const RuntimeError(
          RuntimeErrorCode.invalidContract,
          'An agent with this identifier is already registered.',
        );
      }
      final entry = _AgentEntry(
        controller,
        manifest,
        AgentLifecycleState.registered,
      );
      _entries[manifest.agentId] = entry;
      entry.terminalSubscription = controller.terminalEvents.listen(
        (event) {
          unawaited(_handleControllerTerminal(entry, event));
        },
        onError: (Object error, StackTrace stackTrace) {
          final context = entry.activeContext;
          if (context != null) {
            unawaited(_fail(
              entry,
              context,
              RuntimeErrorCode.providerUnavailable,
              stopController: true,
            ));
          }
        },
      );
      _emitRegistration(manifest, AgentLifecycleState.registered);
      _emitAudit(AgentAuditEventCode.agentRegistered, manifest.agentId, 0);
    } on RuntimeError catch (error) {
      _emitRegistration(
        capturedManifest,
        AgentLifecycleState.failed,
        failureCode: error.code,
      );
      _emitDiagnostic(
        AgentDiagnosticCode.manifestInvalid,
        capturedManifest.agentId,
        0,
        error.code,
      );
      _emitAudit(
        AgentAuditEventCode.registrationRejected,
        capturedManifest.agentId,
        0,
      );
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
      manifest: entry.manifest,
      state: entry.state,
      observedAtMicros: _nowMicros,
    );
  }

  Future<void> start(String agentId, AgentSessionContext context) async {
    _ensureNotDisposed();
    final capturedContext = _snapshotContext(context);
    final entry = _entryFor(agentId, capturedContext.session.streamEpoch);
    final manifest = entry.manifest;
    _validateLifecycleForStart(entry, capturedContext);
    entry.terminalFuture = null;
    var controllerStartInvoked = false;
    _setState(entry, AgentLifecycleState.permissionRequired);
    _emitRegistration(manifest, AgentLifecycleState.permissionRequired);

    try {
      await _validateContext(manifest, capturedContext);
      await _validateCapabilities(manifest, capturedContext);
      await _validateProviders(manifest, capturedContext);
      _setState(entry, AgentLifecycleState.ready);
      _emitRegistration(manifest, AgentLifecycleState.ready);
      _setState(entry, AgentLifecycleState.starting);
      _emitRegistration(manifest, AgentLifecycleState.starting);
      _emitAudit(AgentAuditEventCode.agentStarting, agentId,
          capturedContext.session.streamEpoch);
      controllerStartInvoked = true;
      await entry.controller.start(capturedContext);
      final activeStartGeneration = entry.controller.activeStartGeneration;
      if (activeStartGeneration == null) {
        throw const RuntimeError(
          RuntimeErrorCode.invalidContract,
          'Agent controller did not expose a terminal-event generation.',
        );
      }
      entry.activeStartGeneration = activeStartGeneration;
      _setState(entry, AgentLifecycleState.active, context: capturedContext);
      _emitRegistration(manifest, AgentLifecycleState.active);
      _emitAudit(AgentAuditEventCode.agentStarted, agentId,
          capturedContext.session.streamEpoch);
    } on RuntimeError catch (error) {
      await _fail(
        entry,
        capturedContext,
        error.code,
        stopController: controllerStartInvoked,
      );
      rethrow;
    } on Object {
      await _fail(
        entry,
        capturedContext,
        RuntimeErrorCode.providerUnavailable,
        stopController: controllerStartInvoked,
      );
      throw const RuntimeError(
        RuntimeErrorCode.providerUnavailable,
        'Agent controller failed without an exposed provider-safe error.',
        retryable: true,
      );
    }
  }

  Future<void> stop(String agentId, AgentSessionContext context) async {
    _ensureNotDisposed();
    final capturedContext = _snapshotContext(context);
    final entry = _entryFor(agentId, capturedContext.session.streamEpoch);
    if (entry.state != AgentLifecycleState.active ||
        entry.activeContext == null ||
        !_matches(entry.activeContext!, capturedContext)) {
      _emitDiagnostic(
        AgentDiagnosticCode.staleCallbackDiscarded,
        agentId,
        capturedContext.session.streamEpoch,
        RuntimeErrorCode.staleStreamEpoch,
      );
      _emitAudit(
        AgentAuditEventCode.staleCallbackDiscarded,
        agentId,
        capturedContext.session.streamEpoch,
      );
      throw const RuntimeError(
        RuntimeErrorCode.staleStreamEpoch,
        'Stop request does not match the active agent session generation.',
      );
    }
    _setState(entry, AgentLifecycleState.stopping);
    _emitRegistration(entry.manifest, AgentLifecycleState.stopping);
    _emitAudit(AgentAuditEventCode.agentStopping, agentId,
        capturedContext.session.streamEpoch);
    try {
      await entry.controller.stop(capturedContext);
      _setState(entry, AgentLifecycleState.stopped);
      _emitRegistration(entry.manifest, AgentLifecycleState.stopped);
      _emitAudit(AgentAuditEventCode.agentStopped, agentId,
          capturedContext.session.streamEpoch);
    } on RuntimeError catch (error) {
      await _fail(entry, capturedContext, error.code);
      rethrow;
    } on Object {
      await _fail(entry, capturedContext, RuntimeErrorCode.providerUnavailable);
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
      await entry.terminalSubscription?.cancel();
      entry.terminalSubscription = null;
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
      if (readiness == ProviderReadiness.unavailable ||
          readiness == ProviderReadiness.failed) {
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

  Future<void> _handleControllerTerminal(
    _AgentEntry entry,
    AgentControllerTerminalEvent event,
  ) async {
    final context = entry.activeContext;
    if (context == null ||
        entry.state != AgentLifecycleState.active ||
        event.agentId != context.agentId ||
        event.streamEpoch != context.session.streamEpoch ||
        event.privacyGeneration != context.session.privacyGeneration ||
        entry.activeStartGeneration == null ||
        event.startGeneration != entry.activeStartGeneration) {
      _emitDiagnostic(
        AgentDiagnosticCode.staleCallbackDiscarded,
        entry.manifest.agentId,
        event.streamEpoch,
        RuntimeErrorCode.staleStreamEpoch,
      );
      _emitAudit(
        AgentAuditEventCode.staleCallbackDiscarded,
        entry.manifest.agentId,
        event.streamEpoch,
      );
      return;
    }
    await _fail(
      entry,
      context,
      event.failureCode,
      stopController: true,
    );
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

  Future<void> _fail(
    _AgentEntry entry,
    AgentSessionContext context,
    RuntimeErrorCode failureCode, {
    bool stopController = false,
  }) {
    final inFlight = entry.terminalFuture;
    if (inFlight != null) {
      return inFlight;
    }
    entry.terminalFuture = _completeFailure(
      entry,
      context,
      failureCode,
      stopController: stopController,
    );
    return entry.terminalFuture!;
  }

  Future<void> _completeFailure(
    _AgentEntry entry,
    AgentSessionContext context,
    RuntimeErrorCode failureCode, {
    required bool stopController,
  }) async {
    if (stopController) {
      _setState(entry, AgentLifecycleState.stopping);
      _emitRegistration(entry.manifest, AgentLifecycleState.stopping);
      _emitAudit(AgentAuditEventCode.agentStopping, context.agentId,
          context.session.streamEpoch);
      try {
        await entry.controller.stop(context);
      } on Object {
        // The primary failure remains authoritative. A failed controller stop
        // must never restore an active capability or disclose provider detail.
      }
    }
    _setState(entry, AgentLifecycleState.failed);
    _emitRegistration(
      entry.manifest,
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

  AgentManifest _snapshotManifest(AgentManifest source) => AgentManifest(
        schemaVersion: source.schemaVersion,
        agentId: source.agentId,
        displayName: source.displayName,
        version: source.version,
        requestedPermissions: Set<AgentPermission>.unmodifiable(
          source.requestedPermissions,
        ),
        providerRequirements: List<AgentProviderRequirement>.unmodifiable(
          source.providerRequirements.map(
            (requirement) => AgentProviderRequirement(
              category: requirement.category,
              localOnly: requirement.localOnly,
              minimumRevision: requirement.minimumRevision,
            ),
          ),
        ),
        memoryPolicy: source.memoryPolicy,
      );

  AgentSessionContext _snapshotContext(AgentSessionContext source) {
    final session = TranslationSession(
      sessionId: source.session.sessionId,
      streamEpoch: source.session.streamEpoch,
      direction: source.session.direction,
      privacyGeneration: source.session.privacyGeneration,
      turnGeneration: source.session.turnGeneration,
    );
    final grant = AgentPermissionGrant(
      agentId: source.grant.agentId,
      sessionId: source.grant.sessionId,
      streamEpoch: source.grant.streamEpoch,
      privacyGeneration: source.grant.privacyGeneration,
      permissions: Set<AgentPermission>.unmodifiable(source.grant.permissions),
      issuedAtMicros: source.grant.issuedAtMicros,
      expiresAtMicros: source.grant.expiresAtMicros,
    );
    return AgentSessionContext(
      agentId: source.agentId,
      session: session,
      grant: grant,
      executionMode: source.executionMode,
    );
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
      entry.activeStartGeneration = null;
    }
  }

  bool _matches(AgentSessionContext first, AgentSessionContext second) =>
      first.agentId == second.agentId &&
      first.session.sessionId == second.session.sessionId &&
      first.session.streamEpoch == second.session.streamEpoch &&
      first.session.privacyGeneration == second.session.privacyGeneration &&
      first.session.turnGeneration == second.session.turnGeneration &&
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
