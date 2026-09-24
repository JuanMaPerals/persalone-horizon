import 'dart:typed_data';

import 'halo_bounded_display.dart';

/// Transport-level discovery result. It intentionally does not expose a raw
/// device address outside the adapter implementation.
final class HaloTransportDiscovery {
  const HaloTransportDiscovery({
    required this.reconnectId,
    required this.displayName,
    this.rssi,
  });

  final String reconnectId;
  final String displayName;
  final int? rssi;
}

/// Connection data available only after the required Lua service is enabled.
final class HaloTransportConnection {
  const HaloTransportConnection({
    required this.reconnectId,
    required this.negotiatedMtu,
    required this.hasLuaService,
    required this.hasAudioOutput,
  });

  final String reconnectId;
  final int negotiatedMtu;
  final bool hasLuaService;
  final bool hasAudioOutput;
}

/// Read-only GATT battery data. Null fields mean that the characteristic was
/// not available or could not be read; they never become guessed values.
final class HaloTransportBattery {
  const HaloTransportBattery({
    required this.levelPercent,
    this.isCharging,
  });

  final int levelPercent;
  final bool? isCharging;
}

/// The smallest BLE-facing boundary needed for G2.
///
/// Implementations must not expose OTA, arbitrary Lua, raw audio streaming, or
/// unredacted identifiers through this port.
abstract interface class HaloTransport {
  Stream<HaloTransportDiscovery> get discoveries;
  Stream<bool> get linkStates;

  Future<void> startDiscovery();
  Future<void> stopDiscovery();
  Future<HaloTransportConnection> connect(HaloTransportDiscovery discovery);
  Future<HaloTransportConnection> reconnect(String reconnectId);
  Future<void> disconnect();
  Future<HaloTransportBattery> readBattery();
  Future<String> executeReadOnlyLua(String command);

  /// Sends a command built by [HaloBoundedDisplay]; implementations must
  /// re-check [HaloBoundedDisplay.isAcceptable], never log the payload, and
  /// bound the wait with a timeout.
  Future<void> executeDisplayCommand(HaloDisplayCommand command);
  Future<void> sendUserData(Uint8List payload);
  Future<void> dispose();
}
