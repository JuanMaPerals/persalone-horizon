import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'app_manifest.dart';
import 'test_runner.dart';

/// Builds a reproducible `.horizonapp` package: an uncompressed POSIX ustar
/// archive with sorted entries and fixed metadata (mtime 0, uid/gid 0, mode
/// 0644), so identical inputs produce identical bytes and digest.
///
/// Contents: manifest.json (canonical), validation.json, tests spec,
/// provenance.json, the latest test result with its framebuffer artifacts
/// (when one exists) and CHECKSUMS.sha256 over every other entry.
final class HorizonAppPackage {
  const HorizonAppPackage(this.bytes, this.sha256Hex, this.entries);

  static const String mediaType = 'application/vnd.persalone.horizonapp+tar';

  final Uint8List bytes;
  final String sha256Hex;
  final List<String> entries;

  static HorizonAppPackage build(
    HorizonAppManifest manifest, {
    Map<String, Object?>? latestResult,
    Map<String, Uint8List> resultArtifacts = const <String, Uint8List>{},
  }) {
    final Map<String, Uint8List> files = <String, Uint8List>{
      'manifest.json': _utf8(manifest.canonicalJson()),
      'validation.json': _utf8(canonicalize(<String, Object?>{
        'schema': 'horizon.validation.v1',
        'appDigest': manifest.digest,
        'manifestValid': true,
        'preview': manifest.preview(),
      })),
      'tests/hello-display.default.json': _utf8(canonicalize(<String, Object?>{
        'scenario': 'hello-display.default',
        'target': 'EMULATED',
        'assertions': <String>[
          'manifest.valid', 'composition.noLoss', 'display.page1Visible', //
          'display.insideVisibleCircle', 'glyphs.reported',
          'button.deviceReport', 'button.advancesPage',
          'button.otherGestureIgnored', 'stop.clearsDisplay',
        ],
      })),
      'provenance.json': _utf8(canonicalize(<String, Object?>{
        'schema': 'horizon.provenance.v1',
        'appDigest': manifest.digest,
        'template': manifest.template,
        'builtBy': 'horizon-companion',
        'companionVersion': companionVersion,
        'codeEntrypoints': 'none (V1: text and validated parameters only)',
        'testResult': latestResult?['runId'],
      })),
    };
    if (latestResult != null) {
      final String runId = '${latestResult['runId']}';
      files['results/$runId/result.json'] = _utf8(canonicalize(latestResult));
      for (final MapEntry<String, Uint8List> a in resultArtifacts.entries) {
        files['results/$runId/${a.key}'] = a.value;
      }
    }
    final List<String> names = files.keys.toList()..sort();
    files['CHECKSUMS.sha256'] = _utf8(names
        .map((String n) => '${sha256.convert(files[n]!)}  $n\n')
        .join());
    final List<String> ordered = <String>[...names, 'CHECKSUMS.sha256'];
    final BytesBuilder tar = BytesBuilder(copy: false);
    for (final String name in ordered) {
      final Uint8List data = files[name]!;
      tar.add(_header(name, data.length));
      tar.add(data);
      final int pad = (512 - data.length % 512) % 512;
      if (pad > 0) tar.add(Uint8List(pad));
    }
    tar.add(Uint8List(1024)); // two zero blocks end the archive
    final Uint8List bytes = tar.takeBytes();
    return HorizonAppPackage(bytes, sha256.convert(bytes).toString(), ordered);
  }

  static Uint8List _utf8(String s) => Uint8List.fromList(utf8.encode(s));

  static Uint8List _header(String name, int size) {
    final List<int> nameBytes = utf8.encode(name);
    if (nameBytes.length > 100) {
      throw ArgumentError.value(name, 'name', 'longer than 100 bytes');
    }
    final Uint8List h = Uint8List(512);
    void put(int offset, List<int> bytes) => h.setRange(offset, offset + bytes.length, bytes);
    String octal(int value, int width) =>
        '${value.toRadixString(8).padLeft(width - 1, '0')}\u0000';
    put(0, nameBytes);
    put(100, ascii.encode(octal(0x1A4, 8))); // mode 0644
    put(108, ascii.encode(octal(0, 8))); // uid
    put(116, ascii.encode(octal(0, 8))); // gid
    put(124, ascii.encode(octal(size, 12)));
    put(136, ascii.encode(octal(0, 12))); // mtime 0: reproducible
    put(148, ascii.encode('        ')); // checksum placeholder (spaces)
    h[156] = 0x30; // regular file
    put(257, ascii.encode('ustar\u0000'));
    put(263, ascii.encode('00'));
    final int checksum = h.fold<int>(0, (int a, int b) => a + b);
    put(148, ascii.encode('${checksum.toRadixString(8).padLeft(6, '0')}\u0000 '));
    return h;
  }
}
