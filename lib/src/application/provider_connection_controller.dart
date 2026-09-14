// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import '../domain/provider_connection_models.dart';
import '../domain/runtime_api_models.dart';
import 'runtime_client.dart';

/// Coordinates and verifies OpenCode-compatible provider authentication.
class AiProviderConnectionController {
  AiProviderConnectionController({
    required AiProviderAuthClient client,
    this.operationTimeout = const Duration(seconds: 90),
  }) : _client = client;

  final AiProviderAuthClient _client;
  final Duration operationTimeout;
  final _states = StreamController<AiProviderConnectionState>.broadcast();
  AiProviderConnectionState _state = const AiProviderConnectionState();
  int _revision = 0;
  bool _disposed = false;

  AiProviderConnectionState get state => _state;
  Stream<AiProviderConnectionState> get states => _states.stream;

  Future<void> refresh() async {
    _ensureAvailable();
    if (_state.operatingProviderId != null) return;
    final revision = ++_revision;
    _emit(
      AiProviderConnectionState(
        methods: _state.methods,
        connectedProviderIds: _state.connectedProviderIds,
        loading: true,
      ),
    );
    try {
      final methods = await _client.authMethods();
      final connected = await _connected();
      if (_disposed || revision != _revision) return;
      _emit(
        AiProviderConnectionState(
          methods: methods,
          connectedProviderIds: connected,
        ),
      );
    } catch (error) {
      if (!_disposed && revision == _revision) {
        _emit(AiProviderConnectionState(error: error));
      }
    }
  }

  Future<void> connectApiKey(String providerId, String apiKey) => _operate(
    providerId,
    () => _client.setApiKey(providerId, apiKey),
    shouldConnect: true,
  );

  Future<AiOAuthAuthorization> beginOAuth(
    AiAuthMethod method, {
    Map<String, String> inputs = const {},
  }) async {
    _ensureIdle();
    final revision = ++_revision;
    _emit(
      AiProviderConnectionState(
        methods: _state.methods,
        connectedProviderIds: _state.connectedProviderIds,
        operatingProviderId: method.providerId,
      ),
    );
    try {
      final authorization = await _client
          .beginOAuth(
            method.providerId,
            methodIndex: method.index,
            inputs: inputs,
          )
          .timeout(operationTimeout);
      _validateAuthorization(authorization);
      if (_disposed || revision != _revision) {
        throw StateError('Provider connection operation was superseded.');
      }
      _emit(
        AiProviderConnectionState(
          methods: _state.methods,
          connectedProviderIds: _state.connectedProviderIds,
          pendingMethod: method,
          authorization: authorization,
        ),
      );
      return authorization;
    } catch (error) {
      if (!_disposed && revision == _revision) {
        _emit(
          AiProviderConnectionState(
            methods: _state.methods,
            connectedProviderIds: _state.connectedProviderIds,
            error: error,
          ),
        );
      }
      rethrow;
    }
  }

  Future<void> completeOAuth({String? code}) async {
    final method = _state.pendingMethod;
    final authorization = _state.authorization;
    if (method == null || authorization == null) {
      throw StateError('No OAuth authorization is pending.');
    }
    if (authorization.method == 'code' && (code?.trim().isEmpty ?? true)) {
      throw const FormatException('The OAuth code is required.');
    }
    await _operate(method.providerId, () async {
      if (!(await _connected()).contains(method.providerId)) {
        await _client.completeOAuth(
          method.providerId,
          methodIndex: method.index,
          code: code,
        );
      }
    }, shouldConnect: true);
  }

  Future<void> disconnect(String providerId) => _operate(
    providerId,
    () => _client.disconnectProvider(providerId),
    shouldConnect: false,
  );

  Future<void> _operate(
    String providerId,
    Future<void> Function() operation, {
    required bool shouldConnect,
  }) async {
    _ensureIdle();
    final previous = _state;
    final revision = ++_revision;
    _emit(
      AiProviderConnectionState(
        methods: previous.methods,
        connectedProviderIds: previous.connectedProviderIds,
        operatingProviderId: providerId,
      ),
    );
    try {
      await operation().timeout(operationTimeout);
      final connected = await _connected();
      if (connected.contains(providerId) != shouldConnect) {
        throw StateError('The runtime did not confirm the provider change.');
      }
      if (_disposed || revision != _revision) return;
      _emit(
        AiProviderConnectionState(
          methods: previous.methods,
          connectedProviderIds: connected,
        ),
      );
    } catch (error) {
      if (!_disposed && revision == _revision) {
        _emit(
          AiProviderConnectionState(
            methods: previous.methods,
            connectedProviderIds: previous.connectedProviderIds,
            pendingMethod: previous.pendingMethod,
            authorization: previous.authorization,
            error: error,
          ),
        );
      }
      rethrow;
    }
  }

  Future<Set<String>> _connected() async => (await _client.providers())
      .where((item) => item.connected)
      .map((item) => item.id)
      .toSet();

  static void _validateAuthorization(AiOAuthAuthorization value) {
    if (!{'auto', 'code'}.contains(value.method)) {
      throw FormatException('Unsupported OAuth method: ${value.method}.');
    }
    final url = value.url;
    if (url == null ||
        !{'http', 'https'}.contains(url.scheme) ||
        url.host.isEmpty) {
      throw const FormatException('The runtime returned an invalid OAuth URL.');
    }
  }

  Future<void> dispose({bool disposeClient = false}) async {
    if (_disposed) return;
    _disposed = true;
    _revision++;
    if (disposeClient) _client.dispose();
    await _states.close();
  }

  void _emit(AiProviderConnectionState value) {
    _state = value;
    if (!_states.isClosed) _states.add(value);
  }

  void _ensureIdle() {
    _ensureAvailable();
    if (_state.operatingProviderId != null) {
      throw StateError('Another provider operation is active.');
    }
  }

  void _ensureAvailable() {
    if (_disposed) {
      throw StateError('Provider connection controller is disposed.');
    }
  }
}
