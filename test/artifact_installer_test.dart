import 'dart:convert';
import 'dart:io';

import 'package:dart_ai_runtime/dart_ai_runtime.dart';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('air-artifact-test-');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('installs a verified immutable ZIP artifact', () async {
    final payload = _zip({'opencode.exe': List<int>.filled(2048, 7)});
    final downloader = _MemoryDownloader(payload);
    final spec = _spec(payload);
    final installer = ArtifactInstaller(
      sharedRoot: root,
      downloader: downloader,
      validator: (_, directory) async {
        expect(
          await File(p.join(directory.path, 'opencode.exe')).length(),
          2048,
        );
      },
    );

    final installation = await installer.install(spec);

    expect(
      await File(p.join(installation.directoryPath, 'opencode.exe')).exists(),
      isTrue,
    );
    expect(await installer.installed(spec), isNotNull);
    final marker = jsonDecode(
      await File(
        p.join(installation.directoryPath, ArtifactInstaller.markerName),
      ).readAsString(),
    ) as Map;
    expect(marker['schemaVersion'], 1);
    expect(marker['fingerprint'], spec.fingerprint);
    expect(marker['license'], 'MIT');
  });

  test('concurrent installers download an artifact once', () async {
    final payload = _zip({'opencode.exe': List<int>.filled(2048, 7)});
    final downloader = _MemoryDownloader(
      payload,
      delay: const Duration(milliseconds: 25),
    );
    final spec = _spec(payload);
    final first = ArtifactInstaller(sharedRoot: root, downloader: downloader);
    final second = ArtifactInstaller(sharedRoot: root, downloader: downloader);

    final installations = await Future.wait([
      first.install(spec),
      second.install(spec),
    ]);

    expect(downloader.calls, 1);
    expect(installations[0].directoryPath, installations[1].directoryPath);
  });

  test('same semantic version with another payload remains isolated', () async {
    final firstPayload = _zip({'opencode.exe': List<int>.filled(2048, 7)});
    final secondPayload = _zip({'opencode.exe': List<int>.filled(2048, 8)});
    final firstSpec = _spec(firstPayload);
    final secondSpec = _spec(secondPayload);
    final installer = ArtifactInstaller(
      sharedRoot: root,
      downloader: _SwitchingDownloader([firstPayload, secondPayload]),
    );

    final first = await installer.install(firstSpec);
    final second = await installer.install(secondSpec);

    expect(first.directoryPath, isNot(second.directoryPath));
    expect(await Directory(first.directoryPath).exists(), isTrue);
    expect(await Directory(second.directoryPath).exists(), isTrue);
  });

  test('rejects archive entries that escape the staging directory', () async {
    final payload = _zip({'../escaped.exe': List<int>.filled(2048, 7)});
    final installer = ArtifactInstaller(
      sharedRoot: root,
      downloader: _MemoryDownloader(payload),
    );

    await expectLater(installer.install(_spec(payload)), throwsArgumentError);
    expect(
      await File(p.join(root.parent.path, 'escaped.exe')).exists(),
      isFalse,
    );
  });

  test('rejects an invalid digest after download', () async {
    final payload = _zip({'opencode.exe': List<int>.filled(2048, 7)});
    final spec = _spec(payload, digest: List.filled(64, '0').join());
    final installer = ArtifactInstaller(
      sharedRoot: root,
      downloader: _MemoryDownloader(payload),
    );

    await expectLater(installer.install(spec), throwsStateError);
    expect(await installer.installed(spec), isNull);
  });
}

ArtifactSpec _spec(List<int> payload, {String? digest}) => ArtifactSpec(
  id: 'opencode',
  version: '1.0.0',
  group: 'runtime',
  payloads: [
    ArtifactPayloadSpec(
      id: 'windows-x64',
      uri: Uri.parse('https://example.test/opencode.zip'),
      sha256: digest ?? sha256.convert(payload).toString(),
      bytes: payload.length,
      fileName: 'opencode.zip',
      archiveType: ArtifactArchiveType.zip,
    ),
  ],
  requiredPaths: const ['opencode.exe'],
  license: ArtifactLicense(
    name: 'MIT',
    uri: Uri.parse('https://example.test/license'),
    notice: 'Copyright example.',
  ),
);

List<int> _zip(Map<String, List<int>> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  return ZipEncoder().encode(archive);
}

class _MemoryDownloader implements ArtifactDownloader {
  _MemoryDownloader(this.bytes, {this.delay = Duration.zero});

  final List<int> bytes;
  final Duration delay;
  int calls = 0;

  @override
  Future<void> download(
    ArtifactDownloadRequest request, {
    ArtifactDownloadCancellation? cancellation,
    void Function(ArtifactDownloadProgress progress)? onProgress,
  }) async {
    calls++;
    await Future<void>.delayed(delay);
    cancellation?.throwIfCancelled();
    await File(request.destinationPath).writeAsBytes(bytes, flush: true);
    onProgress?.call(
      ArtifactDownloadProgress(
        receivedBytes: bytes.length,
        totalBytes: request.expectedBytes,
      ),
    );
  }
}

class _SwitchingDownloader implements ArtifactDownloader {
  _SwitchingDownloader(this.payloads);

  final List<List<int>> payloads;
  int _index = 0;

  @override
  Future<void> download(
    ArtifactDownloadRequest request, {
    ArtifactDownloadCancellation? cancellation,
    void Function(ArtifactDownloadProgress progress)? onProgress,
  }) async {
    final bytes = payloads[_index++];
    await File(request.destinationPath).writeAsBytes(bytes, flush: true);
  }
}
