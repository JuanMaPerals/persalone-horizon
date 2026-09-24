import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:persalone_contracts/persalone_contracts.dart';
import 'package:persalone_halo_adapter/persalone_halo_adapter.dart';

import 'emulator_halo_transport.dart';

// CAPTION_COMPOSER_E2E_EMULATED: translated text -> HaloCaptionComposer ->
// bounded page Lua -> official halo-emulator framebuffer. Page 1 goes through
// the real HaloDeviceAdapter displayText path; later pages are sent as the
// composer's own commands because on-device page navigation is not wired.
final String? _python = Platform.environment['HORIZON_E2E_PYTHON'];
final bool _required = Platform.environment['HORIZON_E2E_REQUIRED'] == '1';
final String? _artifacts = Platform.environment['HORIZON_E2E_ARTIFACTS'];
const String _bridge = '../../tooling/e2e/halo_emulator_bridge.py';

String? get _skip => _python != null || _required
    ? null
    : 'CAPTION_COMPOSER_E2E not configured: set HORIZON_E2E_PYTHON';

const Map<String, String> _cases = <String, String>{
  'short': 'Hello world',
  'two_lines': 'The quick brown fox jumps over the lazy dog',
  'max_safe':
      'abc abc abc abc abc abc abc abc abc abc abc abc abc abc abc abc abc abc abc abc abc',
  'long_word': 'Pneumonoultramicroscopicsilicovolcanoconiosis is long',
  'unicode': 'Español ¿qué tal? Größe 中文 €5',
  'page2':
      'This caption is deliberately long so that it cannot fit on a single page '
          'of the round display and must continue on a second ordered page',
  'adversarial':
      '")os.execute("rm -rf /")-- local d=os d.exit() \\")print(2)--',
};

void main() {
  late EmulatorHaloTransport transport;
  late HaloDeviceAdapter device;

  setUp(() async {
    if (_python == null) {
      fail('HORIZON_E2E_REQUIRED=1 but HORIZON_E2E_PYTHON unset');
    }
    transport = EmulatorHaloTransport(python: _python!, bridgeScript: _bridge);
    device = HaloDeviceAdapter(transport: transport);
    final Future<DeviceDiscovery> discovered = device.discoveries.first;
    await device.startDiscovery();
    await device.connect(await discovered);
  });

  tearDown(() async {
    await device.dispose();
    await transport.dispose();
  });

  for (final MapEntry<String, String> entry in _cases.entries) {
    test('${entry.key}: every page is drawn inside the circle, nothing lost',
        skip: _skip, () async {
      final HaloCaptionComposition composition =
          HaloCaptionComposer.compose(entry.value);
      expect(composition.reconstructed, composition.normalisedText);

      final HaloLuaResult result = await device
          .executeAllowedLua(HaloLuaQuery.displayText, text: entry.value);
      expect(result.value, 'page:1/${composition.pageCount}');
      await _checkFrame(transport, '${entry.key}_p1', composition.pages[0]);

      for (int page = 1; page < composition.pageCount; page++) {
        await transport
            .executeDisplayCommand(composition.command(page, powerOn: false));
        await _checkFrame(
            transport, '${entry.key}_p${page + 1}', composition.pages[page]);
      }
      if (entry.key == 'page2') expect(composition.pageCount, 2);
      if (entry.key == 'unicode') {
        expect(composition.foldedChars, greaterThan(0));
        expect(composition.unrenderableChars, 2);
      }
    });
  }

  test('a new caption leaves nothing of the previous page behind', skip: _skip,
      () async {
    await device.executeAllowedLua(HaloLuaQuery.displayText,
        text: _cases['page2']);
    await device.executeAllowedLua(HaloLuaQuery.displayText, text: 'Hi');
    final EmulatorFrame after = await transport.frame();

    final EmulatorHaloTransport reference =
        EmulatorHaloTransport(python: _python!, bridgeScript: _bridge);
    await reference.connect(const HaloTransportDiscovery(
        reconnectId: 'reference', displayName: 'reference'));
    await reference.executeDisplayCommand(
        HaloCaptionComposer.compose('Hi').command(0, powerOn: true));
    final EmulatorFrame expected = await reference.frame();
    await reference.dispose();
    expect(after.sha256, expected.sha256);
  });
}

Future<void> _checkFrame(EmulatorHaloTransport transport, String name,
    List<HaloTextLine> lines) async {
  String? png;
  final String? dir = _artifacts;
  if (dir != null) {
    Directory(dir).createSync(recursive: true);
    png = '$dir/composer_$name.png';
  }
  final EmulatorFrame frame = await transport.frame(png: png);
  expect(frame.lit, greaterThan(0), reason: name);
  expect(frame.outside, 0, reason: '$name: pixels outside the visible circle');
  final List<int> box = frame.bbox!;
  expect(box[0], greaterThan(0), reason: '$name: touches left edge');
  expect(box[2], lessThan(255), reason: '$name: touches right edge');
  expect(box[1], greaterThanOrEqualTo(lines.first.y - 1), reason: name);
  expect(box[3], lessThanOrEqualTo(lines.last.y + 8), reason: name);
}
