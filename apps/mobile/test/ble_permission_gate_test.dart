import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:persalone_mobile/ble_permission_gate.dart';

void main() {
  group('BlePermissionResult.parse is fail-closed', () {
    test('only the exact granted answer opens the path', () {
      final BlePermissionResult result = BlePermissionResult.parse(
          <Object?, Object?>{'granted': true, 'reason': 'granted'});
      expect(result.granted, isTrue);
      expect(result.reason, 'granted');
    });

    test('a denial keeps its coded reason and known missing permissions', () {
      final BlePermissionResult result = BlePermissionResult.parse(
          <Object?, Object?>{
        'granted': false,
        'reason': 'permissionDenied',
        'missing': <Object?>['BLUETOOTH_CONNECT', 'ACCESS_FINE_LOCATION', 7],
      });
      expect(result.granted, isFalse);
      expect(result.reason, 'permissionDenied');
      expect(result.missing, <String>['BLUETOOTH_CONNECT'],
          reason: 'unknown names are dropped, never widened');
    });

    test('older Android is a denial, not a prompt for location', () {
      final BlePermissionResult result = BlePermissionResult.parse(
          <Object?, Object?>{'granted': false, 'reason': 'bleRequiresAndroid12'});
      expect(result.granted, isFalse);
      expect(result.reason, 'bleRequiresAndroid12');
    });

    for (final MapEntry<String, Map<Object?, Object?>> hostile
        in <String, Map<Object?, Object?>>{
      'empty map': <Object?, Object?>{},
      'granted as string': <Object?, Object?>{'granted': 'true', 'reason': 'granted'},
      'granted without reason': <Object?, Object?>{'granted': true},
      'granted with another reason':
          <Object?, Object?>{'granted': true, 'reason': 'permissionDenied'},
      'denied claiming granted':
          <Object?, Object?>{'granted': false, 'reason': 'granted'},
      'free-text reason':
          <Object?, Object?>{'granted': false, 'reason': 'user said no!'},
    }.entries) {
      test('${hostile.key} is refused', () {
        final BlePermissionResult result = BlePermissionResult.parse(hostile.value);
        expect(result.granted, isFalse);
        expect(result.reason, 'malformedResponse');
      });
    }
  });

  group('BlePermissionGate', () {
    test('platform errors and a missing host deny with a code', () async {
      expect(
          (await BlePermissionGate(_Bridge.throwing(
                      PlatformException(code: 'boom')))
                  .ensure())
              .reason,
          'platformError');
      expect(
          (await BlePermissionGate(_Bridge.throwing(
                      MissingPluginException('no android')))
                  .ensure())
              .reason,
          'platformError');
      expect(
          (await BlePermissionGate(_Bridge.throwing(
                      PlatformException(code: 'permission_in_flight')))
                  .ensure())
              .reason,
          'permissionInFlight');
    });

    test('concurrent callers share one platform request', () async {
      final _Bridge bridge = _Bridge.gated();
      final BlePermissionGate gate = BlePermissionGate(bridge);
      final Future<BlePermissionResult> first = gate.ensure();
      final Future<BlePermissionResult> second = gate.ensure();
      bridge.answer
          .complete(<Object?, Object?>{'granted': true, 'reason': 'granted'});
      expect((await first).granted, isTrue);
      expect((await second).granted, isTrue);
      expect(bridge.requests, 1);

      // A later call asks again (a revoked permission must be noticed).
      bridge.answer = Completer<Map<Object?, Object?>>()
        ..complete(<Object?, Object?>{
          'granted': false,
          'reason': 'permissionDenied',
          'missing': <Object?>['BLUETOOTH_SCAN'],
        });
      final BlePermissionResult revoked = await gate.ensure();
      expect(revoked.granted, isFalse);
      expect(bridge.requests, 2);
    });
  });
}

final class _Bridge implements BlePermissionBridge {
  _Bridge.gated() : error = null;
  _Bridge.throwing(Object this.error);

  final Object? error;
  Completer<Map<Object?, Object?>> answer = Completer<Map<Object?, Object?>>();
  int requests = 0;

  @override
  Future<Map<Object?, Object?>> status() => request();

  @override
  Future<Map<Object?, Object?>> request() async {
    requests++;
    final Object? failure = error;
    if (failure != null) throw failure;
    return answer.future;
  }
}
