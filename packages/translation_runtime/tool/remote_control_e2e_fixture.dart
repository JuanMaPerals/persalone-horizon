// Test-only fixture for the Studio E2E (apps/engineering-console/e2e): the
// real RemoteControlServer and RemoteControlGateway, as composed on the
// phone (STOP and PANIC enabled), in front of a port that only records what
// reaches it. A second loopback endpoint lets the test read that record.
// Never shipped; the token is a fixed test value passed on the command line.
import 'dart:convert';
import 'dart:io';

import 'package:persalone_contracts/persalone_contracts.dart';
import 'package:persalone_translation_runtime/persalone_translation_runtime.dart';

Future<void> main(List<String> args) async {
  String option(String name) {
    final int index = args.indexOf('--$name');
    if (index < 0 || index + 1 >= args.length) {
      stderr.writeln('missing --$name');
      exit(64);
    }
    return args[index + 1];
  }

  final _RecordingPort port = _RecordingPort();
  final RemoteControlServer server = await RemoteControlServer.start(
    RemoteControlGateway(port, enabledActions: <ControlAction>{
      ControlAction.stop,
      ControlAction.panic,
    }),
    token: RemoteControlToken.forTesting(option('token')),
    port: int.parse(option('port')),
    allowedOrigins: <String>{option('allow-origin')},
  );
  final HttpServer probe = await HttpServer.bind(
      InternetAddress.loopbackIPv4, int.parse(option('probe-port')));
  probe.listen((HttpRequest request) async {
    request.response
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(<String, Object?>{
        'commands': <Map<String, String>>[
          for (final RuntimeCommand c in port.commands)
            <String, String>{'kind': c.kind.name, 'origin': c.origin.name},
        ],
      }));
    await request.response.close();
  });
  stdout.writeln('REMOTE_CONTROL_FIXTURE ${server.uri}');
  await ProcessSignal.sigterm.watch().first;
  await server.close();
  await probe.close(force: true);
}

final class _RecordingPort implements RuntimeControlPort {
  final List<RuntimeCommand> commands = <RuntimeCommand>[];

  @override
  Stream<CommandResult> get results => const Stream<CommandResult>.empty();
  @override
  LanguageState get language => const LanguageState(
      effective: null, pending: TranslationDirection.englishToSpanish);
  @override
  String? get activeSessionId => 'e2e-session';
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
      observedAtMicros: DateTime.now().microsecondsSinceEpoch,
    );
  }
}
