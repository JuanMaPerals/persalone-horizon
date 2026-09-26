import 'dart:async';
import 'dart:collection';

import 'package:persalone_contracts/persalone_contracts.dart';

import 'horizon_translation_runtime.dart';

/// Domain implementation of [RuntimeControlPort] over the G5 runtime. It has
/// no network surface: callers invoke [execute] directly.
///
/// - Remote commands are limited to STOP, PANIC and DEVICE disconnect.
/// - Normal commands run one at a time; PANIC bypasses the queue and every
///   command queued before it is rejected as [CommandRejection.supersededByPanic].
/// - Language changes only affect the next session ([LanguageState.pending]).
final class HorizonRuntimeController implements RuntimeControlPort {
  HorizonRuntimeController({
    required HorizonTranslationRuntime runtime,
    DeviceAdapterPort? device,
    TranslationDirection initialLanguage =
        TranslationDirection.englishToSpanish,
    DateTime Function()? clock,
  })  : _runtime = runtime,
        _device = device,
        _pending = initialLanguage,
        _clock = clock ?? DateTime.now {
    _subscriptions.add(runtime.snapshots.listen((snapshot) {
      // A session that fails or stops by itself is no longer active.
      if (snapshot.state == HorizonTranslationRuntimeState.failed ||
          snapshot.state == HorizonTranslationRuntimeState.stopped) {
        _endSession();
      }
    }));
    final DeviceAdapterPort? port = device;
    if (port != null) {
      _subscriptions.add(port.discoveries.listen(
        (DeviceDiscovery discovery) =>
            _discovered[discovery.deviceId] = discovery,
      ));
    }
  }

  static const int _rememberedCommandIds = 256;

  final HorizonTranslationRuntime _runtime;
  final DeviceAdapterPort? _device;
  final DateTime Function() _clock;
  final StreamController<CommandResult> _results =
      StreamController<CommandResult>.broadcast();
  final List<StreamSubscription<Object>> _subscriptions =
      <StreamSubscription<Object>>[];
  final LinkedHashSet<String> _seenCommandIds = LinkedHashSet<String>();
  final Map<String, DeviceDiscovery> _discovered = <String, DeviceDiscovery>{};
  Future<void> _queue = Future<void>.value();
  int _panicGeneration = 0;
  int _sessionCounter = 0;
  TranslationDirection _pending;
  TranslationDirection? _effective;
  TranslationSession? _active;

  @override
  Stream<CommandResult> get results => _results.stream;

  @override
  LanguageState get language =>
      LanguageState(effective: _effective, pending: _pending);

  @override
  String? get activeSessionId => _active?.sessionId;

  @override
  Future<CommandResult> execute(RuntimeCommand command) {
    if (!_remember(command.commandId)) {
      return Future<CommandResult>.value(
          _reject(command, CommandRejection.duplicateCommand));
    }
    if (command.origin == ControlOrigin.remote && !command.remoteAllowed) {
      return Future<CommandResult>.value(
          _reject(command, CommandRejection.remoteNotAllowed));
    }
    if (command is PanicCommand) {
      _panicGeneration++;
      return _panic(command);
    }
    final int generation = _panicGeneration;
    final Future<CommandResult> result = _queue.then((_) {
      if (generation != _panicGeneration) {
        return _reject(command, CommandRejection.supersededByPanic);
      }
      return _run(command);
    });
    _queue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<void> dispose() async {
    for (final StreamSubscription<Object> subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _results.close();
  }

  Future<CommandResult> _run(RuntimeCommand command) async {
    switch (command) {
      case StartCommand():
        return _start(command);
      case StopCommand():
        return _stop(command);
      case SetLanguageCommand():
        if (_sessionActive) {
          return _reject(command, CommandRejection.sessionActive);
        }
        _pending = command.direction;
        return _accept(command);
      case DeviceSelectCommand():
        return _selectDevice(command);
      case DeviceDisconnectCommand():
        return _disconnectDevice(command);
      case PanicCommand():
        return _panic(command);
    }
  }

  Future<CommandResult> _start(StartCommand command) async {
    if (_sessionActive) {
      return _reject(command, CommandRejection.sessionActive);
    }
    if (!command.consent.localProcessingAllowed) {
      return _reject(command, CommandRejection.consentRequired);
    }
    final int now = _clock().microsecondsSinceEpoch;
    final TranslationDirection direction = _pending;
    final TranslationSession session = TranslationSession(
      sessionId: 'session-$now-${++_sessionCounter}',
      streamEpoch: now,
      direction: direction,
      privacyGeneration: now,
    );
    final (String source, String target) =
        direction == TranslationDirection.englishToSpanish
            ? ('en-US', 'es-ES')
            : ('es-ES', 'en-US');
    _active = session;
    _effective = direction;
    try {
      await _runtime.start(
        config: LiveTranslationConfig(
          session: session,
          sourceLocale: source,
          targetLocale: target,
          consent: command.consent,
        ),
        audioSession: AudioSessionDescriptor(
          sessionId: session.sessionId,
          streamEpoch: session.streamEpoch,
          streamId: 'microphone-live',
        ),
      );
      return _accept(command);
    } on RuntimeError catch (error) {
      _endSession();
      return _reject(command, CommandRejection.runtimeRejected,
          runtimeError: error.code);
    } on Object {
      _endSession();
      return _reject(command, CommandRejection.runtimeRejected,
          runtimeError: RuntimeErrorCode.providerUnavailable);
    }
  }

  Future<CommandResult> _stop(StopCommand command) async {
    final TranslationSession? active = _active;
    if (active == null) {
      return _reject(command, CommandRejection.noActiveSession);
    }
    if (active.sessionId != command.sessionId) {
      return _reject(command, CommandRejection.sessionMismatch);
    }
    await _runtime.stop();
    _endSession();
    return _accept(command);
  }

  Future<CommandResult> _panic(PanicCommand command) async {
    final List<String> failed = await _runtime.panic();
    _endSession();
    return _accept(command, failedCleanup: failed);
  }

  Future<CommandResult> _selectDevice(DeviceSelectCommand command) async {
    final DeviceAdapterPort? device = _device;
    final DeviceDiscovery? discovery = _discovered[command.deviceId];
    if (device == null || discovery == null) {
      return _reject(command, CommandRejection.deviceUnavailable);
    }
    try {
      await device.connect(discovery);
      return _accept(command);
    } on RuntimeError catch (error) {
      return _reject(command, CommandRejection.deviceUnavailable,
          runtimeError: error.code);
    } on Object {
      return _reject(command, CommandRejection.deviceUnavailable);
    }
  }

  Future<CommandResult> _disconnectDevice(
      DeviceDisconnectCommand command) async {
    final DeviceAdapterPort? device = _device;
    if (device == null) {
      return _reject(command, CommandRejection.deviceUnavailable);
    }
    try {
      await device.disconnect();
      return _accept(command);
    } on RuntimeError catch (error) {
      return _reject(command, CommandRejection.deviceUnavailable,
          runtimeError: error.code);
    } on Object {
      return _reject(command, CommandRejection.deviceUnavailable);
    }
  }

  bool get _sessionActive =>
      _active != null ||
      _runtime.state == HorizonTranslationRuntimeState.preparing ||
      _runtime.state == HorizonTranslationRuntimeState.listening ||
      _runtime.state == HorizonTranslationRuntimeState.stopping;

  void _endSession() {
    _active = null;
    _effective = null;
  }

  bool _remember(String commandId) {
    if (!_seenCommandIds.add(commandId)) return false;
    if (_seenCommandIds.length > _rememberedCommandIds) {
      _seenCommandIds.remove(_seenCommandIds.first);
    }
    return true;
  }

  CommandResult _accept(RuntimeCommand command,
          {List<String> failedCleanup = const <String>[]}) =>
      _publish(CommandResult(
        commandId: command.commandId,
        kind: command.kind,
        origin: command.origin,
        status: CommandStatus.accepted,
        observedAtMicros: _clock().microsecondsSinceEpoch,
        failedCleanup: List<String>.unmodifiable(failedCleanup),
      ));

  CommandResult _reject(RuntimeCommand command, CommandRejection rejection,
          {RuntimeErrorCode? runtimeError}) =>
      _publish(CommandResult(
        commandId: command.commandId,
        kind: command.kind,
        origin: command.origin,
        status: CommandStatus.rejected,
        observedAtMicros: _clock().microsecondsSinceEpoch,
        rejection: rejection,
        runtimeError: runtimeError,
      ));

  CommandResult _publish(CommandResult result) {
    if (!_results.isClosed) _results.add(result);
    return result;
  }
}
