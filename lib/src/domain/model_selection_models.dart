import 'runtime_api_models.dart';

class AiModelSelectionState {
  const AiModelSelectionState({
    this.providers = const [],
    this.selected,
    this.loading = false,
    this.error,
    this.notice,
  });

  final List<AiProviderInfo> providers;
  final AiModelInfo? selected;
  final bool loading;
  final Object? error;
  final String? notice;
}

abstract interface class AiModelSelectionStore {
  Future<String?> read(String runtimeId);
  Future<void> write(String runtimeId, String modelKey);
}
