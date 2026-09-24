import 'dart:async';
import 'dart:typed_data';

import 'package:persalone_contracts/persalone_contracts.dart';
import 'package:persalone_halo_adapter/persalone_halo_adapter.dart';
import 'package:test/test.dart';

void main() {
  group('ScriptedHaloFixture', () {
    test('uses the production DeviceAdapter contract with simulated evidence', () async {
      final ScriptedHaloFixture fixture =
          ScriptedHaloFixture(nowMicros: () => 100);
      addTearDown(fixture.dispose);

      final Future<DeviceDiscovery> discovered = fixture.discoveries.first;
      await fixture.startDiscovery();
      final DeviceDiscovery device = await discovered;
      await fixture.connect(device);

      final CapabilityManifest manifest = await fixture.capabilityManifest();
      final DeviceIdentity identity = await fixture.readIdentity();
      final BatterySnapshot battery = await fixture.readBattery();

      expect(device.truthLabel, TruthLabel.simulated);
      expect(
        manifest.stateFor(Capability.bleConnection).truthLabel,
        TruthLabel.simulated,
      );
      expect(identity.truthLabel, TruthLabel.simulated);
      expect(battery.truthLabel, TruthLabel.simulated);
      expect(manifest.stateFor(Capability.microphoneCapture).truthLabel,
          TruthLabel.blocked);
    });

    test('rejects malformed USERDATA instead of accepting a fake success', () async {
      final ScriptedHaloFixture fixture =
          ScriptedHaloFixture(nowMicros: () => 100);
      addTearDown(fixture.dispose);
      final Future<DeviceDiscovery> discovered = fixture.discoveries.first;
      await fixture.startDiscovery();
      await fixture.connect(await discovered);

      expect(
        fixture.sendUserData(
          UserDataMessage(
            schemaVersion: 'invalid',
            type: 1,
            payload: Uint8List(0),
          ),
        ),
        throwsA(
          isA<RuntimeError>().having(
            (RuntimeError error) => error.code,
            'code',
            RuntimeErrorCode.invalidContract,
          ),
        ),
      );
    });
  });

  group('HaloDeviceAdapter', () {
    test('becomes ready only after a required Lua transport is confirmed', () async {
      final _ControlledTransport transport = _ControlledTransport();
      final HaloDeviceAdapter adapter = HaloDeviceAdapter(
        transport: transport,
        nowMicros: () => 200,
      );
      addTearDown(adapter.dispose);

      final Future<DeviceDiscovery> discovered = adapter.discoveries.first;
      await adapter.startDiscovery();
      final DeviceDiscovery device = await discovered;
      final Future<DeviceAdapterSnapshot> ready = adapter.snapshots
          .where((DeviceAdapterSnapshot snapshot) =>
              snapshot.state == DeviceConnectionState.ready)
          .first;
      await adapter.connect(device);

      expect((await ready).truthLabel, TruthLabel.prepared);
      expect((await adapter.readBattery()).levelPercent, 73);
      await adapter.sendUserData(
        UserDataMessage(
          schemaVersion: CapabilityManifest.currentSchemaVersion,
          type: 1,
          payload: Uint8List.fromList(<int>[1]),
        ),
      );
      expect(transport.lastUserData, Uint8List.fromList(<int>[0x01, 1, 1]));
      expect(
        adapter.sendUserData(
          UserDataMessage(
            schemaVersion: CapabilityManifest.currentSchemaVersion,
            type: 1,
            payload: Uint8List(241),
          ),
        ),
        throwsA(
          isA<RuntimeError>().having(
            (RuntimeError error) => error.code,
            'code',
            RuntimeErrorCode.invalidContract,
          ),
        ),
      );
    });

    test('preserves USERDATA order and duplicate payloads as prepared evidence',
        () async {
      final _ControlledTransport transport = _ControlledTransport();
      final HaloDeviceAdapter adapter = HaloDeviceAdapter(
        transport: transport,
        nowMicros: () => 300,
      );
      addTearDown(adapter.dispose);

      final Future<DeviceDiscovery> discovered = adapter.discoveries.first;
      await adapter.startDiscovery();
      await adapter.connect(await discovered);

      await adapter.sendUserData(
        UserDataMessage(
          schemaVersion: CapabilityManifest.currentSchemaVersion,
          type: 7,
          payload: Uint8List.fromList(<int>[1, 2]),
        ),
      );
      await adapter.sendUserData(
        UserDataMessage(
          schemaVersion: CapabilityManifest.currentSchemaVersion,
          type: 7,
          payload: Uint8List.fromList(<int>[1, 2]),
        ),
      );
      await adapter.sendUserData(
        UserDataMessage(
          schemaVersion: CapabilityManifest.currentSchemaVersion,
          type: 8,
          payload: Uint8List.fromList(<int>[3]),
        ),
      );

      expect(
        transport.userDataWrites,
        <Uint8List>[
          Uint8List.fromList(<int>[0x01, 7, 1, 2]),
          Uint8List.fromList(<int>[0x01, 7, 1, 2]),
          Uint8List.fromList(<int>[0x01, 8, 3]),
        ],
      );
    });

    test('enforces negotiated single-packet USERDATA boundary', () async {
      final _ControlledTransport transport = _ControlledTransport();
      final HaloDeviceAdapter adapter = HaloDeviceAdapter(
        transport: transport,
        nowMicros: () => 400,
      );
      addTearDown(adapter.dispose);

      final Future<DeviceDiscovery> discovered = adapter.discoveries.first;
      await adapter.startDiscovery();
      await adapter.connect(await discovered);

      await adapter.sendUserData(
        UserDataMessage(
          schemaVersion: CapabilityManifest.currentSchemaVersion,
          type: 255,
          payload: Uint8List(240),
        ),
      );
      expect(transport.lastUserData, hasLength(242));

      expect(
        adapter.sendUserData(
          UserDataMessage(
            schemaVersion: CapabilityManifest.currentSchemaVersion,
            type: 255,
            payload: Uint8List(241),
          ),
        ),
        throwsA(isA<RuntimeError>()),
      );
      expect(transport.userDataWrites, hasLength(1));
    });

    test('rejects USERDATA while disconnected and reconnects selected device',
        () async {
      final _ControlledTransport transport = _ControlledTransport();
      final HaloDeviceAdapter adapter = HaloDeviceAdapter(
        transport: transport,
        nowMicros: () => 500,
      );
      addTearDown(adapter.dispose);

      final Future<DeviceDiscovery> discovered = adapter.discoveries.first;
      await adapter.startDiscovery();
      final DeviceDiscovery device = await discovered;
      await adapter.connect(device);
      final Future<DeviceAdapterSnapshot> disconnected = adapter.snapshots
          .where((DeviceAdapterSnapshot snapshot) =>
              snapshot.state == DeviceConnectionState.disconnected)
          .first;
      transport.emitLinkState(false);
      await disconnected;

      expect(
        adapter.sendUserData(
          UserDataMessage(
            schemaVersion: CapabilityManifest.currentSchemaVersion,
            type: 1,
            payload: Uint8List.fromList(<int>[1]),
          ),
        ),
        throwsA(
          isA<RuntimeError>().having(
            (RuntimeError error) => error.code,
            'code',
            RuntimeErrorCode.deviceNotReady,
          ),
        ),
      );

      await adapter.reconnect();
      expect(transport.reconnectIds, <String>['controlled-1']);
    });

    test('denies unsupported caller-supplied display Lua without transport call',
        () async {
      final _ControlledTransport transport = _ControlledTransport();
      final HaloDeviceAdapter adapter = HaloDeviceAdapter(
        transport: transport,
        nowMicros: () => 600,
      );
      addTearDown(adapter.dispose);

      final Future<DeviceDiscovery> discovered = adapter.discoveries.first;
      await adapter.startDiscovery();
      await adapter.connect(await discovered);

      expect(
        adapter.executeAllowedLua(
          HaloLuaQuery.displayText,
          text: 'hello',
        ),
        throwsA(
          isA<RuntimeError>().having(
            (RuntimeError error) => error.code,
            'code',
            RuntimeErrorCode.capabilityUnavailable,
          ),
        ),
      );
      expect(transport.readOnlyLuaCommands, isEmpty);
    });
  });
}

final class _ControlledTransport implements HaloTransport {
  final StreamController<HaloTransportDiscovery> _discoveries =
      StreamController<HaloTransportDiscovery>.broadcast();
  final StreamController<bool> _links = StreamController<bool>.broadcast();
  final List<Uint8List> userDataWrites = <Uint8List>[];
  final List<String> reconnectIds = <String>[];
  final List<String> readOnlyLuaCommands = <String>[];
  Uint8List? lastUserData;

  @override
  Stream<HaloTransportDiscovery> get discoveries => _discoveries.stream;

  @override
  Stream<bool> get linkStates => _links.stream;

  @override
  Future<void> startDiscovery() async {
    _discoveries.add(
      const HaloTransportDiscovery(
        reconnectId: 'controlled-1',
        displayName: 'Controlled Halo',
        rssi: -55,
      ),
    );
  }

  @override
  Future<void> stopDiscovery() async {}

  @override
  Future<HaloTransportConnection> connect(HaloTransportDiscovery discovery) async {
    _links.add(true);
    return const HaloTransportConnection(
      reconnectId: 'controlled-1',
      negotiatedMtu: 247,
      hasLuaService: true,
      hasAudioOutput: true,
    );
  }

  @override
  Future<HaloTransportConnection> reconnect(String reconnectId) {
    reconnectIds.add(reconnectId);
    return connect(
      HaloTransportDiscovery(
        reconnectId: reconnectId,
        displayName: 'Controlled Halo',
      ),
    );
  }

  @override
  Future<void> disconnect() async {
    _links.add(false);
  }

  @override
  Future<HaloTransportBattery> readBattery() async {
    return const HaloTransportBattery(levelPercent: 73, isCharging: false);
  }

  @override
  Future<String> executeReadOnlyLua(String command) async {
    readOnlyLuaCommands.add(command);
    return switch (command) {
      'print(frame.get_eui())' => '0011223344556677',
      'print(frame.HARDWARE_VERSION)' => 'halo',
      'print(frame.FIRMWARE_VERSION)' => 'test-firmware',
      'print(frame.battery_level())' => '73',
      'frame.display.clear()print(1)' => '1',
      _ => throw StateError('Unexpected command.'),
    };
  }

  @override
  Future<void> sendUserData(Uint8List payload) async {
    lastUserData = Uint8List.fromList(payload);
    userDataWrites.add(Uint8List.fromList(payload));
  }

  void emitLinkState(bool connected) {
    _links.add(connected);
  }

  @override
  Future<void> dispose() async {
    await _discoveries.close();
    await _links.close();
  }
}
