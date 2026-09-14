// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../application/runtime_services.dart';
import '../domain/runtime_models.dart';
import 'local_system_prompt_service.dart';
import 'runtime_storage.dart';
import 'windows_job_object.dart';

/// Starts an isolated OpenCode-compatible runtime on a dynamic loopback port.
class LocalAiRuntimeProcessService implements AiRuntimeProcessService {
  /// Creates a process service backed by private [AiRuntimeStorage].
  ///
  /// Managed neutral prompts are enabled by default. Setting
  /// [enableNeutralSystemPrompts] to `false` restores pure upstream mode and
  /// disables all external plugins.
  LocalAiRuntimeProcessService(
    this._storage, {
    AiRuntimeSystemPromptService? systemPromptService,
    bool enableNeutralSystemPrompts = true,
  }) : _systemPromptService = enableNeutralSystemPrompts
           ? systemPromptService ?? LocalAiRuntimeSystemPromptService(_storage)
           : null;

  final AiRuntimeStorage _storage;
  final AiRuntimeSystemPromptService? _systemPromptService;

  /// The bridge used by clients to supply neutral per-session system prompts.
  ///
  /// The value is `null` when neutral system prompts were explicitly disabled.
  AiRuntimeSystemPromptService? get systemPromptService => _systemPromptService;

  @override
  Future<AiRuntimeProcessHandle> start(
    AiRuntimeInstallation installation, {
    required String password,
  }) async {
    final definition = installation.definition;
    final kind = definition.kind;
    await _storage.createPrivateDirectories(kind);
    await _systemPromptService?.prepare(kind);
    final executable = File(
      p.join(installation.directoryPath, definition.executableName),
    );
    if (!await executable.exists()) {
      throw StateError('${definition.executableName} is not installed.');
    }
    final process = await Process.start(
      executable.path,
      const ['serve', '--hostname', '127.0.0.1', '--port', '0'],
      workingDirectory: _storage.workspace(kind).path,
      environment: buildSanitizedEnvironment(
        kind: kind,
        storage: _storage,
        username: kind.id,
        password: password,
        parentEnvironment: Platform.environment,
        allowManagedPlugins: _systemPromptService != null,
      ),
      includeParentEnvironment: false,
      runInShell: false,
    );
    WindowsJobObject? job;
    try {
      if (Platform.isWindows) {
        job = WindowsJobObject.attachToProcess(process.pid);
      }
      final running = _LocalAiRuntimeProcess(
        kind: kind,
        process: process,
        job: job,
        username: kind.id,
        password: password,
        cleanup: _systemPromptService == null
            ? null
            : () => _systemPromptService.clearSystemPrompts(kind),
      );
      await running.waitForEndpoint(const Duration(seconds: 15));
      return running;
    } catch (_) {
      job?.close();
      process.kill();
      rethrow;
    }
  }

  static const Set<String> systemEnvironmentWhitelist = {
    'systemroot',
    'systemdrive',
    'windir',
    'comspec',
    'path',
    'pathext',
    'userprofile',
    'homedrive',
    'homepath',
    'programdata',
    'programfiles',
    'programfiles(x86)',
    'commonprogramfiles',
    'commonprogramfiles(x86)',
    'number_of_processors',
    'processor_architecture',
    'os',
  };

  static final RegExp _sensitivePattern = RegExp(
    r'api[-_]?key|token|secret|auth|credential|password|openai|anthropic|gemini|github|aws|azure',
    caseSensitive: false,
  );

  static Map<String, String> buildSanitizedEnvironment({
    required AiRuntimeKind kind,
    required AiRuntimeStorage storage,
    required String username,
    required String password,
    Map<String, String> parentEnvironment = const {},
    bool allowManagedPlugins = false,
  }) {
    final sanitized = <String, String>{};
    for (final entry in parentEnvironment.entries) {
      final normalizedKey = entry.key.toLowerCase();
      if (systemEnvironmentWhitelist.contains(normalizedKey) &&
          !_sensitivePattern.hasMatch(entry.key) &&
          !_sensitivePattern.hasMatch(entry.value)) {
        sanitized[entry.key] = entry.value;
      }
    }
    final prefix = kind.environmentPrefix;
    sanitized.addAll({
      'XDG_DATA_HOME': storage.data(kind).path,
      'XDG_CACHE_HOME': storage.cache(kind).path,
      'XDG_CONFIG_HOME': storage.config(kind).path,
      'XDG_STATE_HOME': storage.state(kind).path,
      'TEMP': storage.temp(kind).path,
      'TMP': storage.temp(kind).path,
      '${prefix}_SERVER_PASSWORD': password,
      '${prefix}_SERVER_USERNAME': username,
      '${prefix}_DISABLE_AUTOUPDATE': '1',
      if (!allowManagedPlugins) '${prefix}_PURE': '1',
      '${prefix}_DISABLE_PROJECT_CONFIG': '1',
      '${prefix}_CLIENT': storage.applicationId,
      '${prefix}_DISABLE_TOOLS': '1',
      if (kind == AiRuntimeKind.kilo) ...{
        'KILO_DISABLE_EXTERNAL_SKILLS': '1',
        'KILO_DISABLE_LSP_DOWNLOAD': '1',
        'KILO_DISABLE_EMBEDDED_WEB_UI': '1',
      },
    });
    return sanitized;
  }
}

class _LocalAiRuntimeProcess implements AiRuntimeProcessHandle {
  _LocalAiRuntimeProcess({
    required this.kind,
    required Process process,
    required WindowsJobObject? job,
    required this.username,
    required this.password,
    required Future<void> Function()? cleanup,
  }) : _process = process,
       _job = job,
       _cleanupCallback = cleanup {
    _stdoutSubscription = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_handleLine, onError: _handleOutputError);
    _stderrSubscription = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_handleLine, onError: _handleOutputError);
    unawaited(
      process.exitCode.then((code) {
        unawaited(_cleanup().then<void>((_) {}, onError: (_, _) {}));
        if (!_endpoint.isCompleted) {
          _endpoint.completeError(
            StateError('Runtime exited before listening (exit code $code).'),
          );
        }
      }),
    );
  }

  final AiRuntimeKind kind;
  final String username;
  final String password;
  final Process _process;
  WindowsJobObject? _job;
  final Future<void> Function()? _cleanupCallback;
  Future<void>? _cleanupFuture;
  final _lines = StreamController<String>.broadcast();
  final _endpoint = Completer<AiRuntimeEndpoint>();
  late final StreamSubscription<String> _stdoutSubscription;
  late final StreamSubscription<String> _stderrSubscription;
  AiRuntimeEndpoint? _resolvedEndpoint;
  bool _stopped = false;

  @override
  AiRuntimeEndpoint get endpoint =>
      _resolvedEndpoint ?? (throw StateError('Runtime endpoint is not ready.'));

  @override
  Stream<String> get logs => _lines.stream;

  @override
  Future<int> get exitCode => _process.exitCode;

  Future<void> waitForEndpoint(Duration timeout) async {
    _resolvedEndpoint = await _endpoint.future.timeout(timeout);
  }

  void _handleLine(String line) {
    if (!_lines.isClosed) _lines.add(line);
    if (_endpoint.isCompleted) return;
    final match = RegExp(r'https?://(?:127\.0\.0\.1|localhost|\[::1\]):(\d+)')
        .firstMatch(line);
    final port = int.tryParse(match?.group(1) ?? '');
    if (port == null || port < 1 || port > 65535) return;
    _endpoint.complete(
      AiRuntimeEndpoint(
        kind: kind,
        baseUri: Uri.parse('http://127.0.0.1:$port'),
        username: username,
        password: password,
        pid: _process.pid,
      ),
    );
  }

  void _handleOutputError(Object error) {
    if (!_endpoint.isCompleted) _endpoint.completeError(error);
  }

  @override
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _process.kill();
    try {
      await _process.exitCode.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      _job?.close();
      await _process.exitCode.timeout(
        const Duration(seconds: 2),
        onTimeout: () => -1,
      );
    }
    _job?.close();
    _job = null;
    await _cleanup();
    await _stdoutSubscription.cancel();
    await _stderrSubscription.cancel();
    await _lines.close();
  }

  Future<void> _cleanup() =>
      _cleanupFuture ??= _cleanupCallback?.call() ?? Future<void>.value();
}
