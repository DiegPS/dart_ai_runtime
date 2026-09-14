// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../domain/artifact_models.dart';
import '../domain/runtime_models.dart';
import 'runtime_services.dart';

class AiRuntimeSupervisor {
  AiRuntimeSupervisor({
    required AiRuntimeInstallService installer,
    required AiRuntimeProcessService processes,
    required AiRuntimeHealthService health,
    String Function()? passwordGenerator,
    this.allowDownloads = false,
  }) : _installer = installer,
       _processes = processes,
       _health = health,
       _passwordGenerator = passwordGenerator ?? _securePassword;

  final AiRuntimeInstallService _installer;
  final AiRuntimeProcessService _processes;
  final AiRuntimeHealthService _health;
  final String Function() _passwordGenerator;
  final bool allowDownloads;
  final _states = StreamController<AiRuntimeSupervisorState>.broadcast();
  AiRuntimeSupervisorState _state = const AiRuntimeSupervisorState();
  AiRuntimeProcessHandle? _process;
  Future<AiRuntimeEndpoint>? _startFuture;
  AiRuntimeKind? _startingKind;
  ArtifactDownloadCancellationToken? _installationCancellation;
  int _generation = 0;
  bool _disposed = false;

  AiRuntimeSupervisorState get state => _state;
  Stream<AiRuntimeSupervisorState> get states => _states.stream;

  AiRuntimeDefinition definition(AiRuntimeKind kind) =>
      _installer.definition(kind);

  Future<bool> isInstalled(AiRuntimeKind kind) async =>
      await _installer.installed(kind) != null;

  Future<AiRuntimeInstallation> install(AiRuntimeKind kind) async {
    _ensureUsable();
    if (!allowDownloads) {
      throw UnsupportedError('Runtime downloads are disabled by the host app.');
    }
    if (_state.isBusy) throw StateError('An AI runtime operation is active.');
    final definition = _installer.definition(kind);
    final cancellation = ArtifactDownloadCancellationToken();
    _installationCancellation = cancellation;
    _emit(
      AiRuntimeSupervisorState(
        lifecycle: AiRuntimeLifecycle.installing,
        kind: kind,
        version: definition.version,
      ),
    );
    try {
      final previousProcess = _process;
      _process = null;
      if (previousProcess != null) {
        _generation++;
        await previousProcess.stop();
      }
      cancellation.throwIfCancelled();
      final installation = await _installer.install(
        kind,
        cancellation: cancellation,
        onProgress: (progress) => _emit(
          AiRuntimeSupervisorState(
            lifecycle: AiRuntimeLifecycle.installing,
            kind: kind,
            version: definition.version,
            installProgress: progress,
          ),
        ),
      );
      _emit(
        AiRuntimeSupervisorState(
          lifecycle: AiRuntimeLifecycle.stopped,
          kind: kind,
          version: definition.version,
        ),
      );
      return installation;
    } on ArtifactDownloadCancelledException {
      _emit(
        AiRuntimeSupervisorState(
          lifecycle: AiRuntimeLifecycle.stopped,
          kind: kind,
          version: definition.version,
        ),
      );
      rethrow;
    } catch (error) {
      _emit(
        AiRuntimeSupervisorState(
          lifecycle: AiRuntimeLifecycle.unhealthy,
          kind: kind,
          version: definition.version,
          error: error.toString(),
        ),
      );
      rethrow;
    } finally {
      if (identical(_installationCancellation, cancellation)) {
        _installationCancellation = null;
      }
    }
  }

  void cancelInstallation() => _installationCancellation?.cancel();

  Future<AiRuntimeEndpoint> start(AiRuntimeKind kind) {
    final activeStart = _startFuture;
    if (activeStart != null) {
      if (_startingKind == kind) return activeStart;
      throw StateError('Another AI runtime is currently starting.');
    }
    final operation = _start(kind);
    _startFuture = operation;
    _startingKind = kind;
    void clear() {
      if (identical(_startFuture, operation)) {
        _startFuture = null;
        _startingKind = null;
      }
    }

    unawaited(operation.then<void>((_) => clear(), onError: (_, _) => clear()));
    return operation;
  }

  Future<AiRuntimeEndpoint> _start(AiRuntimeKind kind) async {
    _ensureUsable();
    if (_state.isBusy) throw StateError('An AI runtime operation is active.');
    if (_process?.endpoint.kind == kind && _state.isReady) {
      return _process!.endpoint;
    }
    await stop();
    final generation = ++_generation;
    final definition = _installer.definition(kind);
    var installation = await _installer.installed(kind);
    if (installation == null) {
      if (!allowDownloads) {
        throw StateError('${kind.displayName} is not installed.');
      }
      installation = await install(kind);
    }
    if (generation != _generation || _disposed) {
      throw const _RuntimeStartCancelled();
    }
    _emit(
      AiRuntimeSupervisorState(
        lifecycle: AiRuntimeLifecycle.starting,
        kind: kind,
        version: definition.version,
      ),
    );
    AiRuntimeProcessHandle? process;
    try {
      process = await _processes.start(
        installation,
        password: _passwordGenerator(),
      );
      if (generation != _generation) throw const _RuntimeStartCancelled();
      _process = process;
      unawaited(_observeExit(process, generation));
      final health = await _health.waitUntilReady(
        process.endpoint,
        timeout: const Duration(seconds: 25),
      );
      if (!health.healthy) {
        throw StateError(health.message ?? 'Runtime health check failed.');
      }
      if (generation != _generation) throw const _RuntimeStartCancelled();
      _emit(
        AiRuntimeSupervisorState(
          lifecycle: AiRuntimeLifecycle.ready,
          kind: kind,
          version: health.version ?? definition.version,
          endpoint: process.endpoint,
        ),
      );
      return process.endpoint;
    } catch (error) {
      if (process != null) await process.stop();
      if (identical(_process, process)) _process = null;
      if (error is _RuntimeStartCancelled) rethrow;
      _emit(
        AiRuntimeSupervisorState(
          lifecycle: AiRuntimeLifecycle.unhealthy,
          kind: kind,
          version: definition.version,
          error: error.toString(),
        ),
      );
      rethrow;
    }
  }

  Future<void> restart() async {
    final kind = _state.kind;
    if (kind == null) throw StateError('No AI runtime has been selected.');
    await stop();
    await start(kind);
  }

  Future<void> stop() async {
    if (_installationCancellation != null) {
      _generation++;
      cancelInstallation();
      return;
    }
    final process = _process;
    _process = null;
    _generation++;
    if (process != null) await process.stop();
    final kind = _state.kind;
    _emit(
      AiRuntimeSupervisorState(
        lifecycle: kind == null
            ? AiRuntimeLifecycle.notInstalled
            : AiRuntimeLifecycle.stopped,
        kind: kind,
        version: _state.version,
      ),
    );
  }

  Future<void> _observeExit(
    AiRuntimeProcessHandle process,
    int generation,
  ) async {
    final code = await process.exitCode;
    if (_disposed ||
        generation != _generation ||
        !identical(_process, process)) {
      return;
    }
    _process = null;
    _emit(
      AiRuntimeSupervisorState(
        lifecycle: AiRuntimeLifecycle.crashed,
        kind: process.endpoint.kind,
        version: _state.version,
        error: 'The AI runtime stopped unexpectedly (exit code $code).',
      ),
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _installationCancellation?.cancel();
    final process = _process;
    _process = null;
    _generation++;
    if (process != null) await process.stop();
    await _states.close();
  }

  void _emit(AiRuntimeSupervisorState value) {
    _state = value;
    if (!_states.isClosed) _states.add(value);
  }

  void _ensureUsable() {
    if (_disposed) throw StateError('AI runtime supervisor is disposed.');
  }

  static String _securePassword() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }
}

class _RuntimeStartCancelled implements Exception {
  const _RuntimeStartCancelled();
}
