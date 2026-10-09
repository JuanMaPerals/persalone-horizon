/// Where a build serves its loopback endpoints for Studio: the read-only
/// runtime stream and, when enabled, the authenticated control channel.
///
/// The servers bind the phone's loopback only; Studio on the computer reaches
/// them through `adb forward tcp:<port> tcp:<port>`, so nothing listens on
/// the LAN. Only the listed browser origins may call them.
final class LiveStreamConfig {
  const LiveStreamConfig({required this.port, required this.allowedOrigins});

  /// Same default as the Engineering Console's live stream URL.
  static const int defaultPort = 47800;

  /// Same default as the Engineering Console's control URL.
  static const int defaultControlPort = 47801;

  /// Studio served locally by Vite.
  static const String defaultOrigins =
      'http://127.0.0.1:5173,http://localhost:5173';

  final int port;
  final Set<String> allowedOrigins;

  static final RegExp _origin =
      RegExp(r'^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?$');

  /// Parses build-time values; anything that is not a plain origin
  /// (scheme://host[:port], no path, no wildcard) is dropped, never widened.
  static LiveStreamConfig parse({required int port, required String origins}) {
    if (port < 1024 || port > 65535) {
      throw ArgumentError.value(port, 'port', 'must be an unprivileged port');
    }
    return LiveStreamConfig(
      port: port,
      allowedOrigins: origins
          .split(',')
          .map((String origin) => origin.trim())
          .where(_origin.hasMatch)
          .toSet(),
    );
  }
}
