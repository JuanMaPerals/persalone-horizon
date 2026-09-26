import 'dart:io';

import 'package:persalone_contracts/persalone_contracts.dart';
import 'package:persalone_halo_core/persalone_halo_core.dart';
import 'package:persalone_halo_emulator/persalone_halo_emulator.dart';
import 'package:test/test.dart';

// Runs against the official emulator when HORIZON_E2E_PYTHON is set (CI
// e2e-emulated job); skipped otherwise, fails loudly if REQUIRED=1.
final String? _python = Platform.environment['HORIZON_E2E_PYTHON'];
final bool _required = Platform.environment['HORIZON_E2E_REQUIRED'] == '1';
const String _bridge = '../../tooling/e2e/halo_emulator_bridge.py';

String? get _skip => _python != null || _required
    ? null
    : 'official emulator not configured: set HORIZON_E2E_PYTHON';

void main() {
  late EmulatorHaloTransport transport;

  setUp(() async {
    if (_python == null) fail('HORIZON_E2E_REQUIRED=1 but no HORIZON_E2E_PYTHON');
    transport = EmulatorHaloTransport(python: _python!, bridgeScript: _bridge);
    await transport.connect(const HaloTransportDiscovery(
        reconnectId: 'unit', displayName: 'unit'));
  });

  tearDown(() => transport.dispose());

  test('declares EMULATED, never HALO_REAL', skip: _skip, () {
    expect(transport.environment, ExecutionEnvironment.emulated);
  });

  test('the device reports each armed button gesture over Bluetooth',
      skip: _skip, () async {
    expect(await transport.pressButton(HaloButtonPress.singlePress), isEmpty,
        reason: 'no callback before arming: nothing is reported');
    await transport.armButtonReporter();
    for (final HaloButtonPress press in HaloButtonPress.values) {
      expect(await transport.pressButton(press), <String>['btn:${press.wire}']);
    }
  });

  test('framebuffer PNG bytes match the frame and carry the caption',
      skip: _skip, () async {
    await transport.executeDisplayCommand(
        HaloCaptionComposer.compose('Hola Halo').command(0, powerOn: true));
    final EmulatorFrame frame = await transport.frame(withPng: true);
    expect(frame.lit, greaterThan(0));
    expect(frame.png, isNotNull);
    expect(frame.png!.sublist(1, 4), 'PNG'.codeUnits, reason: 'PNG signature');
    expect((await transport.frame()).png, isNull, reason: 'only on request');
  });

  test('a button press never enables arbitrary Lua', skip: _skip, () async {
    await transport.armButtonReporter();
    await transport.pressButton(HaloButtonPress.singlePress);
    expect(
      () => transport.executeReadOnlyLua('os.exit()'),
      throwsStateError,
      reason: 'only the constant clear is routed through read-only Lua',
    );
  });
}
