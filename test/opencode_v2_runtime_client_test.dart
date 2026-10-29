import 'dart:async';
import 'dart:convert';

import 'package:dart_ai_runtime/dart_ai_runtime.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

const _prompt = AiPrompt(
  providerId: 'opencode',
  modelId: 'big-pickle',
  system: 'Host instructions',
  text: 'Hola',
  messageId: 'msg_request',
);
const _model = {
  'id': 'big-pickle',
  'providerID': 'opencode',
  'variant': 'default',
};

void main() {
  late _Transport transport;
  late OpenCodeV2RuntimeClient client;
  setUp(() {
    transport = _Transport();
    client = OpenCodeV2RuntimeClient(
      endpoint: AiRuntimeEndpoint(
        kind: AiRuntimeKind.openCode,
        baseUri: Uri.parse('http://127.0.0.1:1234'),
        username: 'opencode',
        password: 'test-only',
        pid: 1,
        apiVersion: 2,
      ),
      workspaceDirectory: r'C:\private',
      client: transport,
      reconnectDelay: const Duration(milliseconds: 5),
    );
  });
  tearDown(() {
    client.dispose();
    transport.close();
  });

  for (final outcome in ['failed', 'interrupted']) {
    test(
      'idle $outcome without an assistant does not hide the failure',
      () async {
        await client.promptAsync('ses_test', _prompt);
        transport.pages = [
          {
            'data': [
              {'id': 'msg_request', 'type': 'user'},
              {'id': 'idle', 'type': 'idle', 'outcome': outcome},
            ],
            'cursor': <String, Object>{},
          },
        ];
        final messages = await client.messages('ses_test');
        expect(messages.last['info']['parentID'], 'msg_request');
        expect(
          messages.last['info']['error']['type'],
          'runtime.execution-$outcome',
        );
      },
    );
  }

  test('idle-only rejection preserves the original structured cause', () async {
    await client.promptAsync('ses_test', _prompt);
    final cause = {
      'type': 'provider.free-limit',
      'status': 429,
      'message': 'original',
    };
    transport.pages = [
      {
        'data': [
          {'id': 'msg_request', 'type': 'user'},
          {'id': 'idle', 'type': 'idle', 'outcome': 'failed', 'error': cause},
        ],
        'cursor': <String, Object>{},
      },
    ];
    expect((await client.messages('ses_test')).last['info']['error'], cause);
  });

  test(
    'disposal cancels a connected stream before its first listener',
    () async {
      final events = await client.connectEvents();
      client.dispose();
      expect(
        await events.toList().timeout(const Duration(seconds: 1)),
        isEmpty,
      );
      expect(transport.eventCancellations, 1);
      expect(transport.streams.single.hasListener, isFalse);
    },
  );

  test(
    'disposal closes a silent event subscription without waiting for data',
    () async {
      final done = Completer<void>();
      (await client.connectEvents()).listen((_) {}, onDone: done.complete);
      client.dispose();
      await done.future.timeout(const Duration(seconds: 1));
      expect(transport.eventCancellations, 1);
      await expectLater(client.connectEvents(), throwsStateError);
    },
  );

  test(
    'disposal during connection cancels a late successful response',
    () async {
      transport.connectGate = Completer<void>();
      final rejected = expectLater(client.connectEvents(), throwsStateError);
      await _until(
        () => transport.requests.any((r) => r.url.path == '/api/event'),
      );
      client.dispose();
      transport.connectGate!.complete();
      await rejected;
      expect(transport.eventCancellations, 1);
    },
  );

  test(
    'rejected SSE responses cancel their bodies without waiting for EOF',
    () async {
      transport.eventStatus = 401;
      await expectLater(
        client.connectEvents(),
        throwsA(
          isA<AiRuntimeApiException>().having(
            (e) => e.statusCode,
            'status',
            401,
          ),
        ),
      );
      expect(transport.eventCancellations, 1);
    },
  );

  test(
    'cancellation stops reconnects while the transport stays open',
    () async {
      final subscription = (await client.connectEvents()).listen((_) {});
      await subscription.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(transport.streams, hasLength(1));
      expect(transport.eventCancellations, 1);
    },
  );

  test('a new turn ignores late fragments from the previous request', () async {
    final received = <AiRuntimeEvent>[];
    final subscription = (await client.connectEvents()).listen(received.add);
    addTearDown(subscription.cancel);
    await client.promptAsync('ses_test', _prompt);
    transport.deliver();
    transport.step();
    await _until(() => received.isNotEmpty);
    await client.promptAsync(
      'ses_test',
      const AiPrompt(
        providerId: 'opencode',
        modelId: 'big-pickle',
        system: 'Next',
        text: 'Another question',
        messageId: 'msg_next',
      ),
    );
    received.clear();
    transport.emit('session.inbox.delivered', {'inboxID': 'msg_next'});
    transport.emit('session.step.started', {
      'assistantMessageID': 'msg_new',
      'model': _model,
    });
    transport.emit('session.text.delta', {
      'assistantMessageID': 'msg_a',
      'ordinal': 0,
      'delta': 'stale',
    });
    transport.emit('session.step.failed', {
      'assistantMessageID': 'msg_a',
      'error': {
        'type': 'provider.free-limit',
        'status': 429,
        'message': 'old error',
      },
    });
    transport.emit('session.text.delta', {
      'assistantMessageID': 'msg_new',
      'ordinal': 0,
      'delta': 'New answer',
    });
    await _until(() => received.any((e) => e.textDelta == 'New answer'));
    expect(received.any((e) => e.isError || e.textDelta == 'stale'), isFalse);
    expect(
      received.every((e) => e.properties['requestID'] == 'msg_next'),
      isTrue,
    );
  });

  test(
    'repeated message cursors fail without an unbounded pagination loop',
    () async {
      transport.pages = [
        {
          'data': <Object>[],
          'cursor': {'next': 'repeated'},
        },
        {
          'data': <Object>[],
          'cursor': {'next': 'repeated'},
        },
      ];
      await expectLater(client.messages('ses_test'), throwsFormatException);
      expect(
        transport.requests.where((r) => r.url.path.endsWith('/message')),
        hasLength(2),
      );
    },
  );

  test('selects V2 explicitly and preserves the V1/Kilo client', () {
    final v2 = createAiRuntimeClient(
      endpoint: client.endpoint,
      workspaceDirectory: '.',
    );
    expect(v2, isA<OpenCodeV2RuntimeClient>());
    expect(
      () => OpenCodeCompatibleRuntimeClient(
        endpoint: client.endpoint,
        workspaceDirectory: '.',
        client: transport,
      ),
      throwsUnsupportedError,
    );
    v2.dispose();
    final kilo = createAiRuntimeClient(
      endpoint: AiRuntimeEndpoint(
        kind: AiRuntimeKind.kilo,
        baseUri: Uri.parse('http://127.0.0.1:1234'),
        username: 'kilo',
        password: '',
        pid: 1,
      ),
      workspaceDirectory: '.',
    );
    expect(kilo, isA<OpenCodeCompatibleRuntimeClient>());
    kilo.dispose();
  });

  test('uses native model, instruction, request and approval APIs without identity headers', () async {
    await client.createSession();
    await client.promptAsync('ses_test', _prompt);
    final methods = transport.requests
        .map((r) => '${r.method} ${r.url.path}')
        .toList();
    expect(methods, [
      'POST /api/session',
      'PATCH /api/session/ses_test',
      'POST /api/session/ses_test/model',
      'PUT /api/experimental/session/ses_test/instructions/entries/dart-ai-runtime',
      'POST /api/session/ses_test/prompt',
    ]);
    expect(jsonDecode(transport.requests[1].body)['permissions'], [
      {'action': '*', 'resource': '*', 'effect': 'ask'},
      {'action': '*', 'resource': '*', 'effect': 'ask'},
    ]);
    expect(jsonDecode(transport.requests[2].body), {
      'model': {'providerID': 'opencode', 'id': 'big-pickle'},
    });
    expect(jsonDecode(transport.requests[3].body), {
      'value': 'Host instructions',
    });
    expect(jsonDecode(transport.requests.last.body), {
      'id': 'msg_request',
      'text': 'Hola',
      'delivery': 'steer',
    });
    for (final request in transport.requests) {
      expect(request.headers['authorization'], startsWith('Basic '));
      expect(
        request.headers.keys.where((k) => k.toLowerCase().contains('opencode')),
        isEmpty,
      );
    }
  });

  test(
    'native cost tiers require explicit zero input and output in every tier',
    () async {
      transport.models = [
        {
          'id': 'big-pickle',
          'providerID': 'opencode',
          'name': 'Big Pickle',
          'enabled': true,
          'cost': [
            {'input': 0, 'output': 0},
          ],
        },
        {
          'id': 'paid',
          'providerID': 'other',
          'enabled': true,
          'cost': [
            {'input': 0, 'output': 1},
          ],
        },
        {'id': 'unknown', 'providerID': 'other', 'enabled': true, 'cost': []},
        {'id': 'disabled', 'providerID': 'other', 'enabled': false, 'cost': []},
      ];
      final providers = await client.providers();
      expect(
        providers.singleWhere((p) => p.id == 'opencode').models.single.isFree,
        isTrue,
      );
      expect(
        providers
            .singleWhere((p) => p.id == 'other')
            .models
            .every((m) => !m.isFree),
        isTrue,
      );
      expect(
        transport.requests.single.url.queryParameters['location[directory]'],
        r'C:\private',
      );
    },
  );

  test('SSE preserves UTF-8, separates reasoning and gates completion on execution', () async {
    final received = <AiRuntimeEvent>[];
    final sub = (await client.connectEvents()).listen(received.add);
    addTearDown(sub.cancel);
    await client.promptAsync('ses_test', _prompt);
    transport.deliver();
    transport.step();
    transport.emit('session.reasoning.started', {
      'assistantMessageID': 'msg_a',
      'ordinal': 0,
    });
    transport.emit('session.reasoning.delta', {
      'assistantMessageID': 'msg_a',
      'ordinal': 0,
      'delta': 'private reasoning',
    });
    transport.emit('session.text.started', {
      'assistantMessageID': 'msg_a',
      'ordinal': 0,
    });
    transport.emit('session.text.delta', {
      'assistantMessageID': 'msg_a',
      'ordinal': 0,
      'delta': '¡Hola!',
    });
    transport.emit('session.text.ended', {
      'assistantMessageID': 'msg_a',
      'ordinal': 0,
      'text': '¡Hola!',
    });
    transport.emit('session.step.ended', {
      'assistantMessageID': 'msg_a',
      'finish': 'stop',
    });
    await _until(() => received.length >= 6);
    expect(received.any((e) => e.isCompleted), isFalse);
    transport.emit('session.execution.succeeded', {});
    await _until(() => received.any((e) => e.isCompleted));
    final text = received.singleWhere((e) => e.textDelta == '¡Hola!');
    final reasoning = received.singleWhere(
      (e) => e.textDelta == 'private reasoning',
    );
    expect(text.partId, isNot(reasoning.partId));
    expect(text.properties['requestID'], 'msg_request');
    expect(client.responseModel('ses_test'), _model);
  });

  test('rejects pending tools before execution over both SSE and snapshot reconciliation', () async {
    final sub = (await client.connectEvents()).listen((_) {});
    addTearDown(sub.cancel);
    await client.promptAsync('ses_test', _prompt);
    transport.emit('permission.asked', {
      'id': 'permission_live',
      'action': 'filesystem.write',
      'resources': ['blocked.txt'],
    });
    await _until(
      () => transport.requests.any(
        (r) => r.url.path.endsWith('/permission_live/reply'),
      ),
    );
    transport.pending = [
      {
        'id': 'permission_snapshot',
        'sessionID': 'ses_test',
        'action': 'shell.execute',
        'resources': ['anything'],
      },
      {
        'id': 'permission_other',
        'sessionID': 'ses_other',
        'action': 'shell.execute',
        'resources': [],
      },
    ];
    await client.messages('ses_test');
    final replies = transport.requests
        .where((r) => r.url.path.endsWith('/reply'))
        .toList();
    expect(replies, hasLength(2));
    for (final reply in replies) {
      expect(jsonDecode(reply.body)['decision'], 'reject');
    }
    expect(
      replies.any((r) => r.url.path.contains('permission_other')),
      isFalse,
    );
  });

  test(
    'pagination combines steps for a user and only idle completes the turn',
    () async {
      await client.promptAsync('ses_test', _prompt);
      transport.pages = [
        {
          'data': [
            {'id': 'msg_request', 'type': 'user', 'text': 'Hola'},
            {
              'id': 'msg_a',
              'type': 'assistant',
              'model': _model,
              'content': [
                {'type': 'text', 'text': 'One'},
              ],
              'finish': 'tool-calls',
            },
          ],
          'cursor': {'next': 'page2'},
        },
        {
          'data': [
            {
              'id': 'msg_b',
              'type': 'assistant',
              'model': _model,
              'content': [
                {'type': 'text', 'text': 'Two'},
              ],
              'finish': 'stop',
            },
            {'id': 'idle', 'type': 'idle', 'outcome': 'succeeded'},
          ],
          'cursor': {},
        },
      ];
      final messages = await client.messages('ses_test');
      expect(messages, hasLength(2));
      expect(messages.last['info'], {
        'id': 'assistant:msg_request',
        'role': 'assistant',
        'parentID': 'msg_request',
        'finish': 'stop',
      });
      expect(messages.last['parts'], [
        {'type': 'text', 'text': 'One'},
        {'type': 'text', 'text': 'Two'},
      ]);
      final pages = transport.requests
          .where((r) => r.url.path.endsWith('/message'))
          .toList();
      expect(pages.last.url.queryParameters, {
        'limit': '100',
        'cursor': 'page2',
      });
    },
  );

  for (final status in [401, 403, 429]) {
    test(
      'structured V2 error $status is available without text through SSE and snapshots',
      () async {
        final received = <AiRuntimeEvent>[];
        final sub = (await client.connectEvents()).listen(received.add);
        addTearDown(sub.cancel);
        await client.promptAsync('ses_test', _prompt);
        transport.deliver();
        transport.step();
        final cause = {
          'type': status == 429 ? 'provider.free-limit' : 'provider.api',
          'status': status,
          'message': 'original failure',
          'response': {'body': 'sensitive'},
        };
        transport.emit('session.execution.failed', {'error': cause});
        await _until(() => received.any((e) => e.isError));
        final failure = received.firstWhere((e) => e.isError).failure!;
        expect(
          failure.kind,
          status == 429
              ? AiRuntimeFailureKind.quotaExceeded
              : status == 401
              ? AiRuntimeFailureKind.authentication
              : AiRuntimeFailureKind.permissionDenied,
        );
        expect(failure.statusCode, status);
        expect(failure.toString(), isNot(contains('sensitive')));
        transport.pages = [
          {
            'data': [
              {'id': 'msg_request', 'type': 'user'},
              {
                'id': 'msg_a',
                'type': 'assistant',
                'model': _model,
                'content': <Object>[],
                'error': cause,
              },
              {
                'id': 'idle',
                'type': 'idle',
                'outcome': 'failed',
                'error': cause,
              },
            ],
            'cursor': {},
          },
        ];
        expect(
          (await client.messages('ses_test')).last['info']['error'],
          cause,
        );
      },
    );
  }

  test(
    'temporary retries remain recoverable and stale message events are ignored',
    () async {
      final received = <AiRuntimeEvent>[];
      final sub = (await client.connectEvents()).listen(received.add);
      addTearDown(sub.cancel);
      await client.promptAsync('ses_test', _prompt);
      transport.deliver();
      transport.step();
      transport.emit('session.retry.scheduled', {
        'error': {
          'type': 'provider.api',
          'status': 503,
          'message': 'Unavailable',
        },
      });
      transport.emit('session.text.delta', {
        'assistantMessageID': 'old_message',
        'ordinal': 0,
        'delta': 'stale',
      });
      transport.emit('session.execution.failed', {
        'sessionID': 'other',
        'error': {'type': 'provider.free-limit'},
      });
      transport.emit('session.text.delta', {
        'assistantMessageID': 'msg_a',
        'ordinal': 0,
        'delta': 'Recovered',
      });
      await _until(() => received.any((e) => e.textDelta == 'Recovered'));
      expect(received.any((e) => e.isError || e.textDelta == 'stale'), isFalse);
    },
  );

  test(
    'a silent model change fails through either SSE or reconciliation',
    () async {
      final received = <AiRuntimeEvent>[];
      final sub = (await client.connectEvents()).listen(received.add);
      addTearDown(sub.cancel);
      await client.promptAsync('ses_test', _prompt);
      transport.deliver();
      transport.step(model: {'id': 'another-model', 'providerID': 'opencode'});
      await _until(() => received.any((e) => e.isError));
      expect(client.responseModel('ses_test'), isNull);
      transport.pages = [
        {
          'data': [
            {'id': 'msg_request', 'type': 'user'},
            {
              'id': 'msg_a',
              'type': 'assistant',
              'model': {'id': 'another-model', 'providerID': 'opencode'},
              'content': <Object>[],
            },
          ],
          'cursor': {},
        },
      ];
      await expectLater(
        client.messages('ses_test'),
        throwsA(isA<AiRuntimeGenerationException>()),
      );
    },
  );

  test(
    'reconnects native SSE and keeps correlation across the disconnect',
    () async {
      final received = <AiRuntimeEvent>[];
      final sub = (await client.connectEvents()).listen(received.add);
      addTearDown(sub.cancel);
      await client.promptAsync('ses_test', _prompt);
      transport.deliver();
      transport.step();
      await _until(() => received.isNotEmpty);
      await transport.streams.first.close();
      await _until(() => transport.streams.length > 1);
      transport.emit('session.text.delta', {
        'assistantMessageID': 'msg_a',
        'ordinal': 0,
        'delta': 'After reconnect',
      });
      await _until(() => received.any((e) => e.textDelta == 'After reconnect'));
    },
  );
}

Future<void> _until(bool Function() predicate) async {
  final watch = Stopwatch()..start();
  while (!predicate()) {
    if (watch.elapsed > const Duration(seconds: 2)) {
      fail('Timed out waiting for synthetic event.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

class _Transport extends http.BaseClient {
  final requests = <http.Request>[];
  final streams = <StreamController<List<int>>>[];
  int eventCancellations = 0;
  int eventStatus = 200;
  Completer<void>? connectGate;
  List<Map<String, Object?>> models = [];
  List<Map<String, Object?>> pending = [];
  List<Map<String, Object?>> pages = [
    {'data': <Object>[], 'cursor': <String, Object>{}},
  ];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = await request.finalize().bytesToString();
    requests.add(
      http.Request(request.method, request.url)
        ..headers.addAll(request.headers)
        ..body = body,
    );
    final path = request.url.path;
    if (path == '/api/event') {
      await connectGate?.future;
      final stream = StreamController<List<int>>(
        onCancel: () => eventCancellations++,
      );
      streams.add(stream);
      return http.StreamedResponse(
        stream.stream,
        eventStatus,
        headers: {'content-type': 'text/event-stream'},
      );
    }
    Object response = <String, Object>{};
    if (path == '/api/session') {
      response = {
        'data': {'id': 'ses_test'},
      };
    }
    if (path == '/api/model') response = {'data': models};
    if (path.endsWith('/permission')) response = {'data': pending};
    if (path.endsWith('/message')) {
      response = pages[request.url.queryParameters['cursor'] == null ? 0 : 1];
    }
    return http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(response))),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }

  void emit(String type, Map<String, Object?> data) => streams.last.add(
    utf8.encode(
      'data: ${jsonEncode({
        'type': type,
        'data': {'sessionID': 'ses_test', ...data},
      })}\n\n',
    ),
  );
  void deliver() => emit('session.inbox.delivered', {'inboxID': 'msg_request'});
  void step({Map<String, Object?> model = _model}) => emit(
    'session.step.started',
    {'assistantMessageID': 'msg_a', 'model': model},
  );
  @override
  void close() {
    for (final stream in streams) {
      if (!stream.isClosed) unawaited(stream.close());
    }
  }
}
