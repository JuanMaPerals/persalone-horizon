import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:persalone_agent_runtime/persalone_agent_runtime.dart';
import 'package:persalone_audio_adapters/persalone_audio_adapters.dart';
import 'package:persalone_contracts/persalone_contracts.dart';
import 'package:persalone_translation_runtime/persalone_translation_runtime.dart';

void main() {
  runApp(const PersalOneApp());
}

/// Android-first product shell. Each card presents the state observable from
/// the running app and preserves PREPARED/BLOCKED labels until physical evidence
/// exists. It never manufactures device connections, transcripts or latency.
class PersalOneApp extends StatelessWidget {
  const PersalOneApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PersalOne HORIZON',
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const HorizonProductScreen(),
    );
  }
}

class HorizonProductScreen extends StatefulWidget {
  const HorizonProductScreen({super.key});

  @override
  State<HorizonProductScreen> createState() => _HorizonProductScreenState();
}

class _HorizonProductScreenState extends State<HorizonProductScreen> {
  static const AudioFormat _format = AudioFormat.voice16kMono;
  static const int _maxSampleBytes = 32000;
  static final Stopwatch _clock = Stopwatch()..start();

  late final AndroidMicrophoneAdapter _microphone;
  late final AndroidSpeakerAdapter _speaker;
  late final AndroidSpeechRecognizerProvider _stt;
  late final MlKitOnDeviceTranslatorProvider _translator;
  late final AndroidTextToSpeechProvider _tts;
  late final HorizonTranslationRuntime _translationRuntime;
  late final PersalOneAgentRuntime _agentRuntime;
  late final HorizonTranslateAgent _translateAgent;
  final BytesBuilder _sample = BytesBuilder(copy: false);

  StreamSubscription<AudioFrame>? _frameSubscription;
  StreamSubscription<AudioDiagnostic>? _inputDiagnosticSubscription;
  StreamSubscription<AudioDiagnostic>? _outputDiagnosticSubscription;
  StreamSubscription<TranscriptSegment>? _transcriptSubscription;
  StreamSubscription<TranslationSegment>? _translationSubscription;
  StreamSubscription<LiveTranslationDiagnostic>? _runtimeDiagnosticSubscription;
  StreamSubscription<ProviderSnapshot>? _translationSnapshotSubscription;
  StreamSubscription<AgentRegistration>? _agentRegistrationSubscription;
  StreamSubscription<AgentAuditEvent>? _agentAuditSubscription;
  StreamSubscription<AgentDiagnostic>? _agentDiagnosticSubscription;

  AgentSessionContext? _activeAgentContext;
  bool _permissionGranted = false;
  bool _capturing = false;
  bool _playing = false;
  bool _liveRunning = false;
  bool _localConsent = false;
  bool _modelDownloadConsent = false;
  bool? _inputTimestampAvailable;
  bool? _outputTimestampAvailable;
  int _inputFrames = 0;
  int _inputDrops = 0;
  int _outputWrites = 0;
  int _underruns = 0;
  int _staleCallbacks = 0;
  int _agentAuditEvents = 0;
  int _agentDiagnostics = 0;
  TranslationDirection _direction = TranslationDirection.englishToSpanish;
  AgentLifecycleState _agentState = AgentLifecycleState.discovered;
  String _status = 'Sin ensayo físico ejecutado.';
  String _liveStatus =
      'G5 PREPARED — requiere consentimiento y ensayo Android.';
  String _modelStatus = 'No preparado';
  String _agentStatus = 'Registrando manifiesto local.';
  String _partialTranscript = '';
  String _finalTranscript = '';
  String _translation = '';

  @override
  void initState() {
    super.initState();
    final audioBridge = MethodChannelAndroidHostAudioBridge();
    final translationBridge = MethodChannelAndroidLiveTranslationBridge();
    _microphone = AndroidMicrophoneAdapter(bridge: audioBridge);
    _speaker = AndroidSpeakerAdapter(bridge: audioBridge);
    _stt = AndroidSpeechRecognizerProvider(bridge: translationBridge);
    _translator = MlKitOnDeviceTranslatorProvider(bridge: translationBridge);
    _tts = AndroidTextToSpeechProvider(bridge: translationBridge);
    _translationRuntime = HorizonTranslationRuntime(
      input: _microphone,
      stt: _stt,
      translator: _translator,
      synthesizer: _tts,
    );
    _agentRuntime = PersalOneAgentRuntime(
      capabilityResolver: _AndroidHostCapabilityResolver(
        microphonePermissionGranted: () => _permissionGranted,
      ),
      providerResolver: const _LocalTranslationProviderResolver(),
    );
    _translateAgent = HorizonTranslateAgent(
      sessionController:
          HorizonTranslationSessionController(_translationRuntime),
      configForSession: _translationConfigFor,
      audioSessionFor: _audioSessionFor,
    );

    _frameSubscription = _microphone.frames.listen(_collectInputFrame);
    _inputDiagnosticSubscription = _microphone.diagnostics.listen(
      _observeInputDiagnostic,
    );
    _outputDiagnosticSubscription = _speaker.diagnostics.listen(
      _observeOutputDiagnostic,
    );
    _transcriptSubscription = _translationRuntime.transcripts.listen(
      _observeTranscript,
    );
    _translationSubscription = _translationRuntime.translations.listen(
      _observeTranslation,
    );
    _runtimeDiagnosticSubscription = _translationRuntime.diagnostics.listen(
      _observeRuntimeDiagnostic,
    );
    _translationSnapshotSubscription = _translator.snapshots.listen(
      _observeTranslationSnapshot,
    );
    _agentRegistrationSubscription = _agentRuntime.registrations.listen(
      _observeAgentRegistration,
    );
    _agentAuditSubscription = _agentRuntime.auditEvents.listen(
      _observeAgentAudit,
    );
    _agentDiagnosticSubscription = _agentRuntime.diagnostics.listen(
      _observeAgentDiagnostic,
    );
    unawaited(_registerTranslateAgent());
  }

  @override
  void dispose() {
    _frameSubscription?.cancel();
    _inputDiagnosticSubscription?.cancel();
    _outputDiagnosticSubscription?.cancel();
    _transcriptSubscription?.cancel();
    _translationSubscription?.cancel();
    _runtimeDiagnosticSubscription?.cancel();
    _translationSnapshotSubscription?.cancel();
    _agentRegistrationSubscription?.cancel();
    _agentAuditSubscription?.cancel();
    _agentDiagnosticSubscription?.cancel();
    _agentRuntime.dispose();
    _microphone.dispose();
    _speaker.dispose();
    super.dispose();
  }

  Future<void> _registerTranslateAgent() async {
    try {
      await _agentRuntime.register(_translateAgent);
      if (!mounted) return;
      setState(() => _agentStatus = 'Manifiesto registrado — PREPARED.');
    } on RuntimeError catch (error) {
      if (!mounted) return;
      setState(() => _agentStatus = 'Registro bloqueado: ${error.code.name}.');
    }
  }

  Future<void> _requestPermission() async {
    try {
      final bool granted = await _microphone.requestPermission();
      if (!mounted) return;
      setState(() {
        _permissionGranted = granted;
        _status = granted
            ? 'Permiso concedido. G3/G4 siguen PREPARED hasta ensayo físico.'
            : 'Permiso denegado. G3 y G5 quedan bloqueados.';
      });
    } catch (error) {
      _setFailure('No se pudo solicitar permiso: ${error.runtimeType}.');
    }
  }

  Future<void> _toggleCapture() async {
    if (_capturing) {
      try {
        await _microphone.stop();
        if (!mounted) return;
        setState(() {
          _capturing = false;
          _status = _sample.length > 0
              ? 'Captura detenida; muestra local acotada lista para G4.'
              : 'Captura detenida sin frames PCM válidos.';
        });
      } catch (error) {
        _setFailure('No se pudo detener la captura: ${error.runtimeType}.');
      }
      return;
    }

    try {
      _sample.clear();
      _inputFrames = 0;
      _inputDrops = 0;
      _inputTimestampAvailable = null;
      final session = AudioSessionDescriptor(
        sessionId: 'android-host-audio-check',
        streamEpoch: DateTime.now().microsecondsSinceEpoch,
        streamId: 'android-microphone',
      );
      await _microphone.start(session, _format);
      if (!mounted) return;
      setState(() {
        _capturing = true;
        _status = 'Capturando PCM real; no se escribe audio en disco.';
      });
    } catch (error) {
      _setFailure('No se pudo iniciar la captura: ${error.runtimeType}.');
    }
  }

  Future<void> _playCapturedSample() async {
    if (_sample.length == 0) {
      _setFailure('Primero captura una muestra real de micrófono.');
      return;
    }
    try {
      final pcm = _sample.takeBytes();
      final session = AudioSessionDescriptor(
        sessionId: 'android-host-audio-check',
        streamEpoch: DateTime.now().microsecondsSinceEpoch,
        streamId: 'android-speaker',
      );
      await _speaker.start(session, _format);
      if (!mounted) return;
      setState(() => _playing = true);
      await _speaker.enqueue(
        AudioFrame(
          schemaVersion: CapabilityManifest.currentSchemaVersion,
          session: session,
          direction: AudioDirection.output,
          sequence: 0,
          codec: AudioCodec.pcmS16le,
          format: _format,
          capturedAtMicros: _clock.elapsedMicroseconds,
          receivedAtMicros: _clock.elapsedMicroseconds,
          durationMicros: (pcm.length ~/ _format.bytesPerFrame) *
              1000000 ~/
              _format.sampleRateHz,
          payload: pcm,
        ),
      );
      await Future<void>.delayed(
        Duration(
          microseconds: (pcm.length ~/ _format.bytesPerFrame) *
              1000000 ~/
              _format.sampleRateHz,
        ),
      );
      await _speaker.stop();
      if (!mounted) return;
      setState(() {
        _playing = false;
        _status = 'Reproducción finalizada. Registra audibilidad humana en G4.';
      });
    } catch (error) {
      _setFailure('No se pudo reproducir la muestra: ${error.runtimeType}.');
    }
  }

  Future<void> _startLiveTranslation() async {
    if (!_permissionGranted) {
      setState(() => _liveStatus = 'G5 bloqueado: concede micrófono primero.');
      return;
    }
    if (!_localConsent || !_modelDownloadConsent) {
      setState(() {
        _liveStatus =
            'G5 bloqueado: concede procesamiento local y descarga de modelo para esta sesión.';
      });
      return;
    }
    try {
      final int now = DateTime.now().microsecondsSinceEpoch;
      final session = TranslationSession(
        sessionId: 'live-$now',
        streamEpoch: now,
        direction: _direction,
        privacyGeneration: now,
      );
      final context = AgentSessionContext(
        agentId: HorizonTranslateAgent.agentId,
        session: session,
        grant: AgentPermissionGrant(
          agentId: HorizonTranslateAgent.agentId,
          sessionId: session.sessionId,
          streamEpoch: session.streamEpoch,
          privacyGeneration: session.privacyGeneration,
          permissions:
              HorizonTranslateAgent.horizonManifest.requestedPermissions,
          issuedAtMicros: now,
          expiresAtMicros: now + const Duration(hours: 1).inMicroseconds,
        ),
        executionMode: AgentExecutionMode.validation,
      );
      setState(() {
        _activeAgentContext = context;
        _partialTranscript = '';
        _finalTranscript = '';
        _translation = '';
        _staleCallbacks = 0;
        _modelStatus = 'Preparando modelo on-device';
        _liveStatus =
            'G7 autorizó una sesión de validación; preparando proveedores locales.';
      });
      await _agentRuntime.start(HorizonTranslateAgent.agentId, context);
      if (!mounted) return;
      setState(() {
        _liveRunning = true;
        _liveStatus =
            'Escuchando con ruta Android real. PCM y texto permanecen sólo en memoria de sesión.';
      });
    } on RuntimeError catch (error) {
      if (!mounted) return;
      setState(() {
        _liveRunning = false;
        _activeAgentContext = null;
        _liveStatus = 'G5/G7 bloqueado: ${error.code.name}.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _liveRunning = false;
        _activeAgentContext = null;
        _liveStatus = 'G5/G7 no pudo iniciar: ${error.runtimeType}.';
      });
    }
  }

  Future<void> _stopLiveTranslation() async {
    final context = _activeAgentContext;
    if (context == null) return;
    try {
      await _agentRuntime.stop(HorizonTranslateAgent.agentId, context);
    } on RuntimeError catch (error) {
      if (!mounted) return;
      setState(() => _liveStatus = 'Stop bloqueado: ${error.code.name}.');
      return;
    }
    if (!mounted) return;
    setState(() {
      _liveRunning = false;
      _activeAgentContext = null;
      _partialTranscript = '';
      _finalTranscript = '';
      _translation = '';
      _liveStatus =
          'Sesión detenida. Se descartó el estado textual mostrado en memoria.';
    });
  }

  LiveTranslationConfig _translationConfigFor(AgentSessionContext context) {
    final locales =
        context.session.direction == TranslationDirection.englishToSpanish
            ? ('en-US', 'es-ES')
            : ('es-ES', 'en-US');
    return LiveTranslationConfig(
      session: context.session,
      sourceLocale: locales.$1,
      targetLocale: locales.$2,
      consent: TranslationConsent(
        acceptedAtMicros: context.grant.issuedAtMicros,
        localProcessingAllowed: _localConsent,
        modelDownloadAllowed: _modelDownloadConsent,
        remoteProcessingAllowed: false,
      ),
    );
  }

  AudioSessionDescriptor _audioSessionFor(AgentSessionContext context) =>
      AudioSessionDescriptor(
        sessionId: context.session.sessionId,
        streamEpoch: context.session.streamEpoch,
        streamId: 'android-microphone-live',
      );

  void _collectInputFrame(AudioFrame frame) {
    if (!_capturing) return;
    final pcm = frame.payload;
    if (_sample.length + pcm.length <= _maxSampleBytes) _sample.add(pcm);
    if (mounted) setState(() => _inputFrames += 1);
  }

  void _observeInputDiagnostic(AudioDiagnostic diagnostic) {
    if (!mounted) return;
    switch (diagnostic.code) {
      case AudioDiagnosticCode.inputDropped:
        setState(() => _inputDrops += diagnostic.value ?? 1);
      case AudioDiagnosticCode.captureTimestampAvailable:
        setState(() => _inputTimestampAvailable = true);
      case AudioDiagnosticCode.captureTimestampUnavailable:
        setState(() => _inputTimestampAvailable = false);
      default:
        break;
    }
  }

  void _observeOutputDiagnostic(AudioDiagnostic diagnostic) {
    if (!mounted) return;
    switch (diagnostic.code) {
      case AudioDiagnosticCode.outputFrameQueued:
        setState(() => _outputWrites += 1);
      case AudioDiagnosticCode.outputUnderrun:
        setState(() => _underruns = diagnostic.value ?? _underruns + 1);
      case AudioDiagnosticCode.outputTimestampAvailable:
        setState(() => _outputTimestampAvailable = true);
      case AudioDiagnosticCode.outputTimestampUnavailable:
        setState(() => _outputTimestampAvailable = false);
      default:
        break;
    }
  }

  void _observeTranscript(TranscriptSegment segment) {
    if (!mounted) return;
    setState(() {
      if (segment.stability == TranscriptStability.partial) {
        _partialTranscript = segment.text;
      } else {
        _finalTranscript = segment.text;
        _partialTranscript = '';
      }
    });
  }

  void _observeTranslation(TranslationSegment segment) {
    if (mounted) setState(() => _translation = segment.translatedText);
  }

  void _observeRuntimeDiagnostic(LiveTranslationDiagnostic diagnostic) {
    if (diagnostic.code ==
            LiveTranslationDiagnosticCode.staleCallbackDiscarded &&
        mounted) {
      setState(() => _staleCallbacks += 1);
    }
  }

  void _observeTranslationSnapshot(ProviderSnapshot snapshot) {
    if (!mounted) return;
    setState(() {
      _modelStatus = switch (snapshot.readiness) {
        ProviderReadiness.ready => 'Modelo on-device preparado (PREPARED)',
        ProviderReadiness.preparing => 'Preparando modelo on-device',
        ProviderReadiness.unavailable ||
        ProviderReadiness.failed =>
          'Modelo no disponible (${snapshot.failureReason ?? 'sin detalle'})',
        ProviderReadiness.unknown => 'Estado de modelo desconocido',
      };
    });
  }

  void _observeAgentRegistration(AgentRegistration registration) {
    if (!mounted) return;
    setState(() {
      _agentState = registration.state;
      _agentStatus = registration.failureCode == null
          ? 'Estado ${registration.state.name} — evidencia PREPARED.'
          : 'Estado ${registration.state.name}: ${registration.failureCode!.name}.';
    });
  }

  void _observeAgentAudit(AgentAuditEvent event) {
    if (mounted) setState(() => _agentAuditEvents += 1);
  }

  void _observeAgentDiagnostic(AgentDiagnostic diagnostic) {
    if (mounted) setState(() => _agentDiagnostics += 1);
  }

  void _setFailure(String message) {
    if (mounted) setState(() => _status = message);
  }

  String _availability(bool? available) => switch (available) {
        true => 'Disponible según diagnóstico del sistema',
        false => 'No disponible según diagnóstico del sistema',
        null => 'Sin medición en esta ejecución',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('PersalOne HORIZON')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: <Widget>[
            Text('HORIZON / consola de evidencia',
                style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            const Text(
              'Los estados muestran únicamente lo observable en esta instalación. Una UI no puede convertir una capacidad PREPARED en MEASURED.',
            ),
            const SizedBox(height: 20),
            _SectionHeader('Dispositivo'),
            const _EvidenceCard(
              title: 'Halo',
              value:
                  'BLOCKED — no hay gafas físicas ni conexión BLE verificada en esta sesión.',
            ),
            _EvidenceCard(
              title: 'Host Android',
              value: _permissionGranted
                  ? 'Micrófono autorizado por el sistema; evidencia física aún pendiente.'
                  : 'Micrófono no autorizado; captura y agente de traducción bloqueados.',
            ),
            _EvidenceCard(title: 'Estado host', value: _status),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: <Widget>[
                ElevatedButton(
                  onPressed: _permissionGranted ? null : _requestPermission,
                  child: const Text('Solicitar micrófono'),
                ),
                ElevatedButton(
                  onPressed: _permissionGranted && !_playing && !_liveRunning
                      ? _toggleCapture
                      : null,
                  child: Text(
                    _capturing ? 'Detener captura' : 'Iniciar captura real',
                  ),
                ),
                ElevatedButton(
                  onPressed: !_capturing &&
                          !_playing &&
                          !_liveRunning &&
                          _sample.length > 0
                      ? _playCapturedSample
                      : null,
                  child: const Text('Reproducir muestra real'),
                ),
              ],
            ),
            const Divider(height: 40),
            _SectionHeader('Conversación en vivo / EN ↔ ES'),
            const _EvidenceCard(
              title: 'Ruta de ejecución',
              value:
                  'G5 PREPARED — AudioRecord → STT por PCM si el servicio lo soporta → ML Kit local → TTS Android.',
            ),
            _EvidenceCard(title: 'Modelo local', value: _modelStatus),
            _EvidenceCard(title: 'Sesión', value: _liveStatus),
            DropdownButtonFormField<TranslationDirection>(
              value: _direction,
              decoration: const InputDecoration(labelText: 'Dirección'),
              onChanged: _liveRunning
                  ? null
                  : (direction) {
                      if (direction != null) {
                        setState(() => _direction = direction);
                      }
                    },
              items: const <DropdownMenuItem<TranslationDirection>>[
                DropdownMenuItem(
                  value: TranslationDirection.englishToSpanish,
                  child: Text('Inglés → Español'),
                ),
                DropdownMenuItem(
                  value: TranslationDirection.spanishToEnglish,
                  child: Text('Español → Inglés'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: <Widget>[
                ElevatedButton(
                  onPressed: !_liveRunning && !_capturing && !_playing
                      ? _startLiveTranslation
                      : null,
                  child: const Text('Iniciar traducción en vivo'),
                ),
                ElevatedButton(
                  onPressed: _liveRunning ? _stopLiveTranslation : null,
                  child: const Text('Detener y descartar sesión'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _EvidenceCard(
              title: 'Transcripción parcial en memoria',
              value: _partialTranscript.isEmpty
                  ? 'Sin hipótesis parcial.'
                  : _partialTranscript,
            ),
            _EvidenceCard(
              title: 'Última transcripción final en memoria',
              value: _finalTranscript.isEmpty
                  ? 'Sin segmento final.'
                  : _finalTranscript,
            ),
            _EvidenceCard(
              title: 'Última traducción en memoria',
              value:
                  _translation.isEmpty ? 'Sin traducción final.' : _translation,
            ),
            const Divider(height: 40),
            _SectionHeader('Agentes y permisos'),
            _EvidenceCard(title: 'HORIZON Translate', value: _agentStatus),
            _EvidenceCard(
              title: 'Lifecycle de agente',
              value: _agentState.name,
            ),
            CheckboxListTile(
              value: _localConsent,
              onChanged: _liveRunning
                  ? null
                  : (value) => setState(() => _localConsent = value ?? false),
              title: const Text(
                  'Consiento el procesamiento local para esta sesión'),
              subtitle: const Text(
                'El grant de agente se emite sólo al iniciar y no se persiste.',
              ),
              controlAffinity: ListTileControlAffinity.leading,
            ),
            CheckboxListTile(
              value: _modelDownloadConsent,
              onChanged: _liveRunning
                  ? null
                  : (value) =>
                      setState(() => _modelDownloadConsent = value ?? false),
              title:
                  const Text('Autorizo preparar o descargar el modelo local'),
              subtitle: const Text(
                'Sin este consentimiento no se crea la sesión de validación G5.',
              ),
              controlAffinity: ListTileControlAffinity.leading,
            ),
            const _EvidenceCard(
              title: 'Memoria de agente',
              value:
                  'none — no hay historial, PCM, transcript ni traducción persistentes entre sesiones.',
            ),
            const Divider(height: 40),
            _SectionHeader('Privacidad, diagnósticos y latencia'),
            const _EvidenceCard(
              title: 'Datos de sesión',
              value:
                  'PCM, transcript y traducción se mantienen sólo en memoria durante la sesión. Stop vacía el texto visible y descarta callbacks tardíos.',
            ),
            _EvidenceCard(
              title: 'Diagnósticos censurados',
              value:
                  'Frames: $_inputFrames · drops: $_inputDrops · writes: $_outputWrites · underruns: $_underruns · callbacks G5 obsoletos: $_staleCallbacks · auditorías G7: $_agentAuditEvents · diagnósticos G7: $_agentDiagnostics',
            ),
            _EvidenceCard(
              title: 'Timestamp de entrada',
              value: _availability(_inputTimestampAvailable),
            ),
            _EvidenceCard(
              title: 'Timestamp de salida',
              value: _availability(_outputTimestampAvailable),
            ),
            const _EvidenceCard(
              title: 'Latencia de conversación',
              value:
                  'No medida. Los timestamps del sistema no equivalen a latencia end-to-end ni a audibilidad; no existe aún un protocolo loopback aceptado.',
            ),
            const SizedBox(height: 20),
            const Text(
              'Para promover una subcapacidad a MEASURED, sigue docs/ANDROID_PHYSICAL_VALIDATION_RUNBOOK.md en un teléfono Android físico y registra sólo evidencia censurada. Halo audio permanece BLOCKED.',
            ),
          ],
        ),
      ),
    );
  }
}

final class _AndroidHostCapabilityResolver implements AgentCapabilityResolver {
  const _AndroidHostCapabilityResolver(
      {required this.microphonePermissionGranted});

  final bool Function() microphonePermissionGranted;

  @override
  Future<AgentCapabilityAvailability> availabilityFor(
    AgentPermission permission,
  ) async {
    final truthLabel = permission == AgentPermission.microphoneCapture &&
            !microphonePermissionGranted()
        ? TruthLabel.blocked
        : TruthLabel.prepared;
    return AgentCapabilityAvailability(
      permission: permission,
      truthLabel: truthLabel,
    );
  }
}

/// G7 knows only that local provider ports are registered. Their operational
/// readiness remains unknown until G5 prepares them, and G5 blocks start if a
/// native support/model/voice check fails.
final class _LocalTranslationProviderResolver implements AgentProviderResolver {
  const _LocalTranslationProviderResolver();

  @override
  Future<ProviderReadiness> readinessFor(
    AgentProviderRequirement requirement,
  ) async =>
      ProviderReadiness.unknown;
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(title, style: Theme.of(context).textTheme.titleLarge),
      );
}

class _EvidenceCard extends StatelessWidget {
  const _EvidenceCard({required this.title, required this.value});

  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(title, style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 4),
            Text(value),
          ],
        ),
      ),
    );
  }
}
