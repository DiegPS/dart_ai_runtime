import 'dart:io';

import 'package:air_ai_runtime/air_ai_runtime.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('shared binaries and application state use separate roots', () async {
    final root = await Directory.systemTemp.createTemp('air-storage-test-');
    addTearDown(() => root.delete(recursive: true));
    final storage = AiRuntimeStorage(
      sharedStoreRoot: Directory(p.join(root.path, 'shared')),
      applicationDataRoot: Directory(p.join(root.path, 'apps', 'airstream')),
      applicationId: 'airstream',
    );

    await storage.createPrivateDirectories(AiRuntimeKind.openCode);

    expect(
      storage.workspace(AiRuntimeKind.openCode).path,
      contains(p.join('apps', 'airstream')),
    );
    expect(
      storage.workspace(AiRuntimeKind.openCode).path,
      isNot(contains(storage.sharedStoreRoot.path)),
    );
    expect(await storage.config(AiRuntimeKind.openCode).exists(), isTrue);
  });

  test('unpackaged Windows layout shares one store across applications', () {
    final airstream = AiRuntimeStorage.windowsUnpackaged(
      publisherDirectoryName: 'DiegPS',
      applicationId: 'airstream',
      environment: const {'LOCALAPPDATA': r'C:\Users\test\AppData\Local'},
    );
    final godsense = AiRuntimeStorage.windowsUnpackaged(
      publisherDirectoryName: 'DiegPS',
      applicationId: 'godsense',
      environment: const {'LOCALAPPDATA': r'C:\Users\test\AppData\Local'},
    );

    expect(airstream.sharedStoreRoot.path, godsense.sharedStoreRoot.path);
    expect(
      airstream.applicationDataRoot.path,
      isNot(godsense.applicationDataRoot.path),
    );
  });

  test('application id cannot escape its private directory', () {
    expect(
      () => AiRuntimeStorage(
        sharedStoreRoot: Directory('shared'),
        applicationDataRoot: Directory('private'),
        applicationId: '../escape',
      ),
      throwsArgumentError,
    );
  });
}
