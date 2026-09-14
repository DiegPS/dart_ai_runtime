import 'dart:async';
import 'dart:io';

import 'package:dart_ai_runtime/dart_ai_runtime.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  final inferenceEnabled =
      Platform.environment['DART_AI_RUNTIME_TEST_INFERENCE'] == '1';
  for (final kind in AiRuntimeKind.values) {
    final executableVariable = kind == AiRuntimeKind.openCode
        ? 'DART_AI_RUNTIME_TEST_OPENCODE_EXE'
        : 'DART_AI_RUNTIME_TEST_KILO_EXE';
    final executablePath = Platform.environment[executableVariable];
    final providerId = kind == AiRuntimeKind.openCode ? 'opencode' : 'kilo';
    final modelId = kind == AiRuntimeKind.openCode
        ? Platform.environment['DART_AI_RUNTIME_TEST_OPENCODE_MODEL'] ??
              'big-pickle'
        : Platform.environment['DART_AI_RUNTIME_TEST_KILO_MODEL'] ??
              'openrouter/free';

    test(
      'uses changing neutral prompts in one real ${kind.displayName} session',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'air-neutral-session-',
        );
        final storage = AiRuntimeStorage(
          sharedStoreRoot: Directory(p.join(root.path, 'shared')),
          applicationDataRoot: Directory(p.join(root.path, 'private')),
          applicationId: 'neutral-session-test',
        );
        final processService = LocalAiRuntimeProcessService(storage);
        final health = AiRuntimeHealthClient();
        AiRuntimeProcessHandle? process;
        OpenCodeCompatibleRuntimeClient? client;
        try {
          process = await processService.start(
            AiRuntimeInstallation(
              definition: const PinnedAiRuntimeCatalog().definition(kind),
              directoryPath: File(executablePath!).parent.path,
            ),
            password: 'neutral-session-test-only',
          );
          expect(
            (await health.waitUntilReady(process.endpoint)).healthy,
            isTrue,
          );
          client = OpenCodeCompatibleRuntimeClient(
            endpoint: process.endpoint,
            workspaceDirectory: storage.workspace(kind).path,
            systemPromptService: processService.systemPromptService,
            requestTimeout: const Duration(seconds: 20),
          );
          final session = await client.createSession(
            title: 'Neutral multi-turn integration test',
          );

          final first = await _promptAndWait(
            client,
            session.id,
            AiPrompt(
              providerId: providerId,
              modelId: modelId,
              system:
                  'You are a neutral conversational assistant. Begin the answer '
                  'with exactly GODSENSE_TURN_ONE_73A1. Never use tools.',
              text: 'En una frase, confirma que recibiste el primer turno.',
            ),
          );
          final second = await _promptAndWait(
            client,
            session.id,
            AiPrompt(
              providerId: providerId,
              modelId: modelId,
              system:
                  'You are a neutral conversational assistant. Begin the answer '
                  'with exactly GODSENSE_TURN_TWO_84B2. Never use tools.',
              text: 'En una frase, confirma que este es el segundo turno.',
            ),
          );

          expect(first, contains('GODSENSE_TURN_ONE_73A1'));
          expect(second, contains('GODSENSE_TURN_TWO_84B2'));
          final pendingPrompt = File(
            p.join(
              storage.config(kind).path,
              kind.id,
              'dart_ai_runtime',
              'system_prompts',
              '${session.id}.json',
            ),
          );
          expect(await pendingPrompt.exists(), isFalse);
          final messages = await client.messages(session.id);
          expect(
            messages.where(
              (message) => (message['info'] as Map?)?['role'] == 'user',
            ),
            hasLength(2),
          );
          expect(
            messages
                .expand(
                  (message) =>
                      (message['parts'] as List<Object?>? ?? const <Object?>[])
                          .whereType<Map<Object?, Object?>>(),
                )
                .where((part) => part['type'] == 'tool'),
            isEmpty,
          );
          await client.deleteSession(session.id);
        } finally {
          client?.dispose();
          await process?.stop();
          health.dispose();
          if (await root.exists()) await root.delete(recursive: true);
        }
      },
      skip: !inferenceEnabled || executablePath == null
          ? 'Set DART_AI_RUNTIME_TEST_INFERENCE=1 and $executableVariable.'
          : false,
      timeout: const Timeout(Duration(minutes: 7)),
    );
  }
}

Future<String> _promptAndWait(
  OpenCodeCompatibleRuntimeClient client,
  String sessionId,
  AiPrompt prompt,
) async {
  final baseline = (await client.messages(sessionId)).length;
  await client.promptAsync(sessionId, prompt);
  final deadline = DateTime.now().add(const Duration(minutes: 3));
  while (DateTime.now().isBefore(deadline)) {
    final messages = await client.messages(sessionId);
    for (final message in messages.skip(baseline)) {
      final info = message['info'];
      if (info is! Map<Object?, Object?> || info['role'] != 'assistant') {
        continue;
      }
      final finished =
          info['finish'] != null ||
          {'completed', 'idle'}.contains(info['status']?.toString());
      if (!finished) continue;
      final parts = message['parts'];
      if (parts is! List<Object?>) continue;
      final text = parts
          .whereType<Map<Object?, Object?>>()
          .where((part) => part['type'] == 'text')
          .map((part) => part['text']?.toString() ?? '')
          .join();
      if (text.isNotEmpty) return text;
    }
    await Future<void>.delayed(const Duration(milliseconds: 350));
  }
  throw TimeoutException('The real runtime did not finish its response.');
}
