import 'dart:convert';

import 'package:dart_ai_runtime/dart_ai_runtime.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  for (final kind in AiRuntimeKind.values) {
    test('${kind.name} sends auth, workspace and OAuth contracts', () async {
      final requests = <http.Request>[];
      final transport = MockClient((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/authorize')) {
          return http.Response(
            jsonEncode({
              'url': 'https://example.test/login',
              'method': 'code',
              'instructions': 'Enter code',
            }),
            200,
          );
        }
        return http.Response('true', 200);
      });
      addTearDown(transport.close);
      final client = OpenCodeCompatibleRuntimeClient(
        endpoint: _endpoint(kind),
        workspaceDirectory: r'C:\Apps\private-workspace',
        client: transport,
      );

      await client.beginOAuth(
        'provider/id',
        methodIndex: 2,
        inputs: {'kind': 'enterprise'},
      );
      await client.completeOAuth('provider/id', methodIndex: 2, code: ' x ');

      expect(
        requests.first.url.queryParameters['directory'],
        r'C:\Apps\private-workspace',
      );
      expect(requests.first.headers, contains(kind.directoryHeader));
      expect(requests.first.headers['authorization'], startsWith('Basic '));
      expect(jsonDecode(requests.first.body), {
        'method': 2,
        'inputs': {'kind': 'enterprise'},
      });
      expect(jsonDecode(requests.last.body), {'method': 2, 'code': 'x'});
    });
  }

  test('provider catalog filters deprecated and non-text models', () async {
    final transport = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'connected': ['kilo'],
          'default': {'kilo': 'free'},
          'all': [
            {
              'id': 'kilo',
              'name': 'Kilo',
              'models': {
                'free': {
                  'name': 'Free',
                  'cost': {'input': 0, 'output': 0},
                },
                'old': {'status': 'deprecated'},
                'image-only': {
                  'capabilities': {
                    'input': {'text': false},
                  },
                },
              },
            },
          ],
        }),
        200,
      ),
    );
    addTearDown(transport.close);
    final client = OpenCodeCompatibleRuntimeClient(
      endpoint: _endpoint(AiRuntimeKind.kilo),
      workspaceDirectory: '.',
      client: transport,
    );

    final providers = await client.providers();

    expect(providers, hasLength(1));
    expect(providers.single.connected, isTrue);
    expect(providers.single.models.map((model) => model.id), ['free']);
    expect(providers.single.models.single.isFree, isTrue);
    expect(providers.single.models.single.isDefault, isTrue);
  });

  test('rejects non-loopback runtime endpoints', () {
    expect(
      () => OpenCodeCompatibleRuntimeClient(
        endpoint: AiRuntimeEndpoint(
          kind: AiRuntimeKind.openCode,
          baseUri: Uri.parse('https://example.test'),
          username: 'user',
          password: 'password',
          pid: 1,
        ),
        workspaceDirectory: '.',
      ),
      throwsArgumentError,
    );
  });

  test(
    'publishes the system prompt before dispatch and hides it from HTTP',
    () async {
      final bridge = _SystemPromptService();
      late http.Request captured;
      final transport = MockClient((request) async {
        captured = request;
        expect(bridge.prompt, 'Private telemetry');
        return http.Response('', 204);
      });
      addTearDown(transport.close);
      final client = OpenCodeCompatibleRuntimeClient(
        endpoint: _endpoint(AiRuntimeKind.openCode),
        workspaceDirectory: '.',
        client: transport,
        systemPromptService: bridge,
      );

      await client.promptAsync(
        'ses_1',
        const AiPrompt(
          providerId: 'provider',
          modelId: 'model',
          system: 'Private telemetry',
          text: 'Question',
        ),
      );

      final body = Map<String, dynamic>.from(jsonDecode(captured.body) as Map);
      expect(
        body['system'],
        LocalAiRuntimeSystemPromptService.transportPlaceholder,
      );
      expect(captured.body, isNot(contains('Private telemetry')));
      expect(bridge.setCalls, 1);
    },
  );

  test('cleans a pending bridge prompt when dispatch fails', () async {
    final bridge = _SystemPromptService();
    final transport = MockClient((_) async => http.Response('failure', 500));
    addTearDown(transport.close);
    final client = OpenCodeCompatibleRuntimeClient(
      endpoint: _endpoint(AiRuntimeKind.kilo),
      workspaceDirectory: '.',
      client: transport,
      systemPromptService: bridge,
    );

    await expectLater(
      client.promptAsync(
        'ses_1',
        const AiPrompt(
          providerId: 'provider',
          modelId: 'model',
          system: 'System',
          text: 'Question',
        ),
      ),
      throwsA(isA<AiRuntimeApiException>()),
    );
    expect(bridge.removeCalls, 1);
  });
}

AiRuntimeEndpoint _endpoint(AiRuntimeKind kind) => AiRuntimeEndpoint(
  kind: kind,
  baseUri: Uri.parse('http://127.0.0.1:4096'),
  username: kind.id,
  password: 'secret',
  pid: 1,
);

class _SystemPromptService implements AiRuntimeSystemPromptService {
  String? prompt;
  int setCalls = 0;
  int removeCalls = 0;

  @override
  Future<void> clearSystemPrompts(AiRuntimeKind kind) async {}

  @override
  Future<void> prepare(AiRuntimeKind kind) async {}

  @override
  Future<void> removeSystemPrompt(AiRuntimeKind kind, String sessionId) async {
    removeCalls++;
    prompt = null;
  }

  @override
  Future<void> setSystemPrompt(
    AiRuntimeKind kind,
    String sessionId,
    String systemPrompt,
  ) async {
    setCalls++;
    prompt = systemPrompt;
  }
}
