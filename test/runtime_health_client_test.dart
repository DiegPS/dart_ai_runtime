import 'dart:convert';

import 'package:dart_ai_runtime/dart_ai_runtime.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  for (final pid in [7, 8]) {
    test('V2 health checks server identity for PID $pid', () async {
      final health = AiRuntimeHealthClient(
        client: MockClient((request) async {
          expect(request.url.path, '/api/info');
          return http.Response(
            jsonEncode({'version': '2.2.2', 'pid': pid}),
            200,
          );
        }),
      );
      final result = await health.waitUntilReady(
        AiRuntimeEndpoint(
          kind: AiRuntimeKind.openCode,
          baseUri: Uri.parse('http://127.0.0.1:1234'),
          username: 'opencode',
          password: 'test',
          pid: 7,
          apiVersion: 2,
        ),
        timeout: const Duration(milliseconds: 20),
      );
      expect(result.healthy, pid == 7);
    });
  }
  test('accepts an authenticated healthy loopback runtime', () async {
    final transport = MockClient((request) async {
      expect(request.url.path, '/global/health');
      expect(request.headers['authorization'], startsWith('Basic '));
      return http.Response(
        jsonEncode({'healthy': true, 'version': '1.2.3'}),
        200,
      );
    });
    final health = AiRuntimeHealthClient(client: transport);

    final result = await health.waitUntilReady(
      _endpoint(Uri.parse('http://127.0.0.1:1234')),
    );

    expect(result.healthy, isTrue);
    expect(result.version, '1.2.3');
  });

  test('rejects a non-loopback endpoint without making a request', () async {
    final health = AiRuntimeHealthClient(
      client: MockClient((_) async => throw StateError('must not be called')),
    );

    final result = await health.waitUntilReady(
      _endpoint(Uri.parse('https://example.test')),
    );

    expect(result.healthy, isFalse);
    expect(result.message, contains('loopback'));
  });
}

AiRuntimeEndpoint _endpoint(Uri uri) => AiRuntimeEndpoint(
  kind: AiRuntimeKind.openCode,
  baseUri: uri,
  username: 'opencode',
  password: 'secret',
  pid: 1,
);
