import 'artifact_models.dart';

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
    this.apiVersion = 1,
  });

  final AiRuntimeKind kind;
  final Uri baseUri;
  final String username;
  final String password;
  final int pid;

  /// The local HTTP API major version; Kilo uses the V1-compatible contract.
  final int apiVersion;

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

class AiRuntimeDefinition {
  const AiRuntimeDefinition({
    required this.kind,
    required this.version,
    required this.executableName,
    required this.artifact,
  });

  final AiRuntimeKind kind;
  final String version;
  final String executableName;
  final ArtifactSpec artifact;
}

class AiRuntimeInstallation {
  const AiRuntimeInstallation({
    required this.definition,
    required this.directoryPath,
  });

  final AiRuntimeDefinition definition;
  final String directoryPath;
}

enum AiRuntimeLifecycle {
  notInstalled,
  installing,
  stopped,
  starting,
  ready,
  unhealthy,
  crashed,
}

class AiRuntimeSupervisorState {
  const AiRuntimeSupervisorState({
    this.lifecycle = AiRuntimeLifecycle.notInstalled,
    this.kind,
    this.version,
    this.endpoint,
    this.error,
    this.installProgress,
  });

  final AiRuntimeLifecycle lifecycle;
  final AiRuntimeKind? kind;
  final String? version;
  final AiRuntimeEndpoint? endpoint;
  final String? error;
  final ArtifactInstallProgress? installProgress;

  bool get isBusy => switch (lifecycle) {
    AiRuntimeLifecycle.installing || AiRuntimeLifecycle.starting => true,
    _ => false,
  };

  bool get isReady => lifecycle == AiRuntimeLifecycle.ready && endpoint != null;
}
