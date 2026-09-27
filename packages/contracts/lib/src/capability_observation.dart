import 'capability.dart';
import 'truth_label.dart';

/// Runtime activation is deliberately separate from evidence truth.
///
/// Adapted from DreamLayer v0.9.2's correction that an installed/importable
/// capability must not be reported as active unless a reachable execution path
/// is actually running. HORIZON keeps that operational fact orthogonal to
/// [TruthLabel], which answers whether the behavior has reproducible evidence.
enum CapabilityActivation {
  unavailable,
  dormant,
  active,
}

/// One runtime observation of a declared capability.
///
/// A capability can be [CapabilityActivation.active] while still only
/// [TruthLabel.prepared]. That means the execution path is running, but it has
/// not earned MEASURED evidence yet. Conversely, a previously measured
/// capability can be dormant in the current session and must not be presented
/// as currently usable.
final class CapabilityObservation {
  const CapabilityObservation({
    required this.capability,
    required this.activation,
    required this.truthLabel,
    required this.sourceRevision,
    this.reason,
  });

  final Capability capability;
  final CapabilityActivation activation;
  final TruthLabel truthLabel;
  final String sourceRevision;
  final String? reason;

  bool get isOperational => activation == CapabilityActivation.active;

  bool get isUsable =>
      activation == CapabilityActivation.active &&
      truthLabel == TruthLabel.measured;
}
