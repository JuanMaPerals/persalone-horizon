import 'dart:collection';

import 'package:persalone_contracts/persalone_contracts.dart';

/// Domain gateway for untrusted remote control commands. It has no transport
/// and no authentication: a future authenticated channel hands it decoded
/// JSON and returns the redacted result.
///
/// Validation order: strict parse -> duplicate/replay -> expiry -> policy
/// matrix -> rate limit -> session generation -> runtime. PANIC skips the
/// ordinary rate limit and the generation check (a late Panic can only make
/// the system safer) but is still deduplicated and expires.
final class RemoteControlGateway {
  RemoteControlGateway(
    this._port, {
    DateTime Function()? clock,
    this.expiry = const Duration(seconds: 30),
    this.futureSkew = const Duration(seconds: 5),
    this.rateLimit = 5,
    this.rateWindow = const Duration(seconds: 10),
    this.memory = 1024,
  }) : _clock = clock ?? DateTime.now;

  final RuntimeControlPort _port;
  final DateTime Function() _clock;
  final Duration expiry;
  final Duration futureSkew;
  final int rateLimit;
  final Duration rateWindow;
  final int memory;

  final LinkedHashMap<String, (String, int)> _seen =
      LinkedHashMap<String, (String, int)>();
  final ListQueue<int> _recent = ListQueue<int>();

  Future<ControlCommandResult> submit(Object? raw) async {
    final int now = _clock().microsecondsSinceEpoch;
    _forget(now);
    final ControlCommandEnvelope envelope;
    try {
      envelope = ControlCommandEnvelope.parse(raw);
    } on ControlEnvelopeError catch (error) {
      return _result(error.code, now);
    }

    final (String, int)? previous = _seen[envelope.commandId];
    if (previous != null) {
      return _result(
        previous.$1 == envelope.fingerprint
            ? ControlResultCode.duplicate
            : ControlResultCode.replayed,
        now,
        envelope,
      );
    }
    _seen[envelope.commandId] = (envelope.fingerprint, now);
    while (_seen.length > memory) {
      _seen.remove(_seen.keys.first);
    }

    if (now - envelope.issuedAtMicros > expiry.inMicroseconds) {
      return _result(ControlResultCode.expired, now, envelope);
    }
    if (envelope.issuedAtMicros - now > futureSkew.inMicroseconds) {
      return _result(ControlResultCode.notYetValid, now, envelope);
    }
    if (!RemoteControlPolicy.allows(envelope.action)) {
      return _result(ControlResultCode.deniedByPolicy, now, envelope);
    }
    final bool panic = envelope.action == ControlAction.panic;
    if (!panic) {
      while (_recent.isNotEmpty &&
          now - _recent.first > rateWindow.inMicroseconds) {
        _recent.removeFirst();
      }
      if (_recent.length >= rateLimit) {
        return _result(ControlResultCode.rateLimited, now, envelope);
      }
      _recent.add(now);
      if (envelope.sessionGeneration != _port.sessionGeneration) {
        return _result(ControlResultCode.staleGeneration, now, envelope);
      }
    }

    final String commandId = 'remote:${envelope.commandId}';
    final RuntimeCommand command = switch (envelope.action) {
      ControlAction.panic =>
        PanicCommand(commandId: commandId, origin: ControlOrigin.remote),
      ControlAction.deviceDisconnect => DeviceDisconnectCommand(
          commandId: commandId, origin: ControlOrigin.remote),
      ControlAction.stop => StopCommand(
          commandId: commandId,
          origin: ControlOrigin.remote,
          sessionId: _port.activeSessionId ?? '',
        ),
      // Unreachable: denied by the policy matrix above.
      ControlAction.start ||
      ControlAction.languageChange ||
      ControlAction.deviceConnect ||
      ControlAction.deviceSelect =>
        throw StateError('policy matrix violated'),
    };
    final CommandResult result = await _port.execute(command);
    return _result(
      result.status == CommandStatus.accepted
          ? ControlResultCode.accepted
          : ControlResultCode.rejectedByRuntime,
      _clock().microsecondsSinceEpoch,
      envelope,
    );
  }

  void _forget(int now) {
    final int horizon = (expiry + futureSkew).inMicroseconds;
    while (_seen.isNotEmpty && now - _seen.values.first.$2 > horizon) {
      _seen.remove(_seen.keys.first);
    }
  }

  ControlCommandResult _result(ControlResultCode code, int now,
          [ControlCommandEnvelope? envelope]) =>
      ControlCommandResult(
        resultCode: code,
        observedAtMicros: now,
        sessionGeneration: _port.sessionGeneration,
        commandId: envelope?.commandId,
        action: envelope?.action,
      );
}
