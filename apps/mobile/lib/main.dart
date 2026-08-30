import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:persalone_audio_adapters/persalone_audio_adapters.dart';
import 'package:persalone_contracts/persalone_contracts.dart';
import 'package:persalone_translation_runtime/persalone_translation_runtime.dart';

void main() {
  runApp(const PersalOneApp());
}

/// Android-first shell. It exposes separate G3/G4 evidence controls and the G5
/// live path, but never promotes a capability to MEASURED without the documented
/// reproducible physical validation.
class PersalOneApp extends StatelessWidget {
  const PersalOneApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PersalOne HORIZON',
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      home: const AndroidHostAudioScreen(),
    );
  }
}

class AndroidHostAudioScreen extends StatefulWidget {
  const AndroidHostAudioScreen({super.key});

  @override
  State<AndroidHostAudioScreen> createState() => _AndroidHostAudioScreenState();
}

class _AndroidHostAudioScreenState extends State<AndroidHostAudioScreen> {
  static const AudioFormat _format = AudioFormat.voice16kMono;
  static const int _maxSampleBytes = 32000;
  static final Stopwatch _clock = Stopwatch()..start();

  late final AndroidMicrophoneAdapter _microphone;
  late final AndroidSpeakerAdapter _speaker;
  late final AndroidSpeechRecognizerProvider _stt;
  late final MlKitOnDeviceTranslatorProvider _translator;
  late final AndroidTextToSpeechProvider _tts;
  late final HorizonTranslationRuntime _runtime;
  final BytesBuilder _sample = BytesBuilder(copy: false);

  StreamSubscription<AudioFrame>? _frameSubscription;
  StreamSubscription<AudioDiagnostic>? _inputDiagnosticSubscription;
  StreamSubscription<AudioDiagnostic>? _outputDiagnosticSubscription;
  StreamSubscription<TranscriptSegment>? _transcriptSubscription;
  StreamSubscription<TranslationSegment>? _translationSubscription;
  StreamSubscription<LiveTranslationDiagnostic>? _runtimeDiagnosticSubscription;
  StreamSubscription<ProviderSnapshot>? _translationSnapshotSubscription;

  bool _permissionGranted = false;
  bool _capturing = false;
  bool _playing = false;
  bool _liveRunning = false;
  bool _localConsent = false;
  bool _modelDownloadConsent = false;
  int _inputFrames = 0;
  int _inputDrops = 0;
  int _outputWrites = 0;
  int _underruns = 0;
  int _staleCallbacks = 0;
  TranslationDirection _direction = TranslationDirection.englishToSpanish;
  String _status = 'Preparado para validar audio Android con evidencia real.';
  String _liveStatus = 'G5 PREPARED — requiere ensayo físico Android.';
  String _modelStatus = 'No preparado';
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
    _runtime = HorizonTranslationRuntime(
      input: _microphone,
      stt: _stt,
      translator: _translator,
      synthesizer: _tts,
    );
    _frameSubscription = _microphone.frames.listen(_collectInputFrame);
    _inputDiagnosticSubscription = _microphone.diagnostics.listen(
      _observeInputDiagnostic,
    );
    _outputDiagnosticSubscription = _speaker.diagnostics.listen(
      _observeOutputDiagnostic,
    );
    _transcriptSubscription = _runtime.transcripts.listen(_observeTranscript);
    _translationSubscription =
        _runtime.translations.listen(_observeTranslation);
    _runtimeDiagnosticSubscription = _runtime.diagnostics.listen(
      _observeRuntimeDiagnostic,
    );
    _translationSnapshotSubscription = _translator.snapshots.listen(
      _observeTranslationSnapshot,
    );
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
    _runtime.dispose();
    _microphone.dispose();
    _speaker.dispose();
    super.dispose();
  }

  Future<void> _requestPermission() async {
    try {
      final bool granted = await _microphone.requestPermission();
      if (!mounted) return;
      setState(() {
        _permissionGranted = granted;
        _status = granted
            ? 'Permiso concedido. La captura sigue PREPARED hasta el ensayo físico.'
            : 'Se necesita permiso de micrófono para G3 y G5.';
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
              ? 'Captura detenida. Hay una muestra real local lista para reproducir.'
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
      final session = AudioSessionDescriptor(
        sessionId: 'android-host-audio-check',
        streamEpoch: DateTime.now().microsecondsSinceEpoch,
        streamId: 'android-microphone',
      );
      await _microphone.start(session, _format);
      if (!mounted) return;
      setState(() {
        _capturing = true;
        _status =
            'Capturando PCM real desde el micrófono Android. No se guarda en disco.';
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
        _status =
            'Reproducción completada. Confirma la audibilidad según el procedimiento G4.';
      });
    } catch (error) {
      _setFailure('No se pudo reproducir la muestra: ${error.runtimeType}.');
    }
  }

  Future<void> _startLiveTranslation() async {
    if (!_localConsent || !_modelDownloadConsent) {
      setState(() {
        _liveStatus =
            'G5 bloqueado: concede consentimiento local y de descarga de modelo para esta sesión.';
      });
      return;
    }
    try {
      final now = DateTime.now().microsecondsSinceEpoch;
      final session = TranslationSession(
        sessionId: 'live-$now',
        streamEpoch: now,
        direction: _direction,
        privacyGeneration: now,
      );
      final locales = _direction == TranslationDirection.englishToSpanish
          ? ('en-US', 'es-ES')
          : ('es-ES', 'en-US');
      setState(() {
        _partialTranscript = '';
        _finalTranscript = '';
        _translation = '';
        _staleCallbacks = 0;
        _modelStatus = 'Preparando modelo on-device';
        _liveStatus =
            'Preparando reconocimiento, modelo local y síntesis Android.';
      });
      await _runtime.start(
        config: LiveTranslationConfig(
          session: session,
          sourceLocale: locales.$1,
          targetLocale: locales.$2,
          consent: TranslationConsent(
            acceptedAtMicros: now,
            localProcessingAllowed: true,
            modelDownloadAllowed: true,
            remoteProcessingAllowed: false,
          ),
        ),
        audioSession: AudioSessionDescriptor(
          sessionId: session.sessionId,
          streamEpoch: session.streamEpoch,
          streamId: 'android-microphone-live',
        ),
      );
      if (!mounted) return;
      setState(() {
        _liveRunning = true;
        _liveStatus =
            'Escuchando con micrófono Android real. No se persiste audio ni texto.';
      });
    } on RuntimeError catch (error) {
      if (!mounted) return;
      setState(() {
        _liveRunning = false;
        _liveStatus = 'G5 bloqueado: ${error.code.name}.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _liveRunning = false;
        _liveStatus = 'G5 no se pudo iniciar: ${error.runtimeType}.';
      });
    }
  }

  Future<void> _stopLiveTranslation() async {
    await _runtime.stop();
    if (!mounted) return;
    setState(() {
      _liveRunning = false;
      _partialTranscript = '';
      _finalTranscript = '';
      _translation = '';
      _liveStatus =
          'Sesión detenida. Se descartó el estado textual mostrado en memoria.';
    });
  }

  void _collectInputFrame(AudioFrame frame) {
    if (!_capturing) return;
    final pcm = frame.payload;
    if (_sample.length + pcm.length <= _maxSampleBytes) _sample.add(pcm);
    if (mounted) setState(() => _inputFrames += 1);
  }

  void _observeInputDiagnostic(AudioDiagnostic diagnostic) {
    if (diagnostic.code == AudioDiagnosticCode.inputDropped && mounted) {
      setState(() => _inputDrops += diagnostic.value ?? 1);
    }
  }

  void _observeOutputDiagnostic(AudioDiagnostic diagnostic) {
    if (!mounted) return;
    switch (diagnostic.code) {
      case AudioDiagnosticCode.outputFrameQueued:
        setState(() => _outputWrites += 1);
      case AudioDiagnosticCode.outputUnderrun:
        setState(() => _underruns = diagnostic.value ?? _underruns + 1);
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

  void _setFailure(String message) {
    if (mounted) setState(() => _status = message);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('PersalOne HORIZON — Android')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: <Widget>[
          Text('G3/G4: host audio real', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 12),
          const Text(
            'Esta ruta usa AudioRecord y AudioTrack en Android. Los frames se mantienen en memoria de forma acotada sólo para verificación local y no se guardan en disco.',
          ),
          const SizedBox(height: 16),
          const _EvidenceCard(
            title: 'Estado de evidencia',
            value:
                'PREPARED — se requiere dispositivo Android físico para MEASURED',
          ),
          const _EvidenceCard(
            title: 'Halo audio',
            value: 'BLOCKED — pendiente de validación física de las gafas',
          ),
          _EvidenceCard(title: 'Estado', value: _status),
          const SizedBox(height: 12),
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
                    _capturing ? 'Detener captura' : 'Iniciar captura real'),
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
          const SizedBox(height: 20),
          Text('Telemetría local', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text('Frames de entrada: $_inputFrames'),
          Text('Drops de entrada: $_inputDrops'),
          Text('Escrituras de salida: $_outputWrites'),
          Text('Underruns de salida: $_underruns'),
          const Divider(height: 40),
          Text('G5: Live Translator EN ↔ ES',
              style: theme.textTheme.headlineSmall),
          const SizedBox(height: 12),
          const Text(
            'La sesión usa micrófono Android, reconocimiento on-device condicionado por soporte del dispositivo, modelo ML Kit local y TextToSpeech Android. No se habilita una ruta cloud y no se persisten PCM, transcripciones ni traducciones.',
          ),
          _EvidenceCard(
            title: 'Estado G5',
            value: 'PREPARED — no hay ensayo físico registrado',
          ),
          _EvidenceCard(title: 'Estado de modelo', value: _modelStatus),
          _EvidenceCard(title: 'Estado de sesión', value: _liveStatus),
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
          CheckboxListTile(
            value: _localConsent,
            onChanged: _liveRunning
                ? null
                : (value) => setState(() => _localConsent = value ?? false),
            title:
                const Text('Consiento el procesamiento local para esta sesión'),
            subtitle:
                const Text('La autorización termina al detener la sesión.'),
            controlAffinity: ListTileControlAffinity.leading,
          ),
          CheckboxListTile(
            value: _modelDownloadConsent,
            onChanged: _liveRunning
                ? null
                : (value) =>
                    setState(() => _modelDownloadConsent = value ?? false),
            title:
                const Text('Autorizo preparar o descargar el modelo on-device'),
            subtitle: const Text(
                'Sin esta autorización, la sesión se bloquea de forma explícita.'),
            controlAffinity: ListTileControlAffinity.leading,
          ),
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
          const SizedBox(height: 16),
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
          Text('Callbacks obsoletos descartados: $_staleCallbacks'),
          const SizedBox(height: 20),
          const Text(
            'Validación pendiente: en un dispositivo Android físico, verifica reconocimiento compatible con entrada PCM, disponibilidad y descarga del modelo local, voz TTS en el locale destino, barge-in y audibilidad. Registra dispositivo, versión Android, ruta de audio, fecha y observaciones reproducibles. La UI no cambia truth labels por sí sola.',
          ),
        ],
      ),
    );
  }
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
