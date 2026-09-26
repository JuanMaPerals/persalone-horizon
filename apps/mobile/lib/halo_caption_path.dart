import 'package:persalone_contracts/persalone_contracts.dart';
import 'package:persalone_halo_adapter/persalone_halo_adapter.dart';

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
  HaloCaptionPath._(this.device, this.captions);

  final HaloDeviceAdapter device;
  final CaptionOutputAdapter captions;

  ExecutionEnvironment get environment => captions.environment;

  static HaloCaptionPath? compose({
    required bool enabled,
    required HaloTransport Function() transport,
  }) {
    if (!enabled) return null;
    final HaloDeviceAdapter device = HaloDeviceAdapter(transport: transport());
    return HaloCaptionPath._(device, HaloCaptionOutputAdapter(device));
  }

  /// Connects to the first Halo discovered within [timeout]; a timeout is
  /// reported as an error, never as a connection.
  Future<void> connectFirst({
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final Future<DeviceDiscovery> discovered =
        device.discoveries.first.timeout(timeout);
    await device.startDiscovery();
    await device.connect(await discovered);
  }

  Future<void> dispose() => device.dispose();
}
