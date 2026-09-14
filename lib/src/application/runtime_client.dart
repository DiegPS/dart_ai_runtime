import '../domain/runtime_api_models.dart';

abstract interface class AiRuntimeClient {
  Future<List<AiProviderInfo>> providers();
  Future<List<AiAuthMethod>> authMethods();
  Future<AiSession> createSession({String? title});
  Future<AiSession> session(String sessionId);
  Future<List<Map<String, dynamic>>> messages(String sessionId);
  Future<void> promptAsync(String sessionId, AiPrompt prompt);
  Future<void> abort(String sessionId);
  Future<void> deleteSession(String sessionId);
  Future<Stream<AiRuntimeEvent>> connectEvents();
  Stream<AiRuntimeEvent> events();
  void dispose();
}

abstract interface class AiProviderAuthClient {
  Future<List<AiProviderInfo>> providers();
  Future<List<AiAuthMethod>> authMethods();
  Future<void> setApiKey(String providerId, String apiKey);
  Future<AiOAuthAuthorization> beginOAuth(
    String providerId, {
    required int methodIndex,
    Map<String, String> inputs,
  });
  Future<void> completeOAuth(
    String providerId, {
    required int methodIndex,
    String? code,
  });
  Future<void> disconnectProvider(String providerId);
  void dispose();
}
