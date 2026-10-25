import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../application/runtime_services.dart';
import '../domain/runtime_models.dart';
import 'runtime_storage.dart';

/// Stores one-shot system prompts for the trusted OpenCode or Kilo plugin.
///
/// Prompt files and generated plugin configuration live below the private
/// application root in [AiRuntimeStorage]. They are never placed in the shared
/// runtime store. The plugin consumes each prompt file and keeps the trusted
/// value in process memory for repeated provider hooks within that session.
class LocalAiRuntimeSystemPromptService
    implements AiRuntimeSystemPromptService {
  LocalAiRuntimeSystemPromptService(
    this.storage, {
    this.maximumPromptLength = 1024 * 1024,
  }) {
    if (maximumPromptLength < 1) {
      throw ArgumentError.value(
        maximumPromptLength,
        'maximumPromptLength',
        'Must be positive.',
      );
    }
  }

  /// The managed agent selected for all host-controlled conversations.
  static const agentId = 'dart_ai_runtime_neutral';

  /// The placeholder sent through the HTTP API instead of the real prompt.
  static const transportPlaceholder =
      'The trusted host supplies the system prompt through its private session bridge.';

  final AiRuntimeStorage storage;

  /// The maximum number of UTF-16 code units accepted in a system prompt.
  final int maximumPromptLength;

  final Map<String, Future<void>> _operations = {};

  @override
  Future<void> prepare(AiRuntimeKind kind) async {
    await storage.createPrivateDirectories(kind);
    await _rejectAutoLoadedPlugins(kind);
    final managed = _managedDirectory(kind);
    await managed.create(recursive: true);
    await clearSystemPrompts(kind);
    await _writeText(_pluginFile(kind), _pluginSource(kind));
    await _writeManagedConfig(kind);
  }

  @override
  Future<void> setSystemPrompt(
    AiRuntimeKind kind,
    String sessionId,
    String systemPrompt,
  ) {
    _validateSessionId(sessionId);
    if (systemPrompt.trim().isEmpty) {
      throw ArgumentError.value(
        systemPrompt,
        'systemPrompt',
        'Must not be empty.',
      );
    }
    if (systemPrompt.length > maximumPromptLength) {
      throw ArgumentError.value(
        systemPrompt.length,
        'systemPrompt',
        'Exceeds the $maximumPromptLength character limit.',
      );
    }
    return _serialize(kind, sessionId, () async {
      final directory = _promptDirectory(kind);
      await directory.create(recursive: true);
      await _writeText(
        _promptFile(kind, sessionId),
        jsonEncode({
          'version': 1,
          'sessionId': sessionId,
          'system': systemPrompt,
        }),
      );
    });
  }

  @override
  Future<void> removeSystemPrompt(AiRuntimeKind kind, String sessionId) {
    _validateSessionId(sessionId);
    return _serialize(kind, sessionId, () async {
      final file = _promptFile(kind, sessionId);
      if (await file.exists()) await file.delete();
    });
  }

  @override
  Future<void> clearSystemPrompts(AiRuntimeKind kind) async {
    final directory = _promptDirectory(kind);
    if (!await directory.exists()) return;
    await for (final entity in directory.list()) {
      if (entity is File &&
          (entity.path.endsWith('.json') || entity.path.endsWith('.tmp'))) {
        await entity.delete();
      }
    }
  }

  Directory _runtimeConfigDirectory(AiRuntimeKind kind) =>
      Directory(p.join(storage.config(kind).path, kind.id));

  Directory _managedDirectory(AiRuntimeKind kind) =>
      Directory(p.join(_runtimeConfigDirectory(kind).path, 'dart_ai_runtime'));

  Directory _promptDirectory(AiRuntimeKind kind) =>
      Directory(p.join(_managedDirectory(kind).path, 'system_prompts'));

  File _pluginFile(AiRuntimeKind kind) =>
      File(p.join(_managedDirectory(kind).path, 'neutral_system.js'));

  File _promptFile(AiRuntimeKind kind, String sessionId) =>
      File(p.join(_promptDirectory(kind).path, '$sessionId.json'));

  File _configFile(AiRuntimeKind kind) => File(
    p.join(
      _runtimeConfigDirectory(kind).path,
      kind == AiRuntimeKind.openCode ? 'opencode.json' : 'kilo.json',
    ),
  );

  Future<void> _writeManagedConfig(AiRuntimeKind kind) async {
    final file = _configFile(kind);
    await file.parent.create(recursive: true);
    final config = await _readConfig(file);
    final configuredPlugins = switch (config['plugin']) {
      final List<Object?> values =>
        values.map((value) => value.toString()).toList(),
      null => <String>[],
      _ => throw FormatException('${file.path} has a non-list plugin field.'),
    };
    const pluginPath = './dart_ai_runtime/neutral_system.js';
    final unmanagedPlugins = configuredPlugins
        .where((plugin) => plugin != pluginPath)
        .toList(growable: false);
    if (unmanagedPlugins.isNotEmpty) {
      throw StateError(
        'Managed neutral mode refuses external plugins in ${file.path}: '
        '${unmanagedPlugins.join(', ')}.',
      );
    }
    final rawAgents = config['agent'];
    final agents = rawAgents == null
        ? <String, Object?>{}
        : rawAgents is Map
        ? Map<String, Object?>.from(rawAgents)
        : throw FormatException('${file.path} has a non-object agent field.');
    agents[agentId] = {
      'description': 'Neutral assistant controlled by the embedding Dart host',
      'mode': 'primary',
      'prompt': 'The trusted Dart host supplies the system prompt per session.',
      'permission': {'*': 'deny'},
    };
    config
      ..putIfAbsent(
        r'$schema',
        () => kind == AiRuntimeKind.openCode
            ? 'https://opencode.ai/config.json'
            : 'https://app.kilo.ai/config.json',
      )
      ..['plugin'] = <String>[pluginPath]
      ..['default_agent'] = agentId
      ..['agent'] = agents;
    await _writeText(file, const JsonEncoder.withIndent('  ').convert(config));
  }

  Future<Map<String, Object?>> _readConfig(File file) async {
    if (!await file.exists()) return <String, Object?>{};
    final text = await file.readAsString();
    if (text.trim().isEmpty) return <String, Object?>{};
    final value = jsonDecode(text);
    if (value is! Map) {
      throw FormatException('${file.path} does not contain a JSON object.');
    }
    return Map<String, Object?>.from(value);
  }

  Future<void> _rejectAutoLoadedPlugins(AiRuntimeKind kind) async {
    final config = _runtimeConfigDirectory(kind);
    final directories = kind == AiRuntimeKind.openCode
        ? <Directory>[Directory(p.join(config.path, 'plugins'))]
        : <Directory>[
            Directory(p.join(config.path, 'plugin')),
            Directory(p.join(config.path, 'plugins')),
          ];
    for (final directory in directories) {
      if (!await directory.exists()) continue;
      await for (final entity in directory.list()) {
        if (entity is File &&
            {'.js', '.ts'}.contains(p.extension(entity.path).toLowerCase())) {
          throw StateError(
            'Managed neutral mode refuses auto-loaded plugin ${entity.path}.',
          );
        }
      }
    }
  }

  Future<void> _writeText(File destination, String contents) async {
    await destination.parent.create(recursive: true);
    final temporary = File(
      '${destination.path}.$pid.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    await temporary.writeAsString(contents, flush: true);
    try {
      try {
        await temporary.rename(destination.path);
      } on FileSystemException {
        // Some Windows filesystems do not replace an existing destination.
        if (await destination.exists()) await destination.delete();
        await temporary.rename(destination.path);
      }
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<void> _serialize(
    AiRuntimeKind kind,
    String sessionId,
    Future<void> Function() operation,
  ) async {
    final key = '${kind.id}:$sessionId';
    final previous = _operations[key] ?? Future<void>.value();
    final current = previous.then((_) => operation());
    _operations[key] = current;
    try {
      await current;
    } finally {
      if (identical(_operations[key], current)) _operations.remove(key);
    }
  }

  static void _validateSessionId(String sessionId) {
    if (sessionId.isEmpty ||
        sessionId.length > 200 ||
        !RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(sessionId)) {
      throw ArgumentError.value(
        sessionId,
        'sessionId',
        'Invalid runtime session ID.',
      );
    }
  }

  static String _pluginSource(AiRuntimeKind kind) {
    const hook = r'''
import {readFile, rename, unlink} from "node:fs/promises";

const validSessionId = /^[A-Za-z0-9._-]{1,200}$/;
const promptUrl = (sessionID) =>
  new URL(`./system_prompts/${sessionID}.json`, import.meta.url);
const prompts = new Map();
const pending = new Map();
let sequence = 0;

const loadPrompt = (sessionID) => {
  const previous = pending.get(sessionID) ?? Promise.resolve();
  const current = previous.catch(() => {}).then(async () => {
    const url = promptUrl(sessionID);
    const claimed = new URL(`${url.href}.${process.pid}.${sequence++}.tmp`);
    try {
      // Claim only this version: a later host write must never be unlinked by
      // an earlier hook. Retries reuse the last trusted value in memory.
      await rename(url, claimed);
    } catch (error) {
      if (error.code === "ENOENT" && prompts.has(sessionID)) {
        return prompts.get(sessionID);
      }
      throw error;
    }
    try {
      prompts.delete(sessionID);
      const payload = JSON.parse(await readFile(claimed, "utf8"));
      if (payload?.version !== 1 ||
          payload?.sessionId !== sessionID ||
          typeof payload?.system !== "string" ||
          payload.system.trim().length === 0) {
        throw new Error("Invalid or missing host system prompt");
      }
      prompts.set(sessionID, payload.system);
      return payload.system;
    } finally {
      await unlink(claimed).catch(() => {});
    }
  });
  pending.set(sessionID, current);
  return current.finally(() => {
    if (pending.get(sessionID) === current) pending.delete(sessionID);
  });
};

const server = async () => ({
  event: async ({event}) => {
    if (event.type !== "session.deleted") return;
    const sessionID = event.properties?.info?.id;
    if (!validSessionId.test(sessionID ?? "")) return;
    await pending.get(sessionID)?.catch(() => {});
    prompts.delete(sessionID);
  },
  "experimental.chat.system.transform": async (input, output) => {
    const sessionID = input.sessionID;
    if (!validSessionId.test(sessionID)) {
      throw new Error("Invalid runtime session ID");
    }
    const system = await loadPrompt(sessionID);
    output.system.splice(0, output.system.length, system);
  },
});
''';
    return switch (kind) {
      AiRuntimeKind.openCode =>
        '$hook\nexport const DartAiRuntimeNeutralSystem = server;\n',
      AiRuntimeKind.kilo =>
        '$hook\nexport default {id: "dart-ai-runtime-neutral-system", server};\n',
    };
  }
}
