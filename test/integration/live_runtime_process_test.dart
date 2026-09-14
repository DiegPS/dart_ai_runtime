import 'dart:io';

import 'package:air_ai_runtime/air_ai_runtime.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  for (final kind in AiRuntimeKind.values) {
    final variable = kind == AiRuntimeKind.openCode
        ? 'AIR_AI_RUNTIME_TEST_OPENCODE_EXE'
        : 'AIR_AI_RUNTIME_TEST_KILO_EXE';
    final executablePath = Platform.environment[variable];

    test(
      'starts and probes a real ${kind.displayName} runtime',
      () async {
        final root = await Directory.systemTemp.createTemp('air-runtime-live-');
        final storage = AiRuntimeStorage(
          sharedStoreRoot: Directory(p.join(root.path, 'shared')),
          applicationDataRoot: Directory(p.join(root.path, 'private')),
          applicationId: 'air-ai-runtime-test',
        );
        final health = AiRuntimeHealthClient();
        AiRuntimeProcessHandle? process;
        try {
          process = await LocalAiRuntimeProcessService(storage).start(
            AiRuntimeInstallation(
              definition: const PinnedAiRuntimeCatalog().definition(kind),
              directoryPath: File(executablePath!).parent.path,
            ),
            password: 'integration-test-only',
          );
          final status = await health.waitUntilReady(process.endpoint);
          expect(status.healthy, isTrue, reason: status.message);
          final client = OpenCodeCompatibleRuntimeClient(
            endpoint: process.endpoint,
            workspaceDirectory: storage.workspace(kind).path,
          );
          try {
            final providers = await client.providers();
            expect(providers, isNotEmpty);
          } finally {
            client.dispose();
          }
        } finally {
          await process?.stop();
          health.dispose();
          if (await root.exists()) await root.delete(recursive: true);
        }
      },
      skip: executablePath == null
          ? 'Set $variable to opt into this test.'
          : false,
      timeout: const Timeout(Duration(seconds: 55)),
    );
  }
}
