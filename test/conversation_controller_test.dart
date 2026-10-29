// ignore_for_file: use_null_aware_elements

import 'dart:async';

import 'package:dart_ai_runtime/dart_ai_runtime.dart';
import 'package:test/test.dart';

void main() {
  late AiRuntimeSupervisor supervisor;
  late _ProcessService processes;

  setUp(() async {
    processes = _ProcessService();
    supervisor = AiRuntimeSupervisor(
      installer: _Installer(),
      processes: processes,
      health: _Health(),
    );
    await supervisor.start(AiRuntimeKind.openCode);
  });

  tearDown(() => supervisor.dispose());

  Future<void> waitForPrompt(_RuntimeClient client) async {
    while (client.lastPrompt == null) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<Object> request(AiConversationController controller) => controller
      .sendAndWait(
        text: 'Hello',
        providerId: 'test',
        modelId: 'model',
        systemPrompt: '',
        timeout: const Duration(seconds: 1),
      )
      .then<Object>((value) => value, onError: (Object error) => error);

  AiRuntimeEvent rejection({String session = 'session-1'}) =>
      AiRuntimeEvent.fromJson({
        'type': 'session.status',
        'properties': {
          'sessionID': session,
          'status': {
            'type': 'retry',
            'attempt': 1,
            'message': 'Free usage exceeded, subscribe to Go',
            'action': {
              'reason': 'free_tier_limit',
              'provider': 'opencode',
              'title': 'Free limit reached',
              'message': 'Subscribe to OpenCode Go for reliable access to the best open-source models for \$10/month.',
              'label': 'subscribe',
              'link': 'https://opencode.ai/go',
            },
            'next': 2000,
          },
        },
      });

  for (final cleanup in ['success', 'failure', 'stalled']) {
    test(
      'quota rejection before text survives $cleanup cleanup and allows another turn',
      () async {
        final client = _RuntimeClient();
        if (cleanup == 'failure') {
          client.abortFailure = StateError('abort failed');
          client.deleteFailure = StateError('delete failed');
        }
        final stalled = Completer<void>();
        if (cleanup == 'stalled') client.abortGate = stalled;
        final controller = AiConversationController(
          supervisor: supervisor,
          clientFactory: (_) => client,
          reconciliationInterval: const Duration(milliseconds: 10),
        );
        addTearDown(controller.dispose);
        final first = request(controller);
        await waitForPrompt(client);
        final event = rejection();
        client.emit(event);
        client.emit(
          _event('message.updated', messageId: 'late', role: 'assistant'),
        );
        client.emit(
          _event('message.part.updated', messageId: 'late', fullText: 'late'),
        );
        client.emit(_event('message.completed', messageId: 'late'));
        final error = await first;
        expect(
          error,
          isA<AiRuntimeGenerationException>().having(
            (e) => e.kind,
            'kind',
            AiRuntimeFailureKind.quotaExceeded,
          ),
        );
        expect(
          (error as AiRuntimeGenerationException).cause,
          same(event.properties['status']),
        );
        expect(controller.state.error, same(error));
        expect(controller.state.sessionId, isNull);
        expect(controller.state.isBusy, isFalse);
        expect(controller.state.streamedText, isEmpty);
        client.onPrompt = () {
          client.emit(
            rejection(),
          ); // Retired session cannot reject the new turn.
          client.emit(
            _event(
              'message.updated',
              sessionId: 'session-2',
              messageId: 'next',
              role: 'assistant',
            ),
          );
          client.emit(
            _event(
              'message.part.updated',
              sessionId: 'session-2',
              messageId: 'next',
              fullText: 'Recovered',
            ),
          );
          client.emit(
            _event(
              'message.completed',
              sessionId: 'session-2',
              messageId: 'next',
            ),
          );
        };
        expect(await request(controller), 'Recovered');
        if (cleanup == 'stalled') stalled.complete();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(client.abortCount, 1);
        expect(client.deletedSessions, ['session-1']);
        expect(controller.state.error, isNull);
      },
    );
  }

  test(
    'temporary retry and unrelated errors do not reject a valid answer',
    () async {
      final client = _RuntimeClient();
      final controller = AiConversationController(
        supervisor: supervisor,
        clientFactory: (_) => client,
      );
      addTearDown(controller.dispose);
      final response = request(controller);
      await waitForPrompt(client);
      client.emit(rejection(session: 'other'));
      client.emit(
        AiRuntimeEvent.fromJson({
          'type': 'session.error',
          'properties': {
            'error': {
              'name': 'APIError',
              'data': {'statusCode': 403},
            },
          },
        }),
      ); // Unscoped failure is not attributable to this generation.
      client.emit(
        AiRuntimeEvent.fromJson({
          'type': 'message.updated',
          'properties': {
            'info': {
              'id': 'old',
              'sessionID': 'session-1',
              'role': 'assistant',
              'parentID': 'previous-request',
              'error': {
                'name': 'ProviderAuthError',
                'data': {'message': 'denied'},
              },
            },
          },
        }),
      );
      client.emit(
        AiRuntimeEvent.fromJson({
          'type': 'session.status',
          'properties': {
            'sessionID': 'session-1',
            'status': {
              'type': 'retry',
              'attempt': 1,
              'message': 'Service unavailable',
              'next': 2000,
            },
          },
        }),
      );
      client.emit(
        _event('message.updated', messageId: 'answer', role: 'assistant'),
      );
      client.emit(
        _event('message.part.updated', messageId: 'answer', fullText: 'OK'),
      );
      client.emit(_event('message.completed', messageId: 'answer'));
      expect(await response, 'OK');
      expect(client.abortCount, 0);
    },
  );

  for (final channel in ['session.error', 'message.updated', 'snapshot']) {
    for (final code in [401, 403]) {
      test(
        '$channel exposes HTTP $code before text without timing out',
        () async {
          final client = _RuntimeClient();
          final controller = AiConversationController(
            supervisor: supervisor,
            clientFactory: (_) => client,
            reconciliationInterval: const Duration(milliseconds: 10),
          );
          addTearDown(controller.dispose);
          final response = request(controller);
          await waitForPrompt(client);
          final cause = {
            'name': 'APIError',
            'data': {
              'message': 'private failure',
              'statusCode': code,
              'isRetryable': false,
              'responseBody': 'secret',
              'responseHeaders': {'authorization': 'Bearer secret'},
            },
          };
          final info = {
            'id': 'assistant',
            'sessionID': 'session-1',
            'role': 'assistant',
            'parentID': client.lastPrompt!.messageId,
            'error': cause,
          };
          if (channel == 'snapshot') {
            client.history = [
              {'info': info, 'parts': <Object>[]},
            ];
          } else {
            client.emit(
              AiRuntimeEvent.fromJson({
                'type': channel,
                'properties': {
                  'sessionID': 'session-1',
                  if (channel == 'session.error')
                    'error': cause
                  else
                    'info': info,
                },
              }),
            );
          }
          final error = await response;
          expect(error, isA<AiRuntimeGenerationException>());
          final failure = error as AiRuntimeGenerationException;
          expect(
            failure.kind,
            code == 401
                ? AiRuntimeFailureKind.authentication
                : AiRuntimeFailureKind.permissionDenied,
          );
          expect(failure.cause, same(cause));
          expect(failure.toString(), isNot(contains('secret')));
          expect(failure.toString(), isNot(contains('private failure')));
        },
      );
    }
  }

  test(
    'rejection during pending dispatch cannot fail the next request',
    () async {
      final client = _RuntimeClient()..promptAccepted = Completer<void>();
      final oldDispatch = client.promptAccepted!;
      final controller = AiConversationController(
        supervisor: supervisor,
        clientFactory: (_) => client,
      );
      addTearDown(controller.dispose);
      final first = request(controller);
      await waitForPrompt(client);
      client.emit(rejection());
      expect(await first, isA<AiRuntimeGenerationException>());
      client.promptAccepted = null;
      final next = request(controller);
      while (client.prompts.length < 2) {
        await Future<void>.delayed(Duration.zero);
      }
      oldDispatch.completeError(StateError('late dispatch failure'));
      await Future<void>.delayed(Duration.zero);
      expect(client.abortCount, 1);
      client.emit(
        _event(
          'message.updated',
          sessionId: 'session-2',
          messageId: 'next',
          role: 'assistant',
        ),
      );
      client.emit(
        _event(
          'message.part.updated',
          sessionId: 'session-2',
          messageId: 'next',
          fullText: 'OK',
        ),
      );
      client.emit(
        _event('message.completed', sessionId: 'session-2', messageId: 'next'),
      );
      expect(await next, 'OK');
    },
  );

  test('rejection cleanup expires while dispatch stays silent', () async {
    final gate = Completer<void>();
    final client = _RuntimeClient()..promptAccepted = gate;
    final controller = AiConversationController(
      supervisor: supervisor,
      clientFactory: (_) => client,
    );
    addTearDown(controller.dispose);
    final response = request(controller);
    await waitForPrompt(client);
    client.emit(rejection());
    final error = await response;
    expect(error, isA<AiRuntimeGenerationException>());
    await Future<void>.delayed(const Duration(milliseconds: 2100));
    expect(controller.state.error, same(error));
    expect(controller.state.isBusy, isFalse);
    expect(client.abortCount, 0);
    expect(client.deletedSessions, isEmpty);
    gate.complete();
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.error, same(error));
  });

  test('typed reconciliation failures retire the turn instead of becoming timeouts', () async {
    final error = AiRuntimeGenerationException(
      kind: AiRuntimeFailureKind.unknown,
      cause: {'type': 'runtime.model-mismatch'},
    );
    final client = _RuntimeClient()..snapshotFailure = error;
    final controller = AiConversationController(
      supervisor: supervisor,
      clientFactory: (_) => client,
      reconciliationInterval: const Duration(milliseconds: 10),
    );
    addTearDown(controller.dispose);
    expect(await request(controller), same(error));
    expect(controller.state.error, same(error));
    expect(controller.state.isBusy, isFalse);
    expect(controller.state.sessionId, isNull);
  });

  for (final partKind in ['text', 'reasoning']) {
    test(
      'active $partKind progress outlives the idle reconciliation budget',
      () async {
        final client = _RuntimeClient();
        final controller = AiConversationController(
          supervisor: supervisor,
          clientFactory: (_) => client,
          reconciliationInterval: const Duration(milliseconds: 20),
          reconciliationAttempts: 3,
        );
        addTearDown(controller.dispose);
        final response = controller
            .sendAndWait(
              text: 'Synthetic question',
              providerId: 'test',
              modelId: 'model',
              systemPrompt: 'System',
              timeout: const Duration(seconds: 2),
            )
            .then<Object>((value) => value, onError: (Object error) => error);
        while (client.lastPrompt == null) {
          await Future<void>.delayed(Duration.zero);
        }
        client.emit(
          _event('message.updated', messageId: 'current', role: 'assistant'),
        );
        client.emit(
          AiRuntimeEvent.fromJson({
            'type': 'message.part.updated',
            'properties': {
              'sessionID': 'session-1',
              'part': {
                'id': 'progress',
                'messageID': 'current',
                'type': partKind,
                'text': '',
              },
            },
          }),
        );
        for (var index = 0; index < 10; index++) {
          await Future<void>.delayed(const Duration(milliseconds: 15));
          client.emit(
            _event(
              'message.part.delta',
              messageId: 'current',
              partId: 'progress',
              delta: 'x',
            ),
          );
          if (partKind == 'reasoning') {
            expect(controller.state.streamedText, isEmpty);
          }
        }
        client.emit(
          _event(
            'message.part.updated',
            messageId: 'current',
            partId: 'answer',
            fullText: 'Visible answer',
          ),
        );
        client.emit(_event('message.completed', messageId: 'current'));
        expect(
          await response,
          partKind == 'text' ? 'xxxxxxxxxxVisible answer' : 'Visible answer',
        );
      },
    );
  }

  for (final kind in ['heartbeat', 'stale-assistant']) {
    test(
      '$kind events cannot postpone idle timeout and retired context is not reused',
      () async {
        final client = _RuntimeClient();
        final controller = AiConversationController(
          supervisor: supervisor,
          clientFactory: (_) => client,
          reconciliationInterval: const Duration(milliseconds: 20),
          reconciliationAttempts: 3,
          responseTimeout: const Duration(seconds: 1),
        );
        addTearDown(controller.dispose);
        Timer? noise;
        client.onPrompt = () {
          noise = Timer.periodic(const Duration(milliseconds: 10), (_) {
            client.emit(
              kind == 'heartbeat'
                  ? _event('server.heartbeat')
                  : AiRuntimeEvent.fromJson({
                      'type': 'message.part.delta',
                      'properties': {
                        'sessionID': 'session-1',
                        'messageID': 'stale',
                        'parentID': 'old-question',
                        'role': 'assistant',
                        'partID': 'old-part',
                        'field': 'text',
                        'delta': 'ignored',
                      },
                    }),
            );
          });
        };
        final clock = Stopwatch()..start();
        final response = await controller
            .sendAndWait(
              text: 'Timed-out question',
              providerId: 'test',
              modelId: 'model',
              systemPrompt: 'System',
            )
            .then<Object>((value) => value, onError: (Object error) => error);
        noise?.cancel();
        expect(response, isA<TimeoutException>());
        expect(clock.elapsed, lessThan(const Duration(seconds: 1)));
        expect(client.abortCount, 1);
        expect(controller.state.sessionId, isNull);
        expect(controller.state.messages.single.isCancelled, isTrue);
        client.onPrompt = () => scheduleMicrotask(() {
          client.emit(
            _event(
              'message.updated',
              sessionId: 'session-2',
              messageId: 'next',
              role: 'assistant',
            ),
          );
          client.emit(
            _event(
              'message.part.updated',
              sessionId: 'session-2',
              messageId: 'next',
              partId: 'answer',
              fullText: 'Next answer',
            ),
          );
          client.emit(
            _event(
              'message.completed',
              sessionId: 'session-2',
              messageId: 'next',
            ),
          );
        });
        expect(
          await controller.sendAndWait(
            text: 'Next question',
            providerId: 'test',
            modelId: 'model',
            systemPrompt: 'System',
          ),
          'Next answer',
        );
        expect(client.createSessionCount, 2);
        expect(client.lastPrompt!.text, isNot(contains('Timed-out question')));
      },
    );
  }

  test('continuous progress still obeys the total response deadline', () async {
    final client = _RuntimeClient();
    final controller = AiConversationController(
      supervisor: supervisor,
      clientFactory: (_) => client,
      reconciliationInterval: const Duration(milliseconds: 20),
      reconciliationAttempts: 3,
      responseTimeout: const Duration(milliseconds: 100),
    );
    addTearDown(controller.dispose);
    Timer? progress;
    client.onPrompt = () {
      client.emit(
        _event('message.updated', messageId: 'current', role: 'assistant'),
      );
      progress = Timer.periodic(const Duration(milliseconds: 10), (_) {
        client.emit(
          _event(
            'message.part.delta',
            messageId: 'current',
            partId: 'answer',
            delta: 'x',
          ),
        );
      });
    };
    final response = await controller
        .sendAndWait(
          text: 'Question',
          providerId: 'test',
          modelId: 'model',
          systemPrompt: 'System',
        )
        .then<Object>((value) => value, onError: (Object error) => error);
    progress?.cancel();
    expect(response, isA<TimeoutException>());
    expect(client.abortCount, 1);
    expect(controller.state.status, AiConversationStatus.error);
    expect(controller.state.sessionId, isNull);
    expect(controller.state.messages.last.isCancelled, isTrue);
  });

  test('timeout retires local context even if runtime abort fails', () async {
    final client = _RuntimeClient()
      ..abortFailure = StateError('Synthetic abort failure');
    final controller = AiConversationController(
      supervisor: supervisor,
      clientFactory: (_) => client,
      reconciliationInterval: const Duration(milliseconds: 5),
      reconciliationAttempts: 2,
    );
    addTearDown(controller.dispose);
    final response = await controller
        .sendAndWait(
          text: 'Question',
          providerId: 'test',
          modelId: 'model',
          systemPrompt: 'System',
        )
        .then<Object>((value) => value, onError: (Object error) => error);
    expect(response, isA<TimeoutException>());
    expect(controller.state.sessionId, isNull);
    expect(controller.state.messages.single.isCancelled, isTrue);
  });

  test(
    'advancing polling snapshots outlive the idle reconciliation budget',
    () async {
      final client = _RuntimeClient();
      final controller = AiConversationController(
        supervisor: supervisor,
        clientFactory: (_) => client,
        reconciliationInterval: const Duration(milliseconds: 20),
        reconciliationAttempts: 3,
      );
      addTearDown(controller.dispose);
      Timer? updates;
      client.onPrompt = () {
        var size = 0;
        updates = Timer.periodic(const Duration(milliseconds: 15), (timer) {
          size++;
          client.history = [
            {
              'info': {
                'id': 'current',
                'role': 'assistant',
                'parentID': client.lastPrompt!.messageId,
                if (size == 10) 'finish': 'stop',
              },
              'parts': [
                {'type': 'text', 'text': 'x' * size},
              ],
            },
          ];
          if (size == 10) timer.cancel();
        });
      };
      try {
        expect(
          await controller.sendAndWait(
            text: 'Question',
            providerId: 'test',
            modelId: 'model',
            systemPrompt: 'System',
            timeout: const Duration(seconds: 2),
          ),
          'xxxxxxxxxx',
        );
      } finally {
        updates?.cancel();
      }
    },
  );

  test('connects SSE before dispatching a prompt and streams once', () async {
    final client = _RuntimeClient();
    final controller = AiConversationController(
      supervisor: supervisor,
      clientFactory: (_) => client,
      reconciliationInterval: const Duration(seconds: 5),
    );
    client.onPrompt = () {
      expect(client.eventsConnected, isTrue);
      scheduleMicrotask(() {
        client.emit(
          _event(
            'message.updated',
            messageId: 'assistant-1',
            role: 'assistant',
          ),
        );
        client.emit(
          _event(
            'message.part.delta',
            messageId: 'assistant-1',
            partId: 'part-1',
            delta: 'Hello ',
          ),
        );
        client.emit(
          _event(
            'message.part.updated',
            messageId: 'assistant-1',
            partId: 'part-1',
            fullText: 'Hello world',
          ),
        );
        client.emit(_event('message.completed', messageId: 'assistant-1'));
      });
    };

    final result = await controller.sendAndWait(
      text: 'Question',
      providerId: 'test',
      modelId: 'model',
      systemPrompt: 'System',
    );

    expect(result, 'Hello world');
    expect(controller.state.messages.last.content, 'Hello world');
    expect(client.lastPrompt?.toolPermissions, {'*': false});
    await controller.dispose();
  });

  test(
    'ignores prior and user events when correlating the assistant',
    () async {
      final client = _RuntimeClient()
        ..history = [
          {
            'info': {'id': 'old', 'role': 'assistant'},
            'parts': [
              {'type': 'text', 'text': 'old answer'},
            ],
          },
        ];
      final controller = AiConversationController(
        supervisor: supervisor,
        clientFactory: (_) => client,
        reconciliationInterval: const Duration(seconds: 5),
      );
      client.onPrompt = () => scheduleMicrotask(() {
        client.emit(
          _event('message.part.delta', messageId: 'old', delta: 'BAD'),
        );
        client.emit(
          _event('message.updated', messageId: 'user-remote', role: 'user'),
        );
        client.emit(
          _event('message.part.delta', messageId: 'user-remote', delta: 'BAD'),
        );
        client.emit(
          _event('message.updated', messageId: 'new', role: 'assistant'),
        );
        client.emit(
          _event('message.part.delta', messageId: 'new', delta: 'Good'),
        );
        client.emit(_event('message.completed', messageId: 'new'));
      });

      expect(
        await controller.sendAndWait(
          text: 'Repeated question',
          providerId: 'test',
          modelId: 'model',
          systemPrompt: 'System',
        ),
        'Good',
      );
      await controller.dispose();
    },
  );

  test('late events after abort cannot contaminate the next state', () async {
    final client = _RuntimeClient();
    final controller = AiConversationController(
      supervisor: supervisor,
      clientFactory: (_) => client,
      reconciliationInterval: const Duration(seconds: 5),
    );
    await controller.sendMessage(
      text: 'Long question',
      providerId: 'test',
      modelId: 'model',
      systemPrompt: 'System',
    );
    await controller.abort();
    client.emit(_event('message.part.delta', messageId: 'late', delta: 'BAD'));
    client.emit(_event('message.completed', messageId: 'late'));
    await Future<void>.delayed(Duration.zero);

    expect(client.abortCount, 1);
    expect(controller.state.streamedText, isEmpty);
    expect(
      controller.state.messages.where((item) => item.role == 'assistant'),
      isEmpty,
    );
    await controller.dispose();
  });

  test(
    'transport cancellation errors do not escape conversation disposal',
    () async {
      final events = StreamController<AiRuntimeEvent>(
        onCancel: () =>
            Future<void>.error(StateError('Synthetic closed transport')),
      );
      final client = _RuntimeClient()..eventOverride = events.stream;
      final controller = AiConversationController(
        supervisor: supervisor,
        clientFactory: (_) => client,
      );
      await controller.sendMessage(
        text: 'Question',
        providerId: 'test',
        modelId: 'model',
        systemPrompt: 'System',
      );
      await controller.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(client.disposed, true);
    },
  );

  test('abort waits until an in-flight prompt has been accepted', () async {
    final client = _RuntimeClient()..promptAccepted = Completer<void>();
    final controller = AiConversationController(
      supervisor: supervisor,
      clientFactory: (_) => client,
    );
    addTearDown(controller.dispose);
    final sending = controller.sendMessage(
      text: 'Long question',
      providerId: 'test',
      modelId: 'model',
      systemPrompt: 'System',
    );
    while (client.lastPrompt == null) {
      await Future<void>.delayed(Duration.zero);
    }
    final cancelling = controller.abort();
    await Future<void>.delayed(Duration.zero);
    expect(
      client.abortCount,
      0,
      reason: 'Aborting before prompt acceptance leaves a future generation running',
    );
    expect(controller.state.status, AiConversationStatus.canceling);
    client.promptAccepted!.complete();
    await Future.wait([sending, cancelling]);
    expect(client.abortCount, 1);
    expect(controller.state.status, AiConversationStatus.idle);
  });

  test(
    'polling excludes a cancelled reply that appears after the next baseline',
    () async {
      final client = _RuntimeClient();
      final controller = AiConversationController(
        supervisor: supervisor,
        clientFactory: (_) => client,
        reconciliationInterval: const Duration(milliseconds: 5),
      );
      addTearDown(controller.dispose);
      await controller.sendMessage(
        text: 'Cancelled',
        providerId: 'test',
        modelId: 'model',
        systemPrompt: 'System',
      );
      final oldParent =
          client.lastPrompt!.toJson()['messageID'] ?? 'old-parent';
      await controller.abort();
      client.onPrompt = () {
        final newParent =
            client.lastPrompt!.toJson()['messageID'] ?? 'new-parent';
        client.history = [
          {
            'info': {
              'id': 'late-old',
              'role': 'assistant',
              'parentID': oldParent,
              'finish': 'stop',
            },
            'parts': [
              {'type': 'text', 'text': 'WRONG cancelled answer'},
            ],
          },
          {
            'info': {
              'id': 'current',
              'role': 'assistant',
              'parentID': newParent,
              'finish': 'stop',
            },
            'parts': [
              {'type': 'text', 'text': 'Correct current answer'},
            ],
          },
        ];
      };
      final answer = await controller.sendAndWait(
        text: 'Current',
        providerId: 'test',
        modelId: 'model',
        systemPrompt: 'System',
      );
      expect(answer, 'Correct current answer');
    },
  );

  test(
    'disposal closes the client even if SSE cancellation never completes',
    () async {
      final events = StreamController<AiRuntimeEvent>(
        onCancel: () => Completer<void>().future,
      );
      final client = _RuntimeClient()..eventOverride = events.stream;
      final controller = AiConversationController(
        supervisor: supervisor,
        clientFactory: (_) => client,
      );
      await controller.sendMessage(
        text: 'Question',
        providerId: 'test',
        modelId: 'model',
        systemPrompt: 'System',
      );
      await controller.dispose().timeout(const Duration(seconds: 3));
      expect(client.disposed, true);
    },
  );

  test('runtime restart creates a new client and session', () async {
    final clients = <_RuntimeClient>[];
    final controller = AiConversationController(
      supervisor: supervisor,
      clientFactory: (_) {
        final client = _RuntimeClient();
        clients.add(client);
        return client;
      },
      reconciliationInterval: const Duration(seconds: 5),
    );
    // Force creation through the first turn and cancel it.
    await controller.sendMessage(
      text: 'First',
      providerId: 'test',
      modelId: 'model',
      systemPrompt: 'System',
    );
    await controller.abort();
    expect(controller.state.sessionId, isNull);

    await supervisor.restart();
    await controller.sendMessage(
      text: 'Second',
      providerId: 'test',
      modelId: 'model',
      systemPrompt: 'System',
    );
    expect(clients, hasLength(2));
    expect(clients.first.disposed, isTrue);
    expect(controller.state.sessionId, isNotNull);
    await controller.abort();
    await controller.dispose();
  });

  test(
    'late cancelled SSE and session idle cannot complete the current turn',
    () async {
      final client = _RuntimeClient();
      final controller = AiConversationController(
        supervisor: supervisor,
        clientFactory: (_) => client,
        reconciliationInterval: const Duration(seconds: 5),
      );
      addTearDown(controller.dispose);
      await controller.sendMessage(
        text: 'Cancelled',
        providerId: 'test',
        modelId: 'model',
        systemPrompt: 'System',
      );
      final oldParent = client.lastPrompt!.messageId;
      await controller.abort();
      client.onPrompt = () => scheduleMicrotask(() {
        void assistant(String id, String? parent) => client.emit(
          AiRuntimeEvent.fromJson({
            'type': 'message.updated',
            'properties': {
              'info': {
                'id': id,
                'sessionID': 'session-2',
                'role': 'assistant',
                'parentID': parent,
              },
            },
          }),
        );
        assistant('stale', oldParent);
        client.emit(
          _event(
            'message.part.delta',
            messageId: 'stale',
            delta: 'WRONG',
            sessionId: 'session-2',
          ),
        );
        client.emit(
          _event(
            'message.completed',
            messageId: 'stale',
            sessionId: 'session-2',
          ),
        );
        assistant('current', client.lastPrompt!.messageId);
        client.emit(
          _event(
            'message.part.delta',
            messageId: 'current',
            partId: 'current-part',
            delta: 'Correct ',
            sessionId: 'session-2',
          ),
        );
        client.emit(_event('session.idle', sessionId: 'session-2'));
        client.emit(
          _event(
            'message.part.delta',
            messageId: 'current',
            partId: 'current-part',
            delta: 'answer',
            sessionId: 'session-2',
          ),
        );
        client.emit(
          _event(
            'message.completed',
            messageId: 'current',
            sessionId: 'session-2',
          ),
        );
      });
      expect(
        await controller.sendAndWait(
          text: 'Current',
          providerId: 'test',
          modelId: 'model',
          systemPrompt: 'System',
        ),
        'Correct answer',
      );
      expect(
        client.prompts.map((prompt) => prompt.messageId).toSet(),
        hasLength(2),
      );
      for (final prompt in client.prompts) {
        expect(prompt.messageId, matches(RegExp(r'^msg_[a-zA-Z0-9]{26}$')));
      }
    },
  );

  test(
    'a cancelled finish does not finish a partial current polling response',
    () async {
      final client = _RuntimeClient();
      final controller = AiConversationController(
        supervisor: supervisor,
        clientFactory: (_) => client,
        reconciliationInterval: const Duration(milliseconds: 5),
      );
      addTearDown(controller.dispose);
      client.onPrompt = () {
        client.history = [
          {
            'info': {
              'id': 'stale',
              'role': 'assistant',
              'parentID': 'old-parent',
              'finish': 'stop',
            },
            'parts': [
              {'type': 'text', 'text': 'WRONG'},
            ],
          },
          {
            'info': {
              'id': 'current',
              'role': 'assistant',
              'parentID': client.lastPrompt!.messageId,
            },
            'parts': [
              {'type': 'text', 'text': 'Partial current'},
            ],
          },
        ];
      };
      var completed = false;
      final pending = controller
          .sendAndWait(
            text: 'Current',
            providerId: 'test',
            modelId: 'model',
            systemPrompt: 'System',
          )
          .then((answer) {
            completed = true;
            return answer;
          });
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(completed, false);
      expect(controller.state.streamedText, 'Partial current');
      (client.history.last['info'] as Map)['finish'] = 'stop';
      expect(await pending, 'Partial current');
    },
  );

  test('reuses one runtime session across consecutive prompts', () async {
    final client = _RuntimeClient();
    final controller = AiConversationController(
      supervisor: supervisor,
      clientFactory: (_) => client,
      reconciliationInterval: const Duration(seconds: 5),
    );
    var answer = 0;
    client.onPrompt = () => scheduleMicrotask(() {
      answer++;
      final messageId = 'assistant-$answer';
      client.emit(
        _event('message.updated', messageId: messageId, role: 'assistant'),
      );
      client.emit(
        _event(
          'message.part.updated',
          messageId: messageId,
          partId: 'part-$answer',
          fullText: 'Answer $answer',
        ),
      );
      client.emit(_event('message.completed', messageId: messageId));
    });

    expect(
      await controller.sendAndWait(
        text: 'First',
        providerId: 'test',
        modelId: 'model',
        systemPrompt: 'Current telemetry 1',
      ),
      'Answer 1',
    );
    expect(
      await controller.sendAndWait(
        text: 'Second',
        providerId: 'test',
        modelId: 'model',
        systemPrompt: 'Current telemetry 2',
      ),
      'Answer 2',
    );

    expect(client.createSessionCount, 1);
    expect(client.prompts.map((prompt) => prompt.system), [
      'Current telemetry 1',
      'Current telemetry 2',
    ]);
    expect(controller.state.sessionId, 'session-1');
    await controller.dispose();
  });

  test(
    'restores bounded history as untrusted context for a new session',
    () async {
      final client = _RuntimeClient();
      final store = _HistoryStore([
        AiChatMessage(
          id: 'old-user',
          role: 'user',
          content: 'Earlier question',
          timestamp: DateTime.utc(2026),
        ),
        AiChatMessage(
          id: 'old-assistant',
          role: 'assistant',
          content: 'Earlier answer',
          timestamp: DateTime.utc(2026),
        ),
      ]);
      final controller = AiConversationController(
        supervisor: supervisor,
        clientFactory: (_) => client,
        historyStore: store,
        reconciliationInterval: const Duration(seconds: 5),
      );
      await controller.sendMessage(
        text: 'Current question',
        providerId: 'test',
        modelId: 'model',
        systemPrompt: 'System',
      );
      expect(client.lastPrompt?.text, contains('untrusted data'));
      expect(client.lastPrompt?.text, contains('Earlier answer'));
      expect(client.lastPrompt?.text, endsWith('Current question'));
      await controller.abort();
      await controller.dispose();
    },
  );

  test('restored cancelled messages stay visible but are excluded from model context', () async {
    final client = _RuntimeClient();
    final store = _HistoryStore([
      AiChatMessage(
        id: 'user-ok',
        role: 'user',
        content: 'Earlier valid question',
        timestamp: DateTime.utc(2026),
      ),
      AiChatMessage(
        id: 'answer-ok',
        role: 'assistant',
        content: 'Earlier valid answer',
        timestamp: DateTime.utc(2026),
      ),
      AiChatMessage(
        id: 'cancelled-user',
        role: 'user',
        content: 'DO NOT CONTINUE THIS',
        timestamp: DateTime.utc(2026),
        isCancelled: true,
      ),
      AiChatMessage(
        id: 'cancelled-partial',
        role: 'assistant',
        content: 'CANCELLED PARTIAL',
        timestamp: DateTime.utc(2026),
        isCancelled: true,
      ),
    ]);
    final controller = AiConversationController(
      supervisor: supervisor,
      clientFactory: (_) => client,
      historyStore: store,
    );
    addTearDown(controller.dispose);
    await controller.sendMessage(
      text: 'Current question',
      providerId: 'test',
      modelId: 'model',
      systemPrompt: 'System',
    );
    expect(client.lastPrompt!.text, contains('Earlier valid answer'));
    expect(client.lastPrompt!.text, isNot(contains('DO NOT CONTINUE THIS')));
    expect(client.lastPrompt!.text, isNot(contains('CANCELLED PARTIAL')));
    expect(
      controller.state.messages.where((message) => message.isCancelled),
      hasLength(2),
    );
    await controller.abort();
    expect(controller.state.messages.last.isCancelled, true);
    expect(controller.state.sessionId, isNull);
  });
}

AiRuntimeEvent _event(
  String type, {
  String? messageId,
  String? partId,
  String? role,
  String? delta,
  String? fullText,
  String sessionId = 'session-1',
}) => AiRuntimeEvent.fromJson({
  'type': type,
  'properties': {
    'sessionID': sessionId,
    if (messageId != null) 'messageID': messageId,
    if (partId != null) 'partID': partId,
    if (role != null) 'role': role,
    if (delta != null) 'delta': delta,
    if (delta != null) 'field': 'text',
    if (fullText != null)
      'part': {
        'id': partId,
        'messageID': messageId,
        'type': 'text',
        'text': fullText,
      },
  },
});

class _RuntimeClient implements AiRuntimeClient {
  final _events = StreamController<AiRuntimeEvent>.broadcast();
  List<Map<String, dynamic>> history = [];
  void Function()? onPrompt;
  bool eventsConnected = false;
  int abortCount = 0;
  Object? abortFailure;
  Object? snapshotFailure;
  Object? deleteFailure;
  Completer<void>? abortGate;
  final List<String> deletedSessions = [];
  bool disposed = false;
  AiPrompt? lastPrompt;
  final List<AiPrompt> prompts = [];
  int createSessionCount = 0;
  Completer<void>? promptAccepted;
  Stream<AiRuntimeEvent>? eventOverride;

  void emit(AiRuntimeEvent event) => _events.add(event);

  @override
  Future<void> abort(String sessionId) async {
    abortCount++;
    await abortGate?.future;
    if (abortFailure != null) throw abortFailure!;
  }

  @override
  Future<List<AiAuthMethod>> authMethods() async => const [];

  @override
  Future<Stream<AiRuntimeEvent>> connectEvents() async {
    eventsConnected = true;
    return eventOverride ?? _events.stream;
  }

  @override
  Future<AiSession> createSession({String? title}) async =>
      AiSession(id: 'session-${++createSessionCount}');

  @override
  Future<void> deleteSession(String sessionId) async {
    deletedSessions.add(sessionId);
    if (deleteFailure != null) throw deleteFailure!;
  }

  @override
  void dispose() {
    disposed = true;
    _events.close();
  }

  @override
  Stream<AiRuntimeEvent> events() => _events.stream;

  @override
  Future<List<Map<String, dynamic>>> messages(String sessionId) async {
    if (lastPrompt != null && snapshotFailure != null) throw snapshotFailure!;
    return history;
  }

  @override
  Future<void> promptAsync(String sessionId, AiPrompt prompt) async {
    lastPrompt = prompt;
    prompts.add(prompt);
    onPrompt?.call();
    await promptAccepted?.future;
  }

  @override
  Future<List<AiProviderInfo>> providers() async => const [];

  @override
  Future<AiSession> session(String sessionId) async => AiSession(id: sessionId);
}

class _Installer implements AiRuntimeInstallService {
  final runtime = const PinnedAiRuntimeCatalog().definition(
    AiRuntimeKind.openCode,
  );

  @override
  AiRuntimeDefinition definition(AiRuntimeKind kind) => runtime;

  @override
  Future<AiRuntimeInstallation> install(
    AiRuntimeKind kind, {
    ArtifactDownloadCancellation? cancellation,
    void Function(ArtifactInstallProgress progress)? onProgress,
  }) async => AiRuntimeInstallation(definition: runtime, directoryPath: '.');

  @override
  Future<AiRuntimeInstallation?> installed(AiRuntimeKind kind) async =>
      AiRuntimeInstallation(definition: runtime, directoryPath: '.');
}

class _ProcessService implements AiRuntimeProcessService {
  int pid = 0;

  @override
  Future<AiRuntimeProcessHandle> start(
    AiRuntimeInstallation installation, {
    required String password,
  }) async => _Process(++pid, password);
}

class _Process implements AiRuntimeProcessHandle {
  _Process(int pid, String password)
    : endpoint = AiRuntimeEndpoint(
        kind: AiRuntimeKind.openCode,
        baseUri: Uri.parse('http://127.0.0.1:${9000 + pid}'),
        username: 'opencode',
        password: password,
        pid: pid,
      );

  final _exit = Completer<int>();

  @override
  final AiRuntimeEndpoint endpoint;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  Stream<String> get logs => const Stream.empty();

  @override
  Future<void> stop() async {
    if (!_exit.isCompleted) _exit.complete(0);
  }
}

class _Health implements AiRuntimeHealthService {
  @override
  Future<AiRuntimeHealth> waitUntilReady(
    AiRuntimeEndpoint endpoint, {
    Duration timeout = const Duration(seconds: 25),
  }) async => const AiRuntimeHealth(healthy: true);
}

class _HistoryStore implements AiConversationHistoryStore {
  _HistoryStore(this.messages);

  List<AiChatMessage> messages;

  @override
  Future<void> clear() async => messages = [];

  @override
  Future<List<AiChatMessage>> load() async => messages;

  @override
  Future<void> save(List<AiChatMessage> messages) async {
    this.messages = messages;
  }
}
