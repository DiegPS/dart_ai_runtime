import 'runtime_api_models.dart';

class AiProviderConnectionState {
  const AiProviderConnectionState({
    this.methods = const [],
    this.connectedProviderIds = const {},
    this.loading = false,
    this.operatingProviderId,
    this.pendingMethod,
    this.authorization,
    this.error,
  });

  final List<AiAuthMethod> methods;
  final Set<String> connectedProviderIds;
  final bool loading;
  final String? operatingProviderId;
  final AiAuthMethod? pendingMethod;
  final AiOAuthAuthorization? authorization;
  final Object? error;
}
