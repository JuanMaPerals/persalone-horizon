import 'dart:async';
import 'dart:typed_data';

import 'package:persalone_contracts/persalone_contracts.dart';

import 'halo_bounded_display.dart';
import 'halo_caption_composer.dart';
import 'halo_transport.dart';

/// Product-owned Halo adapter. A [ready] state is emitted only after the
/// encapsulated transport has confirmed the required Halo Lua service.
final class HaloDeviceAdapter implements DeviceAdapterPort {
  HaloDeviceAdapter({
    required HaloTransport transport,
    int Function()? nowMicros,
  })  : _transport = transport,
        _nowMicros = nowMicros ?? _defaultNowMicros {
    _discoverySubscription = _transport.discoveries.listen(
      _onTransportDiscovery,
      onError: _onDiscoveryError,
    );
    _linkSubscription = _transport.linkStates.listen(_onLinkState);
  }

  static const String haloFirmwareRevision =
      '78bb15368f78ffe94b1b77b5f592ebe7a3f001a3';
  static const String brilliantSdkRevision =
      '462dff4795cffb85248ab1d2f92d4f319adb03d3';
  static const String _sourceRevision =
      'halo-firmware@78bb15368f78ffe94b1b77b5f592ebe7a3f001a3;'
      'brilliant_sdk@462dff4795cffb85248ab1d2f92d4f319adb03d3';
  static final Stopwatch _clock = Stopwatch()..start();

  final HaloTransport _transport;
  final int Function() _nowMicros;
  final StreamController<DeviceAdapterSnapshot> _snapshots =
      StreamController<DeviceAdapterSnapshot>.broadcast();
  final StreamController<AdapterDiagnostic> _diagnostics =
      StreamController<AdapterDiagnostic>.broadcast();
  final StreamController<DeviceDiscovery> _discoveries =
      StreamController<DeviceDiscovery>.broadcast();
  final Map<String, HaloTransportDiscovery> _available =
      <String, HaloTransportDiscovery>{};

  StreamSubscription<HaloTransportDiscovery>? _discoverySubscription;
  StreamSubscription<bool>? _linkSubscription;
  DeviceDiscovery? _selected;
  DeviceConnectionState _state = DeviceConnectionState.idle;
  int? _maxUserDataPayloadBytes;
  bool _disposed = false;
  bool _displayPoweredOn = false;
  int _linkGeneration = 0;

  @override
  String get adapterId => 'halo-device-adapter';

  /// Execution path of the underlying transport (BLE, emulator or test double).
  ExecutionEnvironment get environment => _transport.environment;

  @override
  String get sourceRevision => _sourceRevision;

  @override
  Stream<DeviceAdapterSnapshot> get snapshots => _snapshots.stream;

  @override
  Stream<AdapterDiagnostic> get diagnostics => _diagnostics.stream;

  @override
  Stream<DeviceDiscovery> get discoveries => _discoveries.stream;

  @override
  Future<void> startDiscovery() async {
    _ensureNotDisposed();
    if (_state == DeviceConnectionState.connecting ||
        _state == DeviceConnectionState.ready) {
      throw const RuntimeError(
        RuntimeErrorCode.deviceNotReady,
        'Discovery is not available during an active Halo session.',
      );
    }
    _transition(DeviceConnectionState.discovering);
    _emitDiagnostic(AdapterDiagnosticCode.scanStarted);
    try {
      await _transport.startDiscovery();
    } catch (error) {
      _fail(
        RuntimeErrorCode.discoveryFailed,
        'Halo discovery could not start.',
        detail: _safeErrorDetail(error),
      );
      rethrow;
    }
  }

  @override
  Future<void> stopDiscovery() async {
    _ensureNotDisposed();
    await _transport.stopDiscovery();
    if (_state == DeviceConnectionState.discovering) {
      _transition(DeviceConnectionState.idle);
    }
  }

  @override
  Future<void> connect(DeviceDiscovery device) async {
    _ensureNotDisposed();
    final HaloTransportDiscovery? selected = _available[device.deviceId];
    if (selected == null) {
      throw const RuntimeError(
        RuntimeErrorCode.deviceNotSelected,
        'The selected Halo discovery is no longer available.',
      );
    }
    _selected = device;
    _transition(DeviceConnectionState.connecting);
    _emitDiagnostic(AdapterDiagnosticCode.connectStarted);
    try {
      final HaloTransportConnection connection =
          await _transport.connect(selected);
      _assertReadyConnection(connection);
      _transition(DeviceConnectionState.ready);
      _emitDiagnostic(AdapterDiagnosticCode.servicesReady);
    } catch (error) {
      _fail(
        RuntimeErrorCode.connectionFailed,
        'Halo connection did not reach a ready state.',
        detail: _safeErrorDetail(error),
      );
      rethrow;
    }
  }

  @override
  Future<void> reconnect() async {
    _ensureNotDisposed();
    final DeviceDiscovery? selected = _selected;
    if (selected == null) {
      throw const RuntimeError(
        RuntimeErrorCode.deviceNotSelected,
        'A previously selected Halo device is required to reconnect.',
      );
    }
    _transition(DeviceConnectionState.connecting);
    _emitDiagnostic(AdapterDiagnosticCode.reconnectScheduled);
    try {
      final HaloTransportConnection connection =
          await _transport.reconnect(selected.deviceId);
      _assertReadyConnection(connection);
      _transition(DeviceConnectionState.ready);
      _emitDiagnostic(AdapterDiagnosticCode.servicesReady);
    } catch (error) {
      _fail(
        RuntimeErrorCode.connectionFailed,
        'Halo reconnect did not reach a ready state.',
        detail: _safeErrorDetail(error),
      );
      _emitDiagnostic(AdapterDiagnosticCode.reconnectFailed);
      rethrow;
    }
  }

  @override
  Future<void> disconnect() async {
    _ensureNotDisposed();
    if (_state == DeviceConnectionState.idle ||
        _state == DeviceConnectionState.disconnected) {
      return;
    }
    _transition(DeviceConnectionState.disconnecting);
    await _transport.disconnect();
    _maxUserDataPayloadBytes = null;
    _transition(DeviceConnectionState.disconnected);
  }

  @override
  Future<CapabilityManifest> capabilityManifest() async {
    _ensureNotDisposed();
    const TruthLabel label = TruthLabel.prepared;
    return const CapabilityManifest(
      schemaVersion: CapabilityManifest.currentSchemaVersion,
      adapterId: 'halo-device-adapter',
      states: <Capability, CapabilityState>{
        Capability.bleConnection: CapabilityState(
          capability: Capability.bleConnection,
          truthLabel: label,
          sourceRevision: _sourceRevision,
          reason:
              'Implementation exists; no physical Halo validation recorded.',
        ),
        Capability.deviceIdentity: CapabilityState(
          capability: Capability.deviceIdentity,
          truthLabel: label,
          sourceRevision: _sourceRevision,
          reason: 'Read-only Lua queries require physical validation.',
        ),
        Capability.batteryStatus: CapabilityState(
          capability: Capability.batteryStatus,
          truthLabel: label,
          sourceRevision: _sourceRevision,
          reason: 'Battery path is not physically validated.',
        ),
        Capability.luaTransport: CapabilityState(
          capability: Capability.luaTransport,
          truthLabel: label,
          sourceRevision: _sourceRevision,
          reason: 'Only an allow-list is exposed; arbitrary Lua is blocked.',
        ),
        Capability.userDataTransport: CapabilityState(
          capability: Capability.userDataTransport,
          truthLabel: label,
          sourceRevision: _sourceRevision,
          reason:
              'Validated framing is prepared; the receiving Halo application still requires physical validation.',
        ),
        Capability.display: CapabilityState(
          capability: Capability.display,
          truthLabel: label,
          sourceRevision: _sourceRevision,
          reason: 'No physical display validation recorded.',
        ),
        Capability.microphoneCapture: CapabilityState(
          capability: Capability.microphoneCapture,
          truthLabel: TruthLabel.blocked,
          sourceRevision: _sourceRevision,
          reason: 'Audio is outside G2.',
        ),
        Capability.speakerPlayback: CapabilityState(
          capability: Capability.speakerPlayback,
          truthLabel: TruthLabel.blocked,
          sourceRevision: _sourceRevision,
          reason: 'Audio is outside G2.',
        ),
        Capability.echoCancellation: CapabilityState(
          capability: Capability.echoCancellation,
          truthLabel: TruthLabel.blocked,
          sourceRevision: _sourceRevision,
          reason: 'AEC is outside G2.',
        ),
        Capability.voiceMode: CapabilityState(
          capability: Capability.voiceMode,
          truthLabel: TruthLabel.blocked,
          sourceRevision: _sourceRevision,
          reason: 'Voice mode is outside G2.',
        ),
      },
    );
  }

  @override
  Future<DeviceIdentity> readIdentity() async {
    _ensureReady();
    try {
      final String rawEui = await _transport.executeReadOnlyLua(
        'print(frame.get_eui())',
      );
      final String hardware = await _transport.executeReadOnlyLua(
        'print(frame.HARDWARE_VERSION)',
      );
      final String firmware = await _transport.executeReadOnlyLua(
        'print(frame.FIRMWARE_VERSION)',
      );
      return DeviceIdentity(
        redactedId: _redact(_lastValue(rawEui)),
        hardwareVersion: _lastValue(hardware),
        firmwareVersion: _lastValue(firmware),
        sourceRevision: _sourceRevision,
        truthLabel: TruthLabel.prepared,
      );
    } catch (error) {
      _fail(
        RuntimeErrorCode.protocolRejected,
        'Halo identity query failed.',
        detail: _safeErrorDetail(error),
      );
      rethrow;
    }
  }

  @override
  Future<BatterySnapshot> readBattery() async {
    _ensureReady();
    try {
      final HaloTransportBattery battery = await _transport.readBattery();
      if (battery.levelPercent < 0 || battery.levelPercent > 100) {
        throw const RuntimeError(
          RuntimeErrorCode.protocolRejected,
          'Halo battery level is outside the allowed range.',
        );
      }
      return BatterySnapshot(
        levelPercent: battery.levelPercent,
        isCharging: battery.isCharging,
        observedAtMicros: _nowMicros(),
        sourceRevision: _sourceRevision,
        truthLabel: TruthLabel.prepared,
      );
    } catch (error) {
      _fail(
        RuntimeErrorCode.protocolRejected,
        'Halo battery query failed.',
        detail: _safeErrorDetail(error),
      );
      rethrow;
    }
  }

  @override
  Future<HaloLuaResult> executeAllowedLua(
    HaloLuaQuery query, {
    String? text,
  }) async {
    _ensureReady();
    if (query == HaloLuaQuery.displayText) {
      return _displayText(text);
    }
    final String command = switch (query) {
      HaloLuaQuery.identity => 'print(frame.HARDWARE_VERSION)',
      HaloLuaQuery.battery => 'print(frame.battery_level())',
      HaloLuaQuery.clearDisplay => 'frame.display.clear()print(1)',
      HaloLuaQuery.displayText => throw StateError('unreachable'),
    };
    if (text != null) {
      throw const RuntimeError(
        RuntimeErrorCode.policyDenied,
        'G2 does not accept caller-supplied Lua text.',
      );
    }
    try {
      final String value = await _transport.executeReadOnlyLua(command);
      return HaloLuaResult(
        query: query,
        value: _lastValue(value),
        sourceRevision: _sourceRevision,
        truthLabel: TruthLabel.prepared,
      );
    } catch (error) {
      _fail(
        RuntimeErrorCode.protocolRejected,
        'Halo allow-listed Lua query failed.',
        detail: _safeErrorDetail(error),
      );
      rethrow;
    }
  }

  /// Shows page [page] (0-based) of [text] as laid out by the caption
  /// composer, through the same bounded command path as
  /// [HaloLuaQuery.displayText]. The result value reports the page actually
  /// shown (`page:<k>/<N>`). Page navigation is driven by the host (e.g. a
  /// button press reported by the device); no Lua is accepted from callers.
  Future<HaloLuaResult> displayTextPage(String text, int page) async {
    _ensureReady();
    return _displayText(text, page: page);
  }

  Future<HaloLuaResult> _displayText(String? text, {int page = 0}) async {
    if (text == null) {
      throw const RuntimeError(
        RuntimeErrorCode.invalidContract,
        'Display text requires caption text.',
      );
    }
    final HaloCaptionComposition composition =
        HaloCaptionComposer.compose(text);
    final int pages = composition.isEmpty ? 1 : composition.pageCount;
    if (page < 0 || page >= pages) {
      throw const RuntimeError(
        RuntimeErrorCode.invalidContract,
        'Caption page is outside the composed pages.',
      );
    }
    final HaloDisplayCommand command = composition.isEmpty
        ? HaloBoundedDisplay.clear
        : composition.command(page, powerOn: !_displayPoweredOn);
    final int generation = _linkGeneration;
    try {
      await _transport.executeDisplayCommand(command);
    } catch (error) {
      // A display failure is reported to the caller without tearing down the
      // device session; caption text never enters the diagnostic detail.
      throw const RuntimeError(
        RuntimeErrorCode.protocolRejected,
        'Halo display command was not acknowledged.',
        retryable: true,
      );
    }
    if (generation != _linkGeneration ||
        _state != DeviceConnectionState.ready) {
      throw const RuntimeError(
        RuntimeErrorCode.deviceNotReady,
        'Halo link changed before the display command completed.',
      );
    }
    if (!composition.isEmpty) _displayPoweredOn = true;
    return HaloLuaResult(
      query: HaloLuaQuery.displayText,
      value: HaloCaptionComposition.resultValue(composition, page: page),
      sourceRevision: _sourceRevision,
      truthLabel: TruthLabel.prepared,
    );
  }

  @override
  Future<void> sendUserData(UserDataMessage message) async {
    _ensureReady();
    final Uint8List messagePayload = message.payload;
    final int? maxPayload = _maxUserDataPayloadBytes;
    if (message.schemaVersion != CapabilityManifest.currentSchemaVersion ||
        message.type < 0 ||
        message.type > 255 ||
        messagePayload.isEmpty ||
        maxPayload == null ||
        messagePayload.length > maxPayload) {
      _emitDiagnostic(AdapterDiagnosticCode.protocolRejected);
      throw const RuntimeError(
        RuntimeErrorCode.invalidContract,
        'USERDATA message schema or type is invalid.',
      );
    }
    final Uint8List payload = Uint8List.fromList(
      <int>[0x01, message.type, ...messagePayload],
    );
    try {
      await _transport.sendUserData(payload);
    } catch (error) {
      _fail(
        RuntimeErrorCode.protocolRejected,
        'Halo USERDATA transport rejected the message.',
        detail: _safeErrorDetail(error),
      );
      rethrow;
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await _discoverySubscription?.cancel();
    await _linkSubscription?.cancel();
    await _transport.dispose();
    await _snapshots.close();
    await _diagnostics.close();
    await _discoveries.close();
  }

  void _onTransportDiscovery(HaloTransportDiscovery discovery) {
    _available[discovery.reconnectId] = discovery;
    final DeviceDiscovery mapped = DeviceDiscovery(
      deviceId: discovery.reconnectId,
      displayName: discovery.displayName,
      rssi: discovery.rssi,
      truthLabel: TruthLabel.prepared,
      discoveredAtMicros: _nowMicros(),
    );
    _discoveries.add(mapped);
    _emitDiagnostic(AdapterDiagnosticCode.scanResult);
  }

  void _onDiscoveryError(Object error, StackTrace stackTrace) {
    _fail(
      RuntimeErrorCode.discoveryFailed,
      'Halo discovery stream failed.',
      detail: _safeErrorDetail(error),
    );
  }

  void _onLinkState(bool connected) {
    if (!connected && _state == DeviceConnectionState.ready) {
      _maxUserDataPayloadBytes = null;
      _transition(DeviceConnectionState.disconnected);
      _emitDiagnostic(AdapterDiagnosticCode.disconnectObserved);
    }
  }

  void _assertReadyConnection(HaloTransportConnection connection) {
    if (!connection.hasLuaService || connection.negotiatedMtu < 23) {
      throw const RuntimeError(
        RuntimeErrorCode.deviceNotReady,
        'Halo did not expose the required encrypted Lua transport.',
      );
    }
    // The packet contains the 0x01 USERDATA marker and one message-type byte.
    // A conservative five-byte ATT/SDK allowance keeps this implementation
    // single-packet until a reviewed application-level reassembly protocol exists.
    _maxUserDataPayloadBytes = connection.negotiatedMtu - 7;
    _emitDiagnostic(AdapterDiagnosticCode.mtuUpdated);
  }

  void _ensureReady() {
    _ensureNotDisposed();
    if (_state != DeviceConnectionState.ready) {
      throw const RuntimeError(
        RuntimeErrorCode.deviceNotReady,
        'Halo must be ready before this operation.',
      );
    }
  }

  void _ensureNotDisposed() {
    if (_disposed) {
      throw const RuntimeError(
        RuntimeErrorCode.sessionClosed,
        'Halo adapter has been disposed.',
      );
    }
  }

  void _transition(
    DeviceConnectionState next, {
    String? failureReason,
  }) {
    if (next != DeviceConnectionState.ready) {
      // Halo boots its display in power-save mode; any link change means the
      // next caption must wake it again, and in-flight results are stale.
      _displayPoweredOn = false;
      _linkGeneration++;
    }
    _state = next;
    _snapshots.add(
      DeviceAdapterSnapshot(
        state: next,
        adapterId: adapterId,
        sourceRevision: _sourceRevision,
        truthLabel: TruthLabel.prepared,
        observedAtMicros: _nowMicros(),
        selectedDevice: _selected,
        failureReason: failureReason,
      ),
    );
  }

  void _fail(
    RuntimeErrorCode code,
    String message, {
    String? detail,
  }) {
    _transition(DeviceConnectionState.failed, failureReason: message);
    _emitDiagnostic(
      code == RuntimeErrorCode.discoveryFailed
          ? AdapterDiagnosticCode.scanFailed
          : AdapterDiagnosticCode.protocolRejected,
      detail: detail,
    );
  }

  void _emitDiagnostic(AdapterDiagnosticCode code, {String? detail}) {
    _diagnostics.add(
      AdapterDiagnostic(
        code: code,
        observedAtMicros: _nowMicros(),
        adapterId: adapterId,
        detail: detail,
      ),
    );
  }

  static int _defaultNowMicros() => _clock.elapsedMicroseconds;

  static String _redact(String value) {
    final String compact = value.replaceAll(RegExp(r'\s+'), '');
    final String suffix =
        compact.length <= 4 ? compact : compact.substring(compact.length - 4);
    return 'halo-••••$suffix';
  }

  static String _lastValue(String value) {
    return value
        .split(RegExp(r'\r?\n'))
        .map((String line) => line.trim())
        .where((String line) => line.isNotEmpty)
        .last;
  }

  static String _safeErrorDetail(Object error) {
    return error.runtimeType.toString();
  }
}
