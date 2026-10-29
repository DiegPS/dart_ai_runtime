import 'package:dart_ai_runtime/dart_ai_runtime.dart';
import 'package:test/test.dart';

void main() {
  test(
    'verified free quota wording is conservative and preserves its cause',
    () {
      for (final message in [
        'Free usage limit reached. Free models work in OpenCode (https://opencode.ai); subscribe to OpenCode Go to keep going: https://opencode.ai/go',
        'Free usage exceeded, subscribe to Go',
        'Service unavailable',
        'Resource exhausted',
        'Rate limit exceeded',
        'Usage limit reached. It will reset in 5 minutes.',
      ]) {
        final status = {
          'type': 'retry',
          'attempt': 1,
          'message': message,
          'next': 2000,
        };
        final event = AiRuntimeEvent.fromJson({
          'type': 'session.status',
          'properties': {'sessionID': 'session-1', 'status': status},
        });
        expect(event.isError, message.startsWith('Free usage'));
        if (event.isError) expect(event.failure!.cause, same(status));
      }
    },
  );

  test('ProviderAuthError is typed without requiring HTTP status', () {
    final cause = {
      'name': 'ProviderAuthError',
      'data': {'providerID': 'test', 'message': 'Bearer secret'},
    };
    final error = AiRuntimeGenerationException.fromRuntimeError(cause);
    expect(error.kind, AiRuntimeFailureKind.authentication);
    expect(error.cause, same(cause));
    expect(error.toString(), isNot(contains('secret')));
  });

  test(
    'null error is not treated as rejection and unknown errors retain cause',
    () {
      expect(
        AiRuntimeEvent.fromJson({
          'type': 'message.updated',
          'properties': {'error': null},
        }).isError,
        isFalse,
      );
      final cause = {
        'name': 'UnknownError',
        'data': {'message': 'private body'},
      };
      final error = AiRuntimeGenerationException.fromRuntimeError(cause);
      expect(error.kind, AiRuntimeFailureKind.unknown);
      expect(error.cause, same(cause));
      expect(error.toString(), isNot(contains('private body')));
    },
  );
  test('prompt correlation id is optional and serialized without losing permissions', () {
    const prompt = AiPrompt(
      providerId: 'test',
      modelId: 'model',
      system: 'System',
      text: 'Question',
      messageId: 'msg_synthetic',
    );
    expect(prompt.toJson()['messageID'], 'msg_synthetic');
    expect(prompt.toJson()['tools'], {'*': false});
    const legacy = AiPrompt(
      providerId: 'test',
      modelId: 'model',
      system: 'System',
      text: 'Question',
    );
    expect(legacy.toJson().containsKey('messageID'), false);
  });
  test('prompts deny every tool by default', () {
    const prompt = AiPrompt(
      providerId: 'kilo',
      modelId: 'kilo-auto/free',
      system: 'Be concise.',
      text: 'Hello',
    );

    expect(prompt.toJson()['tools'], {'*': false});
  });

  test('session updates do not expose their id as a message id', () {
    final event = AiRuntimeEvent.fromJson({
      'type': 'session.updated',
      'properties': {
        'info': {'id': 'session-1'},
      },
    });

    expect(event.messageId, isNull);
  });

  test('message part events expose correlation and streaming fields', () {
    final event = AiRuntimeEvent.fromJson({
      'payload': {
        'type': 'message.part.delta',
        'properties': {
          'sessionID': 'session-1',
          'messageID': 'message-1',
          'partID': 'part-1',
          'field': 'text',
          'delta': 'hello',
        },
      },
    });

    expect(event.sessionId, 'session-1');
    expect(event.messageId, 'message-1');
    expect(event.partId, 'part-1');
    expect(event.textDelta, 'hello');
  });

  test('runtime endpoint recognizes supported loopback forms', () {
    for (final host in ['127.0.0.1', 'localhost', '[::1]']) {
      final endpoint = AiRuntimeEndpoint(
        kind: AiRuntimeKind.openCode,
        baseUri: Uri.parse('http://$host:4096'),
        username: 'user',
        password: 'password',
        pid: 1,
      );
      expect(endpoint.isLoopback, isTrue);
    }
  });
}
