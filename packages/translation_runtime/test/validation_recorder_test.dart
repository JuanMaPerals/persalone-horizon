import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:persalone_contracts/persalone_contracts.dart';
import 'package:persalone_translation_runtime/persalone_translation_runtime.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late StreamController<RuntimeEvent> events;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('horizon_validation_test_');
    events = StreamController<RuntimeEvent>.broadcast(sync: true);
  });

  tearDown(() async {
    await events.close();
    dir.deleteSync(recursive: true);
  });

  RuntimeEvent state(int seq) => RuntimeEvent.sessionState(
        streamSequence: seq,
        observedAtMicros: seq,
        state: RuntimeSessionState.listening,
        sessionId: 's',
        streamEpoch: 1,
      );

  test('records redacted v1 lines and a coded sidecar', () async {
    final ValidationRecorder recorder = await ValidationRecorder.open(
        dir, events.stream,
        runId: 'run-1');
    events
      ..add(state(1))
      ..add(RuntimeEvent.diagnostic(
        streamSequence: 2,
        diagnostic: const LiveTranslationDiagnostic(
          code: LiveTranslationDiagnosticCode.selfEchoSuspected,
          component: 'runtime',
          observedAtMicros: 2,
          detail: 'Model heard "hola amigo"',
        ),
      ));
    recorder.updateMeta(<String, Object>{
      'audioSource': 'voiceCommunication',
      'aecEnabled': true,
    });
    await recorder.close();

    final List<String> lines = recorder.eventsFile.readAsLinesSync();
    expect(lines, hasLength(2));
    expect(lines.map((String l) => (jsonDecode(l) as Map)['schema']),
        everyElement(runtimeEventSchema));
    expect(lines.join('\n'), isNot(contains('hola')));
    final Map<String, Object?> meta =
        jsonDecode(recorder.metaFile.readAsStringSync()) as Map<String, Object?>;
    expect(meta['schema'], validationMetaSchema);
    expect(meta['lines'], 2);
    expect(meta['truncated'], isFalse);
    expect(meta['audioSource'], 'voiceCommunication');
    expect(meta['aecEnabled'], isTrue);
  });

  test('metadata refuses free text', () async {
    final ValidationRecorder recorder =
        await ValidationRecorder.open(dir, events.stream, runId: 'run-2');
    expect(() => recorder.updateMeta(<String, Object>{'note': 'hola amigo'}),
        throwsArgumentError);
    expect(() => recorder.updateMeta(<String, Object>{'with space': true}),
        throwsArgumentError);
    expect(() => recorder.updateMeta(<String, Object>{'ratio': 0.5}),
        throwsArgumentError);
    await recorder.close();
    expect(recorder.metaFile.readAsStringSync(), isNot(contains('hola')));
  });

  test('the event file is bounded and the sidecar says truncated', () async {
    final ValidationRecorder recorder = await ValidationRecorder.open(
        dir, events.stream,
        runId: 'run-3', maxBytes: 1000);
    for (int i = 1; i <= 100; i++) {
      events.add(state(i));
    }
    await recorder.close();
    expect(recorder.eventsFile.lengthSync(), lessThanOrEqualTo(1000));
    expect(recorder.truncated, isTrue);
    final Map<String, Object?> meta =
        jsonDecode(recorder.metaFile.readAsStringSync()) as Map<String, Object?>;
    expect(meta['truncated'], isTrue);
    expect(meta['lines'], recorder.lines);
  });

  test('a run id must be a coded token', () {
    expect(
      () => ValidationRecorder.open(dir, events.stream, runId: '../escape'),
      throwsArgumentError,
    );
  });
}
