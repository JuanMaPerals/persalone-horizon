import 'package:persalone_contracts/persalone_contracts.dart';

typedef RemoteStopHandler = Future<CommandResult> Function(StopCommand command);
typedef RemotePanicHandler = Future<CommandResult> Function(PanicCommand command);

/// Preserves the single runtime authority while routing remote safety actions
/// through the phone-level cleanup path. The transport/gateway still owns
/// authentication, replay/expiry checks and the remote action allow-list.
final class FullDeviceRemoteControlPort implements RuntimeControlPort {
  FullDeviceRemoteControlPort(
    this._delegate, {
    required RemoteStopHandler onRemoteStop,
    required RemotePanicHandler onRemotePanic,
  })  : _onRemoteStop = onRemoteStop,
        _onRemotePanic = onRemotePanic;

  final RuntimeControlPort _delegate;
  final RemoteStopHandler _onRemoteStop;
  final RemotePanicHandler _onRemotePanic;

  @override
  Stream<CommandResult> get results => _delegate.results;

  @override
  LanguageState get language => _delegate.language;

  @override
  String? get activeSessionId => _delegate.activeSessionId;

  @override
  int get sessionGeneration => _delegate.sessionGeneration;

  @override
  Future<CommandResult> execute(RuntimeCommand command) {
    if (command.origin == ControlOrigin.remote) {
      if (command is PanicCommand) return _onRemotePanic(command);
      if (command is StopCommand) return _onRemoteStop(command);
    }
    return _delegate.execute(command);
  }
}
