import 'package:dart_ai_runtime/dart_ai_runtime.dart';
import 'package:test/test.dart';

void main() {
  test('API key connection must be confirmed by provider catalog', () async {
    final client = _AuthClient();
    final controller = AiProviderConnectionController(client: client);
    await controller.connectApiKey('openai', 'secret');
    expect(controller.state.connectedProviderIds, contains('openai'));
    await controller.dispose();
  });

  test('rejects invalid OAuth authorization returned by runtime', () async {
    final client = _AuthClient(
      authorization: const AiOAuthAuthorization(method: 'unsupported'),
    );
    final controller = AiProviderConnectionController(client: client);
    final method = const AiAuthMethod(
      providerId: 'test',
      type: 'oauth',
      label: 'OAuth',
      index: 0,
    );
    await expectLater(controller.beginOAuth(method), throwsFormatException);
    await controller.dispose();
  });

  test('device OAuth does not replay callback after auto-connect', () async {
    final client = _AuthClient();
    final controller = AiProviderConnectionController(client: client);
    final method = const AiAuthMethod(
      providerId: 'test',
      type: 'oauth',
      label: 'OAuth',
      index: 0,
    );
    await controller.beginOAuth(method);
    client.connected.add('test');
    await controller.completeOAuth();
    expect(client.callbackCount, 0);
    await controller.dispose();
  });
}

class _AuthClient implements AiProviderAuthClient {
  _AuthClient({AiOAuthAuthorization? authorization})
    : authorization =
          authorization ??
          AiOAuthAuthorization(
            method: 'auto',
            url: Uri.parse('https://example.com'),
          );

  final AiOAuthAuthorization authorization;
  final connected = <String>{};
  int callbackCount = 0;

  @override
  Future<List<AiAuthMethod>> authMethods() async => const [];

  @override
  Future<AiOAuthAuthorization> beginOAuth(
    String providerId, {
    required int methodIndex,
    Map<String, String> inputs = const {},
  }) async => authorization;

  @override
  Future<void> completeOAuth(
    String providerId, {
    required int methodIndex,
    String? code,
  }) async {
    callbackCount++;
    connected.add(providerId);
  }

  @override
  Future<void> disconnectProvider(String providerId) async {
    connected.remove(providerId);
  }

  @override
  void dispose() {}

  @override
  Future<List<AiProviderInfo>> providers() async => connected
      .map(
        (id) =>
            AiProviderInfo(id: id, name: id, connected: true, models: const []),
      )
      .toList();

  @override
  Future<void> setApiKey(String providerId, String apiKey) async {
    connected.add(providerId);
  }
}
