// Regenerates evidence/capabilities.v1.json and the generated section of
// docs/STATUS.md from the catalogue and the evidence registry. `--check`
// exits 1 when either committed file has drifted.
// Run from packages/contracts: dart run tool/capabilities.dart [--check]
import 'dart:convert';
import 'dart:io';

import 'package:persalone_contracts/persalone_contracts.dart';

const String registryPath = '../../evidence/registry.v1.json';
const String manifestPath = '../../evidence/capabilities.v1.json';
const String statusPath = '../../docs/STATUS.md';
const String statusBegin =
    '<!-- BEGIN GENERATED: dart run tool/capabilities.dart (packages/contracts) -->';
const String statusEnd = '<!-- END GENERATED -->';

List<EvidenceRecord> _records() {
  final Object? registry = jsonDecode(File(registryPath).readAsStringSync());
  if (registry is! Map ||
      registry['schema'] != 'horizon.evidence-registry.v1' ||
      registry['records'] is! List) {
    throw const EvidenceError('registry must be horizon.evidence-registry.v1');
  }
  return <EvidenceRecord>[
    for (final Object? raw in registry['records'] as List<Object?>)
      EvidenceRecord.parse(raw),
  ];
}

/// The STATUS.md table: one row per capability, one column per environment
/// that can hold evidence, then computed readiness. Nothing here is typed by
/// hand.
String renderStatus() {
  final Map<String, Object?> manifest =
      ProductCapabilityManifest.build(_records());
  const List<String> columns = <String>[
    'EMULATED',
    'ANDROID_REAL',
    'HALO_REAL',
  ];
  String cell(String status) =>
      status == 'verified' ? '**VERIFIED**' : status;
  final StringBuffer out = StringBuffer()
    ..writeln(statusBegin)
    ..writeln()
    ..writeln('| Capability | Implementation | ${columns.join(' | ')} | '
        'Required for |')
    ..writeln('|---|---|${columns.map((_) => '---').join('|')}|---|');
  for (final Object? raw in manifest['capabilities']! as List<Object?>) {
    final Map<String, Object?> c = raw! as Map<String, Object?>;
    final Map<String, Object?> status = c['status']! as Map<String, Object?>;
    final List<Object?> required = c['requiredFor']! as List<Object?>;
    out.writeln('| `${c['id']}` | ${c['implementation']} | '
        '${columns.map((String e) => cell(status[e]! as String)).join(' | ')} | '
        '${required.isEmpty ? '—' : required.join(', ')} |');
  }
  final Map<String, Object?> readiness =
      manifest['readiness']! as Map<String, Object?>;
  final Map<String, Object?> finished =
      manifest['productFinished']! as Map<String, Object?>;
  out
    ..writeln()
    ..writeln('| Product target | Verified / required | Missing |')
    ..writeln('|---|---|---|');
  for (final MapEntry<String, Object?> target in readiness.entries) {
    final Map<String, Object?> r = target.value! as Map<String, Object?>;
    final List<Object?> missing = r['missing']! as List<Object?>;
    out.writeln('| ${target.key} | ${r['verified']} / ${r['required']} | '
        '${missing.isEmpty ? '—' : missing.map((Object? m) => '`$m`').join(', ')} |');
  }
  out
    ..writeln()
    ..writeln('**PRODUCT_FINISHED:** ${finished['verified']} / '
        '${finished['required']} — ${finished['finished'] == true ? 'finished' : 'not finished'}.')
    ..writeln()
    ..write(statusEnd);
  return out.toString();
}

/// STATUS.md with its generated section replaced; the hand-written text
/// around the markers is kept as is.
String renderStatusFile(String current) {
  final int begin = current.indexOf(statusBegin);
  final int end = current.indexOf(statusEnd);
  if (begin < 0 || end < begin) {
    throw const EvidenceError('docs/STATUS.md lacks the generated markers');
  }
  return current.replaceRange(begin, end + statusEnd.length, renderStatus());
}

String render() {
  return '${const JsonEncoder.withIndent('  ').convert(ProductCapabilityManifest.build(_records()))}\n';
}

void main(List<String> args) {
  final String manifest = render();
  final File file = File(manifestPath);
  final File statusFile = File(statusPath);
  final String currentStatus = statusFile.readAsStringSync();
  final String status = renderStatusFile(currentStatus);
  if (args.contains('--check')) {
    if (!file.existsSync() ||
        file.readAsStringSync() != manifest ||
        currentStatus != status) {
      stderr.writeln('capabilities.v1.json or docs/STATUS.md drifted: '
          'dart run tool/capabilities.dart');
      exit(1);
    }
    return;
  }
  file.writeAsStringSync(manifest);
  statusFile.writeAsStringSync(status);
}
