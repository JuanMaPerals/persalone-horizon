import 'dart:io';

import 'package:persalone_contracts/persalone_contracts.dart';
import 'package:persalone_translation_runtime/persalone_translation_runtime.dart';

import 'live_stream_config.dart';

/// Studio -> phone control channel of a build that opts in with
/// `--dart-define=HORIZON_REMOTE_CONTROL=true` (off by default).
///
/// It composes existing pieces only: the [RemoteControlGateway] over the same
/// [RuntimeControlPort] the phone's buttons use (one authority), behind the
/// authenticated loopback [RemoteControlServer]. Enabled actions: STOP and
/// PANIC. DEVICE_DISCONNECT is not needed by the phone validation path and
/// stays off; START, language and device connect/select are denied by the
/// policy matrix itself.
///
/// The per-launch token is written only to app-private storage
/// ([tokenFile]), readable from the computer with
/// `adb exec-out run-as <package> cat <path>` (debuggable build, authorised
/// USB debugging); other apps on the phone cannot read it. It is never shown,
/// logged or sent anywhere, and it is deleted on [close].
final class StudioRemoteControl {
  StudioRemoteControl._(this.server, this.tokenFile);

  static const Set<ControlAction> enabledActions = <ControlAction>{
    ControlAction.stop,
    ControlAction.panic,
  };

  final RemoteControlServer server;
  final File tokenFile;

  static Future<StudioRemoteControl> start(
    RuntimeControlPort control, {
    required LiveStreamConfig config,
    required Directory tokenDirectory,
    void Function()? onLocked,
  }) async {
    final File tokenFile = File('${tokenDirectory.path}/token');
    // A token from an earlier launch must never outlive it.
    if (tokenFile.existsSync()) tokenFile.deleteSync();
    final RemoteControlToken token = RemoteControlToken.generate();
    final RemoteControlServer server = await RemoteControlServer.start(
      RemoteControlGateway(control, enabledActions: enabledActions),
      token: token,
      port: config.port,
      allowedOrigins: config.allowedOrigins,
      onLocked: onLocked,
    );
    try {
      tokenDirectory.createSync(recursive: true);
      tokenFile.writeAsStringSync(token.reveal(), flush: true);
    } on Object {
      await server.close();
      rethrow;
    }
    return StudioRemoteControl._(server, tokenFile);
  }

  Future<void> close() async {
    await server.close();
    if (tokenFile.existsSync()) tokenFile.deleteSync();
  }
}
