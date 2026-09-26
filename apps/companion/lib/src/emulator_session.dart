import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:persalone_contracts/persalone_contracts.dart';
import 'package:persalone_halo_core/persalone_halo_core.dart';
import 'package:persalone_halo_emulator/persalone_halo_emulator.dart';

import 'api_error.dart';
import 'metrics.dart';

/// Where the official emulator and its bridge are. Missing pieces make every
/// run BLOCKED with a concrete reason; nothing falls back to a fake display.
final class EmulatorConfig {
  const EmulatorConfig({this.python, this.bridgeScript, this.afterButtonReport});

  final String? python;
  final String? bridgeScript;

  /// Deterministic fault-injection barrier used by concurrency tests. It runs
  /// after the emulated device has reported a button press but before the
  /// session applies any page-advance effect. Production callers leave null.
  final Future<void> Function()? afterButtonReport;

  String? get blockedReason {
    if (python == null) return 'pythonNotConfigured';
    if (bridgeScript == null) return 'bridgeNotConfigured';
    return null;
  }
}

/// One app session on one official-emulator instance (target EMULATED).
///
/// The Halo device adapter owns the link; captions go through
/// [HaloDeviceAdapter.displayTextPage] (composer + bounded commands). The
/// button reporter is the bridge's constant EMULATED-only operation: presses
/// are reported by the device over Bluetooth, and only then does the host move
/// to the next page.
final class EmulatorSession {
  EmulatorSession._(this._transport, this._device, this.caption, this.advanceOn,
      this.pageCount, this._afterButtonReport);

  final EmulatorHaloTransport _transport;
  final HaloDeviceAdapter _device;
  final String caption;
  final String advanceOn;
  final int pageCount;
  final Future<void> Function()? _afterButtonReport;
  int page = 0;
  bool _closed = false;
  StreamSubscription<DeviceAdapterSnapshot>? _snapshots;

  /// Result value of the last page shown (`page:k/N[;folded:n][;replaced:n]`).
  String? lastShown;

  final MetricSeries displayAck = MetricSeries('display.command_ack',
      stage: 'host->emulator display command acknowledged',
      method: 'Stopwatch around HaloDeviceAdapter.displayTextPage');
  final MetricSeries buttonReport = MetricSeries('button.device_report',
      stage: 'button injected -> device Bluetooth report received',
      method: 'Stopwatch around the bridge button operation');
  final MetricSeries pageAdvance = MetricSeries('button.page_advance',
      stage: 'button injected -> next page acknowledged',
      method: 'Stopwatch from injection to display acknowledgement');
  final MetricSeries framebufferRead = MetricSeries('framebuffer.read',
      stage: 'framebuffer request -> PNG received',
      method: 'Stopwatch around the bridge frame operation');

  String get emulatorVersion => _transport.emulatorVersion;

  static Future<EmulatorSession> open(
    EmulatorConfig config, {
    required String caption,
    required String advanceOn,
    void Function(DeviceAdapterSnapshot snapshot)? onDeviceSnapshot,
  }) async {
    final String? blocked = config.blockedReason;
    if (blocked != null) {
      throw ApiError(409, 'emulatorBlocked', <String, Object>{'reason': blocked});
    }
    final int pageCount = HaloCaptionComposer.compose(caption).pageCount;
    final EmulatorHaloTransport transport = EmulatorHaloTransport(
        python: config.python!, bridgeScript: config.bridgeScript!);
    final HaloDeviceAdapter device = HaloDeviceAdapter(transport: transport);
    // Subscribed before connecting so connecting/ready are not missed.
    final StreamSubscription<DeviceAdapterSnapshot>? snapshots =
        onDeviceSnapshot == null ? null : device.snapshots.listen(onDeviceSnapshot);
    try {
      final Future<DeviceDiscovery> discovered = device.discoveries.first;
      await device.startDiscovery();
      await device.connect(await discovered.timeout(const Duration(seconds: 5)));
      await transport.armButtonReporter();
    } on Object {
      await device.dispose();
      await transport.dispose();
      await snapshots?.cancel();
      throw const ApiError(409, 'emulatorBlocked',
          <String, Object>{'reason': 'emulatorStartFailed'});
    }
    final EmulatorSession session = EmulatorSession._(
        transport, device, caption, advanceOn, pageCount, config.afterButtonReport)
      .._snapshots = snapshots;
    await session.showPage(0);
    return session;
  }

  ExecutionEnvironment get environment => _device.environment;

  Future<String> showPage(int index) async {
    _ensureOpen();
    final Stopwatch w = Stopwatch()..start();
    final HaloLuaResult r = await _device.displayTextPage(caption, index);
    displayAck.add(w.elapsed);
    page = index;
    lastShown = r.value;
    return r.value;
  }

  /// Presses [gesture]; if the device reports the configured gesture the next
  /// page is shown (wrapping to the first).
  Future<ButtonOutcome> press(String gesture, {bool Function()? isCurrent}) async {
    _ensureOpen();
    final HaloButtonPress press = HaloButtonPress.values
        .firstWhere((HaloButtonPress p) => p.wire == gesture,
            orElse: () => throw const ApiError(422, 'buttonGestureInvalid'));
    final Stopwatch w = Stopwatch()..start();
    final List<String> reported = await _transport.pressButton(press);
    buttonReport.add(w.elapsed);
    await _afterButtonReport?.call();
    if (isCurrent != null && !isCurrent()) {
      throw const ApiError(409, 'runNotActive');
    }
    final bool advance = reported.contains('btn:$advanceOn');
    String? shown;
    if (advance) {
      shown = await showPage((page + 1) % pageCount);
      pageAdvance.add(w.elapsed);
    }
    return ButtonOutcome(reported, advance, page, pageCount, shown);
  }

  Future<FrameCapture> frame() async {
    _ensureOpen();
    final Stopwatch w = Stopwatch()..start();
    final EmulatorFrame f = await _transport.frame(withPng: true);
    framebufferRead.add(w.elapsed);
    final Uint8List png = f.png!;
    return FrameCapture(png, sha256.convert(png).toString(), f.sha256, f.lit,
        f.outside, f.bbox, f.suspended);
  }

  List<Map<String, Object?>> metrics() => <Map<String, Object?>>[
        displayAck.toJson(),
        buttonReport.toJson(),
        pageAdvance.toJson(),
        framebufferRead.toJson(),
      ];

  /// Clears the display (best effort) and releases the emulator process.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _device.executeAllowedLua(HaloLuaQuery.clearDisplay);
    } on Object {
      // The emulator may already be gone; closing still releases it.
    }
    await _device.dispose();
    await _transport.dispose();
    await _snapshots?.cancel();
  }

  /// Clears the display and reports the resulting frame (for the stop test).
  Future<FrameCapture> clearAndCapture() async {
    _ensureOpen();
    await _device.executeAllowedLua(HaloLuaQuery.clearDisplay);
    return frame();
  }

  void _ensureOpen() {
    if (_closed) throw const ApiError(409, 'runNotActive');
  }
}

final class ButtonOutcome {
  const ButtonOutcome(
      this.deviceReports, this.advanced, this.page, this.pageCount, this.result);

  final List<String> deviceReports;
  final bool advanced;
  final int page;
  final int pageCount;
  final String? result;

  Map<String, Object?> toJson() => <String, Object?>{
        'deviceReports': deviceReports,
        'advanced': advanced,
        'page': page + 1,
        'pageCount': pageCount,
      };
}

final class FrameCapture {
  const FrameCapture(this.png, this.pngSha256, this.pixelSha256, this.lit,
      this.outside, this.bbox, this.suspended);

  final Uint8List png;
  final String pngSha256;
  final String pixelSha256;
  final int lit;
  final int outside;
  final List<int>? bbox;
  final bool suspended;

  Map<String, Object?> summary() => <String, Object?>{
        'pngSha256': pngSha256,
        'pixelSha256': pixelSha256,
        'lit': lit,
        'outside': outside,
        'bbox': bbox,
        'suspended': suspended,
      };
}
