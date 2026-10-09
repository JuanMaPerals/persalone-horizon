import 'package:flutter_test/flutter_test.dart';
import 'package:persalone_contracts/persalone_contracts.dart';
import 'package:persalone_mobile/full_device_remote_control.dart';

void main() {
  test('remote STOP and PANIC use phone-level handlers', () async {
    final _Port delegate = _Port();
    final List<RuntimeCommand> safety = <RuntimeCommand>[];
    final FullDeviceRemoteControlPort port = FullDeviceRemoteControlPort(
      delegate,
      onRemoteStop: (StopCommand command) async {
        safety.add(command);
        return delegate.accept(command);
      },
      onRemotePanic: (PanicCommand command) async {
        safety.add(command);
        return delegate.accept(command);
      },
    );

    await port.execute(const StopCommand(
      commandId: 'remote-stop',
      origin: ControlOrigin.remote,
      sessionId: 'session-1',
    ));
    await port.execute(const PanicCommand(
      commandId: 'remote-panic',
      origin: ControlOrigin.remote,
    ));

    expect(safety.map((command) => command.kind),
        <RuntimeCommandKind>[RuntimeCommandKind.stop, RuntimeCommandKind.panic]);
    expect(delegate.direct, isEmpty,
        reason: 'remote safety commands must not bypass phone cleanup');
  });

  test('local and non-safety commands stay on the delegate', () async {
    final _Port delegate = _Port();
    final FullDeviceRemoteControlPort port = FullDeviceRemoteControlPort(
      delegate,
      onRemoteStop: delegate.accept,
      onRemotePanic: delegate.accept,
    );

    await port.execute(const PanicCommand(
      commandId: 'local-panic',
      origin: ControlOrigin.local,
    ));
    await port.execute(const DeviceDisconnectCommand(
      commandId: 'remote-disconnect',
      origin: ControlOrigin.remote,
    ));

    expect(delegate.direct, hasLength(2));
  });
}

final class _Port implements RuntimeControlPort {
  final List<RuntimeCommand> direct = <RuntimeCommand>[];

  @override
  Stream<CommandResult> get results => const Stream<CommandResult>.empty();

  @override
  LanguageState get language => const LanguageState(
      effective: null, pending: TranslationDirection.englishToSpanish);

  @override
  String? get activeSessionId => 'session-1';

  @override
  int get sessionGeneration => 7;

  Future<CommandResult> accept(RuntimeCommand command) async => CommandResult(
        commandId: command.commandId,
        kind: command.kind,
        origin: command.origin,
        status: CommandStatus.accepted,
        observedAtMicros: 1,
      );

  @override
  Future<CommandResult> execute(RuntimeCommand command) async {
    direct.add(command);
    return accept(command);
  }
}
