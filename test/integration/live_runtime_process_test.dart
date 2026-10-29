import 'dart:async';
import 'dart:io';

import 'package:dart_ai_runtime/dart_ai_runtime.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  for (final kind in AiRuntimeKind.values) {
    final variable = kind == AiRuntimeKind.openCode
        ? 'DART_AI_RUNTIME_TEST_OPENCODE_EXE'
        : 'DART_AI_RUNTIME_TEST_KILO_EXE';
    final executablePath = Platform.environment[variable];

    test(
      'starts and probes a real ${kind.displayName} runtime',
      () async {
        final root = await Directory.systemTemp.createTemp('air-runtime-live-');
        final storage = AiRuntimeStorage(
          sharedStoreRoot: Directory(p.join(root.path, 'shared')),
          applicationDataRoot: Directory(p.join(root.path, 'private')),
          applicationId: 'dart-ai-runtime-test',
        );
        final health = AiRuntimeHealthClient();
        // Probe the runtime protocol itself. Neutral-plugin behavior has a
        // separate opt-in test and may require network package installation.
        final processService = LocalAiRuntimeProcessService(
          storage,
          enableNeutralSystemPrompts: false,
        );
        AiRuntimeProcessHandle? process;
        try {
          final versionOutput = await Process.run(
            executablePath!,
            ['--version'],
            environment: LocalAiRuntimeProcessService.buildSanitizedEnvironment(
              kind: kind,
              storage: storage,
              username: kind.id,
              password: 'version-probe-only',
              parentEnvironment: Platform.environment,
            ),
            includeParentEnvironment: false,
          );
          final legacy =
              kind == AiRuntimeKind.openCode &&
              RegExp(r'\b1\.\d+\.\d+')
                  .hasMatch(versionOutput.stdout.toString());
          process = await processService.start(
            AiRuntimeInstallation(
              definition: legacy
                  ? PinnedAiRuntimeCatalog.openCodeV1
                  : const PinnedAiRuntimeCatalog().definition(kind),
              directoryPath: File(executablePath).parent.path,
            ),
            password: 'integration-test-only',
          );
          final status = await health.waitUntilReady(process.endpoint);
          expect(status.healthy, isTrue, reason: status.message);
          final client = createAiRuntimeClient(
            endpoint: process.endpoint,
            workspaceDirectory: storage.workspace(kind).path,
            systemPromptService: processService.systemPromptService,
          );
          try {
            final firstEvent = (await client.connectEvents()).first.timeout(
              const Duration(seconds: 30),
            );
            final providers = await client.providers();
            expect(providers, isNotEmpty);
            await client.authMethods();
            final session = await client.createSession(
              title: 'dart_ai_runtime integration test',
            );
            expect((await client.session(session.id)).id, session.id);
            expect(await client.messages(session.id), isEmpty);
            expect((await firstEvent).type, isNotEmpty);
            await client.abort(session.id);
            await client.deleteSession(session.id);
          } finally {
            client.dispose();
          }
        } finally {
          await process?.stop();
          health.dispose();
          // Windows may release SQLite handles shortly after process exit.
          // Retry only this test-owned temporary directory, within a deadline.
          for (var attempt = 0; await root.exists(); attempt++) {
            try {
              await root.delete(recursive: true);
            } on PathAccessException {
              if (!Platform.isWindows || attempt >= 20) rethrow;
              await Future<void>.delayed(const Duration(milliseconds: 100));
            }
          }
        }
      },
      skip: executablePath == null
          ? 'Set $variable to opt into this test.'
          : false,
      timeout: const Timeout(Duration(seconds: 55)),
    );
  }
}
