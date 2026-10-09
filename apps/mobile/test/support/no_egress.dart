import 'dart:async';
import 'dart:io';

/// Test guard: any socket to a non-loopback address fails loudly instead of
/// leaving the machine. Loopback (local test servers) stays allowed.
final class NoEgress extends IOOverrides {
  final List<String> attempts = <String>[];

  static bool _isLoopback(Object host) {
    if (host is InternetAddress) return host.isLoopback;
    final String name = '$host'.toLowerCase();
    return name == 'localhost' ||
        name.startsWith('127.') ||
        name == '::1' ||
        name == '[::1]';
  }

  SocketException _refusal(Object host, int port) {
    attempts.add('$host:$port');
    return SocketException('egress blocked in tests: $host:$port');
  }

  @override
  Future<Socket> socketConnect(dynamic host, int port,
      {dynamic sourceAddress, int sourcePort = 0, Duration? timeout}) {
    if (!_isLoopback(host as Object)) {
      return Future<Socket>.error(_refusal(host, port));
    }
    return super.socketConnect(host, port,
        sourceAddress: sourceAddress, sourcePort: sourcePort, timeout: timeout);
  }

  @override
  Future<ConnectionTask<Socket>> socketStartConnect(dynamic host, int port,
      {dynamic sourceAddress, int sourcePort = 0}) {
    if (!_isLoopback(host as Object)) {
      return Future<ConnectionTask<Socket>>.error(_refusal(host, port));
    }
    return super.socketStartConnect(host, port,
        sourceAddress: sourceAddress, sourcePort: sourcePort);
  }
}
