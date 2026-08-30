/// Typed, serializable error codes shared by the mobile app, runtime, fixture,
/// and future device adapters.
enum RuntimeErrorCode {
  capabilityUnavailable,
  consentRequired,
  policyDenied,
  staleStreamEpoch,
  sessionClosed,
  invalidContract,
  discoveryFailed,
  deviceNotSelected,
  connectionFailed,
  pairingRequired,
  deviceNotReady,
  protocolRejected,
  transportUnavailable,
  recognitionUnavailable,
  translationModelUnavailable,
  speechSynthesisUnavailable,
  providerUnavailable,
  agentUnavailable,
  permissionGrantExpired,
  lifecycleInvalid,
}

/// A contract-level failure that is safe to expose to the user interface.
final class RuntimeError implements Exception {
  const RuntimeError(this.code, this.message, {this.retryable = false});

  final RuntimeErrorCode code;
  final String message;
  final bool retryable;

  @override
  String toString() => 'RuntimeError(code: $code, message: $message)';
}
