import 'dart:async';
import 'dart:io';

import 'package:persalone_horizon_companion/horizon_companion.dart';

/// Usage:
/// ```text
/// dart run bin/horizon_companion.dart --workspace DIR
///   [--port 47810] [--python VENV_PYTHON] [--bridge halo_emulator_bridge.py]
///   [--allow-origin http://127.0.0.1:5173]... [--token TOKEN]
/// ```
///
/// `--token` fixes the pairing token (automated tests only); by default a
/// random token is generated on every start.
///
/// Prints one line `HORIZON_COMPANION_READY url=URL token=TOKEN`;
/// paste the token into Studio to pair. The API listens on loopback only.
Future<void> main(List<String> args) async {
  final Map<String, List<String>> opts = <String, List<String>>{};
  for (int i = 0; i < args.length; i++) {
    final String a = args[i];
    if (!a.startsWith('--') || i + 1 >= args.length) {
      stderr.writeln('invalid argument: $a');
      exitCode = 64;
      return;
    }
    opts.putIfAbsent(a.substring(2), () => <String>[]).add(args[++i]);
  }
  final String? workspace = opts['workspace']?.last;
  if (workspace == null) {
    stderr.writeln('--workspace is required');
    exitCode = 64;
    return;
  }
  final Set<String> origins = <String>{
    ...?opts['allow-origin'],
    if (opts['allow-origin'] == null) ...<String>['http://127.0.0.1:5173', 'http://localhost:5173'],
  };
  final CompanionApi api = await CompanionApi.start(
    workspace: Workspace(Directory(workspace)),
    emulator: EmulatorConfig(
      python: opts['python']?.last ?? Platform.environment['HORIZON_E2E_PYTHON'],
      bridgeScript: opts['bridge']?.last,
    ),
    port: int.parse(opts['port']?.last ?? '47810'),
    allowedOrigins: origins,
    token: opts['token']?.last,
  );
  stdout.writeln('HORIZON_COMPANION_READY url=${api.uri} token=${api.token}');
  unawaited(ProcessSignal.sigint.watch().first.then((_) async {
    await api.close();
    exit(0);
  }));
}
