import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:persalone_contracts/persalone_contracts.dart';
import 'package:persalone_halo_adapter/persalone_halo_adapter.dart';
import 'package:persalone_mobile/ble_permission_gate.dart';
import 'package:persalone_mobile/halo_caption_path.dart';

// The BLE permission gate sits in front of the Halo transport: without it no
// Bluetooth operation happens, and with it nothing is promoted beyond what
// the device path already reports (at most PREPARED, never observed).
const TranslationSession _session = TranslationSession(
  sessionId: 'ble-gate',
  streamEpoch: 1,
  direction: TranslationDirection.englishToSpanish,
  privacyGeneration: 1,
);

CaptionUpdate _caption() => const CaptionUpdate(
      session: _session,
      sequence: 1,
      text: 'Hola',
      observedAtMicros: 1,
      truthLabel: TruthLabel.simulated,
    );

void main() {
  late _BleTransport transport;
  setUp(() => transport = _BleTransport());

  HaloCaptionPath compose(BlePermissionResult answer) {
    final HaloCaptionPath path = HaloCaptionPath.compose(
      enabled: true,
      transport: () => transport,
      permission: () async => answer,
    )!;
    addTearDown(path.dispose);
    return path;
  }

  for (final BlePermissionResult denial in <BlePermissionResult>[
    const BlePermissionResult.denied('permissionDenied', <String>['BLUETOOTH_SCAN']),
    const BlePermissionResult.denied('bleRequiresAndroid12'),
    const BlePermissionResult.denied('platformError'),
    const BlePermissionResult.denied('malformedResponse'),
  ]) {
    test('${denial.reason}: no Bluetooth call, captions stay BLOCKED',
        () async {
      final HaloCaptionPath path = compose(denial);

      await expectLater(
        path.connectFirst(timeout: const Duration(seconds: 2)),
        throwsA(isA<HaloPermissionDenied>()
            .having((e) => e.result.reason, 'reason', denial.reason)),
      );
      expect(transport.calls, isEmpty,
          reason: 'the transport must not be touched without permission');

      // The denial is a policy refusal, reported as such on every caption
      // (not as a device failure) and without reaching the transport.
      final CaptionDelivery delivery = await path.captions.show(_caption());
      expect(delivery.status, CaptionDeliveryStatus.blocked);
      expect(delivery.truthLabel, TruthLabel.blocked);
      expect(delivery.reason, 'blePermission.${denial.reason}');
      expect(delivery.environment, ExecutionEnvironment.haloReal);
      await path.captions.clear(_session);
      expect(transport.calls, isEmpty);
    });
  }

  test('a later grant lifts the block and delivers again', () async {
    BlePermissionResult answer =
        const BlePermissionResult.denied('permissionDenied', <String>['BLUETOOTH_CONNECT']);
    final HaloCaptionPath path = HaloCaptionPath.compose(
      enabled: true,
      transport: () => transport,
      permission: () async => answer,
    )!;
    addTearDown(path.dispose);

    await expectLater(path.connectFirst(), throwsA(isA<HaloPermissionDenied>()));
    expect((await path.captions.show(_caption())).status,
        CaptionDeliveryStatus.blocked);

    answer = BlePermissionResult.parse(
        <Object?, Object?>{'granted': true, 'reason': 'granted'});
    await path.connectFirst(timeout: const Duration(seconds: 2));
    final CaptionDelivery delivery = await path.captions.show(_caption());
    expect(delivery.status, CaptionDeliveryStatus.delivered);
    expect(delivery.truthLabel, TruthLabel.prepared);
  });

  test('granted opens discovery, but evidence is never promoted', () async {
    final HaloCaptionPath path = compose(BlePermissionResult.parse(
        <Object?, Object?>{'granted': true, 'reason': 'granted'}));

    await path.connectFirst(timeout: const Duration(seconds: 2));
    expect(transport.calls.first, 'startDiscovery');
    expect(transport.calls, contains('connect'));
    expect(path.environment, ExecutionEnvironment.haloReal,
        reason: 'the environment is what the BLE transport declares');

    final CaptionDelivery delivery = await path.captions.show(_caption());
    expect(delivery.status, CaptionDeliveryStatus.delivered);
    expect(delivery.truthLabel, TruthLabel.prepared,
        reason: 'a permission or a device ack is not observation of HALO_REAL');
  });

  test('a failing discovery surfaces its error and leaks no timeout',
      () async {
    transport.failDiscovery = true;
    final HaloCaptionPath path = compose(BlePermissionResult.parse(
        <Object?, Object?>{'granted': true, 'reason': 'granted'}));
    await expectLater(
        path.connectFirst(timeout: const Duration(milliseconds: 50)),
        throwsA(isA<StateError>()));
    // An unhandled timeout error would fail the test zone after this delay.
    await Future<void>.delayed(const Duration(milliseconds: 120));
  });
}

/// Stands in for the Brilliant BLE transport: declares HALO_REAL and records
/// every call, so a test can prove nothing was attempted.
final class _BleTransport implements HaloTransport {
  final List<String> calls = <String>[];
  final List<HaloDisplayCommand> displayCommands = <HaloDisplayCommand>[];
  bool failDiscovery = false;
  final StreamController<HaloTransportDiscovery> _discoveries =
      StreamController<HaloTransportDiscovery>.broadcast();
  final StreamController<bool> _links = StreamController<bool>.broadcast();

  @override
  ExecutionEnvironment get environment => ExecutionEnvironment.haloReal;
  @override
  Stream<HaloTransportDiscovery> get discoveries => _discoveries.stream;
  @override
  Stream<bool> get linkStates => _links.stream;

  @override
  Future<void> startDiscovery() async {
    calls.add('startDiscovery');
    if (failDiscovery) throw StateError('adapter off');
    _discoveries.add(const HaloTransportDiscovery(
        reconnectId: 'halo-1', displayName: 'Halo', rssi: -50));
  }

  @override
  Future<void> stopDiscovery() async => calls.add('stopDiscovery');

  @override
  Future<HaloTransportConnection> connect(
      HaloTransportDiscovery discovery) async {
    calls.add('connect');
    _links.add(true);
    return const HaloTransportConnection(
      reconnectId: 'halo-1',
      negotiatedMtu: 247,
      hasLuaService: true,
      hasAudioOutput: true,
    );
  }

  @override
  Future<HaloTransportConnection> reconnect(String reconnectId) {
    calls.add('reconnect');
    return connect(HaloTransportDiscovery(
        reconnectId: reconnectId, displayName: 'Halo'));
  }

  @override
  Future<void> disconnect() async {
    calls.add('disconnect');
    _links.add(false);
  }

  @override
  Future<HaloTransportBattery> readBattery() async {
    calls.add('readBattery');
    return const HaloTransportBattery(levelPercent: 80, isCharging: false);
  }

  @override
  Future<String> executeReadOnlyLua(String command) async {
    calls.add('lua');
    return switch (command) {
      'print(frame.get_eui())' => '0011223344556677',
      'print(frame.HARDWARE_VERSION)' => 'halo',
      'print(frame.FIRMWARE_VERSION)' => 'test-firmware',
      'print(frame.battery_level())' => '80',
      'frame.display.clear()print(1)' => '1',
      _ => throw StateError('Unexpected command.'),
    };
  }

  @override
  Future<void> executeDisplayCommand(HaloDisplayCommand command) async {
    calls.add('display');
    displayCommands.add(command);
  }

  @override
  Future<void> sendUserData(Uint8List payload) async => calls.add('userData');

  @override
  Future<void> dispose() async {
    await _discoveries.close();
    await _links.close();
  }
}
