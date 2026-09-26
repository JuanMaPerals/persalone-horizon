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
  OfficialBrilliantHaloTransport();

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
  Future<void> executeDisplayCommand(HaloDisplayCommand command) async {
    if (!HaloBoundedDisplay.isAcceptable(command.lua)) {
      throw StateError('Display command is outside the bounded grammar.');
    }
    // log: false keeps caption text (runtime data plane) out of SDK logs.
    final String? response = await _readyDevice.sendString(
      command.lua,
      awaitResponse: true,
      log: false,
      timeout: const Duration(seconds: 2),
    );
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