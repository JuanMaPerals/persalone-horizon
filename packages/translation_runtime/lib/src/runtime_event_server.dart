import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:persalone_contracts/persalone_contracts.dart';

import 'runtime_event_stream.dart';

/// Transport protocol of the live stream (framing, hello, heartbeat, resume).
/// The event payload schema is [runtimeEventSchema].
const String runtimeStreamProtocol = 'horizon.runtime-stream.v1';

/// Read-only Server-Sent Events endpoint for the redacted runtime events.
///
/// It serves `GET /v1/runtime-events` only and never reads a request body, so
/// it cannot carry commands. It binds to loopback only: exposing it beyond
/// the host requires the authenticated channel designed with the control API.
///
/// Frames: `hello` (protocol, schema, streamId, replay mode), `runtime`
/// (`id: <streamId>:<seq>`), `heartbeat`, and `overflow` before a slow
/// consumer is disconnected. A client resumes with `Last-Event-ID`; an id from
/// another stream (runtime restarted) or outside the replay window gets a
/// `reset` replay so it discards previous state.
final class RuntimeEventServer {
  RuntimeEventServer._(
    this._server,
    this.streamId,
    this._replayCapacity,
    this._clientQueueLimit,
    this._maxClients,
    this._allowedOrigins,
  );

  static const String path = '/v1/runtime-events';

  final HttpServer _server;
  final String streamId;
  final int _replayCapacity;
  final int _clientQueueLimit;
  final int _maxClients;
  final Set<String> _allowedOrigins;
  final ListQueue<(int, String)> _replay = ListQueue<(int, String)>();
  final Set<_Client> _clients = <_Client>{};
  StreamSubscription<RuntimeEvent>? _eventsSubscription;
  Timer? _heartbeat;
  bool _truncated = false;
  int _lastSeq = 0;

  static Future<RuntimeEventServer> start(
    Stream<RuntimeEvent> events, {
    InternetAddress? address,
    int port = 0,
    Duration heartbeat = const Duration(seconds: 1),
    int replayCapacity = 1024,
    int clientQueueLimit = 256,
    int maxClients = 8,
    Set<String> allowedOrigins = const <String>{},
    String? streamId,
  }) async {
    final InternetAddress bind = address ?? InternetAddress.loopbackIPv4;
    if (!bind.isLoopback) {
      throw ArgumentError.value(bind.address, 'address',
          'the read-only runtime stream is loopback-only until an authenticated transport exists');
    }
    final RuntimeEventServer server = RuntimeEventServer._(
      await HttpServer.bind(bind, port),
      streamId ?? _newStreamId(),
      replayCapacity,
      clientQueueLimit,
      maxClients,
      allowedOrigins,
    );
    server._run(events, heartbeat);
    return server;
  }

  Uri get uri => Uri(
        scheme: 'http',
        host: _server.address.address,
        port: _server.port,
        path: path,
      );

  int get clientCount => _clients.length;

  Future<void> close() async {
    _heartbeat?.cancel();
    await _eventsSubscription?.cancel();
    for (final _Client client in List<_Client>.of(_clients)) {
      await client.close();
    }
    await _server.close(force: true);
  }

  void _run(Stream<RuntimeEvent> events, Duration heartbeat) {
    _eventsSubscription = events.listen((RuntimeEvent event) {
      _lastSeq = event.streamSequence;
      final String frame = 'id: $streamId:${event.streamSequence}\n'
          'event: runtime\n'
          'data: ${RuntimeEventStream.encodeLine(event)}\n\n';
      _replay.add((event.streamSequence, frame));
      if (_replay.length > _replayCapacity) {
        _replay.removeFirst();
        _truncated = true;
      }
      for (final _Client client in List<_Client>.of(_clients)) {
        client.enqueue(frame);
      }
    });
    _heartbeat = Timer.periodic(heartbeat, (_) {
      final String frame =
          'event: heartbeat\ndata: ${jsonEncode(<String, Object?>{
            'streamId': streamId,
            'lastSeq': _lastSeq,
          })}\n\n';
      for (final _Client client in List<_Client>.of(_clients)) {
        client.enqueue(frame);
      }
    });
    _server.listen(_handle);
  }

  Future<void> _handle(HttpRequest request) async {
    final HttpResponse response = request.response;
    response.headers
      ..set('cache-control', 'no-store')
      ..set('x-content-type-options', 'nosniff');
    if (request.uri.path != path) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    if (request.method != 'GET') {
      response
        ..statusCode = HttpStatus.methodNotAllowed
        ..headers.set('allow', 'GET');
      await response.close();
      return;
    }
    final String? origin = request.headers.value('origin');
    if (origin != null) {
      if (!_allowedOrigins.contains(origin)) {
        response.statusCode = HttpStatus.forbidden;
        await response.close();
        return;
      }
      response.headers
        ..set('access-control-allow-origin', origin)
        ..set('vary', 'origin');
    }
    if (_clients.length >= _maxClients) {
      response.statusCode = HttpStatus.serviceUnavailable;
      await response.close();
      return;
    }
    response
      ..headers.contentType =
          ContentType('text', 'event-stream', charset: 'utf-8')
      ..bufferOutput = false;

    final (String, int)? resume =
        _parseLastEventId(request.headers.value('last-event-id'));
    final bool canResume = resume != null &&
        resume.$1 == streamId &&
        (_replay.isEmpty || resume.$2 >= _replay.first.$1 - 1);
    final String mode =
        canResume ? 'resume' : (resume == null ? 'full' : 'reset');
    final Iterable<String> frames = _replay
        .where(((int, String) entry) => !canResume || entry.$1 > resume.$2)
        .map(((int, String) entry) => entry.$2);

    final _Client client = _Client(response, _clientQueueLimit, streamId);
    _clients.add(client);
    unawaited(client.done.then((_) => _clients.remove(client)));
    client.enqueue(
      'event: hello\ndata: ${jsonEncode(<String, Object?>{
            'protocol': runtimeStreamProtocol,
            'schema': runtimeEventSchema,
            'streamId': streamId,
            'lastSeq': _lastSeq,
            'replay': mode,
            'truncated': !canResume && _truncated,
          })}\n\n',
      live: false,
    );
    for (final String frame in frames) {
      client.enqueue(frame, live: false);
    }
  }

  static (String, int)? _parseLastEventId(String? value) {
    if (value == null) return null;
    final int split = value.lastIndexOf(':');
    if (split <= 0) return ('', -1);
    final int? seq = int.tryParse(value.substring(split + 1));
    return seq == null ? ('', -1) : (value.substring(0, split), seq);
  }

  static String _newStreamId() {
    final Random random = Random.secure();
    return List<String>.generate(
            16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'))
        .join();
  }
}

/// One subscriber. Live frames are bounded; a consumer that falls behind is
/// sent `overflow` and disconnected so it resynchronises instead of reading
/// stale state. Replay frames are bounded by the server's replay capacity.
final class _Client {
  _Client(this._response, this._limit, this._streamId) {
    _response.done.then((_) => _finish(), onError: (Object _) => _finish());
  }

  final HttpResponse _response;
  final int _limit;
  final String _streamId;
  final ListQueue<(String, bool)> _queue = ListQueue<(String, bool)>();
  final Completer<void> _done = Completer<void>();
  int _liveQueued = 0;
  bool _pumping = false;
  bool _closeAfterDrain = false;
  bool _closed = false;

  Future<void> get done => _done.future;

  void enqueue(String frame, {bool live = true}) {
    if (_closed || _closeAfterDrain) return;
    if (live && _liveQueued >= _limit) {
      _queue
        ..clear()
        ..add((
          'event: overflow\ndata: ${jsonEncode(<String, Object?>{
                'streamId': _streamId,
                'reason': 'slowConsumer',
              })}\n\n',
          false
        ));
      _liveQueued = 0;
      _closeAfterDrain = true;
    } else {
      _queue.add((frame, live));
      if (live) _liveQueued++;
    }
    unawaited(_pump());
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_queue.isNotEmpty && !_closed) {
        final (String frame, bool live) = _queue.removeFirst();
        _response.write(frame);
        await _response.flush();
        if (live && _liveQueued > 0) _liveQueued--;
      }
      if (_closeAfterDrain) await close();
    } on Object {
      await close();
    } finally {
      _pumping = false;
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _response.close();
    } on Object {
      // The peer is already gone.
    }
    _finish();
  }

  void _finish() {
    _closed = true;
    if (!_done.isCompleted) _done.complete();
  }
}
