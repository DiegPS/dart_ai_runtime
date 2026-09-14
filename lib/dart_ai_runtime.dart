/// Reusable local AI runtime integration for Dart applications.
library;

export 'src/application/conversation_controller.dart';
export 'src/application/runtime_client.dart';
export 'src/application/model_selection_controller.dart';
export 'src/application/provider_connection_controller.dart';
export 'src/application/runtime_services.dart';
export 'src/application/runtime_supervisor.dart';
export 'src/domain/artifact_models.dart';
export 'src/domain/conversation_models.dart';
export 'src/domain/model_selection_models.dart';
export 'src/domain/provider_connection_models.dart';
export 'src/domain/runtime_api_models.dart';
export 'src/domain/runtime_models.dart';
export 'src/infrastructure/artifact_installer.dart';
export 'src/infrastructure/http_artifact_downloader.dart';
export 'src/infrastructure/local_runtime_process_service.dart';
export 'src/infrastructure/opencode_compatible_runtime_client.dart';
export 'src/infrastructure/pinned_runtime_catalog.dart';
export 'src/infrastructure/pinned_runtime_installer.dart';
export 'src/infrastructure/runtime_health_client.dart';
export 'src/infrastructure/runtime_storage.dart';

/// Stable package identifier used by diagnostics and integration tests.
const dartAiRuntimePackageName = 'dart_ai_runtime';
