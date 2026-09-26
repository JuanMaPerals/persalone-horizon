import 'session.dart';
import 'truth_label.dart';

/// Execution path that rendered or attempted to render an output. This is not
/// evidence: a delivery on [haloReal] still carries its own [TruthLabel], and a
/// fixture must never report [emulated] or [haloReal].
enum ExecutionEnvironment { simulated, emulated, pcReal, haloReal }

enum CaptionDeliveryStatus { delivered, blocked, failed }

/// Consolidated translated text for one delivered turn. [text] belongs to the
/// runtime data plane and must never be copied into diagnostics or traces.
final class CaptionUpdate {
  const CaptionUpdate({
    required this.session,
    required this.sequence,
    required this.text,
    required this.observedAtMicros,
    required this.truthLabel,
  });

  final TranslationSession session;
  final int sequence;
  final String text;
  final int observedAtMicros;
  final TruthLabel truthLabel;
}

/// Redacted outcome of one caption attempt. It intentionally carries no text.
/// [reason] is a coded, non-sensitive cause for [blocked] or [failed].
final class CaptionDelivery {
  const CaptionDelivery({
    required this.session,
    required this.sequence,
    required this.status,
    required this.environment,
    required this.truthLabel,
    required this.adapterId,
    this.reason,
  });

  final TranslationSession session;
  final int sequence;
  final CaptionDeliveryStatus status;
  final ExecutionEnvironment environment;
  final TruthLabel truthLabel;
  final String adapterId;
  final String? reason;
}

/// Subtitle/HUD output port. Implementations report [CaptionDeliveryStatus.blocked]
/// instead of throwing when a destination refuses text by policy or capability.
abstract interface class CaptionOutputAdapter {
  String get adapterId;
  ExecutionEnvironment get environment;

  Future<CaptionDelivery> show(CaptionUpdate update);
  Future<void> clear(TranslationSession session);
}
