import 'dart:async';

import 'package:dart_ai_runtime/dart_ai_runtime.dart';
import 'package:test/test.dart';

const _free = AiModelInfo(
  id: 'free',
  name: 'Free',
  providerId: 'test',
  isFree: true,
);
const _paid = AiModelInfo(
  id: 'paid',
  name: 'Paid',
  providerId: 'test',
  isFree: false,
);
const _oauth = AiAuthMethod(
  providerId: 'test',
  type: 'oauth',
  label: 'Login',
  index: 1,
);
AiProviderInfo _provider(List<AiModelInfo> models) =>
    AiProviderInfo(id: 'test', name: 'Test', connected: true, models: models);

void main() {
  group('model selection lifecycle', () {
    test(
      'restores a saved model, persists changes and invalidates safely',
      () async {
        final store = _Store()..value = _paid.key;
        final controller = AiModelSelectionController(
          runtimeId: 'runtime',
          loadProviders: () async => [
            _provider([_free, _paid]),
          ],
          store: store,
        );
        addTearDown(controller.dispose);
        final states = <AiModelSelectionState>[];
        controller.states.listen(states.add);
        await controller.refresh();
        expect(controller.state.selected, same(_paid));
        await controller.select(_free.key);
        expect(store.value, _free.key);
        expect(controller.state.selected, same(_free));
        await expectLater(
          controller.select('missing/model'),
          throwsArgumentError,
        );
        controller.invalidate();
        expect(controller.state.selected, isNull);
        await Future<void>.delayed(Duration.zero);
        expect(states.any((s) => s.loading), isTrue);
        await controller.dispose();
        await controller.dispose();
        await expectLater(controller.refresh(), throwsStateError);
        expect(controller.invalidate, throwsStateError);
      },
    );

    test(
      'save failure preserves selection and a later save can succeed',
      () async {
        final error = StateError('Store unavailable');
        final store = _Store()..failure = error;
        final controller = AiModelSelectionController(
          runtimeId: 'runtime',
          loadProviders: () async => [
            _provider([_free, _paid]),
          ],
          store: store,
        );
        addTearDown(controller.dispose);
        await controller.refresh();
        await controller.select(_paid.key);
        expect(controller.state.selected, same(_paid));
        expect(controller.state.error, same(error));
        expect(controller.state.notice, contains('persisted'));
        store.failure = null;
        await controller.select(_free.key);
        expect(store.value, _free.key);
        expect(controller.state.error, isNull);
      },
    );

    test('a newer catalog wins and loading forbids selection', () async {
      final first = Completer<List<AiProviderInfo>>();
      var calls = 0;
      final controller = AiModelSelectionController(
        runtimeId: 'runtime',
        loadProviders: () => ++calls == 1
            ? first.future
            : Future.value([
                _provider([_free]),
              ]),
        store: _Store(),
      );
      addTearDown(controller.dispose);
      final obsolete = controller.refresh();
      await expectLater(controller.select(_free.key), throwsStateError);
      await controller.refresh();
      first.completeError(StateError('Obsolete failure'));
      await obsolete;
      expect(controller.state.selected, same(_free));
      expect(controller.state.error, isNull);
    });

    test(
      'catalog failure is observable and disposal ignores pending results',
      () async {
        final error = StateError('Catalog unavailable');
        final controller = AiModelSelectionController(
          runtimeId: 'runtime',
          loadProviders: () => Future.error(error),
          store: _Store(),
        );
        await controller.refresh();
        expect(controller.state.error, same(error));
        await controller.dispose();
        final pending = Completer<List<AiProviderInfo>>();
        final disposed = AiModelSelectionController(
          runtimeId: 'runtime',
          loadProviders: () => pending.future,
          store: _Store(),
        );
        final operation = disposed.refresh();
        await disposed.dispose();
        pending.complete([
          _provider([_free]),
        ]);
        await operation;
        expect(disposed.state.selected, isNull);
      },
    );

    test('free defaults and sorting never choose a paid fallback', () async {
      const preferred = AiModelInfo(
        id: 'default',
        name: 'Z',
        providerId: 'test',
        isFree: true,
        isDefault: true,
      );
      final controller = AiModelSelectionController(
        runtimeId: 'runtime',
        store: _Store(),
        loadProviders: () async => [
          AiProviderInfo(
            id: 'z',
            name: 'Z',
            connected: true,
            models: const [_paid],
          ),
          AiProviderInfo(
            id: 'a',
            name: 'A',
            connected: true,
            models: const [_free, preferred],
          ),
          AiProviderInfo(
            id: 'hidden',
            name: 'Hidden',
            connected: false,
            models: const [_free],
          ),
        ],
      );
      await controller.refresh();
      expect(controller.state.providers.map((p) => p.id), ['a', 'z']);
      expect(controller.state.selected, same(preferred));
      await controller.dispose();
    });
  });

  group('provider authentication lifecycle', () {
    test('refreshes methods and verifies disconnects', () async {
      final client = _Auth()..connected.add('test');
      final controller = AiProviderConnectionController(client: client);
      final states = <AiProviderConnectionState>[];
      controller.states.listen(states.add);
      await controller.refresh();
      expect(controller.state.methods, [_oauth]);
      expect(controller.state.connectedProviderIds, {'test'});
      await controller.disconnect('test');
      expect(controller.state.connectedProviderIds, isEmpty);
      await controller.dispose(disposeClient: true);
      await controller.dispose(disposeClient: true);
      expect(client.disposed, isTrue);
      expect(states.any((s) => s.loading), isTrue);
      await expectLater(controller.refresh(), throwsStateError);
    });

    test(
      'failed refresh records the cause without throwing to the caller',
      () async {
        final client = _Auth()..methodsError = StateError('Offline');
        final controller = AiProviderConnectionController(client: client);
        addTearDown(controller.dispose);
        await controller.refresh();
        expect(controller.state.error, same(client.methodsError));
      },
    );

    test('code OAuth validates input and invokes one callback', () async {
      final client = _Auth()
        ..authorization = AiOAuthAuthorization(
          method: 'code',
          url: Uri.parse('https://example.test/oauth'),
        );
      final controller = AiProviderConnectionController(client: client);
      addTearDown(controller.dispose);
      await expectLater(controller.completeOAuth(), throwsStateError);
      await controller.beginOAuth(_oauth, inputs: {'region': 'test'});
      await expectLater(
        controller.completeOAuth(code: '  '),
        throwsFormatException,
      );
      await controller.completeOAuth(code: 'confirmed');
      expect(client.callbackCount, 1);
      expect(controller.state.connectedProviderIds, {'test'});
    });

    test('invalid OAuth URLs and timeouts release the operation', () async {
      final client = _Auth()
        ..authorization = AiOAuthAuthorization(
          method: 'code',
          url: Uri.parse('file:///private'),
        );
      final controller = AiProviderConnectionController(
        client: client,
        operationTimeout: const Duration(milliseconds: 15),
      );
      addTearDown(controller.dispose);
      await expectLater(controller.beginOAuth(_oauth), throwsFormatException);
      client.oauthGate = Completer<AiOAuthAuthorization>();
      await expectLater(
        controller.beginOAuth(_oauth),
        throwsA(isA<TimeoutException>()),
      );
      expect(controller.state.operatingProviderId, isNull);
      client.oauthGate!.complete(client.authorization);
    });

    test(
      'busy operations reject overlap and refresh cannot reset them',
      () async {
        final client = _Auth()..keyGate = Completer<void>();
        final controller = AiProviderConnectionController(client: client);
        addTearDown(controller.dispose);
        final connecting = controller.connectApiKey('test', 'test-only');
        await expectLater(controller.disconnect('test'), throwsStateError);
        await controller.refresh();
        expect(controller.state.operatingProviderId, 'test');
        client.keyGate!.complete();
        await connecting;
        expect(controller.state.connectedProviderIds, {'test'});
      },
    );

    test(
      'unconfirmed changes preserve pending OAuth context for retry',
      () async {
        final client = _Auth()..confirmCallback = false;
        final controller = AiProviderConnectionController(client: client);
        addTearDown(controller.dispose);
        await controller.beginOAuth(_oauth);
        await expectLater(controller.completeOAuth(), throwsStateError);
        expect(controller.state.pendingMethod, same(_oauth));
        expect(controller.state.authorization, same(client.authorization));
        client.confirmCallback = true;
        await controller.completeOAuth();
        expect(controller.state.connectedProviderIds, {'test'});
      },
    );

    test('disposal supersedes pending authorization and ignores connection results', () async {
      final client = _Auth()..oauthGate = Completer<AiOAuthAuthorization>();
      final controller = AiProviderConnectionController(client: client);
      final superseded = expectLater(
        controller.beginOAuth(_oauth),
        throwsStateError,
      );
      await controller.dispose();
      client.oauthGate!.complete(client.authorization);
      await superseded;
      final other = _Auth()..keyGate = Completer<void>();
      final disposed = AiProviderConnectionController(client: other);
      final pending = disposed.connectApiKey('test', 'test-only');
      await disposed.dispose();
      other.keyGate!.complete();
      await pending;
      expect(disposed.state.connectedProviderIds, isEmpty);
    });
  });
}

class _Store implements AiModelSelectionStore {
  String? value;
  Object? failure;
  @override
  Future<String?> read(String runtimeId) async => value;
  @override
  Future<void> write(String runtimeId, String modelKey) async {
    if (failure != null) throw failure!;
    value = modelKey;
  }
}

class _Auth implements AiProviderAuthClient {
  final connected = <String>{};
  Object? methodsError;
  Completer<void>? keyGate;
  Completer<AiOAuthAuthorization>? oauthGate;
  AiOAuthAuthorization authorization = AiOAuthAuthorization(
    method: 'auto',
    url: Uri.parse('https://example.test/oauth'),
  );
  bool confirmCallback = true;
  bool disposed = false;
  int callbackCount = 0;
  @override
  Future<List<AiAuthMethod>> authMethods() async {
    if (methodsError != null) throw methodsError!;
    return const [_oauth];
  }

  @override
  Future<AiOAuthAuthorization> beginOAuth(
    String providerId, {
    required int methodIndex,
    Map<String, String> inputs = const {},
  }) async => oauthGate == null ? authorization : oauthGate!.future;
  @override
  Future<void> setApiKey(String providerId, String apiKey) async {
    await keyGate?.future;
    connected.add(providerId);
  }

  @override
  Future<void> completeOAuth(
    String providerId, {
    required int methodIndex,
    String? code,
  }) async {
    callbackCount++;
    if (confirmCallback) connected.add(providerId);
  }

  @override
  Future<void> disconnectProvider(String providerId) async {
    connected.remove(providerId);
  }

  @override
  Future<List<AiProviderInfo>> providers() async => [
    for (final id in connected)
      AiProviderInfo(id: id, name: id, connected: true, models: const []),
  ];
  @override
  void dispose() {
    disposed = true;
  }
}
