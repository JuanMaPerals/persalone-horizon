import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'api_error.dart';
import 'app_manifest.dart';

/// Local, portable project and evidence store (architecture §3, §4.5).
///
/// Layout under [root]:
/// - `projects/{projectId}/manifest.json`
/// - `results/{projectId}/{runId}/result.json` (+ artifact files)
/// - `exports/{projectId}/{packageSha256}.horizonapp`
/// There is no database: the index is rebuilt by scanning, so results survive
/// restarts. Writes are atomic (temp file + rename in the same directory).
final class Workspace {
  Workspace(this.root);

  final Directory root;
  static final RegExp _id = RegExp(r'^[a-z]-[0-9a-f]{12}$');
  static final Random _random = Random.secure();

  static String newId(String prefix) =>
      '$prefix-${List<String>.generate(6, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';

  Directory _dir(List<String> parts) =>
      Directory(<String>[root.path, ...parts].join(Platform.pathSeparator));

  static String checkId(String id) {
    if (!_id.hasMatch(id)) throw const ApiError(404, 'notFound');
    return id;
  }

  Future<String> createProject(HorizonAppManifest manifest) async {
    final String id = newId('p');
    await saveManifest(id, manifest);
    return id;
  }

  Future<void> saveManifest(String projectId, HorizonAppManifest manifest) =>
      _writeAtomic(File('${_dir(<String>['projects', checkId(projectId)]).path}/manifest.json'),
          utf8.encode(const JsonEncoder.withIndent('  ').convert(manifest.toJson())));

  Future<HorizonAppManifest> loadManifest(String projectId) async {
    final File f = File('${_dir(<String>['projects', checkId(projectId)]).path}/manifest.json');
    if (!f.existsSync()) throw const ApiError(404, 'notFound');
    return HorizonAppManifest.parse(jsonDecode(await f.readAsString()));
  }

  Future<List<String>> projectIds() async {
    final Directory d = _dir(<String>['projects']);
    if (!d.existsSync()) return <String>[];
    return d
        .listSync()
        .whereType<Directory>()
        .map((Directory e) => e.uri.pathSegments.where((String s) => s.isNotEmpty).last)
        .where(_id.hasMatch)
        .toList()
      ..sort();
  }

  Future<void> saveResult(String projectId, String runId,
      Map<String, Object?> result, Map<String, Uint8List> artifacts) async {
    final Directory d = _dir(<String>['results', checkId(projectId), checkId(runId)]);
    for (final MapEntry<String, Uint8List> a in artifacts.entries) {
      await _writeAtomic(File('${d.path}/${_safeName(a.key)}'), a.value);
    }
    await _writeAtomic(File('${d.path}/result.json'),
        utf8.encode(const JsonEncoder.withIndent('  ').convert(result)));
  }

  /// Results of a project, newest first (by finishedAt).
  Future<List<Map<String, Object?>>> results(String projectId) async {
    final Directory d = _dir(<String>['results', checkId(projectId)]);
    if (!d.existsSync()) return <Map<String, Object?>>[];
    final List<Map<String, Object?>> out = <Map<String, Object?>>[];
    for (final Directory run in d.listSync().whereType<Directory>()) {
      final File f = File('${run.path}/result.json');
      if (f.existsSync()) {
        out.add((jsonDecode(await f.readAsString()) as Map).cast<String, Object?>());
      }
    }
    out.sort((Map<String, Object?> a, Map<String, Object?> b) =>
        '${b['finishedAt']}'.compareTo('${a['finishedAt']}'));
    return out;
  }

  Future<Uint8List> artifact(String projectId, String runId, String name) async {
    final File f = File('${_dir(<String>['results', checkId(projectId), checkId(runId)]).path}/${_safeName(name)}');
    if (!f.existsSync()) throw const ApiError(404, 'notFound');
    return f.readAsBytes();
  }

  Future<File> saveExport(String projectId, String sha, Uint8List bytes) async {
    final File f = File('${_dir(<String>['exports', checkId(projectId)]).path}/$sha.horizonapp');
    await _writeAtomic(f, bytes);
    return f;
  }

  static String _safeName(String name) {
    if (!RegExp(r'^[a-z0-9][a-z0-9._-]{0,63}$').hasMatch(name) || name.contains('..')) {
      throw const ApiError(404, 'notFound');
    }
    return name;
  }

  static Future<void> _writeAtomic(File target, List<int> bytes) async {
    await target.parent.create(recursive: true);
    final File tmp = File('${target.path}.tmp-${newId('t')}');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(target.path);
  }
}
