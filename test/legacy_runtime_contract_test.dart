import 'dart:convert';

import 'package:dart_ai_runtime/dart_ai_runtime.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

AiRuntimeEndpoint _endpoint() => AiRuntimeEndpoint(
  kind: AiRuntimeKind.openCode,
  baseUri: Uri.parse('http://127.0.0.1:1234'),
  username: 'opencode',
  password: 'test-only',
  pid: 1,
);

void main() {
  test(
    'auth discovery preserves method indexes, options and conditional prompts',
    () async {
      final transport = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'provider': [
              null,
              {
                'type': 'oauth',
                'name': 'Browser',
                'prompts': [
                  {
                    'key': 'region',
                    'type': 'select',
                    'message': 'Choose region',
                    'placeholder': 'Region',
                    'options': [
                      {'value': 'eu', 'label': 'Europe'},
                      false,
                    ],
                    'when': {'key': 'mode', 'value': 'api', 'op': 'neq'},
                  },
                  {'key': 'token', 'type': 'text'},
                ],
              },
            ],
            'single': {'label': 'API key'},
            'fallback': <String, Object>{},
          }),
          200,
        ),
      );
      final client = OpenCodeCompatibleRuntimeClient(
        endpoint: _endpoint(),
        workspaceDirectory: '.',
        client: transport,
      );
      addTearDown(transport.close);
      final methods = await client.authMethods();
      expect(methods.first.index, 1);
      expect(methods.first.label, 'Browser');
      final conditional = methods.first.prompts.first;
      expect(conditional.options, {'eu': 'Europe'});
      expect(conditional.placeholder, 'Region');
      expect(conditional.visible({'mode': 'api'}), isFalse);
      expect(conditional.visible({'mode': 'oauth'}), isTrue);
      expect(methods.first.prompts.last.visible({}), isTrue);
      final equal = AiAuthPrompt.fromJson({
        'key': 'code',
        'type': 'text',
        'when': {'key': 'mode', 'value': 'oauth'},
      });
      expect(equal.visible({'mode': 'oauth'}), isTrue);
      expect(equal.visible({}), isFalse);
      expect(methods.last.label, 'Authentication');
    },
  );

  test(
    'session lifecycle and API key operations preserve IDs and permissions',
    () async {
      final requests = <http.Request>[];
      final transport = MockClient((r) async {
        requests.add(r);
        if (r.url.path.endsWith('/message')) {
          return http.Response('[{"info":{"id":"msg"}},false]', 200);
        }
        if (r.url.path.startsWith('/session') && r.method != 'DELETE') {
          return http.Response('{"id":"ses_test","title":"Test"}', 200);
        }
        return http.Response('', 204);
      });
      addTearDown(transport.close);
      final client = OpenCodeCompatibleRuntimeClient(
        endpoint: _endpoint(),
        workspaceDirectory: '.',
        client: transport,
      );
      expect((await client.createSession(title: 'Test')).title, 'Test');
      expect((await client.session('ses_test')).id, 'ses_test');
      expect(await client.messages('ses_test'), hasLength(1));
      await expectLater(
        client.setApiKey('provider', '  '),
        throwsFormatException,
      );
      await client.setApiKey('provider', ' test-only ');
      expect(jsonDecode(requests.last.body), {
        'type': 'api',
        'key': 'test-only',
      });
      await client.promptAsync(
        'ses_test',
        const AiPrompt(
          providerId: 'provider',
          modelId: 'model',
          system: 'System',
          text: 'Question',
        ),
      );
      expect(jsonDecode(requests.last.body)['tools'], {'*': false});
      await client.abort('ses_test');
      await client.deleteSession('ses_test');
      await client.disconnectProvider('provider');
      expect(requests.last.method, 'DELETE');
      expect(requests.last.url.path, '/auth/provider');
      client.dispose();
    },
  );

  test(
    'catalog fallback and free identifiers are compatible with both runtimes',
    () async {
      final transport = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'providers': [
              {'id': '', 'models': <String, Object>{}},
              {
                'id': 'kilo',
                'models': {
                  'kilo-auto/free': <String, Object>{},
                  'bad': false,
                  'nontext': {
                    'capabilities': {
                      'output': {'text': false},
                    },
                  },
                },
              },
              {
                'id': 'other',
                'models': {
                  'reason:free': {
                    'capabilities': {'reasoning': true},
                  },
                  'paid': {
                    'cost': {'input': 1, 'output': 2},
                  },
                },
              },
              {'id': 'empty', 'models': <Object>[]},
            ],
          }),
          200,
        ),
      );
      addTearDown(transport.close);
      final client = OpenCodeCompatibleRuntimeClient(
        endpoint: _endpoint(),
        workspaceDirectory: '.',
        client: transport,
      );
      final providers = await client.providers();
      expect(providers.map((p) => p.id), ['kilo', 'other', 'empty']);
      expect(providers.first.models.single.isFree, isTrue);
      expect(providers[1].models.first.supportsReasoning, isTrue);
      expect(providers[1].models.last.isFree, isFalse);
    },
  );

  for (final operation in ['providers', 'messages', 'session']) {
    test('malformed $operation responses are format errors', () async {
      final transport = MockClient(
        (_) async => http.Response(operation == 'messages' ? '{}' : '[]', 200),
      );
      addTearDown(transport.close);
      final client = OpenCodeCompatibleRuntimeClient(
        endpoint: _endpoint(),
        workspaceDirectory: '.',
        client: transport,
      );
      final Future<Object?> response = switch (operation) {
        'providers' => client.providers(),
        'messages' => client.messages('s'),
        _ => client.session('s'),
      };
      await expectLater(response, throwsFormatException);
    });
  }

  test(
    'SSE handles event names, malformed frames and a final unterminated frame',
    () async {
      final transport = MockClient(
        (_) async => http.Response(
          'data: invalid\n\ndata: []\n\nevent: message.part.delta\ndata: {"properties":{"sessionID":"s","delta":"Hi","field":"text"}}',
          200,
        ),
      );
      addTearDown(transport.close);
      final client = OpenCodeCompatibleRuntimeClient(
        endpoint: _endpoint(),
        workspaceDirectory: '.',
        client: transport,
      );
      final events = await client.events().toList();
      expect(events.single.type, 'message.part.delta');
      expect(events.single.textDelta, 'Hi');
    },
  );

  test(
    'SSE authentication failures preserve HTTP status and hide the body',
    () async {
      final transport = MockClient(
        (_) async => http.Response('sensitive body', 403),
      );
      addTearDown(transport.close);
      final client = OpenCodeCompatibleRuntimeClient(
        endpoint: _endpoint(),
        workspaceDirectory: '.',
        client: transport,
      );
      await expectLater(
        client.connectEvents(),
        throwsA(
          isA<AiRuntimeApiException>()
              .having((e) => e.statusCode, 'status', 403)
              .having(
                (e) => e.toString(),
                'diagnostic',
                isNot(contains('sensitive')),
              ),
        ),
      );
      final owned = OpenCodeCompatibleRuntimeClient(
        endpoint: _endpoint(),
        workspaceDirectory: '.',
      );
      owned.dispose();
    },
  );
}
