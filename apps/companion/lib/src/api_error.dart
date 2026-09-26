/// Stable, locale-independent API error. The Studio UI localises [code] with
/// [params]; no sentence is sent over the wire.
final class ApiError implements Exception {
  const ApiError(this.status, this.code, [this.params = const <String, Object>{}]);

  final int status;
  final String code;
  final Map<String, Object> params;

  Map<String, Object> toJson() => <String, Object>{
        'error': <String, Object>{'code': code, 'params': params},
      };

  @override
  String toString() => 'ApiError($status, $code, $params)';
}
