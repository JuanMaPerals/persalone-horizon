import 'package:flutter_test/flutter_test.dart';
import 'package:persalone_mobile/live_stream_config.dart';

void main() {
  test('defaults match the Console URL and local Studio origins', () {
    final LiveStreamConfig config = LiveStreamConfig.parse(
      port: LiveStreamConfig.defaultPort,
      origins: LiveStreamConfig.defaultOrigins,
    );
    expect(config.port, 47800);
    expect(config.allowedOrigins,
        <String>{'http://127.0.0.1:5173', 'http://localhost:5173'});
  });

  test('only plain origins survive; wildcards, paths and junk are dropped', () {
    final LiveStreamConfig config = LiveStreamConfig.parse(
      port: 47800,
      origins: ' http://127.0.0.1:5173 ,*,null,http://evil.test/path,'
          'javascript:alert(1),https://studio.example:8443,',
    );
    expect(config.allowedOrigins,
        <String>{'http://127.0.0.1:5173', 'https://studio.example:8443'});
  });

  test('an empty list allows no browser origin at all', () {
    expect(
        LiveStreamConfig.parse(port: 47800, origins: '').allowedOrigins, isEmpty);
  });

  test('privileged or out-of-range ports are refused', () {
    expect(() => LiveStreamConfig.parse(port: 80, origins: ''),
        throwsArgumentError);
    expect(() => LiveStreamConfig.parse(port: 70000, origins: ''),
        throwsArgumentError);
  });
}
