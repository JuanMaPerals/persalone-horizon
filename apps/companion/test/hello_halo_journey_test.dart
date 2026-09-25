import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:persalone_horizon_companion/horizon_companion.dart';
import 'package:test/test.dart';

// V1 journey through the same API Studio uses, against the official
// emulator: create → edit → run → framebuffer → button → test → export.
// Runs when HORIZON_E2E_PYTHON is set (CI e2e-emulated), fails loudly with
// HORIZON_E2E_REQUIRED=1, skipped otherwise.
final String? _python = Platform.environment['HORIZON_E2E_PYTHON'];
final bool _required = Platform.environment['HORIZON_E2E_REQUIRED'] == '1';
final String _bridge = '${Directory.current.path}/../../tooling/e2e/halo_emulator_bridge.py';

String? get _skip => _python != null || _required
    ? null
    : 'official emulator not configured: set HORIZON_E2E_PYTHON';

const String _longCaption =
    'Hola Halo. Este texto es deliberadamente largo para ocupar dos paginas '
    'en la pantalla redonda; el boton muestra la siguiente pagina del caption';

void main() {
  late Directory dir;
  late CompanionApi api;
  late HttpClient http;

  setUp(() async {
    if (_python == null) fail('HORIZON_E2E_REQUIRED=1 but no HORIZON_E2E_PYTHON');
    dir = Directory.systemTemp.createTempSync('companion_journey_');
    api = await CompanionApi.start(
      workspace: Workspace(dir),
      emulator: EmulatorConfig(python: _python, bridgeScript: _bridge),
      token: 'journey',
    );
    http = HttpClient();
  });

  tearDown(() async {
    http.close(force: true);
    await api.close();
    dir.deleteSync(recursive: true);
  });

  Future<(int, Object?, HttpHeaders, Uint8List)> call(String method, String path,
      {Object? body}) async {
    final HttpClientRequest r = await http.openUrl(method, api.uri.resolve(path));
    r.headers.set('authorization', 'Bearer journey');
    if (body != null) {
      r.headers.contentType = ContentType.json;
      r.write(jsonEncode(body));
    }
    final HttpClientResponse res = await r.close();
    final Uint8List bytes = Uint8List.fromList(
        await res.fold<List<int>>(<int>[], (List<int> a, List<int> b) => a..addAll(b)));
    final bool isJson = res.headers.contentType?.mimeType == 'application/json';
    return (res.statusCode, isJson ? jsonDecode(utf8.decode(bytes)) : null, res.headers, bytes);
  }

  Map<String, Object?> obj(Object? v) => (v! as Map).cast<String, Object?>();

  test('Hello Halo: create, edit, run, frame, button, test, export', skip: _skip,
      () async {
    // Create from template.
    final (int c, Object? created, _, _) = await call('POST', '/v1/projects',
        body: <String, Object?>{'template': 'hello-display', 'name': 'Hello Halo'});
    expect(c, 201);
    final String id = '${obj(created)['projectId']}';

    // Edit the caption (validated text, two pages).
    final (int e, Object? edited, _, _) = await call('PUT', '/v1/projects/$id/content',
        body: <String, Object?>{'caption': _longCaption, 'advanceOn': 'single'});
    expect(e, 200);
    expect(obj(obj(edited)['preview'])['pageCount'], 2);

    // Run on the official emulator.
    final (int r, Object? runJson, _, _) = await call('POST', '/v1/projects/$id/runs');
    expect(r, 201, reason: '$runJson');
    final Map<String, Object?> run = obj(runJson);
    expect(run['target'], 'EMULATED');
    expect(run['environment'], 'EMULATED');
    expect(run['page'], 1);
    final String runId = '${run['runId']}';

    // Framebuffer page 1.
    final (int f1, _, HttpHeaders h1, Uint8List png1) =
        await call('GET', '/v1/runs/$runId/framebuffer');
    expect(f1, 200);
    expect(h1.contentType?.mimeType, 'image/png');
    expect(h1.value('x-frame-sha256'), sha256.convert(png1).toString());

    // Another gesture is reported by the device but does not advance.
    final (_, Object? other, _, _) = await call('POST', '/v1/runs/$runId/button',
        body: <String, Object?>{'gesture': 'long'});
    expect(obj(other)['deviceReports'], <String>['btn:long']);
    expect(obj(other)['advanced'], isFalse);

    // The configured gesture advances to page 2; the frame changes.
    final (_, Object? press, _, _) = await call('POST', '/v1/runs/$runId/button',
        body: <String, Object?>{'gesture': 'single'});
    expect(obj(press), <String, Object?>{
      'deviceReports': <String>['btn:single'],
      'advanced': true,
      'page': 2,
      'pageCount': 2,
    });
    final (_, _, _, Uint8List png2) = await call('GET', '/v1/runs/$runId/framebuffer');
    expect(sha256.convert(png2), isNot(sha256.convert(png1)));

    // Invalid gesture is refused.
    final (int bad, _, _, _) = await call('POST', '/v1/runs/$runId/button',
        body: <String, Object?>{'gesture': 'triple'});
    expect(bad, 422);

    // Run state carries measured metrics with sample counts.
    final (_, Object? state, _, _) = await call('GET', '/v1/runs/$runId');
    final List<Object?> metrics = obj(state)['metrics']! as List<Object?>;
    final Map<String, Object?> ack = obj(metrics.firstWhere(
        (Object? m) => obj(m)['name'] == 'display.command_ack'));
    expect(ack['availability'], 'MEASURED');
    expect(ack['samples'], 2);
    expect(ack['p50'], isNull, reason: 'fewer than 5 samples: no percentile');

    // Stop clears and releases the run.
    final (_, Object? stopped, _, _) = await call('POST', '/v1/runs/$runId/stop');
    expect(obj(stopped)['state'], 'stopped');
    expect((await call('GET', '/v1/runs/$runId/framebuffer')).$1, 409);

    // Test run: every assertion passes on the emulator.
    final (int t, Object? resultJson, _, _) = await call('POST', '/v1/projects/$id/tests');
    expect(t, 201);
    final Map<String, Object?> result = obj(resultJson);
    expect(result['outcome'], 'PASS', reason: const JsonEncoder.withIndent(' ').convert(result));
    expect(result['target'], 'EMULATED');
    expect(obj(result['data'])['provenance'], 'SYNTHETIC');
    expect(obj(result['providers'])['stt'], 'NOT_USED');
    expect((result['assertions']! as List<Object?>).map((Object? a) => obj(a)['status']),
        everyElement('PASS'));
    expect(obj(result['environment'])['emulatorVersion'], isNotNull);
    final List<Object?> artifacts = result['artifacts']! as List<Object?>;
    expect(artifacts.map((Object? a) => obj(a)['name']), <String>['page-1.png', 'page-2.png']);
    final (int art, _, _, Uint8List artBytes) = await call(
        'GET', '/v1/projects/$id/tests/${result['runId']}/artifacts/page-1.png');
    expect(art, 200);
    expect(sha256.convert(artBytes).toString(), obj(artifacts.first)['sha256']);

    // Export: reproducible package bound to the tested digest.
    final (int x1, _, HttpHeaders xh1, Uint8List pkg1) =
        await call('POST', '/v1/projects/$id/export');
    final (_, _, HttpHeaders xh2, Uint8List pkg2) =
        await call('POST', '/v1/projects/$id/export');
    expect(x1, 200);
    expect(xh1.value('x-package-sha256'), sha256.convert(pkg1).toString());
    expect(xh2.value('x-package-sha256'), xh1.value('x-package-sha256'));
    expect(pkg1, pkg2);
    expect(utf8.decode(pkg1.sublist(257, 262), allowMalformed: true), 'ustar');
  });

  test('the run is mirrored on the canonical runtime event stream (no text)',
      skip: _skip, () async {
    // Subscribe to the read-only SSE stream announced by /v1/health.
    final (_, Object? health, _, _) = await call('GET', '/v1/health');
    final Uri events = Uri.parse('${obj(health)['runtimeEvents']}');
    expect(events.host, '127.0.0.1');
    final HttpClientRequest sse = await http.getUrl(events);
    sse.headers.set('accept', 'text/event-stream');
    final HttpClientResponse stream = await sse.close();
    final List<Map<String, Object?>> seen = <Map<String, Object?>>[];
    final List<String> raw = <String>[];
    final StreamSubscription<String> sub = stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((String line) {
      if (line.startsWith('data: ')) {
        raw.add(line);
        final Object? d = jsonDecode(line.substring(6));
        if (d is Map && d['schema'] == 'horizon.runtime-event.v1') {
          seen.add(d.cast<String, Object?>());
        }
      }
    });

    final (_, Object? created, _, _) = await call('POST', '/v1/projects',
        body: <String, Object?>{'template': 'hello-display', 'name': 'Events'});
    final String id = '${obj(created)['projectId']}';
    await call('PUT', '/v1/projects/$id/content',
        body: <String, Object?>{'caption': _longCaption, 'advanceOn': 'single'});
    final (_, Object? runJson, _, _) = await call('POST', '/v1/projects/$id/runs');
    final String runId = '${obj(runJson)['runId']}';
    await call('POST', '/v1/runs/$runId/button', body: <String, Object?>{'gesture': 'single'});
    await call('POST', '/v1/runs/$runId/stop');
    await call('POST', '/v1/panic');
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!seen.any((Map<String, Object?> e) => e['code'] == 'panicExecuted') &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await sub.cancel();

    String kindOf(Map<String, Object?> e) => switch (e['kind']) {
          'sessionState' => 'session:${e['state']}',
          'deviceState' => 'device:${e['state']}:${e['environment']}',
          'caption' => 'caption:${e['status']}:${e['environment']}',
          'diagnostic' => 'diag:${e['code']}:${e['detail']}',
          _ => '${e['kind']}',
        };
    final List<String> kinds = seen.map(kindOf).toList();
    expect(kinds, containsAllInOrder(<String>[
      'session:preparing',
      'device:ready:EMULATED',
      'caption:delivered:EMULATED',
      'session:listening',
      'diag:inputButton:single',
      'caption:delivered:EMULATED',
      'session:stopping',
      'session:stopped',
      'diag:panicExecuted:null',
    ]));
    expect(seen.where((Map<String, Object?> e) => e['kind'] == 'caption').first['truth'], 'PREPARED');
    expect(raw.join('\n'), isNot(contains('deliberadamente')), reason: 'no caption text on the stream');
    expect(kinds.where((String k) => k.contains('HALO_REAL')), isEmpty);
  });

  test('Panic stops every run and clears its display', skip: _skip, () async {
    final (_, Object? created, _, _) = await call('POST', '/v1/projects',
        body: <String, Object?>{'template': 'hello-display', 'name': 'Panic'});
    final String id = '${obj(created)['projectId']}';
    final (_, Object? runJson, _, _) = await call('POST', '/v1/projects/$id/runs');
    final String runId = '${obj(runJson)['runId']}';
    final (int p, Object? panic, _, _) = await call('POST', '/v1/panic');
    expect(p, 200);
    expect(obj(panic)['stoppedRuns'], <String>[runId]);
    final (_, Object? state, _, _) = await call('GET', '/v1/runs/$runId');
    expect(obj(state)['state'], 'stopped');
    expect(obj(state)['stopReason'], 'panic');
    expect((await call('POST', '/v1/runs/$runId/button',
            body: <String, Object?>{'gesture': 'single'}))
        .$1, 409);
  });

  test('a new run supersedes the previous lease', skip: _skip, () async {
    final (_, Object? created, _, _) = await call('POST', '/v1/projects',
        body: <String, Object?>{'template': 'hello-display', 'name': 'Lease'});
    final String id = '${obj(created)['projectId']}';
    final (_, Object? first, _, _) = await call('POST', '/v1/projects/$id/runs');
    final (_, Object? second, _, _) = await call('POST', '/v1/projects/$id/runs');
    final (_, Object? firstState, _, _) = await call('GET', '/v1/runs/${obj(first)['runId']}');
    expect(obj(firstState)['stopReason'], 'superseded');
    expect(obj(second)['generation'], greaterThan(obj(first)['generation']! as int));
  });
}
