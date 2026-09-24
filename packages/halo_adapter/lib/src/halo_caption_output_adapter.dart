import 'package:persalone_contracts/persalone_contracts.dart';

import 'halo_device_adapter.dart';

/// Routes runtime captions to a Halo device port through the existing
/// allow-listed [HaloLuaQuery.displayText] query; it adds no Lua of its own.
///
/// A [HaloDeviceAdapter] reports the environment declared by its transport, so
/// an emulator-backed adapter is EMULATED, never HALO_REAL. Any other port
/// (fixture, fake) is reported as [ExecutionEnvironment.simulated].
/// A command acknowledgement is capped at [TruthLabel.prepared]: it proves the
/// device accepted the command, not that a person saw the caption.
final class HaloCaptionOutputAdapter implements CaptionOutputAdapter {
  HaloCaptionOutputAdapter(this._device)
      : environment = switch (_device) {
          final HaloDeviceAdapter device => device.environment,
          _ => ExecutionEnvironment.simulated,
        };

  final DeviceAdapterPort _device;

  @override
  final ExecutionEnvironment environment;

  @override
  String get adapterId => 'halo-caption:${_device.adapterId}';

  @override
  Future<CaptionDelivery> show(CaptionUpdate update) async {
    try {
      final result = await _device.executeAllowedLua(
        HaloLuaQuery.displayText,
        text: update.text,
      );
      return _delivery(
        update,
        CaptionDeliveryStatus.delivered,
        result.truthLabel == TruthLabel.measured
            ? TruthLabel.prepared
            : result.truthLabel,
        pageCount: _pageCount(result.value),
      );
    } on RuntimeError catch (error) {
      final refused = error.code == RuntimeErrorCode.capabilityUnavailable ||
          error.code == RuntimeErrorCode.policyDenied;
      return _delivery(
        update,
        refused ? CaptionDeliveryStatus.blocked : CaptionDeliveryStatus.failed,
        refused ? TruthLabel.blocked : TruthLabel.failed,
        reason: error.code.name,
      );
    }
  }

  @override
  Future<void> clear(TranslationSession session) async {
    await _device.executeAllowedLua(HaloLuaQuery.clearDisplay);
  }

  CaptionDelivery _delivery(
    CaptionUpdate update,
    CaptionDeliveryStatus status,
    TruthLabel truthLabel, {
    String? reason,
    int pageCount = 1,
  }) =>
      CaptionDelivery(
        session: update.session,
        sequence: update.sequence,
        status: status,
        environment: environment,
        truthLabel: truthLabel,
        adapterId: adapterId,
        reason: reason,
        pageCount: pageCount,
      );

  static final RegExp _pages = RegExp(r'^page:\d+/(\d+)$');

  /// Parses `page:<shown>/<total>`; any other value counts as one page.
  static int _pageCount(String value) {
    final RegExpMatch? match = _pages.firstMatch(value);
    return match == null ? 1 : int.parse(match.group(1)!);
  }
}
