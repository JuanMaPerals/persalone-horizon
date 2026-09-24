import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:persalone_contracts/persalone_contracts.dart';
import 'package:persalone_translation_runtime/persalone_translation_runtime.dart';
import 'package:test/test.dart';

void main() {
  late StreamController<RuntimeEvent> events;
  late RuntimeEventServer server;
  int seq = 0;

  RuntimeEvent state(RuntimeSessionState s) => RuntimeEvent.sessionState(
        streamSequence: ++seq,
        observedAtMicros: seq,
        state: s,
        sessionId: 'live-session',
        streamEpoch: 1,
      );

  Future<RuntimeEventServer> startServer({
    int replayCapacity = 64,
    int clientQueueLimit = 64,
    int maxClients = 8,
    Set<String> origins = const <String>{},
  }) =>
      RuntimeEventServer.start(
        events.stream,
        heartbeat: const Duration(milliseconds: 50),
        replayCapacity: replayCapacity,
        clientQueueLimit: clientQueueLimit,
        maxClients: maxClients,
        allowedOrigins: origins,
      );

  setUp(() {
    seq = 0;
    events = StreamController<RuntimeEvent>.broadcast(sync: true);
  });

  tearDown(() async {
    await server.close();
    await events.close();
  });

  test('hello, live runtime frames and heartbeat', () async {
    server = await startServer();
    final _Sse sse = await _Sse.connect(server.uri);
    final _Frame hello = await sse.next('hello');
    expect(hello.data['protocol'], runtimeStreamProtocol);
    expect(hello.data['schema'], runtimeEventSchema);
    expect(hello.data['replay'], 'full');

    events.add(state(RuntimeSessionState.preparing));
    events.add(state(RuntimeSessionState.listening));
    final _Frame first = await sse.next('runtime');
    final _Frame second = await sse.next('runtime');
    expect(first.id, '${server.streamId}:1');
    expect(second.data['state'], 'listening');
    _Frame heartbeat = await sse.next('heartbeat');
    while (heartbeat.data['lastSeq'] != 2) {
      // Heartbeats sent before the events carry an older lastSeq.
      heartbeat = await sse.next('heartbeat');
    }
    expect(heartbeat.data['streamId'], server.streamId);
    await sse.close();
  });

  test('resume replays only missed events, without duplicates', () async {
    server = await startServer();
    for (final RuntimeSessionState s in <RuntimeSessionState>[
      RuntimeSessionState.preparing,
      RuntimeSessionState.listening,
      RuntimeSessionState.stopping,
    ]) {
      events.add(state(s));
    }
    events.add(state(RuntimeSessionState.stopped));
    events.add(state(RuntimeSessionState.preparing));

    final _Sse resumed =
        await _Sse.connect(server.uri, lastEventId: '${server.streamId}:3');
    expect((await resumed.next('hello')).data['replay'], 'resume');
    expect((await resumed.next('runtime')).data['seq'], 4);
    expect((await resumed.next('runtime')).data['seq'], 5);
    await resumed.close();
  });

  test('another stream id or a lost window forces a reset replay', () async {
    server = await startServer(replayCapacity: 2);
    for (int i = 0; i < 5; i++) {
      events.add(state(RuntimeSessionState.listening));
    }
    final _Sse restarted =
        await _Sse.connect(server.uri, lastEventId: 'previous-runtime:3');
    final _Frame hello = await restarted.next('hello');
    expect(hello.data['replay'], 'reset');
    expect(hello.data['truncated'], isTrue);
    expect((await restarted.next('runtime')).data['seq'], 4);
    await restarted.close();

    final _Sse gap =
        await _Sse.connect(server.uri, lastEventId: '${server.streamId}:1');
    expect((await gap.next('hello')).data['replay'], 'reset');
    await gap.close();
  });

  test(
      'a slow consumer gets overflow and is disconnected; server stays healthy',
      () async {
    server = await startServer(clientQueueLimit: 5);
    final _Sse slow = await _Sse.connect(server.uri);
    await slow.next('hello');
    for (int i = 0; i < 200; i++) {
      events.add(state(RuntimeSessionState.listening));
    }
    final _Frame overflow = await slow.next('overflow');
    expect(overflow.data['reason'], 'slowConsumer');
    await slow.closed;
    await _eventually(() => server.clientCount == 0);

    final _Sse fresh =
        await _Sse.connect(server.uri, lastEventId: '${server.streamId}:1');
    expect((await fresh.next('hello')).data['replay'], 'reset');
    await fresh.close();
  });

  test('refuses to bind beyond loopback', () async {
    server = await startServer();
    await expectLater(
      RuntimeEventServer.start(events.stream, address: InternetAddress.anyIPv4),
      throwsArgumentError,
    );
  });

  test('read-only surface: GET on the stream path, allow-listed origins',
      () async {
    server = await startServer(origins: <String>{'http://localhost:5173'});
    final HttpClient http = HttpClient();
    addTearDown(() => http.close(force: true));

    Future<HttpClientResponse> send(String method,
        {String? path, String? origin}) async {
      final HttpClientRequest request = await http.openUrl(
          method, server.uri.replace(path: path ?? server.uri.path));
      if (origin != null) request.headers.set('origin', origin);
      return request.close();
    }

    expect((await send('POST')).statusCode, HttpStatus.methodNotAllowed);
    expect((await send('GET', path: '/v1/control')).statusCode,
        HttpStatus.notFound);
    expect((await send('GET', origin: 'http://evil.example')).statusCode,
        HttpStatus.forbidden);
    final HttpClientResponse allowed =
        await send('GET', origin: 'http://localhost:5173');
    expect(allowed.headers.value('access-control-allow-origin'),
        'http://localhost:5173');
    expect(allowed.headers.contentType?.mimeType, 'text/event-stream');
    await allowed.detachSocket().then((Socket s) => s.destroy());
  });

  test('limits concurrent clients', () async {
    server = await startServer(maxClients: 1);
    final _Sse first = await _Sse.connect(server.uri);
    await first.next('hello');
    final HttpClient http = HttpClient();
    addTearDown(() => http.close(force: true));
    final HttpClientResponse second =
        await (await http.getUrl(server.uri)).close();
    expect(second.statusCode, HttpStatus.serviceUnavailable);
    await first.close();
  });
}

Future<void> _eventually(bool Function() condition) async {
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('condition not reached');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

final class _Frame {
  _Frame(this.event, this.id, this.data);
  final String event;
  final String? id;
  final Map<String, Object?> data;
}

/// Minimal SSE reader for tests.
final class _Sse {
  _Sse._(this._client, this._subscription);

  final HttpClient _client;
  late final StreamSubscription<String> _subscription;
  final List<_Frame> _frames = <_Frame>[];
  final Completer<void> _closed = Completer<void>();
  final StringBuffer _data = StringBuffer();
  String _event = 'message';
  String? _id;

  Future<void> get closed => _closed.future;

  static Future<_Sse> connect(Uri uri, {String? lastEventId}) async {
    final HttpClient client = HttpClient();
    final HttpClientRequest request = await client.getUrl(uri);
    if (lastEventId != null) request.headers.set('last-event-id', lastEventId);
    final HttpClientResponse response = await request.close();
    expect(response.statusCode, HttpStatus.ok);
    late final _Sse sse;
    final StreamSubscription<String> subscription = response
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((String line) => sse._line(line),
            onDone: () => sse._done(), onError: (Object _) => sse._done());
    sse = _Sse._(client, subscription);
    return sse;
  }

  void _line(String line) {
    if (line.isEmpty) {
      if (_data.isNotEmpty) {
        _frames.add(_Frame(
            _event, _id, jsonDecode(_data.toString()) as Map<String, Object?>));
      }
      _data.clear();
      _event = 'message';
      _id = null;
    } else if (line.startsWith('event: ')) {
      _event = line.substring(7);
    } else if (line.startsWith('id: ')) {
      _id = line.substring(4);
    } else if (line.startsWith('data: ')) {
      _data.write(line.substring(6));
    }
  }

  void _done() {
    if (!_closed.isCompleted) _closed.complete();
  }

  Future<_Frame> next(String event) async {
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 5));
    while (true) {
      final int index = _frames.indexWhere((_Frame f) => f.event == event);
      if (index >= 0) return _frames.removeAt(index);
      if (DateTime.now().isAfter(deadline)) fail('no $event frame received');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  Future<void> close() async {
    await _subscription.cancel();
    _client.close(force: true);
  }
}
