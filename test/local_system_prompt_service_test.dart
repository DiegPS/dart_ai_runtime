import 'dart:convert';
import 'dart:io';

import 'package:dart_ai_runtime/dart_ai_runtime.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late AiRuntimeStorage storage;
  late LocalAiRuntimeSystemPromptService service;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('air-system-prompt-test-');
    storage = AiRuntimeStorage(
      sharedStoreRoot: Directory(p.join(root.path, 'shared')),
      applicationDataRoot: Directory(p.join(root.path, 'private')),
      applicationId: 'test-host',
    );
    service = LocalAiRuntimeSystemPromptService(storage);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  for (final kind in AiRuntimeKind.values) {
    test(
      'generated ${kind.name} hook supports retries and new turns',
      () async {
        await service.prepare(kind);
        final managed = Directory(
          p.join(storage.config(kind).path, kind.id, 'dart_ai_runtime'),
        );
        final module = File(p.join(managed.path, 'hook.mjs'));
        await File(p.join(managed.path, 'neutral_system.js')).copy(module.path);
        await service.setSystemPrompt(kind, 'ses_one', 'First trusted context');
        await service.setSystemPrompt(kind, 'ses_two', 'Independent context');
        final script = File(p.join(root.path, 'exercise-hook.mjs'));
        await script.writeAsString(r'''
import assert from 'node:assert/strict';
import {writeFile, readdir} from 'node:fs/promises';
import {join} from 'node:path';
const module = await import(process.argv[2]);
const server = module.default?.server ?? module.DartAiRuntimeNeutralSystem;
const hooks = await server();
const transform = hooks['experimental.chat.system.transform'];
const directory = process.argv[3];
const invoke = async (sessionID) => {
  const output = {system: ['Upstream prompt']};
  await transform({sessionID}, output);
  return output.system;
};
assert.deepEqual(await invoke('ses_one'), ['First trusted context']);
assert.deepEqual(await invoke('ses_one'), ['First trusted context']);
assert.deepEqual(await invoke('ses_two'), ['Independent context']);
assert.deepEqual(await readdir(directory), []);
await writeFile(join(directory, 'ses_one.json'), JSON.stringify({version: 1, sessionId: 'ses_one', system: 'Updated trusted context'}));
const concurrent = await Promise.all(Array.from({length: 20}, () => invoke('ses_one')));
for (const result of concurrent) assert.deepEqual(result, ['Updated trusted context']);
assert.deepEqual(await invoke('ses_two'), ['Independent context']);
await assert.rejects(invoke('ses_unknown'));
await assert.rejects(invoke('../outside'));
await writeFile(join(directory, 'ses_one.json'), JSON.stringify({version: 1, sessionId: 'wrong-session', system: 'Untrusted'}));
await assert.rejects(invoke('ses_one'), /Invalid or missing/);
await assert.rejects(invoke('ses_one'));
await hooks.event({event: {type: 'session.deleted', properties: {info: {id: 'ses_two'}}}});
await assert.rejects(invoke('ses_two'));
assert.deepEqual(await readdir(directory), []);
''');
        final result = await Process.run('node', [
          script.path,
          module.uri.toString(),
          p.join(managed.path, 'system_prompts'),
        ]);
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
      },
    );

    test('prepares a managed neutral ${kind.name} configuration', () async {
      await service.prepare(kind);

      final runtimeConfig = Directory(
        p.join(storage.config(kind).path, kind.id),
      );
      final configFile = File(
        p.join(
          runtimeConfig.path,
          kind == AiRuntimeKind.openCode ? 'opencode.json' : 'kilo.json',
        ),
      );
      final config = Map<String, dynamic>.from(
        jsonDecode(await configFile.readAsString()) as Map,
      );
      final agents = Map<String, dynamic>.from(config['agent'] as Map);
      final neutral = Map<String, dynamic>.from(
        agents[LocalAiRuntimeSystemPromptService.agentId] as Map,
      );
      expect(
        config['default_agent'],
        LocalAiRuntimeSystemPromptService.agentId,
      );
      expect(config['plugin'], contains('./dart_ai_runtime/neutral_system.js'));
      expect(neutral['permission'], {'*': 'deny'});

      final plugin = await File(
        p.join(runtimeConfig.path, 'dart_ai_runtime', 'neutral_system.js'),
      ).readAsString();
      expect(plugin, contains('experimental.chat.system.transform'));
      expect(plugin, contains('output.system.splice'));
      expect(plugin, contains('await unlink(claimed)'));
      if (kind == AiRuntimeKind.openCode) {
        expect(plugin, contains('export const DartAiRuntimeNeutralSystem'));
      } else {
        expect(plugin, contains('export default'));
      }
    });
  }

  test('stores prompts by runtime and session and removes them', () async {
    const sessionId = 'ses_valid-123';
    await service.setSystemPrompt(
      AiRuntimeKind.openCode,
      sessionId,
      'Trusted GodSense telemetry',
    );
    final file = File(
      p.join(
        storage.config(AiRuntimeKind.openCode).path,
        'opencode',
        'dart_ai_runtime',
        'system_prompts',
        '$sessionId.json',
      ),
    );
    final payload = Map<String, dynamic>.from(
      jsonDecode(await file.readAsString()) as Map,
    );
    expect(payload['sessionId'], sessionId);
    expect(payload['system'], 'Trusted GodSense telemetry');

    await service.removeSystemPrompt(AiRuntimeKind.openCode, sessionId);
    expect(await file.exists(), isFalse);
  });

  test('rejects traversal, empty prompts and oversized prompts', () async {
    expect(
      () => LocalAiRuntimeSystemPromptService(storage, maximumPromptLength: 0),
      throwsArgumentError,
    );
    expect(
      () => service.setSystemPrompt(AiRuntimeKind.kilo, '../outside', 'System'),
      throwsArgumentError,
    );
    expect(
      () => service.setSystemPrompt(AiRuntimeKind.kilo, 'ses_1', '  '),
      throwsArgumentError,
    );
    final limited = LocalAiRuntimeSystemPromptService(
      storage,
      maximumPromptLength: 4,
    );
    expect(
      () => limited.setSystemPrompt(AiRuntimeKind.kilo, 'ses_1', '12345'),
      throwsArgumentError,
    );
  });

  test('preserves unrelated fields with only the managed plugin', () async {
    final configDirectory = Directory(
      p.join(storage.config(AiRuntimeKind.kilo).path, 'kilo'),
    );
    await configDirectory.create(recursive: true);
    final configFile = File(p.join(configDirectory.path, 'kilo.json'));
    await configFile.writeAsString(
      jsonEncode({
        'model': 'provider/existing',
        'agent': {
          'existing': {'description': 'Keep me'},
        },
      }),
    );

    await service.prepare(AiRuntimeKind.kilo);
    final config = Map<String, dynamic>.from(
      jsonDecode(await configFile.readAsString()) as Map,
    );
    expect(config['model'], 'provider/existing');
    expect(config['plugin'], ['./dart_ai_runtime/neutral_system.js']);
    expect((config['agent'] as Map), contains('existing'));
  });

  test('fails closed when external plugins are configured', () async {
    final configDirectory = Directory(
      p.join(storage.config(AiRuntimeKind.openCode).path, 'opencode'),
    );
    await configDirectory.create(recursive: true);
    await File(p.join(configDirectory.path, 'opencode.json')).writeAsString(
      jsonEncode({
        'plugin': ['untrusted-plugin'],
      }),
    );

    await expectLater(
      service.prepare(AiRuntimeKind.openCode),
      throwsA(isA<StateError>()),
    );
  });

  test('fails closed when an auto-loaded plugin is present', () async {
    final pluginDirectory = Directory(
      p.join(storage.config(AiRuntimeKind.kilo).path, 'kilo', 'plugin'),
    );
    await pluginDirectory.create(recursive: true);
    await File(p.join(pluginDirectory.path, 'untrusted.js'))
        .writeAsString('export default {};');

    await expectLater(
      service.prepare(AiRuntimeKind.kilo),
      throwsA(isA<StateError>()),
    );
  });
}
