import 'dart:io';

import 'package:dart_ai_runtime/dart_ai_runtime.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('sanitized environment removes inherited credentials', () async {
    final root = await Directory.systemTemp.createTemp('air-env-test-');
    addTearDown(() => root.delete(recursive: true));
    final storage = AiRuntimeStorage(
      sharedStoreRoot: Directory(p.join(root.path, 'shared')),
      applicationDataRoot: Directory(p.join(root.path, 'private')),
      applicationId: 'airstream',
    );

    final environment = LocalAiRuntimeProcessService.buildSanitizedEnvironment(
      kind: AiRuntimeKind.kilo,
      storage: storage,
      username: 'kilo',
      password: 'ephemeral-password',
      parentEnvironment: const {
        'SYSTEMROOT': r'C:\Windows',
        'PATH': r'C:\Windows\System32',
        'OPENAI_API_KEY': 'secret',
        'GITHUB_TOKEN': 'secret',
        'RANDOM_VALUE': 'private',
      },
    );

    expect(environment['SYSTEMROOT'], r'C:\Windows');
    expect(environment['PATH'], contains('System32'));
    expect(environment, isNot(contains('OPENAI_API_KEY')));
    expect(environment, isNot(contains('GITHUB_TOKEN')));
    expect(environment, isNot(contains('RANDOM_VALUE')));
    expect(environment['KILO_SERVER_PASSWORD'], 'ephemeral-password');
    expect(environment['KILO_CLIENT'], 'airstream');
    expect(environment['KILO_DISABLE_TOOLS'], '1');
    expect(environment['KILO_DISABLE_EXTERNAL_SKILLS'], '1');
    expect(environment['XDG_DATA_HOME'], storage.data(AiRuntimeKind.kilo).path);
  });
}
