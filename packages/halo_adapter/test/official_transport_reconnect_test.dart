import 'dart:async';
import 'dart:typed_data';

import 'package:brilliant_ble/brilliant_ble.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:persalone_contracts/persalone_contracts.dart';
import 'package:persalone_halo_adapter/persalone_halo_adapter.dart';
import 'package:test/test.dart';

// The Brilliant SDK emits a NEW BrilliantDevice on every connection change:
// a disconnected one on loss, and after reconnecting one built by
// enableServices() with fresh GATT characteristics. HORIZON must always adopt
// the newest instance and fail closed in between; a kept earlier instance
// still reads `state == connected` and reports a false READY over stale GATT.
const String _halo = 'AA:BB:CC:DD:EE:01';

BrilliantDevice _device({
  String id = _halo,
  BrilliantConnectionState state = BrilliantConnectionState.connected,
  BrilliantDeviceType type = BrilliantDeviceType.halo,
  bool lua = true,
}) {
  final BrilliantDevice device = BrilliantDevice(
    state: state,
    device: BluetoothDevice.fromId(id),
    type: type,
    maxStringLength: 244,
  );
  if (lua) {
    BluetoothCharacteristic characteristic(String uuid) =>
        BluetoothCharacteristic(
          remoteId: DeviceIdentifier(id),
          serviceUuid: Guid('7a230001-5475-a6a4-654c-8431f6ad49c4'),
          characteristicUuid: Guid(uuid),
        );
    device
      ..txChannel = characteristic('7a230002-5475-a6a4-654c-8431f6ad49c4')
      ..rxChannel = characteristic('7a230003-5475-a6a4-654c-8431f6ad49c4');
  }
  return device;
}

final class _Sdk {
  final StreamController<BrilliantDevice> updates =
      StreamController<BrilliantDevice>.broadcast();
  final List<BrilliantDevice> luaTargets = <BrilliantDevice>[];
  BrilliantDevice? nextReconnect;

  OfficialBrilliantHaloTransport transport() => OfficialBrilliantHaloTransport(
        connectionStates: (BrilliantDevice _) => updates.stream,
        reconnector: (String id) async {
          final BrilliantDevice? next = nextReconnect;
          if (next == null) throw StateError('no Halo in range');
          return next;
        },
        luaSender: (BrilliantDevice device, String command, Duration _) async {
          luaTargets.add(device);
          return '80';
        },
        disconnector: (BrilliantDevice _) async {},
      );

  Future<void> settle() => Future<void>.delayed(Duration.zero);
}

void main() {
  late _Sdk sdk;
  late OfficialBrilliantHaloTransport transport;
  late List<bool> links;
  late StreamSubscription<bool> linkSub;

  setUp(() {
    sdk = _Sdk();
    transport = sdk.transport();
    links = <bool>[];
    linkSub = transport.linkStates.listen(links.add);
  });

  tearDown(() async {
    await linkSub.cancel();
    await transport.dispose();
    await sdk.updates.close();
  });

  group('transport', () {
    test('an unexpected loss blocks operations although the old instance '
        'still reads connected', () async {
      final BrilliantDevice first = _device();
      sdk.nextReconnect = first;
      await transport.reconnect(_halo);
      expect((await transport.readBattery()).levelPercent, 80);

      sdk.updates.add(_device(state: BrilliantConnectionState.disconnected));
      await sdk.settle();

      expect(first.state, BrilliantConnectionState.connected,
          reason: 'the SDK never mutates the instance it gave us');
      sdk.luaTargets.clear();
      await expectLater(transport.readBattery(), throwsA(isA<StateError>()));
      expect(sdk.luaTargets, isEmpty, reason: 'no write to a lost link');
      expect(links.last, isFalse);
    });

    test('after a reconnection the NEW instance is used, never the stale one',
        () async {
      final BrilliantDevice first = _device();
      sdk.nextReconnect = first;
      await transport.reconnect(_halo);
      sdk.updates.add(_device(state: BrilliantConnectionState.disconnected));
      // Android reconnects on its own and rediscovers GATT.
      final BrilliantDevice rediscovered = _device();
      sdk.updates.add(rediscovered);
      await sdk.settle();

      sdk.luaTargets.clear();
      await transport.readBattery();
      expect(sdk.luaTargets.single, same(rediscovered));
      expect(sdk.luaTargets.single, isNot(same(first)));
      expect(links, <bool>[true, false, true]);
    });

    test('a broken state stream fails closed until an explicit reconnect',
        () async {
      sdk.nextReconnect = _device();
      await transport.reconnect(_halo);
      sdk.updates.addError(StateError('GATT error'));
      await sdk.settle();
      await expectLater(transport.readBattery(), throwsA(isA<StateError>()));

      final BrilliantDevice fresh = _device();
      sdk.nextReconnect = fresh;
      await transport.reconnect(_halo);
      sdk.luaTargets.clear();
      await transport.readBattery();
      expect(sdk.luaTargets.single, same(fresh));
    });

    test('a reconnected device without the Lua service is never adopted',
        () async {
      sdk.nextReconnect = _device();
      await transport.reconnect(_halo);
      sdk.updates.add(_device(lua: false));
      await sdk.settle();
      await expectLater(transport.readBattery(), throwsA(isA<StateError>()));
      expect(links.last, isFalse);
    });

    test('events of another BLE device never replace the Halo', () async {
      final BrilliantDevice halo = _device();
      sdk.nextReconnect = halo;
      await transport.reconnect(_halo);
      sdk.updates
        ..add(_device(id: 'AA:BB:CC:DD:EE:99', type: BrilliantDeviceType.frame))
        ..add(_device(
            id: 'AA:BB:CC:DD:EE:99',
            state: BrilliantConnectionState.disconnected));
      await sdk.settle();

      sdk.luaTargets.clear();
      await transport.readBattery();
      expect(sdk.luaTargets.single, same(halo));
      expect(links, <bool>[true]);
    });
  });

  test(
      'adapter: READY -> loss -> DISCONNECTED -> blocked -> reconnect -> '
      'new device -> READY -> operation OK', () async {
    final HaloDeviceAdapter adapter =
        HaloDeviceAdapter(transport: _KnownHalo(transport));
    addTearDown(adapter.dispose);
    final List<DeviceConnectionState> states = <DeviceConnectionState>[];
    final StreamSubscription<DeviceAdapterSnapshot> stateSub = adapter.snapshots
        .listen((DeviceAdapterSnapshot s) => states.add(s.state));
    addTearDown(stateSub.cancel);
    sdk.nextReconnect = _device();

    final Future<DeviceDiscovery> found = adapter.discoveries.first;
    await adapter.startDiscovery();
    await adapter.connect(await found);
    await sdk.settle();
    expect(states.last, DeviceConnectionState.ready);
    expect((await adapter.readBattery()).levelPercent, 80);

    sdk.updates.add(_device(state: BrilliantConnectionState.disconnected));
    await sdk.settle();
    expect(states.last, DeviceConnectionState.disconnected);
    sdk.luaTargets.clear();
    await expectLater(adapter.readBattery(), throwsA(isA<RuntimeError>()));
    expect(sdk.luaTargets, isEmpty);

    final BrilliantDevice second = _device();
    sdk.nextReconnect = second;
    await adapter.reconnect();
    await sdk.settle();
    expect(states.last, DeviceConnectionState.ready);
    expect((await adapter.readBattery()).levelPercent, 80);
    expect(sdk.luaTargets.single, same(second),
        reason: 'the new instance, never the one from before the loss');
  });
}

/// Discovery needs a radio, so this wrapper announces one remembered Halo
/// and connects it through the official transport's own reconnect path;
/// adoption, readiness and Lua all run in the real transport.
final class _KnownHalo implements HaloTransport {
  _KnownHalo(this._inner);

  final OfficialBrilliantHaloTransport _inner;
  final StreamController<HaloTransportDiscovery> _found =
      StreamController<HaloTransportDiscovery>.broadcast();

  @override
  ExecutionEnvironment get environment => _inner.environment;
  @override
  Stream<HaloTransportDiscovery> get discoveries => _found.stream;
  @override
  Stream<bool> get linkStates => _inner.linkStates;
  @override
  Future<void> startDiscovery() async => _found.add(
      const HaloTransportDiscovery(reconnectId: _halo, displayName: 'Halo'));
  @override
  Future<void> stopDiscovery() async {}
  @override
  Future<HaloTransportConnection> connect(HaloTransportDiscovery discovery) =>
      _inner.reconnect(discovery.reconnectId);
  @override
  Future<HaloTransportConnection> reconnect(String reconnectId) =>
      _inner.reconnect(reconnectId);
  @override
  Future<void> disconnect() => _inner.disconnect();
  @override
  Future<HaloTransportBattery> readBattery() => _inner.readBattery();
  @override
  Future<String> executeReadOnlyLua(String command) =>
      _inner.executeReadOnlyLua(command);
  @override
  Future<void> executeDisplayCommand(HaloDisplayCommand command) =>
      _inner.executeDisplayCommand(command);
  @override
  Future<void> sendUserData(Uint8List payload) => _inner.sendUserData(payload);
  @override
  Future<void> dispose() => _found.close();
}
