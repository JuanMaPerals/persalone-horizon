import 'dart:async';
import 'dart:io';

import 'support/no_egress.dart';

/// Every mobile test runs with outbound network refused: only loopback (local
/// test servers, the emulator bridge's local endpoints) may be reached. A
/// provider or fallback that tried to leave the machine fails the test.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  IOOverrides.global = NoEgress();
  await testMain();
}
