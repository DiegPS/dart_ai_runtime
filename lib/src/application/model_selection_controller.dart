// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import '../domain/model_selection_models.dart';
import '../domain/runtime_api_models.dart';

/// Framework-neutral provider/model catalog and selection policy.
class AiModelSelectionController {
  AiModelSelectionController({
    required this.runtimeId,
    required Future<List<AiProviderInfo>> Function() loadProviders,
    required AiModelSelectionStore store,
  }) : _loadProviders = loadProviders,
       _store = store;

  final String runtimeId;
  final Future<List<AiProviderInfo>> Function() _loadProviders;
  final AiModelSelectionStore _store;
  final _states = StreamController<AiModelSelectionState>.broadcast();
  AiModelSelectionState _state = const AiModelSelectionState();
  Future<void> _saving = Future<void>.value();
  int _revision = 0;
  bool _disposed = false;

  AiModelSelectionState get state => _state;
  Stream<AiModelSelectionState> get states => _states.stream;

  Future<void> refresh() async {
    _ensureUsable();
    final revision = ++_revision;
    final previous = _state.selected;
    _emit(
      AiModelSelectionState(
        providers: _state.providers,
        selected: previous,
        loading: true,
      ),
    );
    try {
      final catalog = await _loadProviders();
      await _saving;
      final saved = await _store.read(runtimeId);
      if (_disposed || revision != _revision) return;
      final providers =
          catalog
              .where((item) => item.connected && item.models.isNotEmpty)
              .toList(growable: false)
            ..sort((a, b) => a.name.compareTo(b.name));
      final models = providers.expand((item) => item.models).toList();
      final preferredKey = previous?.key ?? saved;
      AiModelInfo? selected = _find(models, preferredKey);
      String? notice;
      if (selected == null && preferredKey != null) {
        notice = 'The saved model is no longer available.';
      } else {
        selected ??= _preferredFreeModel(models);
      }
      _emit(
        AiModelSelectionState(
          providers: providers,
          selected: selected,
          notice: notice,
        ),
      );
    } catch (error) {
      if (!_disposed && revision == _revision) {
        _emit(AiModelSelectionState(error: error));
      }
    }
  }

  Future<void> select(String modelKey, {bool generationActive = false}) async {
    _ensureUsable();
    if (_state.loading || generationActive) {
      throw StateError('The model cannot change during an active operation.');
    }
    final model = _find(
      _state.providers.expand((item) => item.models),
      modelKey,
    );
    if (model == null) throw ArgumentError.value(modelKey, 'modelKey');
    final revision = ++_revision;
    _emit(AiModelSelectionState(providers: _state.providers, selected: model));
    final save = _saving.then((_) => _store.write(runtimeId, modelKey));
    _saving = save.catchError((_) {});
    try {
      await save;
    } catch (error) {
      if (!_disposed && revision == _revision) {
        _emit(
          AiModelSelectionState(
            providers: _state.providers,
            selected: model,
            notice: 'The model was selected but could not be persisted.',
            error: error,
          ),
        );
      }
    }
  }

  void invalidate() {
    _ensureUsable();
    _revision++;
    _emit(const AiModelSelectionState());
  }

  static AiModelInfo? _find(Iterable<AiModelInfo> models, String? key) {
    if (key == null) return null;
    for (final model in models) {
      if (model.key == key) return model;
    }
    return null;
  }

  static AiModelInfo? _preferredFreeModel(List<AiModelInfo> models) {
    final free = models.where((item) => item.isFree).toList()
      ..sort((a, b) {
        final aAuto = a.providerId == 'kilo' && a.id == 'kilo-auto/free';
        final bAuto = b.providerId == 'kilo' && b.id == 'kilo-auto/free';
        if (aAuto != bAuto) return aAuto ? -1 : 1;
        if (a.isDefault != b.isDefault) return a.isDefault ? -1 : 1;
        return a.name.compareTo(b.name);
      });
    return free.isEmpty ? null : free.first;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _revision++;
    await _states.close();
  }

  void _emit(AiModelSelectionState value) {
    _state = value;
    if (!_states.isClosed) _states.add(value);
  }

  void _ensureUsable() {
    if (_disposed) throw StateError('Model selection controller is disposed.');
  }
}
