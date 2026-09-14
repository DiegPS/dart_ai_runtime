import 'dart:io';

import 'package:path/path.dart' as p;

import '../application/runtime_services.dart';
import '../domain/artifact_models.dart';
import '../domain/runtime_models.dart';
import 'artifact_installer.dart';
import 'http_artifact_downloader.dart';
import 'pinned_runtime_catalog.dart';
import 'runtime_storage.dart';

class PinnedAiRuntimeInstaller implements AiRuntimeInstallService {
  PinnedAiRuntimeInstaller({
    required AiRuntimeStorage storage,
    ArtifactDownloader? downloader,
    this.developmentExecutables = const {},
  }) : _installer = ArtifactInstaller(
         sharedRoot: storage.sharedStoreRoot,
         downloader: downloader ?? HttpArtifactDownloader(),
         validator: _validateExecutable,
       );

  static const _catalog = PinnedAiRuntimeCatalog();
  final ArtifactInstaller _installer;
  final Map<AiRuntimeKind, String?> developmentExecutables;

  @override
  AiRuntimeDefinition definition(AiRuntimeKind kind) =>
      _catalog.definition(kind);

  @override
  Future<AiRuntimeInstallation?> installed(AiRuntimeKind kind) async {
    final runtime = definition(kind);
    final installation = await _installer.installed(runtime.artifact);
    if (installation != null) {
      return AiRuntimeInstallation(
        definition: runtime,
        directoryPath: installation.directoryPath,
      );
    }
    final developmentPath = developmentExecutables[kind];
    if (developmentPath != null &&
        developmentPath.isNotEmpty &&
        await File(developmentPath).exists()) {
      return AiRuntimeInstallation(
        definition: runtime,
        directoryPath: File(developmentPath).parent.path,
      );
    }
    return null;
  }

  @override
  Future<AiRuntimeInstallation> install(
    AiRuntimeKind kind, {
    ArtifactDownloadCancellation? cancellation,
    void Function(ArtifactInstallProgress progress)? onProgress,
  }) async {
    final runtime = definition(kind);
    final installation = await _installer.install(
      runtime.artifact,
      cancellation: cancellation,
      onProgress: onProgress,
    );
    return AiRuntimeInstallation(
      definition: runtime,
      directoryPath: installation.directoryPath,
    );
  }

  static Future<void> _validateExecutable(
    ArtifactSpec artifact,
    Directory installation,
  ) async {
    final executable = File(
      p.join(installation.path, artifact.requiredPaths.single),
    );
    if (!await executable.exists() || await executable.length() < 1024 * 1024) {
      throw StateError('Runtime executable is missing or incomplete.');
    }
    final signature = await executable
        .openRead(0, 2)
        .fold<List<int>>(<int>[], (bytes, chunk) => bytes..addAll(chunk));
    if (signature.length != 2 || signature[0] != 0x4d || signature[1] != 0x5a) {
      throw StateError('Runtime executable is not a Windows PE file.');
    }
  }
}
