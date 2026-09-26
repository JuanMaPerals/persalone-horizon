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
}
