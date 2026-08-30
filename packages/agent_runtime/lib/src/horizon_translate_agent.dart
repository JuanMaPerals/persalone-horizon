import 'package:persalone_contracts/persalone_contracts.dart';
import 'package:persalone_translation_runtime/persalone_translation_runtime.dart';

import 'agent_runtime.dart';

/// High-level port that makes the G5 session lifecycle available to the agent.
/// It has no API for audio frames, transcripts, translations, provider tokens or
/// device identifiers.
abstract interface class TranslationSessionController {
  Future<void> start({
    required LiveTranslationConfig config,
    required AudioSessionDescriptor audioSession,
  });

  Future<void> stop();
  Future<void> dispose();
}

/// Adapter for the existing G5 orchestrator. This is the only G7 class that
/// imports the translation runtime, and it invokes only start/stop/dispose.
final class HorizonTranslationSessionController
    implements TranslationSessionController {
  HorizonTranslationSessionController(this._runtime);

  final HorizonTranslationRuntime _runtime;

  @override
  Future<void> start({
    required LiveTranslationConfig config,
    required AudioSessionDescriptor audioSession,
  }) =>
      _runtime.start(config: config, audioSession: audioSession);

  @override
  Future<void> stop() => _runtime.stop();

  @override
  Future<void> dispose() => _runtime.dispose();
}

typedef LiveTranslationConfigForSession = LiveTranslationConfig Function(
  AgentSessionContext context,
);
typedef AudioSessionForAgent = AudioSessionDescriptor Function(
  AgentSessionContext context,
);

/// First HORIZON agent. It controls a session after G7 has authorized it but
/// never participates in the G5 PCM/STT/MT/TTS data path.
final class HorizonTranslateAgent implements AgentController {
  HorizonTranslateAgent({
    required TranslationSessionController sessionController,
    required LiveTranslationConfigForSession configForSession,
    required AudioSessionForAgent audioSessionFor,
  })  : _sessionController = sessionController,
        _configForSession = configForSession,
        _audioSessionFor = audioSessionFor;

  static const String agentId = 'persalone.horizon.translate';

  static const AgentManifest horizonManifest = AgentManifest(
    schemaVersion: AgentManifest.currentSchemaVersion,
    agentId: agentId,
    displayName: 'HORIZON Translate',
    version: '0.1.0',
    requestedPermissions: <AgentPermission>{
      AgentPermission.liveTranslationControl,
      AgentPermission.microphoneCapture,
      AgentPermission.speakerPlayback,
      AgentPermission.localSpeechRecognition,
      AgentPermission.localTextTranslation,
      AgentPermission.modelDownload,
      AgentPermission.localSpeechSynthesis,
    },
    providerRequirements: <AgentProviderRequirement>[
      AgentProviderRequirement(
        category: AgentProviderCategory.localSpeechRecognition,
        localOnly: true,
      ),
      AgentProviderRequirement(
        category: AgentProviderCategory.localTextTranslation,
        localOnly: true,
      ),
      AgentProviderRequirement(
        category: AgentProviderCategory.localSpeechSynthesis,
        localOnly: true,
      ),
    ],
    memoryPolicy: AgentMemoryPolicy.none,
  );

  final TranslationSessionController _sessionController;
  final LiveTranslationConfigForSession _configForSession;
  final AudioSessionForAgent _audioSessionFor;
  bool _disposed = false;

  @override
  AgentManifest get manifest => HorizonTranslateAgent.horizonManifest;

  @override
  Future<void> start(AgentSessionContext context) async {
    _ensureActive();
    final config = _configForSession(context);
    final audioSession = _audioSessionFor(context);
    if (config.session.sessionId != context.session.sessionId ||
        config.session.streamEpoch != context.session.streamEpoch ||
        config.session.privacyGeneration != context.session.privacyGeneration ||
        audioSession.sessionId != context.session.sessionId ||
        audioSession.streamEpoch != context.session.streamEpoch) {
      throw const RuntimeError(
        RuntimeErrorCode.invalidContract,
        'G5 session configuration must match the authorized agent session.',
      );
    }
    await _sessionController.start(config: config, audioSession: audioSession);
  }

  @override
  Future<void> stop(AgentSessionContext context) async {
    _ensureActive();
    await _sessionController.stop();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await _sessionController.dispose();
  }

  void _ensureActive() {
    if (_disposed) {
      throw const RuntimeError(
        RuntimeErrorCode.sessionClosed,
        'HORIZON Translate agent has been disposed.',
      );
    }
  }
}
