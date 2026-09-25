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
      final _Layout layout = _Layout.parse(result.value);
      return _delivery(
        update,
        CaptionDeliveryStatus.delivered,
        result.truthLabel == TruthLabel.measured
            ? TruthLabel.prepared
            : result.truthLabel,
        // Degraded glyphs are reported, never presented as Unicode support.
        reason: layout.replaced > 0
            ? 'glyphsReplaced'
            : layout.folded > 0
                ? 'glyphsFolded'
                : null,
        layout: layout,
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
    _Layout layout = const _Layout(1, 0, 0),
  }) =>
      CaptionDelivery(
        session: update.session,
        sequence: update.sequence,
        status: status,
        environment: environment,
        truthLabel: truthLabel,
        adapterId: adapterId,
        reason: reason,
        pageCount: layout.pages,
        foldedGlyphs: layout.folded,
        replacedGlyphs: layout.replaced,
      );
}

final class _Layout {
  const _Layout(this.pages, this.folded, this.replaced);

  final int pages;
  final int folded;
  final int replaced;

  static final RegExp _value =
      RegExp(r'^page:\d+/(\d+)(?:;folded:(\d+))?(?:;replaced:(\d+))?$');

  /// Parses `page:<shown>/<total>[;folded:n][;replaced:n]`; any other value
  /// counts as one page without degradation.
  static _Layout parse(String value) {
    final RegExpMatch? match = _value.firstMatch(value);
    if (match == null) return const _Layout(1, 0, 0);
    int count(int group) => int.parse(match.group(group) ?? '0');
    return _Layout(count(1), count(2), count(3));
  }
}
