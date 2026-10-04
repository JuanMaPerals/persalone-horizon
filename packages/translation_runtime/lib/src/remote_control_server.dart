import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'remote_control_gateway.dart';

/// Per-launch bearer credential of the remote control channel: 256 random
/// bits, base64url. It is never printed; [toString] is redacted, and only
/// [reveal] (for writing it to app-private storage) returns the value.
final class RemoteControlToken {
  RemoteControlToken._(this._value);

  static RemoteControlToken generate() {
    final Random random = Random.secure();
    return RemoteControlToken._(base64Url
        .encode(List<int>.generate(32, (_) => random.nextInt(256)))
        .replaceAll('=', ''));
  }

  /// A fixed credential for tests and the Studio E2E fixture only; every
  /// app launch uses [generate].
  factory RemoteControlToken.forTesting(String value) {
    if (value.isEmpty) throw ArgumentError.value(value, 'value', 'empty');
    return RemoteControlToken._(value);
  }

  final String _value;

  String reveal() => _value;

  /// Constant-time comparison over the whole candidate.
  bool matches(String candidate) {
    final List<int> a = utf8.encode(_value);
    final List<int> b = utf8.encode(candidate);
    int diff = a.length ^ b.length;
    for (int i = 0; i < b.length; i++) {
      diff |= b[i] ^ a[i % a.length];
    }
    return diff == 0;
  }

  @override
  String toString() => 'RemoteControlToken(redacted)';
}

/// Authenticated transport of the [RemoteControlGateway]. It adds no command
/// semantics: it authenticates, bounds and decodes the request, and hands the
/// JSON to the gateway, which keeps the policy matrix, dedupe/replay, expiry,
/// rate limit and generation checks, in front of the one runtime authority.
///
/// Surface: `GET /v1/control/status` and `POST /v1/control/commands`, plus
/// CORS preflight for allow-listed origins. It binds to loopback only (the
/// computer reaches it through `adb forward`) and fails closed:
/// - every non-preflight request needs `Authorization: Bearer <token>`;
///   CORS is not authentication;
/// - `Host` must name loopback (DNS rebinding) and a present `Origin` must be
///   allow-listed;
/// - bodies are JSON, at most [maxBodyBytes], read within [readTimeout];
/// - after [maxFailedAuth] failed authentications the channel locks until the
///   app is relaunched (with a new token). Local controls are unaffected.
///
/// Responses carry coded tokens and numbers only, never the credential.
final class RemoteControlServer {
  RemoteControlServer._(this._server, this._gateway, this._token,
      this._allowedOrigins, this._maxFailedAuth, this._maxInFlight,
      this._readTimeout, this._onLocked);

  static const String statusPath = '/v1/control/status';
  static const String commandsPath = '/v1/control/commands';
  static const int maxBodyBytes = 1024;
  static const Set<String> _loopbackHosts = <String>{
    '127.0.0.1',
    'localhost',
    '::1',
    '[::1]',
  };

  final HttpServer _server;
  final RemoteControlGateway _gateway;
  final RemoteControlToken _token;
  final Set<String> _allowedOrigins;
  final int _maxFailedAuth;
  final int _maxInFlight;
  final Duration _readTimeout;
  final void Function()? _onLocked;
  int _failedAuth = 0;
  int _inFlight = 0;

  static Future<RemoteControlServer> start(
    RemoteControlGateway gateway, {
    required RemoteControlToken token,
    InternetAddress? address,
    int port = 0,
    Set<String> allowedOrigins = const <String>{},
    int maxFailedAuth = 10,
    int maxInFlight = 4,
    Duration readTimeout = const Duration(seconds: 2),
    void Function()? onLocked,
  }) async {
    final InternetAddress bind = address ?? InternetAddress.loopbackIPv4;
    if (!bind.isLoopback) {
      throw ArgumentError.value(bind.address, 'address',
          'the remote control channel is loopback-only');
    }
    final HttpServer server = await HttpServer.bind(bind, port)
      ..idleTimeout = const Duration(seconds: 5);
    final RemoteControlServer control = RemoteControlServer._(server, gateway,
        token, allowedOrigins, maxFailedAuth, maxInFlight, readTimeout,
        onLocked);
    server.listen(control._handle);
    return control;
  }

  Uri get uri => Uri(
        scheme: 'http',
        host: _server.address.address,
        port: _server.port,
      );

  /// True once too many failed authentications closed the channel.
  bool get locked => _failedAuth >= _maxFailedAuth;

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final HttpResponse response = request.response;
    response
      ..persistentConnection = false
      ..headers.set('cache-control', 'no-store')
      ..headers.set('x-content-type-options', 'nosniff');
    try {
      await _route(request, response);
    } on Object {
      // Never echo an exception: it could carry request content.
      try {
        await _reply(response, HttpStatus.badRequest, 'badRequest');
      } on Object {
        // The response was already sent or the peer is gone.
      }
    }
  }

  Future<void> _route(HttpRequest request, HttpResponse response) async {
    final String? host = request.headers.host;
    if (host == null || !_loopbackHosts.contains(host.toLowerCase())) {
      return _reply(response, HttpStatus.forbidden, 'hostNotAllowed');
    }
    final String path = request.uri.path;
    final String? method = switch (path) {
      statusPath => 'GET',
      commandsPath => 'POST',
      _ => null,
    };
    if (method == null || request.uri.hasQuery) {
      return _reply(response, HttpStatus.notFound, 'notFound');
    }
    final String? origin = request.headers.value('origin');
    if (origin != null) {
      if (!_allowedOrigins.contains(origin)) {
        return _reply(response, HttpStatus.forbidden, 'originNotAllowed');
      }
      response.headers
        ..set('access-control-allow-origin', origin)
        ..set('vary', 'origin');
    }
    if (request.method == 'OPTIONS') {
      // A browser preflight carries no credential; it grants nothing but
      // permission to send the authenticated request.
      if (origin == null ||
          request.headers.value('access-control-request-method') != method) {
        return _reply(response, HttpStatus.forbidden, 'preflightRefused');
      }
      response.statusCode = HttpStatus.noContent;
      response.headers
        ..set('access-control-allow-methods', method)
        ..set('access-control-allow-headers', 'authorization, content-type')
        ..set('access-control-max-age', '60');
      await response.close();
      return;
    }
    if (request.method != method) {
      response.headers.set('allow', method);
      return _reply(response, HttpStatus.methodNotAllowed, 'methodNotAllowed');
    }
    if (locked) {
      return _reply(response, HttpStatus.forbidden, 'controlLocked');
    }
    if (!_authenticated(request.headers.value('authorization'))) {
      _failedAuth++;
      if (locked) _onLocked?.call();
      response.headers.set('www-authenticate', 'Bearer');
      return _reply(response, HttpStatus.unauthorized, 'unauthorized');
    }
    if (_inFlight >= _maxInFlight) {
      return _reply(response, HttpStatus.serviceUnavailable, 'busy');
    }
    _inFlight++;
    try {
      if (method == 'GET') {
        return _json(response, HttpStatus.ok, _gateway.status());
      }
      if (request.headers.contentType?.mimeType != 'application/json') {
        return _reply(
            response, HttpStatus.unsupportedMediaType, 'unsupportedMediaType');
      }
      if (request.contentLength > maxBodyBytes) {
        return _reply(response, HttpStatus.requestEntityTooLarge, 'tooLarge');
      }
      final Uint8List? body = await _readBounded(request);
      if (body == null) {
        return _reply(response, HttpStatus.requestEntityTooLarge, 'tooLarge');
      }
      Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(body));
      } on FormatException {
        decoded = null; // the gateway answers `malformed`
      }
      final Map<String, Object?> result =
          (await _gateway.submit(decoded)).toJson();
      return _json(response, HttpStatus.ok, result);
    } finally {
      _inFlight--;
    }
  }

  bool _authenticated(String? header) {
    const String scheme = 'Bearer ';
    if (header == null || !header.startsWith(scheme)) return false;
    return _token.matches(header.substring(scheme.length));
  }

  /// Reads at most [maxBodyBytes] within [_readTimeout]; null when larger.
  Future<Uint8List?> _readBounded(HttpRequest request) async {
    final BytesBuilder bytes = BytesBuilder(copy: false);
    await for (final List<int> chunk in request.timeout(_readTimeout)) {
      if (bytes.length + chunk.length > maxBodyBytes) return null;
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  Future<void> _reply(HttpResponse response, int status, String error) =>
      _json(response, status, <String, Object?>{'error': error});

  Future<void> _json(
      HttpResponse response, int status, Map<String, Object?> body) async {
    response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await response.close();
  }
}
