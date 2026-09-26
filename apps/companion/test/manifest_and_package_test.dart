import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:persalone_horizon_companion/horizon_companion.dart';
import 'package:test/test.dart';

Map<String, Object?> _valid() =>
    HorizonAppManifest.helloDisplay(appId: 'local.hello-display.test', name: 'Hello')
        .toJson();

Matcher _apiError(String code) =>
    throwsA(isA<ApiError>().having((ApiError e) => e.code, 'code', code));

void main() {
  group('HorizonAppManifest v1', () {
    test('the hello-display template is valid and round-trips', () {
      final HorizonAppManifest m = HorizonAppManifest.parse(_valid());
      expect(m.caption, 'Hello Halo');
      expect(m.advanceOn, 'single');
      expect(HorizonAppManifest.parse(jsonDecode(jsonEncode(m.toJson()))).digest, m.digest);
    });

    test('digest is canonical (key order does not matter)', () {
      final Map<String, Object?> json = _valid();
      final Map<String, Object?> reversed = Map<String, Object?>.fromEntries(
          json.entries.toList().reversed);
      expect(HorizonAppManifest.parse(reversed).digest,
          HorizonAppManifest.parse(json).digest);
    });

    test('unknown or missing fields are refused', () {
      expect(() => HorizonAppManifest.parse(<String, Object?>{..._valid(), 'x': 1}),
          _apiError('manifestUnknownField'));
      expect(() => HorizonAppManifest.parse(Map<String, Object?>.from(_valid())..remove('tests')),
          _apiError('manifestMissingField'));
      expect(() => HorizonAppManifest.parse('not an object'), _apiError('manifestInvalidField'));
    });

    test('no host code and no device Lua in V1', () {
      for (final Map<String, Object?> entry in <Map<String, Object?>>[
        <String, Object?>{'host': 'main.js', 'deviceLua': null},
        <String, Object?>{'host': null, 'deviceLua': 'main.lua'},
      ]) {
        expect(() => HorizonAppManifest.parse(<String, Object?>{..._valid(), 'entrypoints': entry}),
            _apiError('codeEntrypointsNotSupported'));
      }
    });

    test('HALO_REAL and unsupported required capabilities are refused', () {
      expect(
          () => HorizonAppManifest.parse(<String, Object?>{
                ..._valid(),
                'deviceTargets': <String>['HALO_REAL'],
              }),
          _apiError('targetNotAvailable'));
      expect(
          () => HorizonAppManifest.parse(<String, Object?>{
                ..._valid(),
                'capabilities': <String, Object?>{
                  'required': <String>['DISPLAY', 'BUTTON', 'MICROPHONE'],
                  'optional': <String>[],
                },
              }),
          _apiError('capabilityNotSupportedInV1'));
      expect(
          () => HorizonAppManifest.parse(<String, Object?>{
                ..._valid(),
                'capabilities': <String, Object?>{
                  'required': <String>['DISPLAY', 'BUTTON'],
                  'optional': <String>['TELEPORT'],
                },
              }),
          _apiError('capabilityUnknown'));
    });

    test('caption is data: special characters are kept as text, limits enforced', () {
      final HorizonAppManifest base = HorizonAppManifest.parse(_valid());
      for (final String payload in <String>[
        '")os.execute("x")--',
        'frame.display.clear()',
        "]]..'\\\"",
        'Año 中文 €',
      ]) {
        expect(base.withContent(caption: payload).caption, payload);
      }
      expect(() => base.withContent(caption: '   '), _apiError('captionEmpty'));
      expect(() => base.withContent(caption: 'a' * 401), _apiError('captionRejected'));
      expect(() => base.withContent(caption: 'a\uD800'), _apiError('captionRejected'));
      expect(() => base.withContent(advanceOn: 'triple'), _apiError('manifestInvalidField'));
    });

    test('preview reports pages and the glyph limit, never hides loss', () {
      final HorizonAppManifest m = HorizonAppManifest.parse(_valid())
          .withContent(caption: 'Año 中文 ok');
      final Map<String, Object?> p = m.preview();
      expect(p['foldedGlyphs'], 1);
      expect(p['replacedGlyphs'], 2);
      expect(p['noLoss'], isTrue);
      expect(p['pageCount'], 1);
    });
  });

  group('.horizonapp package', () {
    final HorizonAppManifest m =
        HorizonAppManifest.parse(_valid()).withContent(caption: 'Hola Halo');

    test('is byte-for-byte reproducible', () {
      final HorizonAppPackage a = HorizonAppPackage.build(m);
      final HorizonAppPackage b = HorizonAppPackage.build(m);
      expect(a.sha256Hex, b.sha256Hex);
      expect(a.bytes, b.bytes);
      expect(HorizonAppPackage.build(m.withContent(caption: 'Otra')).sha256Hex,
          isNot(a.sha256Hex));
    });

    test('is a valid ustar archive whose checksums match every entry', () {
      final Map<String, Object?> result = <String, Object?>{
        'runId': 't-0123456789ab',
        'outcome': 'PASS',
      };
      final HorizonAppPackage pkg = HorizonAppPackage.build(m,
          latestResult: result,
          resultArtifacts: <String, Uint8List>{'page-1.png': Uint8List.fromList(<int>[1, 2, 3])});
      final Map<String, Uint8List> files = _untar(pkg.bytes);
      expect(files.keys, pkg.entries);
      expect(files.keys, containsAll(<String>[
        'manifest.json', 'validation.json', 'provenance.json',
        'tests/hello-display.default.json', 'results/t-0123456789ab/result.json',
        'results/t-0123456789ab/page-1.png', 'CHECKSUMS.sha256',
      ]));
      final List<String> lines =
          utf8.decode(files['CHECKSUMS.sha256']!).trim().split('\n');
      expect(lines, hasLength(files.length - 1));
      for (final String line in lines) {
        final List<String> parts = line.split('  ');
        expect(sha256.convert(files[parts[1]]!).toString(), parts[0], reason: parts[1]);
      }
      expect(jsonDecode(utf8.decode(files['manifest.json']!)), m.toJson());
    });
  });
}

/// Minimal ustar reader used to verify the writer independently.
Map<String, Uint8List> _untar(Uint8List bytes) {
  final Map<String, Uint8List> out = <String, Uint8List>{};
  int offset = 0;
  while (offset + 512 <= bytes.length) {
    final Uint8List h = bytes.sublist(offset, offset + 512);
    if (h.every((int b) => b == 0)) break;
    final String name = utf8.decode(h.sublist(0, 100).takeWhile((int b) => b != 0).toList());
    final int size = int.parse(ascii.decode(h.sublist(124, 135)), radix: 8);
    final int stored = int.parse(ascii.decode(h.sublist(148, 154)), radix: 8);
    final Uint8List zeroed = Uint8List.fromList(h)..setRange(148, 156, List<int>.filled(8, 0x20));
    expect(zeroed.fold<int>(0, (int a, int b) => a + b), stored, reason: 'header checksum $name');
    expect(ascii.decode(h.sublist(136, 147)), '00000000000', reason: 'mtime 0');
    out[name] = bytes.sublist(offset + 512, offset + 512 + size);
    offset += 512 + ((size + 511) ~/ 512) * 512;
  }
  return out;
}
