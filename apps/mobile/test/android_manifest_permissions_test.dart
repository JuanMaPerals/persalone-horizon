import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Guards the permission scope of the Android app: the Halo BLE path may add
// exactly BLUETOOTH_SCAN (never used to derive location) and
// BLUETOOTH_CONNECT. Any other permission is a new scope decision.
void main() {
  final String manifest =
      File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
  final List<String> declared = RegExp(
          r'<uses-permission[^>]*android:name="android\.permission\.([A-Z_]+)"')
      .allMatches(manifest)
      .map((Match m) => m.group(1)!)
      .toList();

  test('declared permissions are exactly the authorized set', () {
    expect(declared..sort(), <String>[
      'BLUETOOTH_CONNECT',
      'BLUETOOTH_SCAN',
      'RECORD_AUDIO',
    ]);
  });

  test('BLUETOOTH_SCAN asserts it never derives location', () {
    final RegExpMatch? scan = RegExp(
            r'<uses-permission[^>]*android:name="android\.permission\.BLUETOOTH_SCAN"[^>]*>',
            dotAll: true)
        .firstMatch(manifest);
    expect(scan, isNotNull);
    expect(scan!.group(0), contains('android:usesPermissionFlags="neverForLocation"'));
  });

  test('no location or legacy Bluetooth permission is declared', () {
    for (final String forbidden in <String>[
      'ACCESS_FINE_LOCATION',
      'ACCESS_COARSE_LOCATION',
      'ACCESS_BACKGROUND_LOCATION',
      'BLUETOOTH_ADVERTISE',
      'BLUETOOTH_ADMIN',
    ]) {
      expect(manifest, isNot(contains('android.permission.$forbidden')),
          reason: forbidden);
    }
  });
}
