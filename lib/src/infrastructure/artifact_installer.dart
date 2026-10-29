import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../domain/artifact_models.dart';

typedef ArtifactInstallationValidator = Future<void> Function(
  ArtifactSpec spec,
  Directory installation,
);

class ArtifactInstaller {
  ArtifactInstaller({
    required Directory sharedRoot,
    required this._downloader,
    this._validator,
  }) : _root = sharedRoot;

  static const markerName = '.air-artifact.json';
  static final _operationTails = <String, Future<void>>{};

  final Directory _root;
  final ArtifactDownloader _downloader;
  final ArtifactInstallationValidator? _validator;

  Future<ArtifactInstallation?> installed(ArtifactSpec spec) async {
    _validateSpec(spec);
    final directory = _installationDirectory(spec);
    final marker = File(p.join(directory.path, markerName));
    if (!await marker.exists()) return null;
    try {
      final decoded = jsonDecode(await marker.readAsString());
      if (decoded is! Map ||
          decoded['schemaVersion'] != 1 ||
          decoded['group'] != spec.group ||
          decoded['id'] != spec.id ||
          decoded['version'] != spec.version ||
          decoded['fingerprint'] != spec.fingerprint) {
        return null;
      }
      if (!await _hasRequiredPaths(directory, spec.requiredPaths)) return null;
      await _validator?.call(spec, directory);
      return ArtifactInstallation(spec: spec, directoryPath: directory.path);
    } catch (_) {
      return null;
    }
  }

  Future<ArtifactInstallation> install(
    ArtifactSpec spec, {
    ArtifactDownloadCancellation? cancellation,
    void Function(ArtifactInstallProgress progress)? onProgress,
  }) {
    _validateSpec(spec);
    final key = _installationDirectory(spec).path.toLowerCase();
    return _serialize(
      key,
      () => _withFileLock(
        spec,
        () => _installLocked(
          spec,
          cancellation: cancellation,
          onProgress: onProgress,
        ),
      ),
    );
  }

  Future<ArtifactInstallation> _installLocked(
    ArtifactSpec spec, {
    ArtifactDownloadCancellation? cancellation,
    void Function(ArtifactInstallProgress progress)? onProgress,
  }) async {
    onProgress?.call(
      const ArtifactInstallProgress(
        phase: ArtifactInstallPhase.checking,
        message: 'Checking artifact...',
      ),
    );
    final existing = await installed(spec);
    if (existing != null) return existing;

    cancellation?.throwIfCancelled();
    final totalBytes = spec.payloads.fold<int>(
      0,
      (sum, item) => sum + item.bytes,
    );
    final downloads = _downloadsDirectory(spec);
    final family = _familyDirectory(spec);
    final staging = Directory(
      p.join(
        family.path,
        '.staging-${spec.fingerprint}-${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    await downloads.create(recursive: true);
    await staging.create(recursive: true);
    final localFiles = <ArtifactPayloadSpec, File>{};
    final received = <String, int>{};
    try {
      for (var index = 0; index < spec.payloads.length; index++) {
        final payload = spec.payloads[index];
        cancellation?.throwIfCancelled();
        final local = File(
          p.join(
            downloads.path,
            '${index.toString().padLeft(2, '0')}-${_safeFile(payload.fileName)}',
          ),
        );
        localFiles[payload] = local;
        if (!await _matchesPayload(local, payload)) {
          if (await local.exists() && await local.length() > payload.bytes) {
            await local.delete();
          }
          await _downloader.download(
            ArtifactDownloadRequest(
              id: '${spec.group}-${spec.id}-${spec.version}-${payload.id}',
              uri: payload.uri,
              destinationPath: local.path,
              expectedBytes: payload.bytes,
              headers: payload.headers,
            ),
            cancellation: cancellation,
            onProgress: (progress) {
              received[payload.id] = progress.receivedBytes;
              onProgress?.call(
                ArtifactInstallProgress(
                  phase: ArtifactInstallPhase.downloading,
                  message: 'Downloading ${payload.fileName}...',
                  receivedBytes: received.values.fold(0, (a, b) => a + b),
                  totalBytes: totalBytes,
                ),
              );
            },
          );
        }
        onProgress?.call(
          ArtifactInstallProgress(
            phase: ArtifactInstallPhase.verifying,
            message: 'Verifying ${payload.fileName}...',
            receivedBytes: received.values.fold(0, (a, b) => a + b),
            totalBytes: totalBytes,
          ),
        );
        if (!await _matchesPayload(local, payload)) {
          if (await local.exists()) await local.delete();
          throw StateError(
            '${payload.fileName} failed integrity verification.',
          );
        }
        received[payload.id] = payload.bytes;
      }

      final unpacked = Directory(p.join(staging.path, 'unpacked'));
      await unpacked.create(recursive: true);
      for (final entry in localFiles.entries) {
        if (entry.key.archiveType == ArtifactArchiveType.none) continue;
        onProgress?.call(
          ArtifactInstallProgress(
            phase: ArtifactInstallPhase.extracting,
            message: 'Extracting ${entry.key.fileName}...',
            receivedBytes: totalBytes,
            totalBytes: totalBytes,
          ),
        );
        await _extractSecurely(
          entry.value,
          unpacked,
          entry.key.archiveType,
          cancellation,
        );
      }

      final content = spec.archiveRoot == null
          ? unpacked
          : Directory(_inside(unpacked.path, spec.archiveRoot!));
      if (!await content.exists()) {
        throw StateError('Artifact archive has an unexpected structure.');
      }
      for (final entry in localFiles.entries) {
        final payload = entry.key;
        if (payload.archiveType != ArtifactArchiveType.none) continue;
        final targetPath = payload.targetPath;
        if (targetPath == null || targetPath.isEmpty) {
          throw StateError('${payload.fileName} has no installation path.');
        }
        final target = File(_inside(content.path, targetPath));
        await target.parent.create(recursive: true);
        await entry.value.copy(target.path);
      }
      for (final relativePath in spec.removeAfterExtract) {
        final path = _inside(content.path, relativePath);
        final type = await FileSystemEntity.type(path);
        if (type == FileSystemEntityType.file) {
          await File(path).delete();
        } else if (type == FileSystemEntityType.directory) {
          await Directory(path).delete(recursive: true);
        }
      }

      onProgress?.call(
        ArtifactInstallProgress(
          phase: ArtifactInstallPhase.validating,
          message: 'Validating installation...',
          receivedBytes: totalBytes,
          totalBytes: totalBytes,
        ),
      );
      if (!await _hasRequiredPaths(content, spec.requiredPaths)) {
        throw StateError('Artifact installation is incomplete.');
      }
      await _validator?.call(spec, content);
      await File(p.join(content.path, markerName)).writeAsString(
        jsonEncode({
          'schemaVersion': 1,
          'group': spec.group,
          'id': spec.id,
          'version': spec.version,
          'fingerprint': spec.fingerprint,
          'license': spec.license.name,
          'installedAt': DateTime.now().toUtc().toIso8601String(),
        }),
        flush: true,
      );

      cancellation?.throwIfCancelled();
      onProgress?.call(
        ArtifactInstallProgress(
          phase: ArtifactInstallPhase.installing,
          message: 'Installing ${spec.id}...',
          receivedBytes: totalBytes,
          totalBytes: totalBytes,
        ),
      );
      final target = _installationDirectory(spec);
      await target.parent.create(recursive: true);
      if (await target.exists()) {
        final nowInstalled = await installed(spec);
        if (nowInstalled != null) return nowInstalled;
        await target.delete(recursive: true);
      }
      await content.rename(target.path);
      if (await downloads.exists()) await downloads.delete(recursive: true);
      onProgress?.call(
        ArtifactInstallProgress(
          phase: ArtifactInstallPhase.installed,
          message: '${spec.id} is ready.',
          receivedBytes: totalBytes,
          totalBytes: totalBytes,
        ),
      );
      return ArtifactInstallation(spec: spec, directoryPath: target.path);
    } finally {
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }

  Future<T> _withFileLock<T>(
    ArtifactSpec spec,
    Future<T> Function() action,
  ) async {
    final locks = Directory(p.join(_root.path, 'locks'));
    await locks.create(recursive: true);
    final file = File(p.join(locks.path, '${spec.fingerprint}.lock'));
    final handle = await file.open(mode: FileMode.append);
    try {
      await handle.lock(FileLock.exclusive);
      return await action();
    } finally {
      await handle.unlock();
      await handle.close();
    }
  }

  static Future<T> _serialize<T>(
    String key,
    Future<T> Function() action,
  ) async {
    final previous = _operationTails[key] ?? Future<void>.value();
    final gate = Completer<void>();
    _operationTails[key] = gate.future;
    await previous.catchError((_) {});
    try {
      return await action();
    } finally {
      gate.complete();
      if (identical(_operationTails[key], gate.future)) {
        _operationTails.remove(key);
      }
    }
  }

  Future<void> _extractSecurely(
    File input,
    Directory output,
    ArtifactArchiveType type,
    ArtifactDownloadCancellation? cancellation,
  ) async {
    final stream = InputFileStream(input.path);
    try {
      final archive = type == ArtifactArchiveType.tarGzip
          ? TarDecoder().decodeBytes(
              GZipDecoder().decodeBytes(await input.readAsBytes()),
            )
          : ZipDecoder().decodeStream(stream);
      for (final entry in archive.files) {
        cancellation?.throwIfCancelled();
        if (entry.isSymbolicLink) {
          throw StateError(
            'Artifact archives must not contain symbolic links.',
          );
        }
        final targetPath = _inside(output.path, entry.name);
        if (entry.isFile) {
          final target = File(targetPath);
          await target.parent.create(recursive: true);
          final outputStream = OutputFileStream(target.path);
          try {
            entry.writeContent(outputStream);
          } finally {
            await outputStream.close();
          }
        } else {
          await Directory(targetPath).create(recursive: true);
        }
      }
    } finally {
      stream.closeSync();
    }
  }

  Directory _familyDirectory(ArtifactSpec spec) => Directory(
    p.join(_root.path, 'artifacts', _safe(spec.group), _safe(spec.id)),
  );

  Directory _installationDirectory(ArtifactSpec spec) => Directory(
    p.join(
      _familyDirectory(spec).path,
      'versions',
      _safe(spec.version),
      spec.fingerprint,
    ),
  );

  Directory _downloadsDirectory(ArtifactSpec spec) => Directory(
    p.join(
      _root.path,
      'downloads',
      _safe(spec.group),
      _safe(spec.id),
      _safe(spec.version),
      spec.fingerprint,
    ),
  );

  static Future<bool> _matchesPayload(
    File file,
    ArtifactPayloadSpec payload,
  ) async {
    if (!await file.exists() || await file.length() != payload.bytes) {
      return false;
    }
    return (await sha256.bind(file.openRead()).first).toString() ==
        payload.sha256.toLowerCase();
  }

  static Future<bool> _hasRequiredPaths(
    Directory root,
    List<String> paths,
  ) async {
    for (final relative in paths) {
      if (await FileSystemEntity.type(_inside(root.path, relative)) ==
          FileSystemEntityType.notFound) {
        return false;
      }
    }
    return true;
  }

  static void _validateSpec(ArtifactSpec spec) {
    if (spec.id.isEmpty || spec.version.isEmpty || spec.group.isEmpty) {
      throw ArgumentError('Artifact id, version, and group are required.');
    }
    if (spec.payloads.isEmpty || spec.requiredPaths.isEmpty) {
      throw ArgumentError('Artifact payloads and required paths are required.');
    }
    final ids = <String>{};
    for (final payload in spec.payloads) {
      if (!ids.add(payload.id)) throw ArgumentError('Duplicate payload id.');
      if (payload.uri.scheme != 'https' || payload.bytes <= 0) {
        throw ArgumentError('Artifact payloads require HTTPS and a byte size.');
      }
      if (!RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(payload.sha256)) {
        throw ArgumentError('Artifact payloads require a SHA-256 digest.');
      }
      if (payload.archiveType == ArtifactArchiveType.zip &&
          !payload.fileName.toLowerCase().endsWith('.zip')) {
        throw ArgumentError('${payload.fileName} is not a ZIP archive.');
      }
    }
    for (final path in [
      ...spec.requiredPaths,
      ...spec.removeAfterExtract,
      if (spec.archiveRoot != null) spec.archiveRoot!,
      ...spec.payloads.map((item) => item.targetPath).whereType<String>(),
    ]) {
      _inside(p.join(Directory.systemTemp.path, 'air-artifact-root'), path);
    }
  }

  static String _inside(String root, String relative) {
    if (relative.isEmpty || p.isAbsolute(relative)) {
      throw ArgumentError('Artifact paths must be non-empty and relative.');
    }
    final normalizedRoot = p.normalize(root);
    final resolved = p.normalize(p.join(normalizedRoot, relative));
    if (!p.isWithin(normalizedRoot, resolved)) {
      throw ArgumentError('Artifact path escapes its installation directory.');
    }
    return resolved;
  }

  static String _safe(String value) =>
      value.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');

  static String _safeFile(String value) => _safe(p.basename(value));
}
