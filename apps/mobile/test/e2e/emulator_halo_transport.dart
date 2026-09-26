import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:persalone_contracts/persalone_contracts.dart';
import 'package:persalone_halo_adapter/persalone_halo_adapter.dart';

/// Test-only [HaloTransport] that replaces the BLE link with the official
/// halo-emulator (via tooling/e2e/halo_emulator_bridge.py). It accepts exactly
/// what the official transport accepts for display and declares EMULATED.
final class EmulatorHaloTransport implements HaloTransport {
  EmulatorHaloTransport({required this.python, required this.bridgeScript});

  static const Duration ackTimeout = Duration(seconds: 2);

  final String python;
  final String bridgeScript;
  final List<String> sentDisplayCommands = <String>[];
  int bridgeStarts = 0;

  /// PIDs of every bridge process started, to prove none is left behind.
  final List<int> bridgePids = <int>[];

  final StreamController<HaloTransportDiscovery> _discoveries =
      StreamController<HaloTransportDiscovery>.broadcast();
  final StreamController<bool> _links = StreamController<bool>.broadcast();
  _Bridge? _bridge;

  @override
  ExecutionEnvironment get environment => ExecutionEnvironment.emulated;

  @override
  Stream<HaloTransportDiscovery> get discoveries => _discoveries.stream;

  @override
  Stream<bool> get linkStates => _links.stream;

  @override
  Future<void> startDiscovery() async {
    _discoveries.add(const HaloTransportDiscovery(
      reconnectId: 'halo-emulator',
      displayName: 'halo-emulator (EMULATED)',
    ));
  }

  @override
  Future<void> stopDiscovery() async {}

  @override
  Future<HaloTransportConnection> connect(
      HaloTransportDiscovery discovery) async {
    await _bridge?.kill();
    _bridge = await _Bridge.start(python, bridgeScript);
    bridgeStarts++;
    bridgePids.add(_bridge!.pid);
    _links.add(true);
    return const HaloTransportConnection(
      reconnectId: 'halo-emulator',
      negotiatedMtu: 247,
      hasLuaService: true,
      hasAudioOutput: false,
    );
  }

  @override
  Future<HaloTransportConnection> reconnect(String reconnectId) => connect(
        HaloTransportDiscovery(
            reconnectId: reconnectId, displayName: 'halo-emulator'),
      );

  @override
  Future<void> disconnect() async {
    await _bridge?.kill();
    _bridge = null;
    _links.add(false);
  }

  /// Fault injection for cleanup tests: the next clears fail as a display
  /// that rejects the command would.
  bool failClear = false;
  int clears = 0;

  @override
  Future<String> executeReadOnlyLua(String command) async {
    if (command != HaloBoundedDisplay.clear.lua) {
      throw StateError('Only the constant clear is routed to the emulator.');
    }
    if (failClear) {
      throw StateError('simulated display clear failure');
    }
    clears++;
    final List<String> prints = await _exec(command);
    return prints.join('\n');
  }

  @override
  Future<void> executeDisplayCommand(HaloDisplayCommand command) async {
    if (!HaloBoundedDisplay.isAcceptable(command.lua)) {
      throw StateError('Display command is outside the bounded grammar.');
    }
    final List<String> prints = await _exec(command.lua);
    if (prints.isEmpty || prints.last != '1') {
      throw StateError('Emulator did not acknowledge the display command.');
    }
    sentDisplayCommands.add(command.lua);
  }

  @override
  Future<HaloTransportBattery> readBattery() =>
      throw UnsupportedError('Battery is not part of the E2E caption path.');

  @override
  Future<void> sendUserData(Uint8List payload) =>
      throw UnsupportedError('USERDATA is not part of the E2E caption path.');

  @override
  Future<void> dispose() async {
    await _bridge?.kill();
    await _discoveries.close();
    await _links.close();
  }

  /// Simulates an emulator crash: the process dies without a disconnect.
  Future<void> crash() async => _bridge?.kill();

  Future<EmulatorFrame> frame({String? png}) async {
    final Map<String, Object?> reply = await _requireBridge()
        .request(<String, Object?>{'op': 'frame', 'png': png});
    return EmulatorFrame(
      lit: reply['lit']! as int,
      upper: reply['upper']! as int,
      lower: reply['lower']! as int,
      sha256: reply['sha256']! as String,
      suspended: reply['suspended']! as bool,
      outside: reply['outside']! as int,
      bbox: (reply['bbox'] as List<Object?>?)?.cast<int>(),
    );
  }

  Future<bool> globalIsNil(String name) async {
    final Map<String, Object?> reply = await _requireBridge()
        .request(<String, Object?>{'op': 'global_is_nil', 'name': name});
    return reply['value']! as bool;
  }

  String get emulatorVersion => _requireBridge().version;

  Future<List<String>> _exec(String lua) async {
    final Map<String, Object?> reply = await _requireBridge().request(
        <String, Object?>{'op': 'exec', 'lua': lua},
        timeout: ackTimeout);
    return (reply['prints']! as List<Object?>).cast<String>();
  }

  _Bridge _requireBridge() {
    final _Bridge? bridge = _bridge;
    if (bridge == null || bridge.exited) {
      throw StateError('halo-emulator is not running.');
    }
    return bridge;
  }
}

final class EmulatorFrame {
  const EmulatorFrame({
    required this.lit,
    required this.upper,
    required this.lower,
    required this.sha256,
    required this.suspended,
    this.outside = 0,
    this.bbox,
  });

  final int lit;
  final int upper;
  final int lower;
  final String sha256;
  final bool suspended;

  /// Lit pixels outside the visible 256 px circle (clipped on hardware).
  final int outside;

  /// [x0, y0, x1, y1] of lit pixels, or null for a black frame.
  final List<int>? bbox;
}

final class _Bridge {
  _Bridge._(this._process, this.version);

  final Process _process;
  final String version;

  int get pid => _process.pid;
  final Queue<Completer<Map<String, Object?>>> _pending =
      Queue<Completer<Map<String, Object?>>>();
  bool exited = false;

  static Future<_Bridge> start(String python, String script) async {
    final Directory sandbox =
        Directory.systemTemp.createTempSync('halo_emu_bridge_');
    final Process process =
        await Process.start(python, <String>[script, sandbox.path]);
    // The bridge may be SIGKILLed; the sandbox is removed by its owner here.
    unawaited(process.exitCode.then((_) {
      if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
    }));
    final Completer<_Bridge> ready = Completer<_Bridge>();
    _Bridge? bridge;
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((String line) {
      final Map<String, Object?> message =
          (jsonDecode(line) as Map<Object?, Object?>).cast<String, Object?>();
      if (bridge == null) {
        bridge = _Bridge._(process, message['version']! as String);
        ready.complete(bridge);
      } else if (bridge!._pending.isNotEmpty) {
        bridge!._pending.removeFirst().complete(message);
      }
    });
    unawaited(process.stderr.drain<void>());
    unawaited(process.exitCode.then((_) {
      final _Bridge? current = bridge;
      if (current == null) {
        if (!ready.isCompleted) {
          ready.completeError(StateError('halo-emulator exited on start.'));
        }
        return;
      }
      current.exited = true;
      while (current._pending.isNotEmpty) {
        current._pending
            .removeFirst()
            .completeError(StateError('halo-emulator exited.'));
      }
    }));
    return ready.future.timeout(const Duration(seconds: 20));
  }

  Future<Map<String, Object?>> request(
    Map<String, Object?> body, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (exited) {
      throw StateError('halo-emulator exited.');
    }
    final Completer<Map<String, Object?>> reply =
        Completer<Map<String, Object?>>();
    _pending.add(reply);
    _process.stdin.writeln(jsonEncode(body));
    final Map<String, Object?> message = await reply.future.timeout(timeout);
    if (message['ok'] != true) {
      throw StateError('halo-emulator error: ${message['error']}');
    }
    return message;
  }

  Future<void> kill() async {
    if (exited) {
      return;
    }
    _process.kill(ProcessSignal.sigkill);
    await _process.exitCode;
    // Let the exit handler remove the sandbox before callers inspect disk.
    await Future<void>.delayed(Duration.zero);
    exited = true;
  }
}
