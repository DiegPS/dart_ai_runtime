enum AiRuntimeKind { openCode, kilo }

extension AiRuntimeKindDetails on AiRuntimeKind {
  String get id => switch (this) {
    AiRuntimeKind.openCode => 'opencode',
    AiRuntimeKind.kilo => 'kilo',
  };

  String get displayName => switch (this) {
    AiRuntimeKind.openCode => 'OpenCode',
    AiRuntimeKind.kilo => 'Kilo',
  };

  String get environmentPrefix => switch (this) {
    AiRuntimeKind.openCode => 'OPENCODE',
    AiRuntimeKind.kilo => 'KILO',
  };

  String get directoryHeader => switch (this) {
    AiRuntimeKind.openCode => 'x-opencode-directory',
    AiRuntimeKind.kilo => 'x-kilo-directory',
  };
}

class AiRuntimeEndpoint {
  const AiRuntimeEndpoint({
    required this.kind,
    required this.baseUri,
    required this.username,
    required this.password,
    required this.pid,
  });

  final AiRuntimeKind kind;
  final Uri baseUri;
  final String username;
  final String password;
  final int pid;

  bool get isLoopback {
    final host = baseUri.host.toLowerCase();
    return host == '127.0.0.1' || host == 'localhost' || host == '::1';
  }
}

class AiRuntimeHealth {
  const AiRuntimeHealth({required this.healthy, this.version, this.message});

  final bool healthy;
  final String? version;
  final String? message;
}
