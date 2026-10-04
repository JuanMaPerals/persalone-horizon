import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:persalone_contracts/persalone_contracts.dart';
import 'package:persalone_translation_runtime/persalone_translation_runtime.dart';
import 'package:test/test.dart';

// The authenticated transport in front of RemoteControlGateway: every refusal
// below must leave the runtime untouched, and no response may carry the
// credential.
void main() {
  late _Port port;
  late RemoteControlToken token;
  late RemoteControlServer server;
  late List<String> bodies;
  int ids = 0;
  int locks = 0;
  const String studio = 'http://127.0.0.1:5173';

  Future<RemoteControlServer> startServer({int maxFailedAuth = 10}) =>
      RemoteControlServer.start(
        RemoteControlGateway(port, enabledActions: <ControlAction>{
          ControlAction.stop,
          ControlAction.panic,
        }),
        token: token,
        allowedOrigins: <String>{studio},
        maxFailedAuth: maxFailedAuth,
        readTimeout: const Duration(milliseconds: 200),
        onLocked: () => locks++,
      );

  Map<String, Object?> envelope(String action,
          {String? id, int? issuedAt, int? generation}) =>
      <String, Object?>{
        'schemaVersion': 1,
        'commandId': id ?? 'studio-${(++ids).toString().padLeft(6, '0')}',
        'issuedAt': issuedAt ?? DateTime.now().microsecondsSinceEpoch,
        'sessionGeneration': generation ?? port.sessionGeneration,
        'action': action,
      };

  Future<_Reply> send(
    String method,
    String path, {
    Object? json,
    String? rawBody,
    String? auth,
    bool withAuth = true,
    String? origin,
    String? host,
    String contentType = 'application/json',
    Map<String, String> headers = const <String, String>{},
  }) async {
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest request =
          await client.openUrl(method, server.uri.replace(path: path));
      if (host != null) request.headers.host = host;
      if (withAuth) {
        request.headers
            .set('authorization', auth ?? 'Bearer ${token.reveal()}');
      }
      if (origin != null) request.headers.set('origin', origin);
      headers.forEach(request.headers.set);
      final String? body = rawBody ?? (json == null ? null : jsonEncode(json));
      if (body != null) {
        request.headers.set('content-type', contentType);
        request.write(body);
      }
      final HttpClientResponse response = await request.close();
      final String text = await utf8.decodeStream(response);
      bodies.add(text);
      return _Reply(response.statusCode, text, response.headers);
    } finally {
      client.close(force: true);
    }
  }

  setUp(() async {
    ids = 0;
    locks = 0;
    bodies = <String>[];
    port = _Port()..active = 'session-1';
    token = RemoteControlToken.generate();
    server = await startServer();
  });

  tearDown(() async {
    await server.close();
    for (final String body in bodies) {
      expect(body, isNot(contains(token.reveal())),
          reason: 'no response may carry the credential');
    }
  });

  test('refuses to bind beyond loopback', () async {
    await expectLater(
      RemoteControlServer.start(RemoteControlGateway(port),
          token: token, address: InternetAddress.anyIPv4),
      throwsArgumentError,
    );
  });

  test('the token is 256 random bits and never printed', () {
    final RemoteControlToken other = RemoteControlToken.generate();
    expect(token.reveal(), hasLength(43));
    expect(token.reveal(), matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
    expect(other.reveal(), isNot(token.reveal()));
    expect('$token', 'RemoteControlToken(redacted)');
    expect(token.matches(token.reveal()), isTrue);
    expect(token.matches(other.reveal()), isFalse);
    expect(token.matches(''), isFalse);
    expect(token.matches('${token.reveal()}x'), isFalse);
    expect(token.matches(token.reveal().substring(1)), isFalse);
  });

  test('status needs the bearer token and carries no secret', () async {
    port.generation = 3;
    expect((await send('GET', RemoteControlServer.statusPath, withAuth: false))
        .status, HttpStatus.unauthorized);
    expect(
        (await send('GET', RemoteControlServer.statusPath,
                auth: 'Bearer ${RemoteControlToken.generate().reveal()}'))
            .status,
        HttpStatus.unauthorized);
    expect(
        (await send('GET', RemoteControlServer.statusPath,
                auth: token.reveal()))
            .status,
        HttpStatus.unauthorized,
        reason: 'the Bearer scheme is required');

    final _Reply ok = await send('GET', RemoteControlServer.statusPath);
    expect(ok.status, HttpStatus.ok);
    expect(ok.json.keys, unorderedEquals(<String>[
      'schemaVersion',
      'sessionGeneration',
      'observedAt',
      'enabledActions'
    ]));
    expect(ok.json['sessionGeneration'], 3);
    expect(ok.json['enabledActions'], <String>['stop', 'panic']);
    expect(ok.headers.value('cache-control'), 'no-store');
  });

  test('authenticated STOP and PANIC reach the one runtime authority as remote',
      () async {
    final _Reply stop = await send('POST', RemoteControlServer.commandsPath,
        json: envelope('stop', id: 'studio-stop-1'));
    expect(stop.status, HttpStatus.ok);
    expect(stop.json['resultCode'], 'accepted');
    expect(stop.json['commandId'], 'studio-stop-1');
    final _Reply panic = await send('POST', RemoteControlServer.commandsPath,
        json: envelope('panic'));
    expect(panic.json['resultCode'], 'accepted');

    expect(port.commands.map((RuntimeCommand c) => c.kind), <RuntimeCommandKind>[
      RuntimeCommandKind.stop,
      RuntimeCommandKind.panic,
    ]);
    expect(port.commands.map((RuntimeCommand c) => c.origin),
        everyElement(ControlOrigin.remote));
    expect((port.commands.first as StopCommand).sessionId, 'session-1');
  });

  test('START, language, device connect/select and disconnect are denied',
      () async {
    for (final String action in <String>[
      'start',
      'languageChange',
      'deviceConnect',
      'deviceSelect',
      'deviceDisconnect',
    ]) {
      final _Reply reply = await send('POST', RemoteControlServer.commandsPath,
          json: envelope(action));
      expect(reply.json['resultCode'], 'deniedByPolicy', reason: action);
    }
    for (final Map<String, Object?> hostile in <Map<String, Object?>>[
      <String, Object?>{...envelope('stop'), 'lua': 'os.execute()'},
      <String, Object?>{...envelope('stop'), 'action': 'shell'},
      <String, Object?>{'action': 'panic'},
    ]) {
      final _Reply reply = await send('POST', RemoteControlServer.commandsPath,
          json: hostile);
      expect(reply.json['resultCode'], 'malformed');
    }
    expect(port.commands, isEmpty);
  });

  test('dedupe, replay, expiry and stale generation go through the gateway',
      () async {
    final Map<String, Object?> stop = envelope('stop', id: 'fixed-stop-1');
    await send('POST', RemoteControlServer.commandsPath, json: stop);
    expect(
        (await send('POST', RemoteControlServer.commandsPath, json: stop))
            .json['resultCode'],
        'duplicate');
    expect(
        (await send('POST', RemoteControlServer.commandsPath,
                json: envelope('panic', id: 'fixed-stop-1')))
            .json['resultCode'],
        'replayed');
    final int old = DateTime.now()
        .subtract(const Duration(minutes: 1))
        .microsecondsSinceEpoch;
    expect(
        (await send('POST', RemoteControlServer.commandsPath,
                json: envelope('panic', issuedAt: old)))
            .json['resultCode'],
        'expired');
    expect(
        (await send('POST', RemoteControlServer.commandsPath,
                json: envelope('stop', generation: 99)))
            .json['resultCode'],
        'staleGeneration');
    expect(port.commands, hasLength(1));
  });

  test('a foreign Host (DNS rebinding) is refused even with the token',
      () async {
    for (final String host in <String>['evil.example', '192.168.1.10']) {
      final _Reply reply = await send('POST', RemoteControlServer.commandsPath,
          json: envelope('panic'), host: host);
      expect(reply.status, HttpStatus.forbidden, reason: host);
      expect(reply.json['error'], 'hostNotAllowed');
    }
    expect(port.commands, isEmpty);
    expect(
        (await send('GET', RemoteControlServer.statusPath, host: 'localhost'))
            .status,
        HttpStatus.ok);
  });

  test('CORS: allow-listed origin only, and CORS is not authentication',
      () async {
    final _Reply foreign = await send('POST', RemoteControlServer.commandsPath,
        json: envelope('panic'), origin: 'https://evil.example');
    expect(foreign.status, HttpStatus.forbidden);
    expect(foreign.headers.value('access-control-allow-origin'), isNull);

    final _Reply noToken = await send('POST', RemoteControlServer.commandsPath,
        json: envelope('panic'), origin: studio, withAuth: false);
    expect(noToken.status, HttpStatus.unauthorized);
    expect(port.commands, isEmpty);

    final _Reply ok = await send('POST', RemoteControlServer.commandsPath,
        json: envelope('panic'), origin: studio);
    expect(ok.json['resultCode'], 'accepted');
    expect(ok.headers.value('access-control-allow-origin'), studio);
  });

  test('preflight grants only the path method to allow-listed origins',
      () async {
    final _Reply preflight = await send(
        'OPTIONS', RemoteControlServer.commandsPath,
        withAuth: false,
        origin: studio,
        headers: <String, String>{'access-control-request-method': 'POST'});
    expect(preflight.status, HttpStatus.noContent);
    expect(preflight.headers.value('access-control-allow-methods'), 'POST');
    expect(preflight.headers.value('access-control-allow-headers'),
        'authorization, content-type');

    for (final (String? origin, String method) in <(String?, String)>[
      ('https://evil.example', 'POST'),
      (studio, 'DELETE'),
      (null, 'POST'),
    ]) {
      final _Reply refused = await send(
          'OPTIONS', RemoteControlServer.commandsPath,
          withAuth: false,
          origin: origin,
          headers: <String, String>{'access-control-request-method': method});
      expect(refused.status, HttpStatus.forbidden, reason: '$origin $method');
    }
    expect(port.commands, isEmpty);
  });

  test('bounded, JSON-only bodies; unknown paths and methods refused',
      () async {
    final _Reply large = await send('POST', RemoteControlServer.commandsPath,
        rawBody: '{"x":"${'a' * 2048}"}');
    expect(large.status, HttpStatus.requestEntityTooLarge);
    final _Reply text = await send('POST', RemoteControlServer.commandsPath,
        rawBody: jsonEncode(envelope('panic')), contentType: 'text/plain');
    expect(text.status, HttpStatus.unsupportedMediaType);
    final _Reply garbage = await send('POST', RemoteControlServer.commandsPath,
        rawBody: '{not json');
    expect(garbage.json['resultCode'], 'malformed');

    expect((await send('GET', RemoteControlServer.commandsPath)).status,
        HttpStatus.methodNotAllowed);
    expect((await send('POST', RemoteControlServer.statusPath, json: <String, Object?>{})).status,
        HttpStatus.methodNotAllowed);
    expect((await send('GET', '/v1/runtime-events')).status,
        HttpStatus.notFound);
    expect((await send('GET', '${RemoteControlServer.statusPath}/x')).status,
        HttpStatus.notFound);
    expect(port.commands, isEmpty);
  });

  test('a body that never arrives times out without reaching the runtime',
      () async {
    final Socket socket =
        await Socket.connect(server.uri.host, server.uri.port);
    socket.write('POST ${RemoteControlServer.commandsPath} HTTP/1.1\r\n'
        'Host: 127.0.0.1\r\n'
        'Authorization: Bearer ${token.reveal()}\r\n'
        'Content-Type: application/json\r\n'
        'Content-Length: 200\r\n\r\n{"schemaVersion":1');
    final String reply = await utf8.decoder
        .bind(socket)
        .join()
        .timeout(const Duration(seconds: 5));
    socket.destroy();
    // The connection is ended (closed, or refused with a 4xx) and the slot
    // is released: the channel still answers afterwards.
    expect(reply, anyOf(isEmpty, startsWith('HTTP/1.1 4')));
    expect(port.commands, isEmpty);
    expect((await send('GET', RemoteControlServer.statusPath)).status,
        HttpStatus.ok);
  });

  test('golden: every response shape Studio must parse', () async {
    // Fixed clock and ids, so the file is stable. Studio's parser is tested
    // against it (apps/engineering-console/tests/remoteControl.test.ts).
    const int now = 1790000000000000;
    await server.close();
    port
      ..generation = 4
      ..rejectNext = false;
    server = await RemoteControlServer.start(
      RemoteControlGateway(port,
          clock: () => DateTime.fromMicrosecondsSinceEpoch(now),
          rateLimit: 3,
          enabledActions: <ControlAction>{
            ControlAction.stop,
            ControlAction.panic
          }),
      token: token,
      allowedOrigins: <String>{studio},
      maxFailedAuth: 2,
    );
    Map<String, Object?> at(String action, String id,
            {int issuedAt = now, int generation = 4, int schema = 1}) =>
        <String, Object?>{
          'schemaVersion': schema,
          'commandId': id,
          'issuedAt': issuedAt,
          'sessionGeneration': generation,
          'action': action,
        };
    final List<String> lines = <String>[];
    Future<void> record(String label, Future<_Reply> reply) async {
      final _Reply r = await reply;
      lines.add(jsonEncode(<String, Object?>{
        'label': label,
        'status': r.status,
        'body': r.json,
      }));
    }

    const String commands = RemoteControlServer.commandsPath;
    await record('status', send('GET', RemoteControlServer.statusPath));
    await record('accepted-stop',
        send('POST', commands, json: at('stop', 'golden-stop-1')));
    await record('duplicate',
        send('POST', commands, json: at('stop', 'golden-stop-1')));
    await record('replayed',
        send('POST', commands, json: at('panic', 'golden-stop-1')));
    await record('accepted-panic',
        send('POST', commands, json: at('panic', 'golden-panic-1')));
    await record('denied-start',
        send('POST', commands, json: at('start', 'golden-start-1')));
    await record('denied-device-disconnect',
        send('POST', commands, json: at('deviceDisconnect', 'golden-disc-1')));
    await record(
        'expired',
        send('POST', commands,
            json: at('panic', 'golden-old-1', issuedAt: now - 60000000)));
    await record(
        'not-yet-valid',
        send('POST', commands,
            json: at('panic', 'golden-future-1', issuedAt: now + 60000000)));
    await record('stale-generation',
        send('POST', commands, json: at('stop', 'golden-stale-1', generation: 3)));
    await record('malformed',
        send('POST', commands, json: <String, Object?>{'action': 'panic'}));
    await record('unsupported-schema',
        send('POST', commands, json: at('panic', 'golden-v2-1', schema: 2)));
    port.rejectNext = true;
    await record('rejected-by-runtime',
        send('POST', commands, json: at('stop', 'golden-rej-1')));
    await record('rate-limited',
        send('POST', commands, json: at('stop', 'golden-rate-1')));
    await record(
        'origin-not-allowed',
        send('POST', commands,
            json: at('panic', 'golden-origin-1'),
            origin: 'https://evil.example'));
    await record('host-not-allowed',
        send('GET', RemoteControlServer.statusPath, host: 'evil.example'));
    await record('too-large',
        send('POST', commands, rawBody: '{"x":"${'a' * 2048}"}'));
    await record('unauthorized',
        send('GET', RemoteControlServer.statusPath, auth: 'Bearer wrong'));
    await record('unauthorized',
        send('GET', RemoteControlServer.statusPath, auth: 'Bearer wrong'));
    await record('control-locked', send('GET', RemoteControlServer.statusPath));

    _golden('control-results.v1.ndjson', lines);
  });

  test('repeated failed authentication locks the channel (fail-closed)',
      () async {
    await server.close();
    server = await startServer(maxFailedAuth: 3);
    for (int i = 0; i < 3; i++) {
      expect(
          (await send('POST', RemoteControlServer.commandsPath,
                  json: envelope('panic'), auth: 'Bearer wrong-$i'))
              .status,
          HttpStatus.unauthorized);
    }
    expect(server.locked, isTrue);
    expect(locks, 1);
    final _Reply after = await send('POST', RemoteControlServer.commandsPath,
        json: envelope('panic'));
    expect(after.status, HttpStatus.forbidden);
    expect(after.json['error'], 'controlLocked');
    expect(port.commands, isEmpty, reason: 'even the right token is refused');
  });
}

final class _Reply {
  _Reply(this.status, this.body, this.headers);

  final int status;
  final String body;
  final HttpHeaders headers;

  Map<String, Object?> get json =>
      (jsonDecode(body) as Map<Object?, Object?>).cast<String, Object?>();
}

final class _Port implements RuntimeControlPort {
  final List<RuntimeCommand> commands = <RuntimeCommand>[];
  String? active;
  int generation = 0;
  bool rejectNext = false;

  @override
  Stream<CommandResult> get results => const Stream<CommandResult>.empty();
  @override
  LanguageState get language => const LanguageState(
      effective: null, pending: TranslationDirection.englishToSpanish);
  @override
  String? get activeSessionId => active;
  @override
  int get sessionGeneration => generation;
  @override
  Future<CommandResult> execute(RuntimeCommand command) async {
    commands.add(command);
    final bool reject = rejectNext;
    rejectNext = false;
    return CommandResult(
      commandId: command.commandId,
      kind: command.kind,
      origin: command.origin,
      status: reject ? CommandStatus.rejected : CommandStatus.accepted,
      rejection: reject ? CommandRejection.noActiveSession : null,
      observedAtMicros: 1,
    );
  }
}

const String _goldenDir = '../../apps/engineering-console/tests/fixtures';

void _golden(String name, List<String> lines) {
  final File file = File('$_goldenDir/$name');
  final String content = '${lines.join('\n')}\n';
  if (Platform.environment['HORIZON_UPDATE_GOLDEN'] == '1') {
    file.createSync(recursive: true);
    file.writeAsStringSync(content);
  }
  expect(file.existsSync(), isTrue,
      reason: 'run with HORIZON_UPDATE_GOLDEN=1 to create $name');
  expect(file.readAsStringSync(), content,
      reason: 'golden drift: regenerate with HORIZON_UPDATE_GOLDEN=1');
}
