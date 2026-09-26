import 'dart:async';
import 'dart:io';

import 'package:persalone_contracts/persalone_contracts.dart';
import 'package:persalone_horizon_companion/horizon_companion.dart';
import 'package:test/test.dart';

final String? _python = Platform.environment['HORIZON_E2E_PYTHON'];
final bool _required = Platform.environment['HORIZON_E2E_REQUIRED'] == '1';
final String _bridge =
    '${Directory.current.path}/../../tooling/e2e/halo_emulator_bridge.py';

String? get _skip => _python != null || _required
    ? null
    : 'official emulator not configured: set HORIZON_E2E_PYTHON';

void main() {
  test(
    'shared authority: Panic cancels an in-flight test button and suppresses stale effects',
    skip: _skip,
    () async {
      if (_python == null) {
        fail('HORIZON_E2E_REQUIRED=1 but no HORIZON_E2E_PYTHON');
      }

      final Directory dir =
          Directory.systemTemp.createTempSync('companion_authority_');
      final Workspace workspace = Workspace(dir);
      final Completer<void> buttonReported = Completer<void>();
      final Completer<void> releaseButton = Completer<void>();
      final EmulatorConfig config = EmulatorConfig(
        python: _python,
        bridgeScript: _bridge,
        afterButtonReport: () async {
          if (!buttonReported.isCompleted) buttonReported.complete();
          await releaseButton.future;
        },
      );
      final AppRunHost host = AppRunHost(workspace, config);
      final HelloDisplayTestRunner runner =
          HelloDisplayTestRunner(workspace, host);
      final List<Map<String, Object?>> events = <Map<String, Object?>>[];
      final StreamSubscription<RuntimeEvent> sub =
          host.events.events.listen((RuntimeEvent event) {
        events.add(event.toJson());
      });

      try {
        final String projectId = await workspace.createProject(
          HorizonAppManifest.helloDisplay(
            appId: 'local.authority-panic',
            name: 'Authority Panic',
          ),
        );

        final Future<Map<String, Object?>> testFuture = runner.run(projectId);

        // The official emulator has reported the physical-style button event,
        // but the host has not yet applied any page-advance effect.
        await buttonReported.future.timeout(const Duration(seconds: 20));

        // Calling an async function executes synchronously until its first
        // await: Panic invalidates the generation before waiting for the
        // serialized in-flight operation to drain.
        final Future<Map<String, Object?>> panicFuture = host.panic();
        await Future<void>.delayed(Duration.zero);
        releaseButton.complete();

        final Map<String, Object?> result =
            await testFuture.timeout(const Duration(seconds: 20));
        final Map<String, Object?> panic =
            await panicFuture.timeout(const Duration(seconds: 20));

        expect(result['outcome'], 'CANCELLED');
        expect(result['blockedReason'], 'runNotActive');
        expect(result['evidence'], 'UNKNOWN');
        expect((panic['stoppedRuns']! as List<Object?>), hasLength(1));

        final int panicIndex = events.indexWhere(
          (Map<String, Object?> e) =>
              e['kind'] == 'diagnostic' && e['code'] == 'panicExecuted',
        );
        expect(panicIndex, greaterThanOrEqualTo(0));

        // After Panic invalidates the generation, no stale input or caption
        // effect from that old generation may be published. Lifecycle
        // stopping/stopped events are expected and are the recovery evidence.
        final Iterable<Map<String, Object?>> afterPanic =
            events.skip(panicIndex + 1);
        expect(
          afterPanic.where(
            (Map<String, Object?> e) =>
                e['kind'] == 'diagnostic' && e['code'] == 'inputButton',
          ),
          isEmpty,
        );
        expect(
          afterPanic.where(
            (Map<String, Object?> e) => e['kind'] == 'caption',
          ),
          isEmpty,
        );

        final List<Map<String, Object?>> persisted =
            await workspace.results(projectId);
        expect(persisted, hasLength(1));
        expect(persisted.single['outcome'], 'CANCELLED');
      } finally {
        if (!releaseButton.isCompleted) releaseButton.complete();
        await sub.cancel();
        await host.dispose();
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      }
    },
  );

  group('one authority under concurrency (official emulator)', () {
    late Directory dir;
    late Workspace workspace;
    late AppRunHost host;
    late List<Map<String, Object?>> events;
    late StreamSubscription<RuntimeEvent> sub;
    Completer<void>? buttonReported;
    Completer<void>? releaseButton;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('companion_concurrency_');
      workspace = Workspace(dir);
      buttonReported = null;
      releaseButton = null;
      host = AppRunHost(
        workspace,
        EmulatorConfig(
          python: _python,
          bridgeScript: _bridge,
          afterButtonReport: () async {
            final Completer<void>? reported = buttonReported;
            if (reported != null && !reported.isCompleted) reported.complete();
            await releaseButton?.future;
          },
        ),
      );
      events = <Map<String, Object?>>[];
      sub = host.events.events
          .listen((RuntimeEvent event) => events.add(event.toJson()));
    });

    tearDown(() async {
      final Completer<void>? release = releaseButton;
      if (release != null && !release.isCompleted) release.complete();
      await sub.cancel();
      await host.dispose();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    Future<String> project(String id) => workspace.createProject(
        HorizonAppManifest.helloDisplay(appId: 'local.$id', name: id));

    Matcher apiError(String code) =>
        isA<ApiError>().having((ApiError e) => e.code, 'code', code);

    test('a Start requested before Panic never runs after it', skip: _skip,
        () async {
      final String projectId = await project('start-vs-panic');
      // start() runs synchronously up to its first await (manifest load);
      // the Panic lands in that window.
      final Future<AppRun> start = host.start(projectId);
      final Map<String, Object?> panic = await host.panic();

      await expectLater(start, throwsA(apiError('runCancelledByPanic')));
      expect(panic['stoppedRuns'], isEmpty);
      expect(
          events.where((Map<String, Object?> e) =>
              e['kind'] == 'sessionState' && e['state'] == 'listening'),
          isEmpty,
          reason: 'no run may reach listening after the Panic');
      // The authority is usable again right away.
      final AppRun next = await host.start(projectId);
      expect(next.state, RunState.running);
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('Panic || Panic: each resolves only once the run is closed',
        skip: _skip, () async {
      final AppRun run = await host.start(await project('double-panic'));
      final Future<Map<String, Object?>> first = host.panic();
      final Future<Map<String, Object?>> second = host.panic();

      final Map<String, Object?> secondResult = await second;
      expect(run.state, RunState.stopped,
          reason: 'the second Panic must not report before the close ends');
      final Map<String, Object?> firstResult = await first;
      expect(run.state, RunState.stopped);
      expect(firstResult['stoppedRuns'], <String>[run.runId]);
      expect(secondResult['stoppedRuns'], <String>[run.runId]);
      expect(secondResult['generation'] as int,
          greaterThan(firstResult['generation'] as int));
      expect(
          events.where((Map<String, Object?> e) =>
              e['kind'] == 'sessionState' && e['state'] == 'stopped'),
          hasLength(1),
          reason: 'one close, shared by both Panics');
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('Stop || Panic: Panic waits for the Stop already in flight',
        skip: _skip, () async {
      final AppRun run = await host.start(await project('stop-vs-panic'));
      final Future<AppRun> stop = host.stop(run.runId);
      final Map<String, Object?> panic = await host.panic();

      expect(run.state, RunState.stopped);
      expect(panic['stoppedRuns'], <String>[run.runId]);
      expect(await stop, same(run));
      expect(run.stopReason, 'userStop', reason: 'the first reason is kept');
      expect(() => host.frame(run.runId), throwsA(apiError('runNotActive')));
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('Test Lab cannot keep the device while Studio takes the lease',
        skip: _skip, () async {
      final HelloDisplayTestRunner runner =
          HelloDisplayTestRunner(workspace, host);
      final String testProject = await project('lab-run');
      final String studioProject = await project('studio-run');
      buttonReported = Completer<void>();
      releaseButton = Completer<void>();

      final Future<Map<String, Object?>> test = runner.run(testProject);
      await buttonReported!.future.timeout(const Duration(seconds: 30));
      // Studio starts while the Test Lab press is in flight; release the
      // device report only once the lease authority has begun superseding
      // the Test Lab run (after Studio's manifest load).
      final Future<AppRun> studio = host.start(studioProject);
      final DateTime deadline = DateTime.now().add(const Duration(seconds: 20));
      while (!events.any((Map<String, Object?> e) =>
          e['kind'] == 'sessionState' && e['state'] == 'stopping')) {
        if (DateTime.now().isAfter(deadline)) fail('Test Lab run never superseded');
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      releaseButton!.complete();

      final Map<String, Object?> result =
          await test.timeout(const Duration(seconds: 30));
      final AppRun studioRun = await studio.timeout(const Duration(seconds: 30));
      expect(result['outcome'], 'CANCELLED');
      expect(result['evidence'], 'UNKNOWN');
      expect(studioRun.state, RunState.running);
      // The superseded Test Lab press published no page advance.
      expect(
          events.where((Map<String, Object?> e) =>
              e['kind'] == 'diagnostic' && e['code'] == 'inputButton'),
          isEmpty);
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('Studio cannot act on a run the Test Lab superseded', skip: _skip,
        () async {
      final HelloDisplayTestRunner runner =
          HelloDisplayTestRunner(workspace, host);
      final AppRun studioRun = await host.start(await project('studio-first'));
      final Map<String, Object?> result =
          await runner.run(await project('lab-second'));

      expect(result['outcome'], isNot('CANCELLED'));
      expect(studioRun.state, RunState.stopped);
      expect(studioRun.stopReason, 'superseded');
      expect(() => host.press(studioRun.runId, 'singlePress'),
          throwsA(apiError('runNotActive')));
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('restart after Panic succeeds 10/10', skip: _skip, () async {
      final String projectId = await project('restart');
      for (int i = 0; i < 10; i++) {
        final AppRun run = await host.start(projectId);
        final FrameCapture frame = await host.frame(run.runId);
        expect(frame, isNotNull, reason: 'attempt ${i + 1}');
        final Map<String, Object?> panic = await host.panic();
        expect(panic['stoppedRuns'], <String>[run.runId],
            reason: 'attempt ${i + 1}');
        expect(run.state, RunState.stopped, reason: 'attempt ${i + 1}');
      }
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}
