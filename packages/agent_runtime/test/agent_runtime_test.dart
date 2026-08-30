import 'package:persalone_agent_runtime/persalone_agent_runtime.dart';
import 'package:persalone_contracts/persalone_contracts.dart';
import 'package:test/test.dart';

const AgentManifest _manifest = AgentManifest(
  schemaVersion: AgentManifest.currentSchemaVersion,
  agentId: 'persalone.test.agent',
  displayName: 'Test agent',
  version: '0.1.0',
  requestedPermissions: <AgentPermission>{
    AgentPermission.liveTranslationControl,
  },
  providerRequirements: <AgentProviderRequirement>[
    AgentProviderRequirement(
      category: AgentProviderCategory.localTextTranslation,
      localOnly: true,
    ),
  ],
  memoryPolicy: AgentMemoryPolicy.none,
);

const TranslationSession _session = TranslationSession(
  sessionId: 'session-1',
  streamEpoch: 3,
  direction: TranslationDirection.englishToSpanish,
  privacyGeneration: 1,
);

AgentSessionContext _context({
  Set<AgentPermission> permissions = const <AgentPermission>{
    AgentPermission.liveTranslationControl,
  },
  AgentExecutionMode mode = AgentExecutionMode.validation,
  int epoch = 3,
}) =>
    AgentSessionContext(
      agentId: _manifest.agentId,
      session: TranslationSession(
        sessionId: _session.sessionId,
        streamEpoch: epoch,
        direction: _session.direction,
        privacyGeneration: _session.privacyGeneration,
      ),
      grant: AgentPermissionGrant(
        agentId: _manifest.agentId,
        sessionId: _session.sessionId,
        streamEpoch: epoch,
        privacyGeneration: _session.privacyGeneration,
        permissions: permissions,
        issuedAtMicros: 10,
        expiresAtMicros: 200,
      ),
      executionMode: mode,
    );

final class _FakeController implements AgentController {
  _FakeController(this.manifest);

  @override
  final AgentManifest manifest;
  int starts = 0;
  int stops = 0;
  int disposes = 0;

  @override
  Future<void> dispose() async {
    disposes += 1;
  }

  @override
  Future<void> start(AgentSessionContext context) async {
    starts += 1;
  }

  @override
  Future<void> stop(AgentSessionContext context) async {
    stops += 1;
  }
}

final class _CapabilityResolver implements AgentCapabilityResolver {
  _CapabilityResolver(this.label);

  final TruthLabel label;

  @override
  Future<AgentCapabilityAvailability> availabilityFor(
    AgentPermission permission,
  ) async =>
      AgentCapabilityAvailability(permission: permission, truthLabel: label);
}

final class _ProviderResolver implements AgentProviderResolver {
  _ProviderResolver(this.readiness);

  final ProviderReadiness readiness;

  @override
  Future<ProviderReadiness> readinessFor(
    AgentProviderRequirement requirement,
  ) async =>
      readiness;
}

final class _TranslationController implements TranslationSessionController {
  int starts = 0;
  int stops = 0;
  int disposes = 0;
  LiveTranslationConfig? config;
  AudioSessionDescriptor? audioSession;

  @override
  Future<void> dispose() async {
    disposes += 1;
  }

  @override
  Future<void> start({
    required LiveTranslationConfig config,
    required AudioSessionDescriptor audioSession,
  }) async {
    starts += 1;
    this.config = config;
    this.audioSession = audioSession;
  }

  @override
  Future<void> stop() async {
    stops += 1;
  }
}

PersalOneAgentRuntime _runtime({
  TruthLabel capability = TruthLabel.prepared,
  ProviderReadiness provider = ProviderReadiness.ready,
}) =>
    PersalOneAgentRuntime(
      capabilityResolver: _CapabilityResolver(capability),
      providerResolver: _ProviderResolver(provider),
      clock: () => DateTime.fromMicrosecondsSinceEpoch(100),
    );

void main() {
  group('PersalOneAgentRuntime', () {
    test('does not call an agent when the grant omits a declared permission',
        () async {
      final runtime = _runtime();
      final controller = _FakeController(_manifest);
      await runtime.register(controller);

      await expectLater(
        runtime.start(
          _manifest.agentId,
          _context(permissions: const <AgentPermission>{}),
        ),
        throwsA(
          isA<RuntimeError>().having(
            (RuntimeError error) => error.code,
            'code',
            RuntimeErrorCode.policyDenied,
          ),
        ),
      );
      expect(controller.starts, 0);
      await runtime.dispose();
    });

    test('blocks standard execution of a PREPARED capability', () async {
      final runtime = _runtime(capability: TruthLabel.prepared);
      final controller = _FakeController(_manifest);
      await runtime.register(controller);

      await expectLater(
        runtime.start(
          _manifest.agentId,
          _context(mode: AgentExecutionMode.standard),
        ),
        throwsA(
          isA<RuntimeError>().having(
            (RuntimeError error) => error.code,
            'code',
            RuntimeErrorCode.capabilityUnavailable,
          ),
        ),
      );
      expect(controller.starts, 0);
      await runtime.dispose();
    });

    test('blocks a provider requirement before calling the controller',
        () async {
      final runtime = _runtime(provider: ProviderReadiness.unavailable);
      final controller = _FakeController(_manifest);
      await runtime.register(controller);

      await expectLater(
        runtime.start(_manifest.agentId, _context()),
        throwsA(
          isA<RuntimeError>().having(
            (RuntimeError error) => error.code,
            'code',
            RuntimeErrorCode.providerUnavailable,
          ),
        ),
      );
      expect(controller.starts, 0);
      await runtime.dispose();
    });

    test('rejects a stale stop epoch without calling the controller', () async {
      final runtime = _runtime();
      final controller = _FakeController(_manifest);
      await runtime.register(controller);
      await runtime.start(_manifest.agentId, _context());

      await expectLater(
        runtime.stop(_manifest.agentId, _context(epoch: 4)),
        throwsA(
          isA<RuntimeError>().having(
            (RuntimeError error) => error.code,
            'code',
            RuntimeErrorCode.staleStreamEpoch,
          ),
        ),
      );
      expect(controller.stops, 0);
      await runtime.stop(_manifest.agentId, _context());
      expect(controller.stops, 1);
      await runtime.dispose();
    });
  });

  group('HorizonTranslateAgent', () {
    test('delegates only a high-level session start and stop to G5', () async {
      final translation = _TranslationController();
      final agent = HorizonTranslateAgent(
        sessionController: translation,
        configForSession: (AgentSessionContext context) =>
            LiveTranslationConfig(
          session: context.session,
          sourceLocale: 'en-US',
          targetLocale: 'es-ES',
          consent: const TranslationConsent(
            acceptedAtMicros: 10,
            localProcessingAllowed: true,
            modelDownloadAllowed: true,
            remoteProcessingAllowed: false,
          ),
        ),
        audioSessionFor: (AgentSessionContext context) =>
            AudioSessionDescriptor(
          sessionId: context.session.sessionId,
          streamEpoch: context.session.streamEpoch,
          streamId: 'android-host',
        ),
      );
      final runtime = PersalOneAgentRuntime(
        capabilityResolver: _CapabilityResolver(TruthLabel.prepared),
        providerResolver: _ProviderResolver(ProviderReadiness.ready),
        clock: () => DateTime.fromMicrosecondsSinceEpoch(100),
      );
      await runtime.register(agent);

      final AgentSessionContext context = AgentSessionContext(
        agentId: HorizonTranslateAgent.agentId,
        session: _session,
        grant: AgentPermissionGrant(
          agentId: HorizonTranslateAgent.agentId,
          sessionId: _session.sessionId,
          streamEpoch: _session.streamEpoch,
          privacyGeneration: _session.privacyGeneration,
          permissions:
              HorizonTranslateAgent.horizonManifest.requestedPermissions,
          issuedAtMicros: 10,
          expiresAtMicros: 200,
        ),
        executionMode: AgentExecutionMode.validation,
      );

      await runtime.start(HorizonTranslateAgent.agentId, context);
      await runtime.stop(HorizonTranslateAgent.agentId, context);

      expect(translation.starts, 1);
      expect(translation.stops, 1);
      expect(translation.config?.session.streamEpoch, _session.streamEpoch);
      await runtime.dispose();
      expect(translation.disposes, 1);
    });
  });
}
