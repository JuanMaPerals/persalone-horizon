import 'dart:async';

import 'package:flutter/services.dart';

/// Platform side of the Bluetooth permission check (MainActivity,
/// `persalone.ble/permissions`). Answers are coded maps, never text.
abstract interface class BlePermissionBridge {
  /// Current decision without prompting the user.
  Future<Map<Object?, Object?>> status();

  /// Prompts for the missing permissions (Android 12+) and returns the
  /// decision read back from the platform afterwards.
  Future<Map<Object?, Object?>> request();
}

final class MethodChannelBlePermissionBridge implements BlePermissionBridge {
  MethodChannelBlePermissionBridge({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('persalone.ble/permissions');

  final MethodChannel _channel;

  @override
  Future<Map<Object?, Object?>> status() => _invoke('status');

  @override
  Future<Map<Object?, Object?>> request() => _invoke('request');

  Future<Map<Object?, Object?>> _invoke(String method) async =>
      await _channel.invokeMapMethod<Object?, Object?>(method) ??
      const <Object?, Object?>{};
}

/// Outcome of the permission gate. Only [granted] opens the Halo BLE path;
/// it proves permission, not that a Halo exists or showed anything.
final class BlePermissionResult {
  const BlePermissionResult._(this.granted, this.reason, this.missing);

  const BlePermissionResult.denied(String reason,
      [List<String> missing = const <String>[]])
      : this._(false, reason, missing);

  final bool granted;

  /// Coded: granted, permissionDenied, bleRequiresAndroid12,
  /// permissionInFlight, platformError, malformedResponse.
  final String reason;

  /// Short names of the permissions still missing (BLUETOOTH_SCAN...).
  final List<String> missing;

  static const Set<String> _knownPermissions = <String>{
    'BLUETOOTH_SCAN',
    'BLUETOOTH_CONNECT',
  };
  static final RegExp _code = RegExp(r'^[A-Za-z][A-Za-z0-9_]{0,47}$');

  /// Granted only for the exact platform answer `granted: true` with reason
  /// `granted`; anything else, including partial or unexpected shapes, is a
  /// denial with a coded reason.
  static BlePermissionResult parse(Map<Object?, Object?> raw) {
    final Object? granted = raw['granted'];
    final Object? reason = raw['reason'];
    if (granted is! bool || reason is! String || !_code.hasMatch(reason)) {
      return const BlePermissionResult.denied('malformedResponse');
    }
    if (granted) {
      return reason == 'granted'
          ? const BlePermissionResult._(true, 'granted', <String>[])
          : const BlePermissionResult.denied('malformedResponse');
    }
    if (reason == 'granted') {
      return const BlePermissionResult.denied('malformedResponse');
    }
    final Object? missing = raw['missing'];
    return BlePermissionResult.denied(
      reason,
      missing is List
          ? missing.whereType<String>().where(_knownPermissions.contains).toList()
          : const <String>[],
    );
  }
}

/// Fail-closed gate in front of every Bluetooth operation of the Halo path.
/// Concurrent callers share one platform request.
final class BlePermissionGate {
  BlePermissionGate(this._bridge);

  final BlePermissionBridge _bridge;
  Future<BlePermissionResult>? _inFlight;

  Future<BlePermissionResult> ensure() =>
      _inFlight ??= _ask().whenComplete(() => _inFlight = null);

  Future<BlePermissionResult> _ask() async {
    try {
      return BlePermissionResult.parse(await _bridge.request());
    } on PlatformException catch (error) {
      return BlePermissionResult.denied(error.code == 'permission_in_flight'
          ? 'permissionInFlight'
          : 'platformError');
    } on Object {
      // MissingPluginException (no Android host) or anything unexpected.
      return const BlePermissionResult.denied('platformError');
    }
  }
}
