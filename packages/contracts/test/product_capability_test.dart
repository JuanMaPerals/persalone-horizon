import 'dart:convert';
import 'dart:io';

import 'package:persalone_contracts/persalone_contracts.dart';
import 'package:test/test.dart';

import '../tool/capabilities.dart' as tool;

Map<String, Object?> _record({
  String capability = 'liveTranslation',
  String environment = 'ANDROID_REAL',
  Map<String, Object?>? artifact,
  Map<String, Object?> extra = const <String, Object?>{},
}) =>
    <String, Object?>{
      'capability': capability,
      'environment': environment,
      'commit': 'a' * 40,
      'tree': 'b' * 40,
      'method': 'physical run per the validation pack',
      'artifact': artifact ??
          <String, Object?>{
            'name': 'variant-A.ndjson',
            'sha256': 'c' * 64,
            'source': 'operator upload',
          },
      'recordedAt': '2026-10-01',
      'recorder': 'operator',
      ...extra,
    };

void main() {
  test('the committed manifest is exactly what the evidence produces', () {
    // A hand edit to capabilities.v1.json, or evidence added without
    // regenerating it, fails here (and in CI).
    final String committed =
        File('../../evidence/capabilities.v1.json').readAsStringSync();
    expect(committed, tool.render());
  });

  test('without evidence nothing is verified and readiness is zero', () {
    final Map<String, Object?> manifest =
        ProductCapabilityManifest.build(const <EvidenceRecord>[]);
    for (final Object? capability in manifest['capabilities']! as List<Object?>) {
      final Map<String, Object?> status = (capability! as Map<String, Object?>)[
          'status']! as Map<String, Object?>;
      expect(status.values, isNot(contains('verified')),
          reason: 'code, flags or UI can never produce a verified status');
    }
    final Map<String, Object?> finished =
        manifest['productFinished']! as Map<String, Object?>;
    expect(finished['verified'], 0);
    expect(finished['finished'], isFalse);
  });

  test('evidence only counts for the environment it was measured in', () {
    final Map<String, Object?> emulatedOnly = ProductCapabilityManifest.build(
        <EvidenceRecord>[
      EvidenceRecord.parse(
          _record(capability: 'stopPanic', environment: 'EMULATED')),
    ]);
    final Map<String, Object?> readiness =
        emulatedOnly['readiness']! as Map<String, Object?>;
    for (final String target in <String>['ANDROID_REAL', 'HALO_REAL']) {
      expect((readiness[target]! as Map<String, Object?>)['verified'], 0,
          reason: 'an emulator run is not $target');
    }

    final Map<String, Object?> onPhone = ProductCapabilityManifest.build(
        <EvidenceRecord>[EvidenceRecord.parse(_record())]);
    final Map<String, Object?> android = (onPhone['readiness']!
        as Map<String, Object?>)['ANDROID_REAL']! as Map<String, Object?>;
    expect(android['verified'], 1);
    expect(android['missing'], isNot(contains('liveTranslation')));
  });

  test('today: no ANDROID_REAL or HALO_REAL evidence, product not finished',
      () {
    final Map<String, Object?> manifest = jsonDecode(
            File('../../evidence/capabilities.v1.json').readAsStringSync())
        as Map<String, Object?>;
    final Map<String, Object?> finished =
        manifest['productFinished']! as Map<String, Object?>;
    expect(finished['verified'], 0);
    expect(finished['required'], 8);
    expect(finished['finished'], isFalse);
  });

  group('evidence records are strict', () {
    for (final MapEntry<String, Map<String, Object?>> hostile
        in <String, Map<String, Object?>>{
      'a simulation': _record(environment: 'SIMULATED'),
      'unknown environment': _record(environment: 'HARDWARE'),
      'unknown capability': _record(capability: 'telepathy'),
      'extra field': _record(extra: <String, Object?>{'verified': true}),
      'short sha256': _record(artifact: <String, Object?>{
        'name': 'x.ndjson',
        'sha256': 'c' * 63,
        'source': 'operator upload',
      }),
      'upper-case sha256': _record(artifact: <String, Object?>{
        'name': 'x.ndjson',
        'sha256': 'C' * 64,
        'source': 'operator upload',
      }),
      'artifact without source': _record(artifact: <String, Object?>{
        'name': 'x.ndjson',
        'sha256': 'c' * 64,
      }),
      'multi-line method':
          _record(extra: const <String, Object?>{})..['method'] = 'a\nb',
      'bad date': _record()..['recordedAt'] = 'yesterday',
      'short commit': _record()..['commit'] = 'abc',
    }.entries) {
      test('${hostile.key} is refused', () {
        expect(() => EvidenceRecord.parse(hostile.value),
            throwsA(isA<EvidenceError>()));
      });
    }
  });

  test('the catalogue declares every capability once, never as verified',
      () {
    final List<ProductCapability> declared = <ProductCapability>[
      for (final CapabilityDeclaration d in ProductCapabilities.catalogue)
        d.capability,
    ];
    expect(declared.toSet(), ProductCapability.values.toSet());
    expect(declared, hasLength(ProductCapability.values.length));
    for (final CapabilityDeclaration d in ProductCapabilities.catalogue) {
      expect(
          <CapabilityStatus>[
            CapabilityStatus.unavailable,
            CapabilityStatus.installed,
            CapabilityStatus.dormant,
            CapabilityStatus.available,
          ],
          contains(d.implementation),
          reason: d.capability.name);
    }
  });

  test('runtime-only states never appear in the static manifest', () {
    final String json = File('../../evidence/capabilities.v1.json')
        .readAsStringSync();
    expect(json, isNot(contains('"active"')));
    expect(json, isNot(contains('"degraded"')));
  });
}
