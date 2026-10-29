import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

enum ArtifactArchiveType { none, zip, tarGzip }

class ArtifactPayloadSpec {
  const ArtifactPayloadSpec({
    required this.id,
    required this.uri,
    required this.sha256,
    required this.bytes,
    required this.fileName,
    this.archiveType = ArtifactArchiveType.none,
    this.targetPath,
    this.headers = const {},
  });

  final String id;
  final Uri uri;
  final String sha256;
  final int bytes;
  final String fileName;
  final ArtifactArchiveType archiveType;
  final String? targetPath;
  final Map<String, String> headers;
}

class ArtifactLicense {
  const ArtifactLicense({
    required this.name,
    required this.uri,
    required this.notice,
  });

  final String name;
  final Uri uri;
  final String notice;
}

class ArtifactSpec {
  const ArtifactSpec({
    required this.id,
    required this.version,
    required this.group,
    required this.payloads,
    required this.requiredPaths,
    required this.license,
    this.archiveRoot,
    this.removeAfterExtract = const [],
  });

  final String id;
  final String version;
  final String group;
  final List<ArtifactPayloadSpec> payloads;
  final List<String> requiredPaths;
  final ArtifactLicense license;
  final String? archiveRoot;
  final List<String> removeAfterExtract;

  String get fingerprint => sha256
      .convert(
        utf8.encode(
          '$group|$id|$version|'
          '${payloads.map((item) => '${item.id}:${item.sha256}:${item.targetPath ?? ''}').join('|')}',
        ),
      )
      .toString();
}

enum ArtifactInstallPhase {
  checking,
  downloading,
  verifying,
  extracting,
  validating,
  installing,
  installed,
}

class ArtifactInstallProgress {
  const ArtifactInstallProgress({
    required this.phase,
    required this.message,
    this.receivedBytes = 0,
    this.totalBytes = 0,
  });

  final ArtifactInstallPhase phase;
  final String message;
  final int receivedBytes;
  final int totalBytes;

  double? get fraction =>
      totalBytes > 0 ? (receivedBytes / totalBytes).clamp(0, 1) : null;
}

class ArtifactInstallation {
  const ArtifactInstallation({required this.spec, required this.directoryPath});

  final ArtifactSpec spec;
  final String directoryPath;
}

class ArtifactDownloadRequest {
  const ArtifactDownloadRequest({
    required this.id,
    required this.uri,
    required this.destinationPath,
    required this.expectedBytes,
    this.headers = const {},
  });

  final String id;
  final Uri uri;
  final String destinationPath;
  final int expectedBytes;
  final Map<String, String> headers;
}

class ArtifactDownloadProgress {
  const ArtifactDownloadProgress({
    required this.receivedBytes,
    required this.totalBytes,
  });

  final int receivedBytes;
  final int totalBytes;
}

abstract interface class ArtifactDownloadCancellation {
  bool get isCancelled;
  Future<void> get whenCancelled;
  void throwIfCancelled();
  void Function() addListener(void Function() listener);
}

class ArtifactDownloadCancellationToken
    implements ArtifactDownloadCancellation {
  bool _cancelled = false;
  final _listeners = <void Function()>{};
  final _cancelledCompleter = Completer<void>();

  @override
  bool get isCancelled => _cancelled;

  @override
  Future<void> get whenCancelled => _cancelledCompleter.future;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _cancelledCompleter.complete();
    for (final listener in List<void Function()>.from(_listeners)) {
      listener();
    }
    _listeners.clear();
  }

  @override
  void throwIfCancelled() {
    if (_cancelled) throw const ArtifactDownloadCancelledException();
  }

  @override
  void Function() addListener(void Function() listener) {
    if (_cancelled) {
      listener();
      return () {};
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }
}

abstract interface class ArtifactDownloader {
  Future<void> download(
    ArtifactDownloadRequest request, {
    ArtifactDownloadCancellation? cancellation,
    void Function(ArtifactDownloadProgress progress)? onProgress,
  });
}

class ArtifactDownloadCancelledException implements Exception {
  const ArtifactDownloadCancelledException();

  @override
  String toString() => 'Artifact download cancelled.';
}

class ArtifactDownloadException implements Exception {
  const ArtifactDownloadException(this.message);

  final String message;

  @override
  String toString() => 'ArtifactDownloadException: $message';
}
