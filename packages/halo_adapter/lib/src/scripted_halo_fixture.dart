import 'dart:async';

import 'package:persalone_contracts/persalone_contracts.dart';

import 'halo_bounded_display.dart';

/// Deterministic test-only implementation of [DeviceAdapterPort].
///
/// It does not emulate a radio, physical battery, or human-visible display. Its
/// purpose is to exercise the same product contract and failure boundaries that
/// a physical [HaloDeviceAdapter] will use.
final class ScriptedHaloFixture implements DeviceAdapterPort {
  ScriptedHaloFixture({int Function()? nowMicros})
      : _nowMicros = nowMicros ?? _defaultNowMicros;

  /// Last bounded command the fixture would have sent. SIMULATED evidence only.
  HaloDisplayCommand? lastDisplayCommand;

  static const String fixtureRevision = 'scripted-halo-fixture/1';
  static final Stopwatch _clock = Stopwatch()..start();

  final int Function() _nowMicros;
  final StreamController<DeviceAdapterSnapshot> _snapshots =
      StreamController<DeviceAdapterSnapshot>.broadcast();
  final StreamController<AdapterDiagnostic> _diagnostics =
      StreamController<AdapterDiagnostic>.broadcast();
  final StreamController<DeviceDiscovery> _discoveries =
      StreamController<DeviceDiscovery>.broadcast();

  static const DeviceDiscovery _device = DeviceDiscovery(
    deviceId: 'scripted-halo-001',
    displayName: 'Scripted Halo Fixture',
    truthLabel: TruthLabel.simulated,
    discoveredAtMicros: 0,
  );

  DeviceConnectionState _state = DeviceConnectionState.idle;
  bool _disposed = false;

  @override
  String get adapterId => 'scripted-halo-fixture';

  @override
  String get sourceRevision => fixtureRevision;

  @override
  Stream<DeviceAdapterSnapshot> get snapshots => _snapshots.stream;

  @override
  Stream<AdapterDiagnostic> get diagnostics => _diagnostics.stream;

  @override
  Stream<DeviceDiscovery> get discoveries => _discoveries.stream;

  @override
  Future<void> startDiscovery() async {
    _ensureNotDisposed();
    _transition(DeviceConnectionState.discovering);
    _emit(AdapterDiagnosticCode.scanStarted);
    _discoveries.add(
      DeviceDiscovery(
        deviceId: _device.deviceId,
        displayName: _device.displayName,
        truthLabel: TruthLabel.simulated,
        discoveredAtMicros: _nowMicros(),
      ),
    );
    _emit(AdapterDiagnosticCode.scanResult);
  }

  @override
  Future<void> stopDiscovery() async {
    _ensureNotDisposed();
    if (_state == DeviceConnectionState.discovering) {
      _transition(DeviceConnectionState.idle);
    }
  }

  @override
  Future<void> connect(DeviceDiscovery device) async {
    _ensureNotDisposed();
    if (device.deviceId != _device.deviceId ||
        device.truthLabel != TruthLabel.simulated) {
      _transition(
        DeviceConnectionState.failed,
        failureReason: 'Fixture accepts only its deterministic discovery.',
      );
      throw const RuntimeError(
        RuntimeErrorCode.deviceNotSelected,
        'The requested deterministic fixture does not exist.',
      );
    }
    _transition(DeviceConnectionState.connecting);
    _emit(AdapterDiagnosticCode.connectStarted);
    _transition(DeviceConnectionState.ready, selected: device);
    _emit(AdapterDiagnosticCode.servicesReady);
    _emit(AdapterDiagnosticCode.mtuUpdated);
  }

  @override
  Future<void> reconnect() async {
    _ensureNotDisposed();
    _transition(DeviceConnectionState.connecting);
    _emit(AdapterDiagnosticCode.reconnectScheduled);
    _transition(DeviceConnectionState.ready, selected: _device);
    _emit(AdapterDiagnosticCode.servicesReady);
  }

  @override
  Future<void> disconnect() async {
    _ensureNotDisposed();
    _transition(DeviceConnectionState.disconnecting);
    _transition(DeviceConnectionState.disconnected);
    _emit(AdapterDiagnosticCode.disconnectObserved);
  }

  @override
  Future<CapabilityManifest> capabilityManifest() async {
    _ensureNotDisposed();
    return const CapabilityManifest(
      schemaVersion: CapabilityManifest.currentSchemaVersion,
      adapterId: 'scripted-halo-fixture',
      states: <Capability, CapabilityState>{
        Capability.bleConnection: CapabilityState(
          capability: Capability.bleConnection,
          truthLabel: TruthLabel.simulated,
          sourceRevision: fixtureRevision,
          reason: 'Deterministic contract fixture; no physical radio.',
        ),
        Capability.deviceIdentity: CapabilityState(
          capability: Capability.deviceIdentity,
          truthLabel: TruthLabel.simulated,
          sourceRevision: fixtureRevision,
          reason: 'Synthetic identity for contract tests only.',
        ),
        Capability.batteryStatus: CapabilityState(
          capability: Capability.batteryStatus,
          truthLabel: TruthLabel.simulated,
          sourceRevision: fixtureRevision,
          reason: 'Synthetic battery snapshot for contract tests only.',
        ),
        Capability.luaTransport: CapabilityState(
          capability: Capability.luaTransport,
          truthLabel: TruthLabel.simulated,
          sourceRevision: fixtureRevision,
          reason: 'Scripted allow-list response; no Lua runtime.',
        ),
        Capability.userDataTransport: CapabilityState(
          capability: Capability.userDataTransport,
          truthLabel: TruthLabel.simulated,
          sourceRevision: fixtureRevision,
          reason: 'Deterministic payload validation only.',
        ),
        Capability.display: CapabilityState(
          capability: Capability.display,
          truthLabel: TruthLabel.simulated,
          sourceRevision: fixtureRevision,
          reason: 'No physical display is simulated.',
        ),
        Capability.microphoneCapture: CapabilityState(
          capability: Capability.microphoneCapture,
          truthLabel: TruthLabel.blocked,
          sourceRevision: fixtureRevision,
          reason: 'Audio is outside G2.',
        ),
        Capability.speakerPlayback: CapabilityState(
          capability: Capability.speakerPlayback,
          truthLabel: TruthLabel.blocked,
          sourceRevision: fixtureRevision,
          reason: 'Audio is outside G2.',
        ),
        Capability.echoCancellation: CapabilityState(
          capability: Capability.echoCancellation,
          truthLabel: TruthLabel.blocked,
          sourceRevision: fixtureRevision,
          reason: 'AEC is outside G2.',
        ),
        Capability.voiceMode: CapabilityState(
          capability: Capability.voiceMode,
          truthLabel: TruthLabel.blocked,
          sourceRevision: fixtureRevision,
          reason: 'Voice mode is outside G2.',
        ),
      },
    );
  }

  @override
  Future<DeviceIdentity> readIdentity() async {
    _ensureReady();
    return const DeviceIdentity(
      redactedId: 'fixture-••••0001',
      hardwareVersion: 'simulated-halo',
      firmwareVersion: fixtureRevision,
      sourceRevision: fixtureRevision,
      truthLabel: TruthLabel.simulated,
    );
  }

  @override
  Future<BatterySnapshot> readBattery() async {
    _ensureReady();
    return BatterySnapshot(
      levelPercent: 73,
      isCharging: false,
      observedAtMicros: _nowMicros(),
      sourceRevision: fixtureRevision,
      truthLabel: TruthLabel.simulated,
    );
  }

  @override
  Future<HaloLuaResult> executeAllowedLua(
    HaloLuaQuery query, {
    String? text,
  }) async {
    _ensureReady();
    if (query == HaloLuaQuery.displayText) {
      if (text == null) {
        throw const RuntimeError(
          RuntimeErrorCode.invalidContract,
          'Display text requires caption text.',
        );
      }
      // Same bounded builder as the physical path; the result stays SIMULATED.
      lastDisplayCommand = HaloBoundedDisplay.text(
        text,
        powerOn: lastDisplayCommand == null,
      );
      return HaloLuaResult(
        query: query,
        value: '1',
        sourceRevision: fixtureRevision,
        truthLabel: TruthLabel.simulated,
      );
    }
    if (text != null) {
      throw const RuntimeError(
        RuntimeErrorCode.policyDenied,
        'The fixture does not accept caller-supplied Lua text.',
      );
    }
    final String value = switch (query) {
      HaloLuaQuery.identity => 'simulated-halo',
      HaloLuaQuery.battery => '73',
      HaloLuaQuery.clearDisplay => '1',
      HaloLuaQuery.displayText => throw StateError('unreachable'),
    };
    return HaloLuaResult(
      query: query,
      value: value,
      sourceRevision: fixtureRevision,
      truthLabel: TruthLabel.simulated,
    );
  }

  @override
  Future<void> sendUserData(UserDataMessage message) async {
    _ensureReady();
    if (message.schemaVersion != CapabilityManifest.currentSchemaVersion ||
        message.type < 0 ||
        message.type > 255 ||
        message.payload.isEmpty) {
      _emit(AdapterDiagnosticCode.protocolRejected);
      throw const RuntimeError(
        RuntimeErrorCode.invalidContract,
        'Fixture rejected malformed USERDATA.',
      );
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await _snapshots.close();
    await _diagnostics.close();
    await _discoveries.close();
  }

  void _ensureNotDisposed() {
    if (_disposed) {
      throw const RuntimeError(
        RuntimeErrorCode.sessionClosed,
        'Scripted Halo fixture has been disposed.',
      );
    }
  }

  void _ensureReady() {
    _ensureNotDisposed();
    if (_state != DeviceConnectionState.ready) {
      throw const RuntimeError(
        RuntimeErrorCode.deviceNotReady,
        'Scripted Halo fixture must be ready before this operation.',
      );
    }
  }

  void _transition(
    DeviceConnectionState next, {
    DeviceDiscovery? selected,
    String? failureReason,
  }) {
    _state = next;
    _snapshots.add(
      DeviceAdapterSnapshot(
        state: next,
        adapterId: adapterId,
        sourceRevision: fixtureRevision,
        truthLabel: TruthLabel.simulated,
        observedAtMicros: _nowMicros(),
        selectedDevice: selected,
        failureReason: failureReason,
      ),
    );
  }

  void _emit(AdapterDiagnosticCode code) {
    _diagnostics.add(
      AdapterDiagnostic(
        code: code,
        observedAtMicros: _nowMicros(),
        adapterId: adapterId,
      ),
    );
  }

  static int _defaultNowMicros() => _clock.elapsedMicroseconds;
}
