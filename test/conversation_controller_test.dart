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
  bool disposed = false;
  AiPrompt? lastPrompt;
  final List<AiPrompt> prompts = [];
  int createSessionCount = 0;
  Completer<void>? promptAccepted;

  void emit(AiRuntimeEvent event) => _events.add(event);

  @override
  Future<void> abort(String sessionId) async => abortCount++;

  @override
  Future<List<AiAuthMethod>> authMethods() async => const [];

  @override
  Future<Stream<AiRuntimeEvent>> connectEvents() async {
    eventsConnected = true;
    return _events.stream;
  }

  @override
  Future<AiSession> createSession({String? title}) async =>
      AiSession(id: 'session-${++createSessionCount}');

  @override
  Future<void> deleteSession(String sessionId) async {}

  @override
  void dispose() {
    disposed = true;
    _events.close();
  }

  @override
  Stream<AiRuntimeEvent> events() => _events.stream;

  @override
  Future<List<Map<String, dynamic>>> messages(String sessionId) async =>
      history;

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
