import 'dart:async';

import 'package:persalone_contracts/persalone_contracts.dart';

import 'api_error.dart';
import 'app_manifest.dart';
import 'emulator_session.dart';
import 'run_events.dart';
import 'workspace.dart';

/// State of an interactive app run as reported to Studio.
enum RunState { running, stopped, failed }

final class AppRun {
  AppRun._(this.runId, this.projectId, this.appDigest, this.generation,
      this.session, this.startedAt);

  final String runId;
  final String projectId;
  final String appDigest;
  final int generation;
  final EmulatorSession session;
  final DateTime startedAt;
  RunState state = RunState.running;
  String? stopReason;
  int _turn = 0;
  final List<Map<String, Object?>> events = <Map<String, Object?>>[];
  int _seq = 0;
  Future<void> _queue = Future<void>.value();

  void _event(String type, [Map<String, Object?> detail = const <String, Object?>{}]) {
    events.add(<String, Object?>{
      'seq': ++_seq,
      'at': DateTime.now().toUtc().toIso8601String(),
      'type': type,
      ...detail,
    });
    if (events.length > 200) events.removeAt(0);
  }

  /// Operations on one run are serialized: a button press never interleaves
  /// with a frame read or a stop.
  Future<T> _serial<T>(Future<T> Function() op) {
    final Completer<T> done = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        done.complete(await op());
      } catch (e, s) {
        done.completeError(e, s);
      }
    });
    return done.future;
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'runId': runId,
        'projectId': projectId,
        'appDigest': appDigest,
        'generation': generation,
        'state': state.name,
        'stopReason': stopReason,
        'target': 'EMULATED',
        'environment': session.environment.name.toUpperCase(),
        'providers': providersV1,
        'data': 'SYNTHETIC',
        'page': session.page + 1,
        'pageCount': session.pageCount,
        'advanceOn': session.advanceOn,
        'startedAt': startedAt.toIso8601String(),
        'metrics': session.metrics(),
        'events': events,
      };
}

/// Stage-by-stage provider truth for a hello-display run: nothing is
/// translated or spoken, the HUD and button are the official emulator.
const Map<String, String> providersV1 = <String, String>{
  'stt': 'NOT_USED',
  'translation': 'NOT_USED',
  'tts': 'NOT_USED',
  'display': 'EMULATED',
  'button': 'EMULATED',
};

/// The single authority for app runs in this host (architecture §3): one
/// exclusive device lease, a generation per run, serialized operations and a
/// Panic that stops everything without waiting for the UI.
final class AppRunHost {
  AppRunHost(this._workspace, this._config, [RunEventSource? events])
      : events = events ?? RunEventSource();

  final Workspace _workspace;
  final EmulatorConfig _config;

  /// Canonical runtime events of every run (served read-only over SSE).
  final RunEventSource events;
  final Map<String, AppRun> _runs = <String, AppRun>{};
  AppRun? _leaseHolder;
  int _generation = 0;

  EmulatorConfig get config => _config;

  AppRun get(String runId) =>
      _runs[Workspace.checkId(runId)] ?? (throw const ApiError(404, 'notFound'));

  Future<AppRun> start(String projectId) async {
    final HorizonAppManifest manifest = await _workspace.loadManifest(projectId);
    // Exclusive lease: a new interactive run releases the previous device.
    final AppRun? previous = _leaseHolder;
    if (previous != null) await stop(previous.runId, reason: 'superseded');
    final int generation = ++_generation;
    final String runId = Workspace.newId('r');
    events.sessionState(runId, generation, RuntimeSessionState.preparing);
    final EmulatorSession session;
    try {
      session = await EmulatorSession.open(_config,
          caption: manifest.caption,
          advanceOn: manifest.advanceOn,
          // The emulator transport always declares EMULATED.
          onDeviceSnapshot: (DeviceAdapterSnapshot s) =>
              events.device(s, ExecutionEnvironment.emulated));
    } on Object {
      events.sessionState(runId, generation, RuntimeSessionState.failed);
      rethrow;
    }
    if (generation != _generation) {
      // A Panic arrived while the emulator was starting.
      await session.close();
      events.sessionState(runId, generation, RuntimeSessionState.stopped);
      throw const ApiError(409, 'runCancelledByPanic');
    }
    final AppRun run = AppRun._(runId, projectId, manifest.digest, generation,
        session, DateTime.now().toUtc());
    events.captionShown(runId, generation, ++run._turn, session.lastShown!,
        session.environment);
    events.sessionState(runId, generation, RuntimeSessionState.listening);
    run._event('runStarted', <String, Object?>{'page': 1, 'pageCount': session.pageCount});
    _runs[run.runId] = run;
    _leaseHolder = run;
    return run;
  }

  Future<ButtonOutcome> press(String runId, String gesture) {
    final AppRun run = _active(runId);
    return run._serial(() async {
      _ensureCurrent(run);
      final ButtonOutcome o = await run.session.press(
        gesture,
        isCurrent: () => _isCurrent(run),
      );
      // Panic invalidates the generation immediately. Never publish a device
      // result that completed after that invalidation.
      _ensureCurrent(run);
      for (final String report in o.deviceReports) {
        events.diagnostic(LiveTranslationDiagnosticCode.inputButton, 'halo-button',
            runId: run.runId,
            generation: run.generation,
            sequence: run._turn,
            detail: report.startsWith('btn:') ? report.substring(4) : 'unknown');
      }
      if (o.advanced) {
        events.captionShown(run.runId, run.generation, ++run._turn,
            run.session.lastShown!, run.session.environment);
      }
      run._event('button', <String, Object?>{
        'gesture': gesture,
        'deviceReports': o.deviceReports,
        'advanced': o.advanced,
        'page': o.page + 1,
      });
      return o;
    });
  }

  Future<FrameCapture> frame(String runId) {
    final AppRun run = _active(runId);
    return run._serial(() async {
      _ensureCurrent(run);
      final FrameCapture capture = await run.session.frame();
      _ensureCurrent(run);
      return capture;
    });
  }

  /// Test-only product operation used by the canonical test runner. It stays
  /// behind the same lease, queue and generation guards as Studio actions.
  Future<FrameCapture> clearAndCapture(String runId) {
    final AppRun run = _active(runId);
    return run._serial(() async {
      _ensureCurrent(run);
      final FrameCapture capture = await run.session.clearAndCapture();
      _ensureCurrent(run);
      return capture;
    });
  }

  Future<AppRun> stop(String runId, {String reason = 'userStop'}) async {
    final AppRun run = get(runId);
    if (run.state != RunState.running) return run;
    events.sessionState(run.runId, run.generation, RuntimeSessionState.stopping);
    await run._serial(() async {
      await run.session.close();
      run.state = RunState.stopped;
      run.stopReason = reason;
      run._event('runStopped', <String, Object?>{'reason': reason});
    });
    events.sessionState(run.runId, run.generation, RuntimeSessionState.stopped);
    if (identical(_leaseHolder, run)) _leaseHolder = null;
    return run;
  }

  /// Emergency stop: invalidates the generation first (in-flight starts are
  /// cancelled), then closes every run and clears its display.
  Future<Map<String, Object?>> panic() async {
    _generation++;
    events.diagnostic(LiveTranslationDiagnosticCode.panicExecuted, 'companion');
    final List<String> stopped = <String>[];
    for (final AppRun run in _runs.values.toList()) {
      if (run.state == RunState.running) {
        await stop(run.runId, reason: 'panic');
        stopped.add(run.runId);
      }
    }
    _leaseHolder = null;
    return <String, Object?>{'stoppedRuns': stopped, 'generation': _generation};
  }

  Future<void> dispose() async {
    await panic();
  }

  AppRun _active(String runId) {
    final AppRun run = get(runId);
    if (run.state != RunState.running) throw const ApiError(409, 'runNotActive');
    return run;
  }

  bool _isCurrent(AppRun run) =>
      run.generation == _generation && run.state == RunState.running;

  void _ensureCurrent(AppRun run) {
    if (!_isCurrent(run)) {
      throw const ApiError(409, 'runNotActive');
    }
  }
}
