import '../domain/artifact_models.dart';
import '../domain/runtime_models.dart';

abstract interface class AiRuntimeInstallService {
  AiRuntimeDefinition definition(AiRuntimeKind kind);

  Future<AiRuntimeInstallation?> installed(AiRuntimeKind kind);

  Future<AiRuntimeInstallation> install(
    AiRuntimeKind kind, {
    ArtifactDownloadCancellation? cancellation,
    void Function(ArtifactInstallProgress progress)? onProgress,
  });
}

abstract interface class AiRuntimeProcessHandle {
  AiRuntimeEndpoint get endpoint;
  Stream<String> get logs;
  Future<int> get exitCode;
  Future<void> stop();
}

abstract interface class AiRuntimeProcessService {
  Future<AiRuntimeProcessHandle> start(
    AiRuntimeInstallation installation, {
    required String password,
  });
}

abstract interface class AiRuntimeHealthService {
  Future<AiRuntimeHealth> waitUntilReady(
    AiRuntimeEndpoint endpoint, {
    Duration timeout,
  });
}
