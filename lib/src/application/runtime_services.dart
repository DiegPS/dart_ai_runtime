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

/// Supplies host-controlled system prompts to a managed runtime session.
///
/// OpenCode-compatible plugin hooks receive the runtime-generated system
/// prompt but not the `system` field posted to the prompt endpoint. This port
/// lets a trusted runtime plugin retrieve the host prompt by [sessionId]
/// before the model request is assembled.
abstract interface class AiRuntimeSystemPromptService {
  /// Prepares the trusted plugin and removes prompts left by an earlier process.
  Future<void> prepare(AiRuntimeKind kind);

  /// Makes [systemPrompt] available to the next turn in [sessionId].
  Future<void> setSystemPrompt(
    AiRuntimeKind kind,
    String sessionId,
    String systemPrompt,
  );

  /// Removes any pending system prompt for [sessionId].
  Future<void> removeSystemPrompt(AiRuntimeKind kind, String sessionId);

  /// Removes every pending prompt for [kind] without deleting runtime config.
  Future<void> clearSystemPrompts(AiRuntimeKind kind);
}
