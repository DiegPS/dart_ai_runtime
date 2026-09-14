/// Reusable local AI runtime integration for Dart applications.
library;

export 'src/application/runtime_client.dart';
export 'src/domain/artifact_models.dart';
export 'src/domain/runtime_api_models.dart';
export 'src/domain/runtime_models.dart';
export 'src/infrastructure/artifact_installer.dart';
export 'src/infrastructure/http_artifact_downloader.dart';
export 'src/infrastructure/opencode_compatible_runtime_client.dart';

/// Stable package identifier used by diagnostics and integration tests.
const airAiRuntimePackageName = 'air_ai_runtime';
