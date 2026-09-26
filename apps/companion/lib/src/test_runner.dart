import 'dart:io';
import 'dart:typed_data';

import 'package:persalone_halo_core/persalone_halo_core.dart';

import 'api_error.dart';
import 'app_manifest.dart';
import 'app_run_host.dart';
import 'emulator_session.dart';
import 'workspace.dart';

const String companionVersion = '0.1.0';
const String testResultSchema = 'horizon.test-result.v1';

/// Runs the hello-display scenario on a fresh official-emulator instance and
/// records a result in the architecture §4.2 format: separate data
/// provenance, target, providers, outcome, evidence, assertions, metrics and
/// hashed artifacts. It never reports HALO_REAL.
final class HelloDisplayTestRunner {
  HelloDisplayTestRunner(this._workspace, this._config);

  final Workspace _workspace;
  final EmulatorConfig _config;

  Future<Map<String, Object?>> run(String projectId) async {
    final HorizonAppManifest manifest = await _workspace.loadManifest(projectId);
    final String runId = Workspace.newId('t');
    final DateTime started = DateTime.now().toUtc();
    final Stopwatch wall = Stopwatch()..start();
    final List<Map<String, Object?>> assertions = <Map<String, Object?>>[];
    final Map<String, Uint8List> artifacts = <String, Uint8List>{};
    final List<Map<String, Object?>> artifactIndex = <Map<String, Object?>>[];
    List<Map<String, Object?>> metrics = <Map<String, Object?>>[];
    String outcome;
    String? blockedReason;
    String? emulatorVersion;

    void check(String id, Object? expected, Object? actual, {bool? pass}) {
      assertions.add(<String, Object?>{
        'id': id,
        'expected': expected,
        'actual': actual,
        'status': (pass ?? expected == actual) ? 'PASS' : 'FAIL',
      });
    }

    void keep(String name, FrameCapture f) {
      artifacts[name] = f.png;
      artifactIndex.add(<String, Object?>{
        'name': name,
        'sha256': f.pngSha256,
        'bytes': f.png.length,
        'kind': 'framebuffer-png',
      });
    }

    // Static checks need no emulator.
    final HaloCaptionComposition c = manifest.composition;
    check('manifest.valid', true, true);
    check('composition.noLoss', c.normalisedText, c.reconstructed);
    final String expectedValue = HaloCaptionComposition.resultValue(c);

    EmulatorSession? session;
    try {
      session = await EmulatorSession.open(_config,
          caption: manifest.caption, advanceOn: manifest.advanceOn);
      emulatorVersion = session.emulatorVersion;
      final FrameCapture first = await session.frame();
      keep('page-1.png', first);
      check('display.page1Visible', 'lit > 0', 'lit = ${first.lit}', pass: first.lit > 0);
      final bool inside = first.outside == 0 &&
          first.bbox != null &&
          first.bbox![0] > 0 &&
          first.bbox![2] < 255;
      check('display.insideVisibleCircle', 'outside = 0, bbox within x 1..254',
          'outside = ${first.outside}, bbox = ${first.bbox}', pass: inside);
      final String shownValue = await session.showPage(0);
      check('glyphs.reported', expectedValue, shownValue);

      final ButtonOutcome press = await session.press(manifest.advanceOn);
      check('button.deviceReport', <String>['btn:${manifest.advanceOn}'],
          press.deviceReports, pass: _sameList(press.deviceReports, <String>['btn:${manifest.advanceOn}']));
      final FrameCapture afterPress = await session.frame();
      if (c.pageCount > 1) {
        keep('page-2.png', afterPress);
        check('button.advancesPage', 'page 2/${c.pageCount}, frame changed',
            'page ${press.page + 1}/${c.pageCount}, frame ${afterPress.pixelSha256 == first.pixelSha256 ? 'unchanged' : 'changed'}',
            pass: press.page == 1 && afterPress.pixelSha256 != first.pixelSha256);
      } else {
        check('button.advancesPage', 'single page: wraps to page 1, frame unchanged',
            'page ${press.page + 1}/1, frame ${afterPress.pixelSha256 == first.pixelSha256 ? 'unchanged' : 'changed'}',
            pass: press.page == 0 && afterPress.pixelSha256 == first.pixelSha256);
      }

      final String other = buttonGestures.firstWhere((String g) => g != manifest.advanceOn);
      final int pageBefore = session.page;
      final ButtonOutcome ignored = await session.press(other);
      final FrameCapture afterOther = await session.frame();
      check('button.otherGestureIgnored',
          'device reports btn:$other, page and frame unchanged',
          'device reports ${ignored.deviceReports}, page ${ignored.page + 1}, frame ${afterOther.pixelSha256 == afterPress.pixelSha256 ? 'unchanged' : 'changed'}',
          pass: _sameList(ignored.deviceReports, <String>['btn:$other']) &&
              !ignored.advanced &&
              ignored.page == pageBefore &&
              afterOther.pixelSha256 == afterPress.pixelSha256);

      final FrameCapture cleared = await session.clearAndCapture();
      check('stop.clearsDisplay', 'lit = 0', 'lit = ${cleared.lit}', pass: cleared.lit == 0);
      metrics = session.metrics();
      outcome = assertions.every((Map<String, Object?> a) => a['status'] == 'PASS')
          ? 'PASS'
          : 'FAIL';
    } on ApiError catch (e) {
      if (e.code != 'emulatorBlocked') rethrow;
      outcome = 'BLOCKED';
      blockedReason = '${e.params['reason']}';
    } finally {
      await session?.close();
    }

    final Map<String, Object?> result = <String, Object?>{
      'schema': testResultSchema,
      'runId': runId,
      'projectId': projectId,
      'appId': manifest.appId,
      'appVersion': manifest.version,
      'appDigest': manifest.digest,
      'scenario': 'hello-display.default',
      'startedAt': started.toIso8601String(),
      'finishedAt': DateTime.now().toUtc().toIso8601String(),
      'durationMs': wall.elapsedMilliseconds,
      'data': <String, Object?>{
        'provenance': 'SYNTHETIC',
        'source': 'authored-caption',
        'inputs': <String, Object?>{
          'captionChars': manifest.caption.length,
          'pageCount': c.pageCount,
          'foldedGlyphs': c.foldedChars,
          'replacedGlyphs': c.unrenderableChars,
          'advanceOn': manifest.advanceOn,
        },
        'seed': null,
      },
      'target': 'EMULATED',
      'environment': <String, Object?>{
        'emulator': 'halo-emulator',
        'emulatorVersion': emulatorVersion,
        'companionVersion': companionVersion,
        'dart': Platform.version.split(' ').first,
        'os': Platform.operatingSystem,
      },
      'providers': providersV1,
      'outcome': outcome,
      'blockedReason': blockedReason,
      'evidence': outcome == 'BLOCKED' ? 'UNKNOWN' : 'MEASURED',
      'evidenceScope': 'software behaviour on the official emulator; not Halo hardware',
      'assertions': assertions,
      'metrics': metrics,
      'artifacts': artifactIndex,
    };
    await _workspace.saveResult(projectId, runId, result, artifacts);
    return result;
  }

  static bool _sameList(List<String> a, List<String> b) =>
      a.length == b.length && Iterable<int>.generate(a.length).every((int i) => a[i] == b[i]);
}
