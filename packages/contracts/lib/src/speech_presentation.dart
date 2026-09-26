import 'session.dart';

/// A provider that reports timestamps declares the monotonic clock they come
/// from. Two intervals may only be combined across providers when both
/// declare the same non-empty domain (e.g. `android.clock_monotonic`).
abstract interface class ProviderClockDomain {
  String get monotonicClockDomain;
}

enum SpeechPresentationStatus {
  /// The platform output reported presenting the utterance's frames.
  presented,

  /// The presentation could not be measured; [SpeechPresentation.reason]
  /// says why. The interval stays UNKNOWN, it is never estimated.
  unavailable,
}

/// When one spoken translation reached the platform audio output. Carries no
/// text or audio. Times are microseconds on the provider's
/// [ProviderClockDomain]; they are only comparable with times from the same
/// domain.
final class SpeechPresentation {
  const SpeechPresentation({
    required this.session,
    required this.sequence,
    required this.status,
    this.queuedAtMicros,
    this.firstFramePresentedAtMicros,
    this.audiblePresentedAtMicros,
    this.reason,
  });

  final TranslationSession session;

  /// Sequence of the translation segment that was spoken.
  final int sequence;
  final SpeechPresentationStatus status;

  /// The synthesizer accepted the utterance.
  final int? queuedAtMicros;

  /// The first synthesized frame (possibly leading silence) was presented.
  final int? firstFramePresentedAtMicros;

  /// The first non-silent frame was presented; null when the utterance had
  /// no frame above the silence threshold.
  final int? audiblePresentedAtMicros;

  /// Coded cause when [status] is unavailable (never free text).
  final String? reason;
}

/// Optional capability of a speech synthesizer that plays through an output
/// it can observe. The runtime turns these reports into latency samples.
abstract interface class SpeechPresentationReporter
    implements ProviderClockDomain {
  Stream<SpeechPresentation> get presentations;
}
