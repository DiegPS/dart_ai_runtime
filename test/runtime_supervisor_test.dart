import 'dart:async';

import 'package:air_ai_runtime/air_ai_runtime.dart';
import 'package:test/test.dart';

void main() {
  test(
    'downloads, installs and starts an absent runtime when enabled',
    () async {
      final installer = _FakeInstaller(installedByDefault: false);
      final processes = _FakeProcesses();
      final supervisor = AiRuntimeSupervisor(
        installer: installer,
        processes: processes,
        health: _HealthyClient(),
        allowDownloads: true,
      );
      addTearDown(supervisor.dispose);

      await supervisor.start(AiRuntimeKind.kilo);

      expect(installer.installCount, 1);
      expect(processes.paths, ['downloaded/kilo']);
      expect(supervisor.state.isReady, isTrue);
    },
  );

  test('switching runtimes stops the previous process', () async {
    final processes = _FakeProcesses();
    final supervisor = AiRuntimeSupervisor(
      installer: _FakeInstaller(),
      processes: processes,
      health: _HealthyClient(),
      passwordGenerator: () => 'secret',
    );
    addTearDown(supervisor.dispose);

    await supervisor.start(AiRuntimeKind.openCode);
    final first = processes.handles.single;
    await supervisor.start(AiRuntimeKind.kilo);

    expect(first.stopped, isTrue);
    expect(processes.handles, hasLength(2));
    expect(supervisor.state.kind, AiRuntimeKind.kilo);
  });

  test('concurrent starts for the same runtime share one process', () async {
    final processes = _FakeProcesses();
    final supervisor = AiRuntimeSupervisor(
      installer: _FakeInstaller(),
      processes: processes,
      health: _HealthyClient(),
    );
    addTearDown(supervisor.dispose);

    await Future.wait([
      supervisor.start(AiRuntimeKind.openCode),
      supervisor.start(AiRuntimeKind.openCode),
    ]);

    expect(processes.handles, hasLength(1));
  });

  test('unexpected process exit is reported as a crash', () async {
    final processes = _FakeProcesses();
    final supervisor = AiRuntimeSupervisor(
      installer: _FakeInstaller(),
      processes: processes,
      health: _HealthyClient(),
    );
    addTearDown(supervisor.dispose);
    await supervisor.start(AiRuntimeKind.openCode);

    processes.handles.single.crash(17);
    await Future<void>.delayed(Duration.zero);

    expect(supervisor.state.lifecycle, AiRuntimeLifecycle.crashed);
    expect(supervisor.state.error, contains('17'));
  });

  test('host can forbid automatic runtime downloads', () async {
    final supervisor = AiRuntimeSupervisor(
      installer: _FakeInstaller(installedByDefault: false),
      processes: _FakeProcesses(),
      health: _HealthyClient(),
    );
    addTearDown(supervisor.dispose);

    await expectLater(supervisor.start(AiRuntimeKind.kilo), throwsStateError);
    await expectLater(
      supervisor.install(AiRuntimeKind.kilo),
      throwsUnsupportedError,
    );
  });
}

class _FakeInstaller implements AiRuntimeInstallService {
  _FakeInstaller({this.installedByDefault = true});

  final bool installedByDefault;
  int installCount = 0;

  @override
  AiRuntimeDefinition definition(AiRuntimeKind kind) => AiRuntimeDefinition(
    kind: kind,
    version: '1',
    executableName: '${kind.id}.exe',
    artifact: PinnedAiRuntimeCatalog().definition(kind).artifact,
  );

  @override
  Future<AiRuntimeInstallation?> installed(AiRuntimeKind kind) async =>
      installedByDefault
      ? AiRuntimeInstallation(
          definition: definition(kind),
          directoryPath: 'installed/${kind.id}',
        )
      : null;

  @override
  Future<AiRuntimeInstallation> install(
    AiRuntimeKind kind, {
    ArtifactDownloadCancellation? cancellation,
    void Function(ArtifactInstallProgress progress)? onProgress,
  }) async {
    installCount++;
    return AiRuntimeInstallation(
      definition: definition(kind),
      directoryPath: 'downloaded/${kind.id}',
    );
  }
}

class _FakeProcesses implements AiRuntimeProcessService {
  final handles = <_FakeProcess>[];
  final paths = <String>[];

  @override
  Future<AiRuntimeProcessHandle> start(
    AiRuntimeInstallation installation, {
    required String password,
  }) async {
    paths.add(installation.directoryPath);
    final process = _FakeProcess(installation.definition.kind, password);
    handles.add(process);
    return process;
  }
}

class _FakeProcess implements AiRuntimeProcessHandle {
  _FakeProcess(AiRuntimeKind kind, String password)
    : endpoint = AiRuntimeEndpoint(
        kind: kind,
        baseUri: Uri.parse('http://127.0.0.1:12345'),
        username: kind.id,
        password: password,
        pid: 1,
      );

  final _exit = Completer<int>();
  bool stopped = false;

  @override
  final AiRuntimeEndpoint endpoint;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  Stream<String> get logs => const Stream.empty();

  void crash(int code) => _exit.complete(code);

  @override
  Future<void> stop() async {
    stopped = true;
    if (!_exit.isCompleted) _exit.complete(0);
  }
}

class _HealthyClient implements AiRuntimeHealthService {
  @override
  Future<AiRuntimeHealth> waitUntilReady(
    AiRuntimeEndpoint endpoint, {
    Duration timeout = const Duration(seconds: 25),
  }) async => const AiRuntimeHealth(healthy: true, version: '1');
}
