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
  HaloCaptionPath._(this.device, CaptionOutputAdapter captions, this._permission) {
    this.captions = _PermissionGatedCaptions(captions, () => _denied);
  }

  final HaloDeviceAdapter device;
  late final CaptionOutputAdapter captions;
  final Future<BlePermissionResult> Function()? _permission;

  /// The last permission answer when it was a denial; while set, every
  /// caption is BLOCKED by policy and the device is not asked.
  BlePermissionResult? _denied;

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
      _denied = result.granted ? null : result;
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

/// Reports a Bluetooth permission denial as a policy-blocked caption (coded
/// `blePermission.<reason>`), so runtime events and validation logs match the
/// BLOCKED state the app shows, instead of a device failure.
final class _PermissionGatedCaptions implements CaptionOutputAdapter {
  _PermissionGatedCaptions(this._inner, this._denied);

  final CaptionOutputAdapter _inner;
  final BlePermissionResult? Function() _denied;

  @override
  ExecutionEnvironment get environment => _inner.environment;

  @override
  String get adapterId => _inner.adapterId;

  @override
  Future<CaptionDelivery> show(CaptionUpdate update) async {
    final BlePermissionResult? denied = _denied();
    if (denied == null) return _inner.show(update);
    return CaptionDelivery(
      session: update.session,
      sequence: update.sequence,
      status: CaptionDeliveryStatus.blocked,
      environment: environment,
      truthLabel: TruthLabel.blocked,
      adapterId: adapterId,
      reason: 'blePermission.${denied.reason}',
    );
  }

  @override
  Future<void> clear(TranslationSession session) async {
    if (_denied() != null) return;
    await _inner.clear(session);
  }
}
