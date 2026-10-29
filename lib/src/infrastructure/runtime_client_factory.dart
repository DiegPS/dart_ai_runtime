import '../application/runtime_client.dart';
import '../application/runtime_services.dart';
import '../domain/runtime_models.dart';
import 'opencode_compatible_runtime_client.dart';
import 'opencode_v2_runtime_client.dart';

/// Creates the client matching the supervised endpoint's HTTP API version.
///
/// OpenCode 2 uses native instruction entries. The V1 system-prompt bridge is
/// retained for legacy OpenCode and Kilo endpoints.
AiRuntimeClient createAiRuntimeClient({
  required AiRuntimeEndpoint endpoint,
  required String workspaceDirectory,
  AiRuntimeSystemPromptService? systemPromptService,
  Duration requestTimeout = const Duration(seconds: 20),
}) => endpoint.apiVersion == 2
    ? OpenCodeV2RuntimeClient(
        endpoint: endpoint,
        workspaceDirectory: workspaceDirectory,
        requestTimeout: requestTimeout,
      )
    : OpenCodeCompatibleRuntimeClient(
        endpoint: endpoint,
        workspaceDirectory: workspaceDirectory,
        systemPromptService: systemPromptService,
        requestTimeout: requestTimeout,
      );
