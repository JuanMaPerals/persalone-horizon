import 'dart:async';
import 'dart:typed_data';

import 'package:brilliant_ble/brilliant_ble.dart';

import 'halo_transport.dart';

/// Official Brilliant SDK transport, deliberately limited to the safe G2
/// surface. The device-side USERDATA application protocol is not enabled here
/// because no reviewed Halo Lua application has been deployed.
final class OfficialBrilliantHaloTransport implements HaloTransport {
  OfficialBrilliantHaloTransport();

  static const String brilliantSdkRevision =
      '462dff4795cffb85248ab1d2f92d4f319adb03d3';

  final StreamController<HaloTransportDiscovery> _discoveries =
      StreamController<HaloTransportDiscovery>.broadcast();
  final StreamController<bool> _linkStates = StreamController<bool>.broadcast();
  final Map<String, BrilliantScannedDevice> _scanned =
      <String, BrilliantScannedDevice>{};

  StreamSubscription<BrilliantScannedDevice>? _scanSubscription;
  StreamSubscription<BrilliantDevice>? _connectionSubscription;
  BrilliantDevice? _device;

  @override
  Stream<HaloTransportDiscovery> get discoveries => _discoveries.stream;

  @override
  Stream<bool> get linkStates => _linkStates.stream;

  @override
  Future<void> startDiscovery() async {
    await stopDiscovery();
    try {
      _scanSubscription = BrilliantBluetooth.scan().listen(
        (BrilliantScannedDevice scanned) {
          final String reconnectId = scanned.device.remoteId.str;
          final String name = scanned.device.advName.isEmpty
              ? 'Halo device'
              : scanned.device.advName;
          _scanned[reconnectId] = scanned;
          _discoveries.add(
            HaloTransportDiscovery(
              reconnectId: reconnectId,
              displayName: name,
              rssi: scanned.rssi,
            ),
          );
        },
        onError: _discoveries.addError,
      );
    } catch (error, stackTrace) {
      _discoveries.addError(error, stackTrace);
      rethrow;
    }
  }

  @override
  Future<void> stopDiscovery() async {
    await _scanSubscription?.cancel();
    _scanSubscription = null;
    await BrilliantBluetooth.stopScan();
  }

  @override
  Future<HaloTransportConnection> connect(HaloTransportDiscovery discovery) async {
    final BrilliantScannedDevice? scanned = _scanned[discovery.reconnectId];
    if (scanned == null) {
      throw StateError('Selected device is no longer available for connection.');
    }
    final BrilliantDevice device = await BrilliantBluetooth.connect(scanned);
    return _adopt(device);
  }

  @override
  Future<HaloTransportConnection> reconnect(String reconnectId) async {
    final BrilliantDevice device = await BrilliantBluetooth.reconnect(reconnectId);
    return _adopt(device);
  }

  Future<HaloTransportConnection> _adopt(BrilliantDevice device) async {
    await _connectionSubscription?.cancel();
    _device = device;
    _connectionSubscription = device.connectionState.listen(
      (BrilliantDevice update) {
        _linkStates.add(update.state == BrilliantConnectionState.connected);
      },
      onError: (_, __) => _linkStates.add(false),
    );

    final bool hasLuaService = device.txChannel != null && device.rxChannel != null;
    final bool hasAudioOutput = device.audioTxChannel != null;
    if (device.type != BrilliantDeviceType.halo || !hasLuaService) {
      await disconnect();
      throw StateError('Required Halo Lua service is incomplete.');
    }
    _linkStates.add(true);
    return HaloTransportConnection(
      reconnectId: device.uuid,
      negotiatedMtu: device.device.mtuNow,
      hasLuaService: hasLuaService,
      hasAudioOutput: hasAudioOutput,
    );
  }

  BrilliantDevice get _readyDevice {
    final BrilliantDevice? device = _device;
    if (device == null || device.state != BrilliantConnectionState.connected) {
      throw StateError('Halo transport is not ready.');
    }
    return device;
  }

  @override
  Future<HaloTransportBattery> readBattery() async {
    final String levelResponse = await executeReadOnlyLua(
      'print(frame.battery_level())',
    );
    final int? level = int.tryParse(_lastLine(levelResponse));
    if (level == null || level < 0 || level > 100) {
      throw StateError('Halo returned an invalid battery level.');
    }
    return HaloTransportBattery(levelPercent: level);
  }

  @override
  Future<String> executeReadOnlyLua(String command) async {
    if (!_isApprovedReadOnlyCommand(command)) {
      throw StateError('Lua command is outside the G2 allow-list.');
    }
    final String? response = await _readyDevice.sendString(
      command,
      awaitResponse: true,
      log: false,
      timeout: const Duration(seconds: 3),
    );
    if (response == null) {
      throw StateError('Halo returned no Lua response.');
    }
    return response;
  }

  @override
  Future<void> sendUserData(Uint8List payload) async {
    if (payload.length < 2) {
      throw ArgumentError.value(
        payload,
        'payload',
        'must include the USERDATA marker and at least one data byte',
      );
    }
    if (payload.first != 0x01) {
      throw ArgumentError.value(
        payload,
        'payload',
        'must start with the Halo USERDATA marker 0x01',
      );
    }
    await _readyDevice.sendDataRaw(
      Uint8List.fromList(payload),
      awaitBtResponse: true,
    );
  }

  @override
  Future<void> disconnect() async {
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;
    final BrilliantDevice? device = _device;
    _device = null;
    if (device != null) {
      await device.disconnect();
    }
    _linkStates.add(false);
  }

  @override
  Future<void> dispose() async {
    await stopDiscovery();
    await disconnect();
    await _discoveries.close();
    await _linkStates.close();
  }

  static String _lastLine(String value) {
    return value
        .split(RegExp(r'\r?\n'))
        .map((String line) => line.trim())
        .where((String line) => line.isNotEmpty)
        .last;
  }

  static bool _isApprovedReadOnlyCommand(String command) {
    return <String>{
      'print(frame.battery_level())',
      'print(frame.get_eui())',
      'print(frame.HARDWARE_VERSION)',
      'print(frame.FIRMWARE_VERSION)',
      'frame.display.clear()print(1)',
    }.contains(command);
  }
}
