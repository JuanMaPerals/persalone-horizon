import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:persalone_contracts/persalone_contracts.dart';

import 'runtime_event_stream.dart';

/// Wire schema of the validation run sidecar.
const String validationMetaSchema = 'horizon.validation-meta.v1';

/// Records a physical validation run to local files: the already redacted
/// `horizon.runtime-event.v1` stream as NDJSON (the Engineering Console loads
/// it offline), and a sidecar with coded run metadata (capture source, echo
/// canceller). No audio, transcript or translation can reach either file:
/// events are redacted by construction and metadata accepts only booleans,
/// integers and short coded tokens. The event file is bounded; when the cap is
/// hit, recording stops and the sidecar says `truncated: true`.
final class ValidationRecorder {
  ValidationRecorder._(this.runId, this.eventsFile, this.metaFile, this._sink,
      this._maxBytes);

  static const int defaultMaxBytes = 8 * 1024 * 1024;
  static final RegExp _token = RegExp(r'^[A-Za-z0-9_.:-]{1,64}$');

  final String runId;
  final File eventsFile;
  final File metaFile;
  final IOSink _sink;
  final int _maxBytes;
  final Map<String, Object> _meta = <String, Object>{};
  StreamSubscription<RuntimeEvent>? _subscription;
  int _bytes = 0;
  int _lines = 0;
  bool _truncated = false;
  bool _closed = false;

  int get lines => _lines;
  bool get truncated => _truncated;

  static Future<ValidationRecorder> open(
    Directory directory,
    Stream<RuntimeEvent> events, {
    String? runId,
    int maxBytes = defaultMaxBytes,
  }) async {
    await directory.create(recursive: true);
    final String id = runId ?? 'run-${DateTime.now().toUtc().millisecondsSinceEpoch}';
    if (!_token.hasMatch(id)) {
      throw ArgumentError.value(id, 'runId', 'must be a coded token');
    }
    final File eventsFile = File('${directory.path}/$id.ndjson');
    final File metaFile = File('${directory.path}/$id.meta.json');
    final ValidationRecorder recorder = ValidationRecorder._(
        id, eventsFile, metaFile, eventsFile.openWrite(), maxBytes);
    recorder._writeMeta();
    recorder._subscription = events.listen(recorder._onEvent);
    return recorder;
  }

  /// Merges coded metadata (e.g. the capture configuration) into the sidecar.
  /// Free text is refused so nothing personal can be recorded by mistake.
  void updateMeta(Map<String, Object> values) {
    for (final MapEntry<String, Object> entry in values.entries) {
      final Object value = entry.value;
      final bool coded = value is bool ||
          value is int ||
          (value is String && _token.hasMatch(value));
      if (!_token.hasMatch(entry.key) || !coded) {
        throw ArgumentError.value(
            entry.key, 'values', 'metadata must be coded (bool/int/token)');
      }
    }
    _meta.addAll(values);
    _writeMeta();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription?.cancel();
    await _sink.flush();
    await _sink.close();
    _writeMeta();
  }

  void _onEvent(RuntimeEvent event) {
    if (_closed || _truncated) return;
    final String line = '${RuntimeEventStream.encodeLine(event)}\n';
    final int size = utf8.encode(line).length;
    if (_bytes + size > _maxBytes) {
      _truncated = true;
      _writeMeta();
      return;
    }
    _bytes += size;
    _lines++;
    _sink.write(line);
  }

  void _writeMeta() {
    metaFile.writeAsStringSync(jsonEncode(<String, Object>{
      'schema': validationMetaSchema,
      'eventSchema': runtimeEventSchema,
      'runId': runId,
      'lines': _lines,
      'truncated': _truncated,
      ..._meta,
    }));
  }
}
