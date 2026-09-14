import 'package:dart_ai_runtime/dart_ai_runtime.dart';
import 'package:test/test.dart';

void main() {
  test('prefers Kilo Auto Free and never auto-selects a paid model', () async {
    final store = _ModelStore();
    final controller = AiModelSelectionController(
      runtimeId: 'kilo',
      loadProviders: () async => [
        AiProviderInfo(
          id: 'kilo',
          name: 'Kilo',
          connected: true,
          models: const [
            AiModelInfo(
              id: 'paid',
              name: 'Paid',
              providerId: 'kilo',
              isFree: false,
              isDefault: true,
            ),
            AiModelInfo(
              id: 'kilo-auto/free',
              name: 'Auto Free',
              providerId: 'kilo',
              isFree: true,
            ),
          ],
        ),
      ],
      store: store,
    );
    await controller.refresh();
    expect(controller.state.selected?.id, 'kilo-auto/free');
    await controller.dispose();
  });

  test('rejects model changes during a generation', () async {
    final model = const AiModelInfo(
      id: 'free',
      name: 'Free',
      providerId: 'test',
      isFree: true,
    );
    final controller = AiModelSelectionController(
      runtimeId: 'opencode',
      loadProviders: () async => [
        AiProviderInfo(
          id: 'test',
          name: 'Test',
          connected: true,
          models: [model],
        ),
      ],
      store: _ModelStore(),
    );
    await controller.refresh();
    expect(
      () => controller.select(model.key, generationActive: true),
      throwsStateError,
    );
    await controller.dispose();
  });

  test('does not silently replace a missing saved model', () async {
    final store = _ModelStore()..value = 'gone/model';
    final controller = AiModelSelectionController(
      runtimeId: 'opencode',
      loadProviders: () async => const [],
      store: store,
    );
    await controller.refresh();
    expect(controller.state.selected, isNull);
    expect(controller.state.notice, isNotNull);
    await controller.dispose();
  });
}

class _ModelStore implements AiModelSelectionStore {
  String? value;

  @override
  Future<String?> read(String runtimeId) async => value;

  @override
  Future<void> write(String runtimeId, String modelKey) async {
    value = modelKey;
  }
}
