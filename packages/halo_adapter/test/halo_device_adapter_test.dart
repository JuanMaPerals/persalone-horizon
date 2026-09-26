import 'dart:async';
import 'dart:typed_data';

import 'package:persalone_contracts/persalone_contracts.dart';
import 'package:persalone_halo_adapter/persalone_halo_adapter.dart';
import 'package:test/test.dart';

void main() {
  group('ScriptedHaloFixture', () {
    test('uses the production DeviceAdapter contract with simulated evidence',
        () async {
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

    test('rejects malformed USERDATA instead of accepting a fake success',
        () async {
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
    test('becomes ready only after a required Lua transport is confirmed',
        () async {
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
  });

  group('HaloDeviceAdapter bounded displayText', () {
    Future<(HaloDeviceAdapter, _ControlledTransport)> connected() async {
      final _ControlledTransport transport = _ControlledTransport();
      final HaloDeviceAdapter adapter =
          HaloDeviceAdapter(transport: transport, nowMicros: () => 200);
      addTearDown(adapter.dispose);
      final Future<DeviceDiscovery> discovered = adapter.discoveries.first;
      await adapter.startDiscovery();
      await adapter.connect(await discovered);
      return (adapter, transport);
    }

    test('wakes the display only on the first caption after each connection',
        () async {
      final (HaloDeviceAdapter adapter, _ControlledTransport transport) =
          await connected();

      final HaloLuaResult result = await adapter
          .executeAllowedLua(HaloLuaQuery.displayText, text: 'uno');
      await adapter.executeAllowedLua(HaloLuaQuery.displayText, text: 'dos');
      await adapter.disconnect();
      await adapter.reconnect();
      await adapter.executeAllowedLua(HaloLuaQuery.displayText, text: 'tres');

      expect(result.truthLabel, TruthLabel.prepared);
      expect(
          transport.displayCommands.map((String lua) =>
              lua.startsWith('local d=frame.display d.power_save(false)')),
          <bool>[
            true,
            false,
            true,
          ]);
      expect(transport.displayCommands.every(HaloBoundedDisplay.isAcceptable),
          isTrue);
      expect(transport.executed, isEmpty);
    });

    test('rejects oversized or missing text before anything is sent', () async {
      final (HaloDeviceAdapter adapter, _ControlledTransport transport) =
          await connected();

      for (final String? text in <String?>[
        'a' * (HaloCaptionComposer.maxInputChars + 1),
        'a\uD800',
        null,
      ]) {
        await expectLater(
          adapter.executeAllowedLua(HaloLuaQuery.displayText, text: text),
          throwsA(isA<RuntimeError>().having((RuntimeError e) => e.code, 'code',
              RuntimeErrorCode.invalidContract)),
        );
      }
      expect(transport.displayCommands, isEmpty);
    });

    test('reports a timeout as retryable without tearing down the link',
        () async {
      final (HaloDeviceAdapter adapter, _ControlledTransport transport) =
          await connected();
      transport.displayError = TimeoutException('no ack');

      await expectLater(
        adapter.executeAllowedLua(HaloLuaQuery.displayText, text: 'hola'),
        throwsA(isA<RuntimeError>()
            .having((RuntimeError e) => e.code, 'code',
                RuntimeErrorCode.protocolRejected)
            .having((RuntimeError e) => e.retryable, 'retryable', isTrue)),
      );

      transport.displayError = null;
      await adapter.executeAllowedLua(HaloLuaQuery.displayText, text: 'hola');
      expect(transport.displayCommands.single,
          startsWith('local d=frame.display d.power_save(false)'));
      expect((await adapter.readBattery()).levelPercent, 73);
    });

    test('discards a display result when the link changes mid-flight',
        () async {
      final (HaloDeviceAdapter adapter, _ControlledTransport transport) =
          await connected();
      transport.displayGate = Completer<void>();

      final Future<HaloLuaResult> pending =
          adapter.executeAllowedLua(HaloLuaQuery.displayText, text: 'tarde');
      await adapter.disconnect();
      transport.displayGate!.complete();

      await expectLater(
        pending,
        throwsA(isA<RuntimeError>().having((RuntimeError e) => e.code, 'code',
            RuntimeErrorCode.deviceNotReady)),
      );
    });

    test('clear stays a constant allow-listed command without text', () async {
      final (HaloDeviceAdapter adapter, _ControlledTransport transport) =
          await connected();

      await adapter.executeAllowedLua(HaloLuaQuery.clearDisplay);
      await expectLater(
        adapter.executeAllowedLua(HaloLuaQuery.clearDisplay, text: 'x'),
        throwsA(isA<RuntimeError>().having(
            (RuntimeError e) => e.code, 'code', RuntimeErrorCode.policyDenied)),
      );
      expect(transport.executed, <String>['frame.display.clear()print(1)']);
    });
  });

  group('HaloCaptionOutputAdapter', () {
    const String injection = "]]) frame.display.clear() os.execute('x') --";

    test('only the official BLE transport declares HALO_REAL', () {
      expect(OfficialBrilliantHaloTransport().environment,
          ExecutionEnvironment.haloReal);
      final HaloDeviceAdapter adapter = HaloDeviceAdapter(
        transport: _ControlledTransport(),
        nowMicros: () => 1,
      );
      addTearDown(adapter.dispose);
      expect(adapter.environment, ExecutionEnvironment.simulated);
      expect(HaloCaptionOutputAdapter(adapter).environment,
          ExecutionEnvironment.simulated);
    });

    test(
        'delivers device captions with the transport environment and never '
        'sends caption text outside the bounded command', () async {
      final _ControlledTransport transport = _ControlledTransport();
      final HaloDeviceAdapter adapter = HaloDeviceAdapter(
        transport: transport,
        nowMicros: () => 200,
      );
      addTearDown(adapter.dispose);
      final Future<DeviceDiscovery> discovered = adapter.discoveries.first;
      await adapter.startDiscovery();
      await adapter.connect(await discovered);
      final HaloCaptionOutputAdapter captions =
          HaloCaptionOutputAdapter(adapter);

      final CaptionDelivery delivery = await captions.show(_caption(injection));

      expect(captions.environment, ExecutionEnvironment.simulated);
      expect(delivery.environment, ExecutionEnvironment.simulated);
      expect(delivery.status, CaptionDeliveryStatus.delivered);
      expect(delivery.truthLabel, TruthLabel.prepared);
      expect(delivery.reason, isNull);
      expect(transport.displayCommands.single,
          startsWith('local d=frame.display d.power_save(false)'));
      expect(HaloBoundedDisplay.isAcceptable(transport.displayCommands.single),
          isTrue);
      expect(
        transport.executed.where((String command) =>
            command.contains('os.execute') || command.contains(injection)),
        isEmpty,
      );

      await captions.clear(_caption('').session);
      expect(transport.executed.last, 'frame.display.clear()print(1)');
    });

    test('UNICODE LIMIT: degraded glyphs are reported on the delivery',
        () async {
      final ScriptedHaloFixture fixture =
          ScriptedHaloFixture(nowMicros: () => 100);
      addTearDown(fixture.dispose);
      final Future<DeviceDiscovery> discovered = fixture.discoveries.first;
      await fixture.startDiscovery();
      await fixture.connect(await discovered);
      final HaloCaptionOutputAdapter captions =
          HaloCaptionOutputAdapter(fixture);

      final CaptionDelivery plain = await captions.show(_caption('hello'));
      expect(plain.reason, isNull);
      expect(plain.foldedGlyphs + plain.replacedGlyphs, 0);

      final CaptionDelivery folded = await captions.show(_caption('qué tal'));
      expect(folded.status, CaptionDeliveryStatus.delivered);
      expect(folded.reason, 'glyphsFolded');
      expect(folded.foldedGlyphs, 1);

      final CaptionDelivery replaced =
          await captions.show(_caption('año 中文'));
      expect(replaced.reason, 'glyphsReplaced');
      expect(replaced.foldedGlyphs, 1);
      expect(replaced.replacedGlyphs, 2);
    });

    test('reports a fixture as SIMULATED, never HALO_REAL or EMULATED',
        () async {
      final ScriptedHaloFixture fixture =
          ScriptedHaloFixture(nowMicros: () => 100);
      addTearDown(fixture.dispose);
      final Future<DeviceDiscovery> discovered = fixture.discoveries.first;
      await fixture.startDiscovery();
      await fixture.connect(await discovered);
      final HaloCaptionOutputAdapter captions =
          HaloCaptionOutputAdapter(fixture);

      final CaptionDelivery delivery = await captions.show(_caption('hola'));

      expect(captions.environment, ExecutionEnvironment.simulated);
      expect(delivery.status, CaptionDeliveryStatus.delivered);
      expect(delivery.truthLabel, TruthLabel.simulated);
      expect(fixture.lastDisplayCommand, isNotNull);
    });
  });
}

CaptionUpdate _caption(String text) => CaptionUpdate(
      session: const TranslationSession(
        sessionId: 'caption-session',
        streamEpoch: 1,
        direction: TranslationDirection.spanishToEnglish,
        privacyGeneration: 1,
      ),
      sequence: 1,
      text: text,
      observedAtMicros: 1,
      truthLabel: TruthLabel.simulated,
    );

final class _ControlledTransport implements HaloTransport {
  @override
  ExecutionEnvironment get environment => ExecutionEnvironment.simulated;

  final StreamController<HaloTransportDiscovery> _discoveries =
      StreamController<HaloTransportDiscovery>.broadcast();
  final StreamController<bool> _links = StreamController<bool>.broadcast();
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
  Future<HaloTransportConnection> connect(
      HaloTransportDiscovery discovery) async {
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

  final List<String> executed = <String>[];

  @override
  Future<String> executeReadOnlyLua(String command) async {
    executed.add(command);
    return switch (command) {
      'print(frame.get_eui())' => '0011223344556677',
      'print(frame.HARDWARE_VERSION)' => 'halo',
      'print(frame.FIRMWARE_VERSION)' => 'test-firmware',
      'print(frame.battery_level())' => '73',
      'frame.display.clear()print(1)' => '1',
      _ => throw StateError('Unexpected command.'),
    };
  }

  final List<String> displayCommands = <String>[];
  Completer<void>? displayGate;
  Object? displayError;

  @override
  Future<void> executeDisplayCommand(HaloDisplayCommand command) async {
    await displayGate?.future;
    final Object? error = displayError;
    if (error != null) {
      throw error;
    }
    displayCommands.add(command.lua);
  }

  @override
  Future<void> sendUserData(Uint8List payload) async {
    lastUserData = Uint8List.fromList(payload);
  }

  @override
  Future<void> dispose() async {
    await _discoveries.close();
    await _links.close();
  }
}
