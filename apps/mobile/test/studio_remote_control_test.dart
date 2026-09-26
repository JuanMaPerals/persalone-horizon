import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:persalone_contracts/persalone_contracts.dart';
import 'package:persalone_mobile/live_stream_config.dart';
import 'package:persalone_mobile/studio_remote_control.dart';

void main() {
  late Directory dir;
  late _Port port;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('studio-control-');
    port = _Port();
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<StudioRemoteControl> start() => StudioRemoteControl.start(
        port,
        config: const LiveStreamConfig(port: 0, allowedOrigins: <String>{}),
        tokenDirectory: Directory('${dir.path}/horizon-control'),
      );

  Future<(int, Map<String, Object?>)> call(StudioRemoteControl control,
      String method, String path,
      {String? token, Object? json}) async {
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest request =
          await client.openUrl(method, control.server.uri.replace(path: path));
      if (token != null) request.headers.set('authorization', 'Bearer $token');
      if (json != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(json));
      }
      final HttpClientResponse response = await request.close();
      final Object? body = jsonDecode(await utf8.decodeStream(response));
      return (
        response.statusCode,
        (body! as Map<Object?, Object?>).cast<String, Object?>()
      );
    } finally {
      client.close(force: true);
    }
  }

  Map<String, Object?> envelope(String action, String id) => <String, Object?>{
        'schemaVersion': 1,
        'commandId': id,
        'issuedAt': DateTime.now().microsecondsSinceEpoch,
        'sessionGeneration': port.sessionGeneration,
        'action': action,
      };

  test('the token lives only in the app-private file and authenticates',
      () async {
    final StudioRemoteControl control = await start();
    addTearDown(control.close);
    final String token = control.tokenFile.readAsStringSync();
    expect(token, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
    expect(control.tokenFile.path, endsWith('/horizon-control/token'));
    expect('${control.server}', isNot(contains(token)));

    expect((await call(control, 'GET', '/v1/control/status')).$1,
        HttpStatus.unauthorized);
    final (int status, Map<String, Object?> body) =
        await call(control, 'GET', '/v1/control/status', token: token);
    expect(status, HttpStatus.ok);
    expect(body['enabledActions'], <String>['stop', 'panic']);
  });

  test('only STOP and PANIC are enabled; DEVICE_DISCONNECT is not', () async {
    final StudioRemoteControl control = await start();
    addTearDown(control.close);
    final String token = control.tokenFile.readAsStringSync();
    for (final String action in <String>[
      'deviceDisconnect',
      'start',
      'languageChange',
      'deviceConnect',
      'deviceSelect'
    ]) {
      final (_, Map<String, Object?> body) = await call(
          control, 'POST', '/v1/control/commands',
          token: token, json: envelope(action, 'denied-$action'));
      expect(body['resultCode'], 'deniedByPolicy', reason: action);
    }
    expect(port.commands, isEmpty);
    final (_, Map<String, Object?> panic) = await call(
        control, 'POST', '/v1/control/commands',
        token: token, json: envelope('panic', 'remote-panic-1'));
    expect(panic['resultCode'], 'accepted');
    expect(port.commands.single, isA<PanicCommand>());
  });

  test('each launch rotates the token; close deletes it', () async {
    final StudioRemoteControl first = await start();
    final String firstToken = first.tokenFile.readAsStringSync();
    await first.close();
    expect(first.tokenFile.existsSync(), isFalse);

    final StudioRemoteControl second = await start();
    addTearDown(second.close);
    final String secondToken = second.tokenFile.readAsStringSync();
    expect(secondToken, isNot(firstToken));
    expect(
        (await call(second, 'GET', '/v1/control/status', token: firstToken))
            .$1,
        HttpStatus.unauthorized);
  });

  test('a token left by an earlier launch is replaced, never reused', () async {
    final File stale = File('${dir.path}/horizon-control/token')
      ..createSync(recursive: true)
      ..writeAsStringSync('stale-token-from-an-earlier-launch');
    final StudioRemoteControl control = await start();
    addTearDown(control.close);
    expect(stale.readAsStringSync(), isNot('stale-token-from-an-earlier-launch'));
    expect(
        (await call(control, 'GET', '/v1/control/status',
                token: 'stale-token-from-an-earlier-launch'))
            .$1,
        HttpStatus.unauthorized);
  });

  test('the control port defaults next to the live stream', () {
    expect(LiveStreamConfig.defaultControlPort, 47801);
    expect(LiveStreamConfig.defaultControlPort,
        isNot(LiveStreamConfig.defaultPort));
  });
}

final class _Port implements RuntimeControlPort {
  final List<RuntimeCommand> commands = <RuntimeCommand>[];

  @override
  Stream<CommandResult> get results => const Stream<CommandResult>.empty();
  @override
  LanguageState get language => const LanguageState(
      effective: null, pending: TranslationDirection.englishToSpanish);
  @override
  String? get activeSessionId => 'session-1';
  @override
  int get sessionGeneration => 1;
  @override
  Future<CommandResult> execute(RuntimeCommand command) async {
    commands.add(command);
    return CommandResult(
      commandId: command.commandId,
      kind: command.kind,
      origin: command.origin,
      status: CommandStatus.accepted,
      observedAtMicros: 1,
    );
  }
}
