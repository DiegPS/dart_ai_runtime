import 'dart:async';
import 'dart:io';

import 'package:dart_ai_runtime/dart_ai_runtime.dart';
import 'package:dart_ai_runtime/src/infrastructure/windows_job_object.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late AiRuntimeStorage storage;
  late File executable;
  late _Bridge bridge;
  final fixture = p.absolute(
    'test',
    'fixtures',
    'runtime_process_fixture.dart',
  );
  setUp(() async {
    root = await Directory.systemTemp.createTemp('air-process-test-');
    executable = File(p.join(root.path, 'fixture.exe'));
    await executable.writeAsBytes([1]);
    storage = AiRuntimeStorage(
      sharedStoreRoot: Directory(p.join(root.path, 'shared')),
      applicationDataRoot: Directory(p.join(root.path, 'private')),
      applicationId: 'process-test',
    );
    bridge = _Bridge();
  });
  tearDown(() => root.delete(recursive: true));

  AiRuntimeInstallation installation(bool v2) => AiRuntimeInstallation(
    definition: AiRuntimeDefinition(
      kind: AiRuntimeKind.openCode,
      version: v2 ? '2.2.2' : '1.18.27',
      executableName: 'fixture.exe',
      artifact: PinnedAiRuntimeCatalog.openCodeV2.artifact,
    ),
    directoryPath: root.path,
  );

  for (final v2 in [true, false]) {
    test(
      'V${v2 ? 2 : 1} process readiness, environment, logs and idempotent shutdown',
      () async {
        Process? spawned;
        final service = LocalAiRuntimeProcessService(
          storage,
          systemPromptService: bridge,
          processStarter:
              (
                exe,
                args, {
                required workingDirectory,
                required environment,
                required includeParentEnvironment,
                required runInShell,
              }) async {
                expect(exe, executable.path);
                expect(args, [
                  'serve',
                  '--hostname',
                  '127.0.0.1',
                  '--port',
                  '0',
                ]);
                expect(includeParentEnvironment, isFalse);
                expect(runInShell, isFalse);
                expect(environment['OPENCODE_SERVER_PASSWORD'], 'test-only');
                expect(environment.containsKey('OPENAI_API_KEY'), isFalse);
                if (v2) expect(environment['OPENCODE_PASSWORD'], 'test-only');
                spawned = await Process.start(
                  Platform.resolvedExecutable,
                  [fixture, v2 ? 'stderr' : 'normal'],
                  workingDirectory: workingDirectory,
                  environment: environment,
                  includeParentEnvironment: false,
                );
                return spawned!;
              },
        );
        final handle = await service.start(
          installation(v2),
          password: 'test-only',
        );
        try {
          expect(handle.endpoint.apiVersion, v2 ? 2 : 1);
          expect(handle.endpoint.isLoopback, isTrue);
          expect(handle.endpoint.baseUri.port, greaterThan(0));
          final log = handle.logs.firstWhere(
            (line) => line.contains('Fixture received: ping'),
          );
          spawned!.stdin.writeln('ping');
          expect(
            await log.timeout(const Duration(seconds: 2)),
            contains('ping'),
          );
          expect(bridge.prepareCount, v2 ? 0 : 1);
        } finally {
          await handle.stop();
          await handle.stop();
        }
        expect(await handle.exitCode, isA<int>());
        expect(bridge.clearCount, v2 ? 0 : 1);
      },
    );
  }

  for (final mode in ['exit', 'invalid-utf8']) {
    test('startup $mode fails and terminates the test-owned child', () async {
      Process? spawned;
      final service = LocalAiRuntimeProcessService(
        storage,
        enableNeutralSystemPrompts: false,
        processStarter:
            (
              exe,
              args, {
              required workingDirectory,
              required environment,
              required includeParentEnvironment,
              required runInShell,
            }) async {
              spawned = await Process.start(
                Platform.resolvedExecutable,
                [fixture, mode],
                workingDirectory: workingDirectory,
                environment: environment,
                includeParentEnvironment: false,
              );
              return spawned!;
            },
      );
      await expectLater(
        service.start(installation(true), password: 'test-only'),
        mode == 'exit' ? throwsStateError : throwsFormatException,
      );
      await spawned!.exitCode.timeout(const Duration(seconds: 2));
    });
  }

  test('missing executables fail before launch', () async {
    await executable.delete();
    final service = LocalAiRuntimeProcessService(
      storage,
      enableNeutralSystemPrompts: false,
      processStarter: (
        exe,
        args, {
        required workingDirectory,
        required environment,
        required includeParentEnvironment,
        required runInShell,
      }) async => throw StateError('Must not launch'),
    );
    await expectLater(
      service.start(installation(true), password: 'test-only'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'reason',
          contains('not installed'),
        ),
      ),
    );
  });

  test('job objects reject invalid process IDs and release their handles', () {
    expect(
      () => WindowsJobObject.attachToProcess(0),
      throwsA(isA<Exception>()),
    );
  }, skip: !Platform.isWindows);
}

class _Bridge implements AiRuntimeSystemPromptService {
  int prepareCount = 0;
  int clearCount = 0;
  @override
  Future<void> prepare(AiRuntimeKind kind) async {
    prepareCount++;
  }

  @override
  Future<void> clearSystemPrompts(AiRuntimeKind kind) async {
    clearCount++;
  }

  @override
  Future<void> removeSystemPrompt(AiRuntimeKind kind, String sessionId) async {}
  @override
  Future<void> setSystemPrompt(
    AiRuntimeKind kind,
    String sessionId,
    String systemPrompt,
  ) async {}
}
