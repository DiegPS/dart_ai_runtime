import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dart_ai_runtime/dart_ai_runtime.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late AiRuntimeStorage storage;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('air-pinned-test-');
    storage = AiRuntimeStorage(
      sharedStoreRoot: Directory(p.join(root.path, 'shared')),
      applicationDataRoot: Directory(p.join(root.path, 'private')),
      applicationId: 'pinned-test',
    );
  });
  tearDown(() => root.delete(recursive: true));

  test(
    'installs a pinned PE and rejects corruption of its cached executable',
    () async {
      final bytes = List<int>.filled(1024 * 1024, 0)
        ..[0] = 0x4d
        ..[1] = 0x5a;
      final runtime = _definition(bytes);
      final downloader = _Bytes(bytes);
      final installer = PinnedAiRuntimeInstaller(
        storage: storage,
        downloader: downloader,
        runtimeDefinitions: {AiRuntimeKind.openCode: runtime},
      );
      expect(await installer.installed(AiRuntimeKind.openCode), isNull);
      final progress = <ArtifactInstallProgress>[];
      final installed = await installer.install(
        AiRuntimeKind.openCode,
        onProgress: progress.add,
      );
      expect(
        (await installer.installed(AiRuntimeKind.openCode))?.directoryPath,
        installed.directoryPath,
      );
      expect(progress.last.phase, ArtifactInstallPhase.installed);
      expect(progress.last.fraction, 1);
      final file = await File(p.join(installed.directoryPath, 'fixture.exe'))
          .open(mode: FileMode.writeOnly);
      await file.writeFrom([0, 0]);
      await file.close();
      expect(await installer.installed(AiRuntimeKind.openCode), isNull);
    },
  );

  for (final size in [2, 1024 * 1024]) {
    test('does not publish an invalid executable with size $size', () async {
      final bytes = List<int>.filled(size, 0);
      final installer = PinnedAiRuntimeInstaller(
        storage: storage,
        downloader: _Bytes(bytes),
        runtimeDefinitions: {AiRuntimeKind.openCode: _definition(bytes)},
      );
      await expectLater(
        installer.install(AiRuntimeKind.openCode),
        throwsStateError,
      );
      expect(await installer.installed(AiRuntimeKind.openCode), isNull);
    });
  }

  test(
    'development overrides are explicit and missing paths stay unavailable',
    () async {
      final executable = File(p.join(root.path, 'dev.exe'));
      await executable.writeAsBytes([1]);
      final installer = PinnedAiRuntimeInstaller(
        storage: storage,
        downloader: _Bytes([]),
        developmentExecutables: {
          AiRuntimeKind.openCode: executable.path,
          AiRuntimeKind.kilo: p.join(root.path, 'missing.exe'),
        },
        runtimeDefinitions: {
          AiRuntimeKind.openCode: PinnedAiRuntimeCatalog.openCodeV1,
        },
      );
      expect(installer.definition(AiRuntimeKind.openCode).version, '1.18.27');
      expect(
        (await installer.installed(AiRuntimeKind.openCode))?.directoryPath,
        root.path,
      );
      expect(await installer.installed(AiRuntimeKind.kilo), isNull);
    },
  );
}

AiRuntimeDefinition _definition(List<int> bytes) => AiRuntimeDefinition(
  kind: AiRuntimeKind.openCode,
  version: 'fixture-1',
  executableName: 'fixture.exe',
  artifact: ArtifactSpec(
    id: 'fixture',
    version: '1',
    group: 'test',
    payloads: [
      ArtifactPayloadSpec(
        id: 'exe',
        uri: Uri.parse('https://example.test/fixture.exe'),
        sha256: sha256.convert(bytes).toString(),
        bytes: bytes.length,
        fileName: 'fixture.exe',
        targetPath: 'fixture.exe',
      ),
    ],
    requiredPaths: const ['fixture.exe'],
    license: ArtifactLicense(
      name: 'MIT',
      uri: Uri.parse('https://example.test/license'),
      notice: 'Test fixture',
    ),
  ),
);

class _Bytes implements ArtifactDownloader {
  _Bytes(this.bytes);
  final List<int> bytes;
  @override
  Future<void> download(
    ArtifactDownloadRequest request, {
    ArtifactDownloadCancellation? cancellation,
    void Function(ArtifactDownloadProgress)? onProgress,
  }) async {
    cancellation?.throwIfCancelled();
    await File(request.destinationPath).writeAsBytes(bytes);
    onProgress?.call(
      ArtifactDownloadProgress(
        receivedBytes: bytes.length,
        totalBytes: bytes.length,
      ),
    );
  }
}
