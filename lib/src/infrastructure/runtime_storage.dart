import 'dart:io';

import 'package:path/path.dart' as p;

import '../domain/runtime_models.dart';

/// Separates immutable suite-wide binaries from mutable application data.
class AiRuntimeStorage {
  AiRuntimeStorage({
    required this.sharedStoreRoot,
    required this.applicationDataRoot,
    required this.applicationId,
  }) {
    if (applicationId.isEmpty ||
        !RegExp(r'^[a-z0-9][a-z0-9._-]*$').hasMatch(applicationId)) {
      throw ArgumentError.value(applicationId, 'applicationId');
    }
  }

  /// Shared and recoverable models/runtime binaries.
  ///
  /// Packaged Windows apps should pass a PublisherCacheFolder resolved by the
  /// host app. Unpackaged apps may use [windowsUnpackaged].
  final Directory sharedStoreRoot;

  /// Private state owned by one application. Never shared between products.
  final Directory applicationDataRoot;

  final String applicationId;

  factory AiRuntimeStorage.windowsUnpackaged({
    required String publisherDirectoryName,
    required String applicationId,
    Map<String, String>? environment,
  }) {
    final values = environment ?? Platform.environment;
    final localAppData = values['LOCALAPPDATA'];
    if (localAppData == null || localAppData.isEmpty) {
      throw StateError('LOCALAPPDATA is unavailable. Inject storage paths.');
    }
    final suiteRoot = Directory(p.join(localAppData, publisherDirectoryName));
    return AiRuntimeStorage(
      sharedStoreRoot: Directory(p.join(suiteRoot.path, 'AirRuntimeStore-v1')),
      applicationDataRoot: Directory(
        p.join(suiteRoot.path, 'applications', applicationId),
      ),
      applicationId: applicationId,
    );
  }

  Directory runtimeRoot(AiRuntimeKind kind) =>
      Directory(p.join(applicationDataRoot.path, 'ai', kind.id));

  Directory data(AiRuntimeKind kind) =>
      Directory(p.join(runtimeRoot(kind).path, 'data'));
  Directory cache(AiRuntimeKind kind) =>
      Directory(p.join(runtimeRoot(kind).path, 'cache'));
  Directory config(AiRuntimeKind kind) =>
      Directory(p.join(runtimeRoot(kind).path, 'config'));
  Directory state(AiRuntimeKind kind) =>
      Directory(p.join(runtimeRoot(kind).path, 'state'));
  Directory temp(AiRuntimeKind kind) =>
      Directory(p.join(runtimeRoot(kind).path, 'temp'));
  Directory workspace(AiRuntimeKind kind) =>
      Directory(p.join(runtimeRoot(kind).path, 'workspace'));

  Future<void> createPrivateDirectories(AiRuntimeKind kind) async {
    for (final directory in [
      data(kind),
      cache(kind),
      config(kind),
      state(kind),
      temp(kind),
      workspace(kind),
    ]) {
      await directory.create(recursive: true);
    }
  }
}
