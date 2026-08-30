import 'audio.dart';
import 'session.dart';
import 'truth_label.dart';

/// Whether speech text can still be replaced by a subsequent recognition event.
enum TranscriptStability { partial, finalResult }

/// Explicit consent for one translation session. It is intentionally scoped to
/// a session and does not authorize background capture or persistence.
final class TranslationConsent {
  const TranslationConsent({
    required this.acceptedAtMicros,
    required this.localProcessingAllowed,
    required this.modelDownloadAllowed,
    required this.remoteProcessingAllowed,
  });

  final int acceptedAtMicros;
  final bool localProcessingAllowed;
  final bool modelDownloadAllowed;
  final bool remoteProcessingAllowed;
}

/// Session settings visible to provider adapters without exposing audio or text
/// in diagnostics.
final class LiveTranslationConfig {
  const LiveTranslationConfig({
    required this.session,
    required this.sourceLocale,
    required this.targetLocale,
    required this.consent,
  });

  final TranslationSession session;
  final String sourceLocale;
  final String targetLocale;
  final TranslationConsent consent;
}

/// A speech-recognition hypothesis. Text belongs to the runtime data plane and
/// must not be copied into telemetry or diagnostic detail fields.
final class TranscriptSegment {
  const TranscriptSegment({
    required this.session,
    required this.sequence,
    required this.text,
    required this.stability,
    required this.observedAtMicros,
    required this.truthLabel,
    this.confidence,
  });

  final TranslationSession session;
  final int sequence;
  final String text;
  final TranscriptStability stability;
  final int observedAtMicros;
  final TruthLabel truthLabel;
  final double? confidence;
}

/// A translated final segment. The runtime does not send partial hypotheses to
/// speech synthesis unless a later policy explicitly permits that behavior.
final class TranslationSegment {
  const TranslationSegment({
    required this.session,
    required this.sequence,
    required this.sourceText,
    required this.translatedText,
    required this.observedAtMicros,
    required this.truthLabel,
  });

  final TranslationSession session;
  final int sequence;
  final String sourceText;
  final String translatedText;
  final int observedAtMicros;
  final TruthLabel truthLabel;
}

enum ProviderReadiness { unknown, preparing, ready, unavailable, failed }

enum LiveTranslationDiagnosticCode {
  consentDenied,
  providerPreparing,
  providerReady,
  providerUnavailable,
  frameRejected,
  transcriptPartial,
  transcriptFinal,
  translationCompleted,
  synthesisStarted,
  synthesisCompleted,
  synthesisFailed,
  staleCallbackDiscarded,
}

/// Redacted event from a G5 provider or runtime. [detail] must never contain
/// PCM, transcript, translation, voice identifier, account identifier, or key.
final class LiveTranslationDiagnostic {
  const LiveTranslationDiagnostic({
    required this.code,
    required this.component,
    required this.observedAtMicros,
    this.sequence,
    this.detail,
  });

  final LiveTranslationDiagnosticCode code;
  final String component;
  final int observedAtMicros;
  final int? sequence;
  final String? detail;
}

/// Common observable status from a provider implementation.
final class ProviderSnapshot {
  const ProviderSnapshot({
    required this.providerId,
    required this.sourceRevision,
    required this.readiness,
    required this.truthLabel,
    required this.observedAtMicros,
    this.failureReason,
  });

  final String providerId;
  final String sourceRevision;
  final ProviderReadiness readiness;
  final TruthLabel truthLabel;
  final int observedAtMicros;
  final String? failureReason;
}

/// Streaming STT must consume canonical G3 frames. It cannot acquire a second
/// microphone independently of [AudioInputAdapter].
abstract interface class StreamingSttProvider {
  String get providerId;
  String get sourceRevision;
  Stream<ProviderSnapshot> get snapshots;
  Stream<LiveTranslationDiagnostic> get diagnostics;
  Stream<TranscriptSegment> get transcripts;

  Future<void> prepare(LiveTranslationConfig config, AudioFormat format);
  Future<void> push(AudioFrame frame);
  Future<void> stop();
  Future<void> dispose();
}

/// Text translation provider. The initial Android provider is on-device, but a
/// cloud provider may implement this port without affecting the runtime.
abstract interface class TextTranslationProvider {
  String get providerId;
  String get sourceRevision;
  Stream<ProviderSnapshot> get snapshots;
  Stream<LiveTranslationDiagnostic> get diagnostics;

  Future<void> prepare(LiveTranslationConfig config);
  Future<TranslationSegment> translate(TranscriptSegment finalTranscript);
  Future<void> dispose();
}

/// Speech synthesis provider. It receives translated text from the runtime and
/// emits only redacted lifecycle events, not a claim of human audibility.
abstract interface class SpeechSynthesisProvider {
  String get providerId;
  String get sourceRevision;
  Stream<ProviderSnapshot> get snapshots;
  Stream<LiveTranslationDiagnostic> get diagnostics;

  Future<void> prepare(LiveTranslationConfig config);
  Future<void> speak(TranslationSegment segment);
  Future<void> stop();
  Future<void> dispose();
}
