import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:persalone_contracts/persalone_contracts.dart';
import 'package:persalone_translation_runtime/persalone_translation_runtime.dart';

import 'api_error.dart';
import 'app_manifest.dart';
import 'app_run_host.dart';
import 'emulator_session.dart';
import 'package_export.dart';
import 'test_runner.dart';
import 'workspace.dart';

/// Local Studio API `/v1` (architecture §7), loopback only.
///
/// Every request except CORS preflight needs `Authorization: Bearer <token>`
/// (the pairing token printed at start). The Host header must name the
/// loopback listener (DNS-rebinding defence) and a browser Origin must be in
/// the allow-list; CORS is not treated as authentication. Bodies are JSON
/// and at most 64 KiB. Errors are stable codes that the UI localises.
final class CompanionApi {
  CompanionApi._(this._server, this.token, this._workspace, this._host,
      this._tests, this._allowedOrigins, this._events);

  static const int maxBodyBytes = 64 * 1024;

  final HttpServer _server;
  final String token;
  final Workspace _workspace;
  final AppRunHost _host;
  final HelloDisplayTestRunner _tests;
  final Set<String> _allowedOrigins;
  final RuntimeEventServer _events;

  /// Read-only canonical runtime event stream (SSE, loopback).
  Uri get eventsUri => _events.uri;

  Uri get uri => Uri(scheme: 'http', host: _server.address.address, port: _server.port);

  static Future<CompanionApi> start({
    required Workspace workspace,
    required EmulatorConfig emulator,
    int port = 0,
    int eventsPort = 0,
    Set<String> allowedOrigins = const <String>{},
    String? token,
  }) async {
    final HttpServer server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    final AppRunHost host = AppRunHost(workspace, emulator);
    final RuntimeEventServer events = await RuntimeEventServer.start(
      host.events.events,
      port: eventsPort,
      allowedOrigins: allowedOrigins,
    );
    final CompanionApi api = CompanionApi._(
      server,
      token ?? _newToken(),
      workspace,
      host,
      HelloDisplayTestRunner(workspace, emulator),
      allowedOrigins,
      events,
    );
    server.listen(api._handle);
    return api;
  }

  Future<void> close() async {
    await _host.dispose();
    await _events.close();
    await _host.events.close();
    await _server.close(force: true);
  }

  static String _newToken() {
    final Random r = Random.secure();
    return List<String>.generate(32, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  Future<void> _handle(HttpRequest request) async {
    final HttpResponse response = request.response;
    response.headers
      ..set('cache-control', 'no-store')
      ..set('x-content-type-options', 'nosniff');
    try {
      _checkHost(request);
      final String? origin = request.headers.value('origin');
      if (origin != null) {
        if (!_allowedOrigins.contains(origin)) throw const ApiError(403, 'originNotAllowed');
        response.headers
          ..set('access-control-allow-origin', origin)
          ..set('vary', 'origin')
          ..set('access-control-expose-headers',
              'x-frame-sha256, x-package-sha256, content-disposition');
      }
      if (request.method == 'OPTIONS') {
        response.headers
          ..set('access-control-allow-methods', 'GET, POST, PUT, OPTIONS')
          ..set('access-control-allow-headers', 'authorization, content-type')
          ..set('access-control-max-age', '600');
        response.statusCode = HttpStatus.noContent;
        await response.close();
        return;
      }
      if (request.headers.value('authorization') != 'Bearer $token') {
        throw const ApiError(401, 'unauthorized');
      }
      await _route(request);
    } on ApiError catch (e) {
      await _json(response, e.toJson(), status: e.status);
    } on RuntimeError catch (e) {
      // Device/runtime refusals keep their coded cause; no message text.
      await _json(response,
          ApiError(409, 'deviceRefused', <String, Object>{'reason': e.code.name}).toJson(),
          status: 409);
    } on Object {
      await _json(response, const ApiError(500, 'internalError').toJson(), status: 500);
    }
  }

  void _checkHost(HttpRequest request) {
    final String? host = request.headers.value('host');
    final Set<String> allowed = <String>{
      '127.0.0.1:${_server.port}',
      'localhost:${_server.port}',
    };
    if (host == null || !allowed.contains(host)) throw const ApiError(421, 'hostNotAllowed');
  }

  Future<void> _route(HttpRequest request) async {
    final List<String> p = request.uri.pathSegments;
    final String m = request.method;
    final HttpResponse res = request.response;
    if (p.isEmpty || p.first != 'v1') throw const ApiError(404, 'notFound');
    final List<String> s = p.sublist(1);

    if (m == 'GET' && _is(s, <String>['health'])) {
      return _json(res, _health());
    }
    if (m == 'GET' && _is(s, <String>['templates'])) {
      return _json(res, <String, Object?>{
        'templates': <Map<String, Object?>>[
          <String, Object?>{
            'id': 'hello-display',
            'capabilities': <String>['DISPLAY', 'BUTTON'],
            'targets': v1Targets,
            'editable': <String>['caption', 'advanceOn'],
            'buttonGestures': buttonGestures,
          },
        ],
      });
    }
    if (m == 'GET' && _is(s, <String>['projects'])) {
      final List<Map<String, Object?>> projects = <Map<String, Object?>>[];
      for (final String id in await _workspace.projectIds()) {
        projects.add(await _projectView(id));
      }
      return _json(res, <String, Object?>{'projects': projects});
    }
    if (m == 'POST' && _is(s, <String>['projects'])) {
      final Map<String, Object?> body = await _body(request);
      if (body['template'] != 'hello-display') throw const ApiError(422, 'templateUnknown');
      final Object? name = body['name'];
      if (name is! String || name.trim().isEmpty || name.length > 60) {
        throw const ApiError(422, 'manifestInvalidField', <String, Object>{'field': 'name'});
      }
      final HorizonAppManifest manifest = HorizonAppManifest.helloDisplay(
          appId: 'local.hello-display.${Workspace.newId('a').substring(2)}', name: name.trim());
      final String id = await _workspace.createProject(manifest);
      return _json(res, await _projectView(id), status: 201);
    }
    if (s.length >= 2 && s[0] == 'projects') {
      final String projectId = Workspace.checkId(s[1]);
      final List<String> rest = s.sublist(2);
      if (m == 'GET' && rest.isEmpty) return _json(res, await _projectView(projectId));
      if (m == 'PUT' && _is(rest, <String>['content'])) {
        final Map<String, Object?> body = await _body(request);
        for (final String k in body.keys) {
          if (k != 'caption' && k != 'advanceOn') {
            throw ApiError(422, 'manifestUnknownField', <String, Object>{'field': 'content.$k'});
          }
        }
        final HorizonAppManifest current = await _workspace.loadManifest(projectId);
        final Object? caption = body['caption'];
        final Object? advanceOn = body['advanceOn'];
        final HorizonAppManifest next = current.withContent(
          caption: caption == null ? null : HorizonAppManifest.validateCaption(caption),
          advanceOn: advanceOn == null ? null : '$advanceOn',
        );
        await _workspace.saveManifest(projectId, next);
        return _json(res, await _projectView(projectId));
      }
      if (m == 'POST' && _is(rest, <String>['runs'])) {
        final AppRun run = await _host.start(projectId);
        return _json(res, run.toJson(), status: 201);
      }
      if (m == 'POST' && _is(rest, <String>['tests'])) {
        return _json(res, await _tests.run(projectId), status: 201);
      }
      if (m == 'GET' && _is(rest, <String>['tests'])) {
        return _json(res, <String, Object?>{'results': await _workspace.results(projectId)});
      }
      if (m == 'GET' && rest.length == 4 && rest[0] == 'tests' && rest[2] == 'artifacts') {
        final Uint8List bytes =
            await _workspace.artifact(projectId, Workspace.checkId(rest[1]), rest[3]);
        return _bytes(res, bytes, 'image/png');
      }
      if (m == 'POST' && _is(rest, <String>['export'])) {
        final HorizonAppManifest manifest = await _workspace.loadManifest(projectId);
        final List<Map<String, Object?>> results = await _workspace.results(projectId);
        final Map<String, Object?>? latest = results
            .where((Map<String, Object?> r) => r['appDigest'] == manifest.digest)
            .firstOrNull;
        final Map<String, Uint8List> artifacts = <String, Uint8List>{};
        if (latest != null) {
          for (final Object? a in latest['artifacts']! as List<Object?>) {
            final String name = '${(a! as Map<String, Object?>)['name']}';
            artifacts[name] = await _workspace.artifact(projectId, '${latest['runId']}', name);
          }
        }
        final HorizonAppPackage pkg = HorizonAppPackage.build(manifest,
            latestResult: latest, resultArtifacts: artifacts);
        await _workspace.saveExport(projectId, pkg.sha256Hex, pkg.bytes);
        res.headers
          ..set('x-package-sha256', pkg.sha256Hex)
          ..set('content-disposition',
              'attachment; filename="${manifest.appId}-${manifest.version}.horizonapp"');
        return _bytes(res, pkg.bytes, HorizonAppPackage.mediaType);
      }
    }
    if (s.length >= 2 && s[0] == 'runs') {
      final String runId = Workspace.checkId(s[1]);
      final List<String> rest = s.sublist(2);
      if (m == 'GET' && rest.isEmpty) return _json(res, _host.get(runId).toJson());
      if (m == 'POST' && _is(rest, <String>['button'])) {
        final Map<String, Object?> body = await _body(request);
        final ButtonOutcome o = await _host.press(runId, '${body['gesture']}');
        return _json(res, o.toJson());
      }
      if (m == 'GET' && _is(rest, <String>['framebuffer'])) {
        final FrameCapture f = await _host.frame(runId);
        res.headers.set('x-frame-sha256', f.pngSha256);
        return _bytes(res, f.png, 'image/png');
      }
      if (m == 'POST' && _is(rest, <String>['stop'])) {
        return _json(res, (await _host.stop(runId)).toJson());
      }
    }
    if (m == 'POST' && _is(s, <String>['panic'])) {
      return _json(res, await _host.panic());
    }
    throw const ApiError(404, 'notFound');
  }

  Map<String, Object?> _health() {
    final String? blocked = _host.config.blockedReason;
    return <String, Object?>{
      'status': blocked == null ? 'READY' : 'DEGRADED',
      'companionVersion': companionVersion,
      'runtimeEvents': eventsUri.toString(),
      'components': <String, Object?>{
        'api': <String, Object?>{'state': 'READY'},
        'emulator': blocked == null
            ? <String, Object?>{'state': 'READY', 'target': 'EMULATED'}
            : <String, Object?>{'state': 'BLOCKED', 'reason': blocked},
        'halo': <String, Object?>{'state': 'BLOCKED', 'reason': 'hardwareNotAvailableInV1'},
      },
    };
  }

  Future<Map<String, Object?>> _projectView(String projectId) async {
    final HorizonAppManifest manifest = await _workspace.loadManifest(projectId);
    final List<Map<String, Object?>> results = await _workspace.results(projectId);
    return <String, Object?>{
      'projectId': projectId,
      'manifest': manifest.toJson(),
      'appDigest': manifest.digest,
      'preview': manifest.preview(),
      'latestTest': results.firstOrNull,
    };
  }

  static bool _is(List<String> s, List<String> expected) =>
      s.length == expected.length &&
      Iterable<int>.generate(s.length).every((int i) => s[i] == expected[i]);

  static Future<Map<String, Object?>> _body(HttpRequest request) async {
    final BytesBuilder b = BytesBuilder(copy: false);
    await for (final List<int> chunk in request) {
      b.add(chunk);
      if (b.length > maxBodyBytes) throw const ApiError(413, 'bodyTooLarge');
    }
    if (b.isEmpty) return <String, Object?>{};
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(b.takeBytes()));
    } on FormatException {
      throw const ApiError(400, 'bodyNotJson');
    }
    if (decoded is! Map) throw const ApiError(400, 'bodyNotJson');
    return decoded.cast<String, Object?>();
  }

  static Future<void> _json(HttpResponse res, Map<String, Object?> body, {int status = 200}) async {
    res.statusCode = status;
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode(body));
    await res.close();
  }

  static Future<void> _bytes(HttpResponse res, Uint8List bytes, String type) async {
    res.statusCode = 200;
    res.headers.contentType = ContentType.parse(type);
    res.add(bytes);
    await res.close();
  }
}
