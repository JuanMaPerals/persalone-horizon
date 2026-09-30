import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// flutter_test_config.dart installs the no-egress guard for every mobile
// test; this proves it is active (a missing config would let traffic out).
void main() {
  test('outbound connections are refused; loopback still works', () async {
    await expectLater(
        Socket.connect('203.0.113.7', 443), throwsA(isA<SocketException>()));
    final ServerSocket local = await ServerSocket.bind('127.0.0.1', 0);
    addTearDown(local.close);
    (await Socket.connect('127.0.0.1', local.port)).destroy();
  });
}
