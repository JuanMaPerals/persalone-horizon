import 'caption.dart';

/// Intervals of one translation turn that the runtime observes itself, both
/// ends on the same monotonic clock of the same process.
///
/// - [finalToTranslation]: final transcript received -> translation returned.
/// - [translationToCaption]: translation -> caption destination acknowledged
///   a delivered caption.
/// - [finalToCaption]: final transcript -> caption delivered (what the wearer
///   waits for once the speaker's turn is recognised).
/// - [finalToSpeechQueued]: final transcript -> the synthesizer accepted the
///   utterance. This is NOT audible output.
/// - [speechEndToFinal]: recognizer end of speech -> final transcript, both
///   reported by the STT provider on its own monotonic clock; emitted only
///   when the provider supplies the end-of-speech time.
/// - [speechQueuedToAudible]: the synthesizer accepted the utterance -> the
///   platform output presented its first non-silent frame, both ends on the
///   synthesizer's monotonic clock (see [SpeechPresentation]). It is the
///   platform presentation time, not acoustic arrival or human perception;
///   emitted only when the provider measured it.
/// - [speechEndToAudible]: recognizer end of speech -> that same presentation;
///   emitted only when the STT and TTS providers declare one clock domain.
enum TurnLatencyStage {
  speechEndToFinal,
  finalToTranslation,
  translationToCaption,
  finalToCaption,
  finalToSpeechQueued,
  speechQueuedToAudible,
  speechEndToAudible,
}

/// One measured interval. It carries no text, audio or identifiers beyond the
/// turn sequence. [environment] is the execution path of the destination that
/// closed the interval, or null when the runtime cannot know it.
final class TurnLatencySample {
  const TurnLatencySample({
    required this.stage,
    required this.turn,
    required this.micros,
    this.environment,
  });

  final TurnLatencyStage stage;
  final int turn;
  final int micros;
  final ExecutionEnvironment? environment;
}
