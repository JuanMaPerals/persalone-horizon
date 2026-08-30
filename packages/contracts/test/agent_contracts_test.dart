import 'package:persalone_contracts/persalone_contracts.dart';
import 'package:test/test.dart';

void main() {
  const AgentManifest validManifest = AgentManifest(
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

  const TranslationSession session = TranslationSession(
    sessionId: 'session-1',
    streamEpoch: 4,
    direction: TranslationDirection.englishToSpanish,
    privacyGeneration: 2,
  );

  group('AgentManifest', () {
    test('accepts a complete versioned manifest', () {
      expect(validManifest.validate, returnsNormally);
    });

    test('rejects duplicate provider categories', () {
      const AgentManifest duplicateProviders = AgentManifest(
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
          AgentProviderRequirement(
            category: AgentProviderCategory.localTextTranslation,
            localOnly: true,
          ),
        ],
        memoryPolicy: AgentMemoryPolicy.none,
      );

      expect(
        duplicateProviders.validate,
        throwsA(
          isA<RuntimeError>().having(
            (RuntimeError error) => error.code,
            'code',
            RuntimeErrorCode.invalidContract,
          ),
        ),
      );
    });
  });

  group('AgentPermissionGrant', () {
    const AgentPermissionGrant grant = AgentPermissionGrant(
      agentId: 'persalone.test.agent',
      sessionId: 'session-1',
      streamEpoch: 4,
      privacyGeneration: 2,
      permissions: <AgentPermission>{
        AgentPermission.liveTranslationControl,
      },
      issuedAtMicros: 10,
      expiresAtMicros: 20,
    );

    test('is active only inside its explicit time window', () {
      expect(grant.isActiveAt(9), isFalse);
      expect(grant.isActiveAt(10), isTrue);
      expect(grant.isActiveAt(19), isTrue);
      expect(grant.isActiveAt(20), isFalse);
    });

    test('matches only its declared session, epoch and privacy generation', () {
      expect(grant.matches(session, 'persalone.test.agent'), isTrue);
      expect(grant.matches(session, 'persalone.other.agent'), isFalse);
      expect(
        grant.matches(
          const TranslationSession(
            sessionId: 'session-1',
            streamEpoch: 5,
            direction: TranslationDirection.englishToSpanish,
            privacyGeneration: 2,
          ),
          'persalone.test.agent',
        ),
        isFalse,
      );
    });
  });
}
