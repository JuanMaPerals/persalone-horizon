import 'package:persalone_contracts/persalone_contracts.dart';
import 'package:persalone_halo_adapter/persalone_halo_adapter.dart';

import 'ble_permission_gate.dart';

/// The transport's permission precondition was not met: no Bluetooth
/// operation was attempted and captions stay BLOCKED.
final class HaloPermissionDenied implements Exception {
  const HaloPermissionDenied(this.result);

  final BlePermissionResult result;

  @override
  String toString() => 'HaloPermissionDenied(${result.reason})';
}

/// Composition root of the G5 caption path to a Halo display:
/// runtime -> [HaloCaptionOutputAdapter] -> [HaloDeviceAdapter] (composer +
/// bounded commands) -> [HaloTransport]. It reuses those pieces unchanged.
///
/// It exists only when a build enables it (`HORIZON_HALO_CAPTIONS`): the
/// environment is whatever the transport declares, so the Brilliant BLE
/// transport reports HALO_REAL, and no HALO_REAL label may appear in runs
/// where no physical Halo is present. Every delivery stays at most PREPARED
/// (a device acknowledgement, not a person seeing the caption).
final class HaloCaptionPath {
  HaloCaptionPath._(this.device, this.captions, this._permission);

  final HaloDeviceAdapter device;
  final CaptionOutputAdapter captions;
  final Future<BlePermissionResult> Function()? _permission;

  ExecutionEnvironment get environment => captions.environment;

  /// [permission] is the transport's precondition, checked before any
  /// discovery: the BLE gate for the Brilliant transport, or explicitly null
  /// for a transport that needs none (the official emulator).
  static HaloCaptionPath? compose({
    required bool enabled,
    required HaloTransport Function() transport,
    required Future<BlePermissionResult> Function()? permission,
  }) {
    if (!enabled) return null;
    final HaloDeviceAdapter device = HaloDeviceAdapter(transport: transport());
    return HaloCaptionPath._(
        device, HaloCaptionOutputAdapter(device), permission);
  }

  /// Connects to the first Halo discovered within [timeout]. Without the
  /// transport's permission it throws [HaloPermissionDenied] before touching
  /// the transport; a timeout is an error, never a connection.
  Future<void> connectFirst({
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final Future<BlePermissionResult> Function()? permission = _permission;
    if (permission != null) {
      final BlePermissionResult result = await permission();
      if (!result.granted) throw HaloPermissionDenied(result);
    }
    final Future<DeviceDiscovery> discovered =
        device.discoveries.first.timeout(timeout);
    try {
      await device.startDiscovery();
    } on Object {
      discovered.ignore();
      rethrow;
    }
    await device.connect(await discovered);
  }

  Future<void> dispose() => device.dispose();
}
