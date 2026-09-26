import 'dart:convert';
import 'dart:io';

import 'package:persalone_horizon_companion/horizon_companion.dart';
import 'package:test/test.dart';

// API boundary checks that need no emulator (the emulator is not configured,
// so runs must come back BLOCKED with a reason, never a fake display).
void main() {
  late Directory dir;
  late CompanionApi api;
  late HttpClient http;
  const String origin = 'http://127.0.0.1:5173';

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('companion_api_test_');
    api = await CompanionApi.start(
      workspace: Workspace(dir),
      emulator: const EmulatorConfig(),
      allowedOrigins: <String>{origin},
      token: 'test-token',
    );
    http = HttpClient();
  });

  tearDown(() async {
    http.close(force: true);
    await api.close();
    dir.deleteSync(recursive: true);
  });

  Future<(int, Map<String, Object?>, HttpHeaders)> call(String method, String path,
      {Object? body, String? token = 'test-token', String? originHeader, String? host}) async {
    final HttpClientRequest r = await http.openUrl(method, api.uri.resolve(path));
    if (token != null) r.headers.set('authorization', 'Bearer $token');
    if (originHeader != null) r.headers.set('origin', originHeader);
    if (host != null) r.headers.set('host', host);
    if (body != null) {
      r.headers.contentType = ContentType.json;
      r.write(body is String ? body : jsonEncode(body));
    }
    final HttpClientResponse res = await r.close();
    final String text = await res.transform(utf8.decoder).join();
    return (
      res.statusCode,
      text.isEmpty ? <String, Object?>{} : (jsonDecode(text) as Map).cast<String, Object?>(),
      res.headers,
    );
  }

  test('listens on loopback only', () {
    expect(api.uri.host, '127.0.0.1');
  });

  test('requires the pairing token', () async {
    expect((await call('GET', '/v1/health', token: null)).$1, 401);
    expect((await call('GET', '/v1/health', token: 'wrong')).$1, 401);
    final (int status, Map<String, Object?> body, _) = await call('GET', '/v1/health');
    expect(status, 200);
    expect((body['components']! as Map)['emulator'],
        <String, Object?>{'state': 'BLOCKED', 'reason': 'pythonNotConfigured'});
    expect((body['components']! as Map)['halo'],
        <String, Object?>{'state': 'BLOCKED', 'reason': 'hardwareNotAvailableInV1'});
  });

  test('rejects foreign origins and rebinding hosts; CORS is not auth', () async {
    expect((await call('GET', '/v1/health', originHeader: 'https://evil.example')).$1, 403);
    expect((await call('GET', '/v1/health', host: 'evil.example:80')).$1, 421);
    final (int preflight, _, HttpHeaders h) =
        await call('OPTIONS', '/v1/health', token: null, originHeader: origin);
    expect(preflight, 204);
    expect(h.value('access-control-allow-origin'), origin);
    expect((await call('GET', '/v1/health', token: null, originHeader: origin)).$1, 401);
  });

  test('bodies are bounded JSON objects', () async {
    expect((await call('POST', '/v1/projects', body: 'not json')).$1, 400);
    expect((await call('POST', '/v1/projects', body: <int>[1])).$1, 400);
    final String big = jsonEncode(<String, Object?>{'template': 'hello-display', 'name': 'x' * 70000});
    expect((await call('POST', '/v1/projects', body: big)).$1, 413);
  });

  test('project lifecycle without emulator: create, edit, preview, blocked run and test',
      () async {
    final (int created, Map<String, Object?> project, _) = await call('POST', '/v1/projects',
        body: <String, Object?>{'template': 'hello-display', 'name': 'Hola'});
    expect(created, 201);
    final String id = '${project['projectId']}';

    final (int edited, Map<String, Object?> after, _) = await call('PUT', '/v1/projects/$id/content',
        body: <String, Object?>{'caption': 'Año 中文 ")os.exit()--', 'advanceOn': 'double'});
    expect(edited, 200);
    final Map<String, Object?> preview = (after['preview']! as Map).cast<String, Object?>();
    expect(preview['replacedGlyphs'], 2);
    expect((after['manifest']! as Map)['content'],
        <String, Object?>{'caption': 'Año 中文 ")os.exit()--', 'advanceOn': 'double'});

    final (int badField, Map<String, Object?> err, _) = await call('PUT', '/v1/projects/$id/content',
        body: <String, Object?>{'lua': 'os.exit()'});
    expect(badField, 422);
    expect((err['error']! as Map)['code'], 'manifestUnknownField');

    final (int run, Map<String, Object?> runErr, _) = await call('POST', '/v1/projects/$id/runs');
    expect(run, 409);
    expect(runErr['error'], <String, Object?>{
      'code': 'emulatorBlocked',
      'params': <String, Object?>{'reason': 'pythonNotConfigured'},
    });

    final (int tested, Map<String, Object?> result, _) = await call('POST', '/v1/projects/$id/tests');
    expect(tested, 201);
    expect(result['outcome'], 'BLOCKED');
    expect(result['blockedReason'], 'pythonNotConfigured');
    expect(result['evidence'], 'UNKNOWN');
    expect(result['target'], 'EMULATED');

    // Results survive a restart: a new API over the same workspace sees them.
    await api.close();
    api = await CompanionApi.start(
        workspace: Workspace(dir), emulator: const EmulatorConfig(), token: 'test-token');
    final (_, Map<String, Object?> list, _) = await call('GET', '/v1/projects/$id/tests');
    expect((list['results']! as List<Object?>).single, isA<Map<Object?, Object?>>());
  });

  test('unknown ids and traversal attempts are not found', () async {
    for (final String path in <String>[
      '/v1/projects/p-zzz',
      '/v1/projects/..%2F..%2Fetc/tests',
      '/v1/runs/r-000000000000',
      '/v1/nope',
    ]) {
      expect((await call('GET', path)).$1, 404, reason: path);
    }
  });
}
