// Regenerates evidence/capabilities.v1.json from the catalogue and the
// evidence registry. `--check` exits 1 when the committed file has drifted.
// Run from packages/contracts: dart run tool/capabilities.dart [--check]
import 'dart:convert';
import 'dart:io';

import 'package:persalone_contracts/persalone_contracts.dart';

const String registryPath = '../../evidence/registry.v1.json';
const String manifestPath = '../../evidence/capabilities.v1.json';

String render() {
  final Object? registry =
      jsonDecode(File(registryPath).readAsStringSync());
  if (registry is! Map ||
      registry['schema'] != 'horizon.evidence-registry.v1' ||
      registry['records'] is! List) {
    throw const EvidenceError('registry must be horizon.evidence-registry.v1');
  }
  final List<EvidenceRecord> records = <EvidenceRecord>[
    for (final Object? raw in registry['records'] as List<Object?>)
      EvidenceRecord.parse(raw),
  ];
  return '${const JsonEncoder.withIndent('  ').convert(ProductCapabilityManifest.build(records))}\n';
}

void main(List<String> args) {
  final String manifest = render();
  final File file = File(manifestPath);
  if (args.contains('--check')) {
    if (!file.existsSync() || file.readAsStringSync() != manifest) {
      stderr.writeln('capabilities.v1.json drifted: dart run tool/capabilities.dart');
      exit(1);
    }
    return;
  }
  file.writeAsStringSync(manifest);
}
