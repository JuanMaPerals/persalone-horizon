import 'dart:async';
import 'dart:typed_data';

import 'package:brilliant_ble/brilliant_ble.dart';
import 'package:brilliant_msg/brilliant_msg.dart' show RxAudio;
import 'package:persalone_contracts/persalone_contracts.dart'
    show ExecutionEnvironment;

import 'package:persalone_halo_core/persalone_halo_core.dart';

import 'halo_audio_transport.dart';

/// Official Brilliant SDK transport, deliberately limited to the safe G2
/// surface. The device-side USERDATA application protocol is not enabled here
/// because no reviewed Halo Lua application has been deployed.
final class OfficialBrilliantHaloTransport implements HaloTransport, HaloAudioTransport {
  /// The optional functions are test seams over the SDK's static and
  /// platform-bound calls; production uses the SDK directly.
  OfficialBrilliantHaloTransport({
    Stream<BrilliantDevice> Function(BrilliantDevice device)? connectionStates,
    Future<BrilliantDevice> Function(String reconnectId)? reconnector,
    Future<String?> Function(
            BrilliantDevice device, String command, Duration timeout)?
        luaSender,
    Future<void> Function(BrilliantDevice device)? disconnector,
  })  : _connectionStates = connectionStates ?? _sdkConnectionStates,
        _reconnector = reconnector ?? BrilliantBluetooth.reconnect,
        _luaSender = luaSender ?? _sdkSendLua,
        _disconnector = disconnector ?? _sdkDisconnect;

  final Stream<BrilliantDevice> Function(BrilliantDevice device)
      _connectionStates;
  final Future<BrilliantDevice> Function(String reconnectId) _reconnector;
  final Future<String?> Function(
      BrilliantDevice device, String command, Duration timeout) _luaSender;
  final Future<void> Function(BrilliantDevice device) _disconnector;

  static Stream<BrilliantDevice> _sdkConnectionStates(BrilliantDevice device) =>
      device.connectionState;

  // log: false keeps caption text (runtime data plane) out of SDK logs.
  static Future<String?> _sdkSendLua(
          BrilliantDevice device, String command, Duration timeout) =>
      device.sendString(command,
          awaitResponse: true, log: false, timeout: timeout);

  static Future<void> _sdkDisconnect(BrilliantDevice device) =>
      device.disconnect();

  @override
  ExecutionEnvironment get environment => ExecutionEnvironment.haloReal;

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
  RxAudio? _rxAudio;

  /// Set once a scan was requested from the Bluetooth stack. Stopping and
  /// disposing never reach Bluetooth otherwise, so a path that was refused
  /// its Bluetooth permission tears down without a single Bluetooth call.
  bool _scanRequested = false;

  static const int _startListeningMsg = 0x30;
  static const int _stopListeningMsg = 0x31;
  static const int _startPlaybackMsg = 0x40;
  static const int _stopPlaybackMsg = 0x41;

  @override
  Stream<HaloTransportDiscovery> get discoveries => _discoveries.stream;

  @override
  Stream<bool> get linkStates => _linkStates.stream;

  @override
  Future<void> startDiscovery() async {
    await stopDiscovery();
    try {
      _scanRequested = true;
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
    if (!_scanRequested) return;
    _scanRequested = false;
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
    final BrilliantDevice device = await _reconnector(reconnectId);
    return _adopt(device);
  }

  Future<HaloTransportConnection> _adopt(BrilliantDevice device) async {
    await _connectionSubscription?.cancel();
    _device = device;
    final String uuid = device.uuid;
    _connectionSubscription = _connectionStates(device).listen(
      (BrilliantDevice update) {
        // The SDK stream carries every BLE device's events; only this Halo's
        // count.
        if (update.uuid == uuid) _onConnectionUpdate(update);
      },
      onError: (Object _, StackTrace __) => _failClosed(),
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

  /// The SDK emits a NEW [BrilliantDevice] on every change: a disconnected
  /// one when the link is lost, and after a reconnection one built by
  /// `enableServices()` with freshly discovered GATT characteristics. The
  /// transport always adopts the newest one; an earlier instance (whose
  /// `state` field still reads connected, and whose characteristics are
  /// stale) must never be used again, or the transport reports a false READY.
  void _onConnectionUpdate(BrilliantDevice update) {
    if (update.state == BrilliantConnectionState.connected) {
      if (update.type != BrilliantDeviceType.halo ||
          update.txChannel == null ||
          update.rxChannel == null) {
        _failClosed();
        return;
      }
      _device = update;
      _addLinkState(true);
      return;
    }
    // Audio decoding was attached to the lost link's notifications.
    _detachAudio();
    _device = update;
    _addLinkState(false);
  }

  /// A broken state stream or an unusable device: nothing is ready until an
  /// explicit reconnect adopts a new instance.
  void _failClosed() {
    _detachAudio();
    _device = null;
    _addLinkState(false);
  }

  void _detachAudio() {
    _rxAudio?.detach();
    _rxAudio = null;
  }

  void _addLinkState(bool connected) {
    if (!_linkStates.isClosed) _linkStates.add(connected);
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
    final String? response =
        await _luaSender(_readyDevice, command, const Duration(seconds: 3));
    if (response == null) {
      throw StateError('Halo returned no Lua response.');
    }
    return response;
  }

  @override
  Future<void> executeDisplayCommand(HaloDisplayCommand command) async {
    if (!HaloBoundedDisplay.isAcceptable(command.lua)) {
      throw StateError('Display command is outside the bounded grammar.');
    }
    final String? response = await _luaSender(
        _readyDevice, command.lua, const Duration(seconds: 2));
    if (response == null || _lastLine(response) != '1') {
      throw StateError('Halo did not acknowledge the display command.');
    }
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
  Stream<Uint8List> get encodedMicrophoneAudio {
    final RxAudio audio = _rxAudio ??= RxAudio(streaming: true);
    return audio.attach(_readyDevice.dataResponse);
  }

  @override
  Future<void> startMicrophone({
    int gain = 10,
    bool echoCancellation = true,
    bool voiceMode = true,
  }) async {
    await _readyDevice.sendMessage(
      _startListeningMsg,
      Uint8List.fromList(<int>[
        gain.clamp(0, 20),
        echoCancellation ? 1 : 0,
        voiceMode ? 1 : 0,
      ]),
    );
  }

  @override
  Future<void> stopMicrophone() async {
    await _readyDevice.sendMessage(
      _stopListeningMsg,
      Uint8List.fromList(<int>[0]),
    );
    _rxAudio?.detach();
    _rxAudio = null;
  }

  @override
  Future<void> startSpeaker({int volume = 100}) async {
    await _readyDevice.sendMessage(
      _startPlaybackMsg,
      Uint8List.fromList(<int>[volume.clamp(0, 100)]),
    );
  }

  @override
  Future<void> sendEncodedSpeakerAudio(Uint8List lc3Frame) async {
    await _readyDevice.sendAudio(lc3Frame);
  }

  @override
  Future<void> stopSpeaker() async {
    await _readyDevice.sendMessage(
      _stopPlaybackMsg,
      Uint8List.fromList(<int>[0]),
    );
  }

  @override
  Future<void> disconnect() async {
    _rxAudio?.detach();
    _rxAudio = null;
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;
    final BrilliantDevice? device = _device;
    _device = null;
    if (device != null) {
      await _disconnector(device);
    }
    _addLinkState(false);
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