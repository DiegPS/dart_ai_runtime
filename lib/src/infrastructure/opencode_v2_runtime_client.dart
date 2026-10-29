import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../application/runtime_client.dart';
import '../domain/runtime_api_models.dart';
import '../domain/runtime_models.dart';
import 'opencode_compatible_runtime_client.dart';

/// Connects Dart conversations to the official OpenCode 2 HTTP/SSE server.
///
/// Uses the native agent, model selection, permissions, and instruction-entry
/// APIs. Host system instructions supplement the native agent instructions.
/// Tools denied by the host are gated with `ask` and rejected before execution,
/// preserving the server's native tool definitions. No provider is called
/// directly and no client identity headers are fabricated.
class OpenCodeV2RuntimeClient implements AiRuntimeClient {
  OpenCodeV2RuntimeClient({
    required this.endpoint,
    required this.workspaceDirectory,
    http.Client? client,
    this.requestTimeout = const Duration(seconds: 20),
    this.reconnectDelay = const Duration(milliseconds: 250),
  }) : _http = client ?? http.Client(),
       _ownsHttp = client == null {
    if (!endpoint.isLoopback || endpoint.kind != AiRuntimeKind.openCode) {
      if (_ownsHttp) _http.close();
      throw ArgumentError('OpenCode 2 requires a loopback OpenCode endpoint.');
    }
  }

  final AiRuntimeEndpoint endpoint;
  final String workspaceDirectory;
  final Duration requestTimeout;
  final Duration reconnectDelay;
  final http.Client _http;
  final bool _ownsHttp;
  bool _disposed = false;
  final Map<String, AiPrompt> _requests = {};
  final Map<String, String> _delivered = {};
  final Map<String, String> _assistantRequests = {};
  final Map<String, Map<String, String>> _verified = {};
  final Map<String, Future<void>> _permissionReplies = {};
  final Set<Future<void> Function()> _eventClosers = {};

  /// The actual provider and model observed for the session's latest response.
  ///
  /// Returns `null` until an assistant model has been verified. A different
  /// provider or model terminates the turn rather than silently falling back.
  Map<String, String>? responseModel(String sessionId) => _verified[sessionId];

  @override
  Future<List<AiProviderInfo>> providers() async {
    final response = _map(
      await _json(
        'GET',
        '/api/model',
        query: {'location[directory]': workspaceDirectory},
      ),
    );
    final grouped = <String, List<AiModelInfo>>{};
    for (final model in _maps(response['data'])) {
      if (model['enabled'] != true || model['status'] == 'deprecated') continue;
      final capabilities = _map(model['capabilities']);
      if (_map(capabilities['output'])['text'] == false) continue;
      final provider = model['providerID'] as String;
      final costs = _maps(model['cost']).toList();
      grouped
          .putIfAbsent(provider, () => [])
          .add(
            AiModelInfo(
              id: model['id'] as String,
              name: model['name'] as String? ?? model['id'] as String,
              providerId: provider,
              isFree:
                  costs.isNotEmpty &&
                  costs.every((c) => c['input'] == 0 && c['output'] == 0),
              supportsReasoning: capabilities['reasoning'] == true,
            ),
          );
    }
    return [
      for (final entry in grouped.entries)
        AiProviderInfo(
          id: entry.key,
          name: entry.key,
          connected: true,
          models: List.unmodifiable(entry.value),
        ),
    ];
  }

  @override
  Future<List<AiAuthMethod>> authMethods() => Future.value(const []);

  @override
  Future<AiSession> createSession({String? title}) async {
    final response = _map(
      await _json(
        'POST',
        '/api/session',
        body: {
          'location': {'directory': workspaceDirectory},
          'title': ?title,
          'permissions': _permissions(const {'*': false}),
        },
      ),
    );
    return AiSession.fromJson(_map(response['data']));
  }

  @override
  Future<AiSession> session(String sessionId) async => AiSession.fromJson(
    _map(_map(await _json('GET', _session(sessionId)))['data']),
  );

  @override
  Future<void> promptAsync(String sessionId, AiPrompt prompt) async {
    if (prompt.messageId == null) {
      throw ArgumentError('OpenCode 2 prompts require a unique messageId.');
    }
    final previous = _requests[sessionId];
    if (previous != null) {
      _assistantRequests.removeWhere(
        (_, request) => request == previous.messageId,
      );
    }
    _requests[sessionId] = prompt;
    _verified.remove(sessionId);
    await _json(
      'PATCH',
      _session(sessionId),
      body: {'permissions': _permissions(prompt.toolPermissions)},
    );
    await _json(
      'POST',
      '${_session(sessionId)}/model',
      body: {
        'model': {'providerID': prompt.providerId, 'id': prompt.modelId},
      },
    );
    await _json(
      'PUT',
      '/api/experimental/session/${_segment(sessionId)}/instructions/entries/dart-ai-runtime',
      body: {'value': prompt.system},
    );
    await _json(
      'POST',
      '${_session(sessionId)}/prompt',
      body: {'id': prompt.messageId, 'text': prompt.text, 'delivery': 'steer'},
    );
  }

  // Native ask rules hold operations pending approval. Every request reaching
  // this client is rejected, never auto-approved. Explicit allows run on-server.
  static List<Map<String, String>> _permissions(
    Map<String, bool> permissions,
  ) => [
    {'action': '*', 'resource': '*', 'effect': 'ask'},
    for (final entry in permissions.entries)
      {
        'action': entry.key,
        'resource': '*',
        'effect': entry.value ? 'allow' : 'ask',
      },
  ];

  @override
  Future<void> abort(String sessionId) async {
    await _json('POST', '${_session(sessionId)}/interrupt');
  }

  @override
  Future<void> deleteSession(String sessionId) async {
    try {
      await _json('DELETE', _session(sessionId));
    } finally {
      final request = _requests.remove(sessionId);
      if (request != null) {
        _assistantRequests.removeWhere(
          (_, parent) => parent == request.messageId,
        );
      }
      _delivered.remove(sessionId);
      _verified.remove(sessionId);
    }
  }

  @override
  Future<List<Map<String, dynamic>>> messages(String sessionId) async {
    if (_requests.containsKey(sessionId)) {
      await _rejectPendingPermissions(sessionId);
    }
    final raw = <Map<String, dynamic>>[];
    String? cursor;
    final cursors = <String>{};
    do {
      final page = _map(
        await _json(
          'GET',
          '${_session(sessionId)}/message',
          query: {
            'limit': '100',
            if (cursor == null) 'order': 'asc' else 'cursor': cursor,
          },
        ),
      );
      raw.addAll(_maps(page['data']));
      cursor = _map(page['cursor'])['next'] as String?;
      if (cursor != null && !cursors.add(cursor)) {
        throw const FormatException('Runtime message cursor repeated.');
      }
    } while (cursor != null);
    final normalized = <Map<String, dynamic>>[];
    String? userId;
    Map<String, dynamic>? assistant;
    for (final message in raw) {
      if (message['type'] == 'user') {
        userId = message['id'] as String;
        assistant = null;
        normalized.add({
          'info': {'id': userId, 'role': 'user'},
          'parts': <Object>[],
        });
      } else if (message['type'] == 'assistant' && userId != null) {
        if (_requests[sessionId]?.messageId == userId) {
          _verifyModel(sessionId, _map(message['model']));
        }
        if (assistant == null) {
          assistant = {
            'info': <String, dynamic>{
              'id': _responseId(userId),
              'role': 'assistant',
              'parentID': userId,
            },
            'parts': <Map<String, dynamic>>[],
          };
          normalized.add(assistant);
        }
        (assistant['parts'] as List<Map<String, dynamic>>).addAll(
          _maps(message['content'])
              .where((c) => c['type'] == 'text' || c['type'] == 'reasoning'),
        );
        if (message['error'] != null) {
          (assistant['info'] as Map)['error'] = message['error'];
        }
      } else if (message['type'] == 'idle' && userId != null) {
        final error =
            message['error'] ??
            (message['outcome'] == 'failed' ||
                    message['outcome'] == 'interrupted'
                ? <String, Object?>{
                    'type': 'runtime.execution-${message['outcome']}',
                    'message': 'The runtime did not complete this execution.',
                  }
                : null);
        if (assistant == null && error != null) {
          assistant = {
            'info': <String, dynamic>{
              'id': _responseId(userId),
              'role': 'assistant',
              'parentID': userId,
            },
            'parts': <Object>[],
          };
          normalized.add(assistant);
        }
        if (assistant != null) {
          final info = assistant['info'] as Map;
          if (error != null) info['error'] = error;
          if (message['outcome'] == 'succeeded') info['finish'] = 'stop';
        }
      }
    }
    return normalized;
  }

  void _verifyModel(String sessionId, Map<String, dynamic> actual) {
    final requested = _requests[sessionId];
    if (requested == null) return;
    if (actual['providerID'] != requested.providerId ||
        actual['id'] != requested.modelId) {
      throw AiRuntimeGenerationException(
        kind: AiRuntimeFailureKind.unknown,
        cause: {
          'type': 'runtime.model-mismatch',
          'expected': {
            'providerID': requested.providerId,
            'id': requested.modelId,
          },
          'actual': actual,
        },
      );
    }
    _verified[sessionId] = Map.unmodifiable({
      'providerID': actual['providerID'] as String,
      'id': actual['id'] as String,
      if (actual['variant'] is String) 'variant': actual['variant'] as String,
    });
  }

  Future<void> _rejectPendingPermissions(String sessionId) async {
    final response = _map(
      await _json('GET', '${_session(sessionId)}/permission'),
    );
    await Future.wait([
      for (final request in _maps(response['data']))
        if (request['sessionID'] == sessionId)
          _rejectPermission(sessionId, request['id'] as String),
    ]);
  }

  Future<void> _rejectPermission(String sessionId, String id) {
    final key = '$sessionId/$id';
    return _permissionReplies.putIfAbsent(key, () async {
      try {
        await _json(
          'POST',
          '${_session(sessionId)}/permission/${_segment(id)}/reply',
          body: {
            'decision': 'reject',
            'message': 'The host has not authorized this operation.',
          },
        );
      } finally {
        _permissionReplies.remove(key);
      }
    });
  }

  @override
  Stream<AiRuntimeEvent> events() async* {
    yield* await connectEvents();
  }

  @override
  Future<Stream<AiRuntimeEvent>> connectEvents() async {
    final response = await _openEvents();
    if (_disposed) {
      await response.stream.listen((_) {}).cancel();
      throw StateError('Runtime client disposed.');
    }
    return _events(response);
  }

  Future<http.StreamedResponse> _openEvents() async {
    if (_disposed) throw StateError('Runtime client disposed.');
    final response = await _http
        .send(
          http.Request('GET', endpoint.baseUri.resolve('/api/event'))
            ..headers.addAll(_headers(sse: true)),
        )
        .timeout(requestTimeout);
    if (response.statusCode != 200) {
      await response.stream.listen((_) {}).cancel();
      throw AiRuntimeApiException(response.statusCode, '');
    }
    return response;
  }

  Stream<AiRuntimeEvent> _events(http.StreamedResponse initial) {
    late StreamController<AiRuntimeEvent> output;
    StreamSubscription<String>? subscription;
    Timer? reconnect;
    var closed = false;
    var started = false;
    var generation = 0;
    late void Function(http.StreamedResponse) attach;
    late void Function(int) retry;
    Future<void> stop() async {
      if (closed) return;
      closed = true;
      generation++;
      reconnect?.cancel();
      _eventClosers.remove(stop);
      try {
        if (!started) {
          await initial.stream.listen((_) {}).cancel();
        } else {
          await subscription?.cancel();
        }
      } catch (_) {}
      unawaited(output.close());
    }

    retry = (int failedGeneration) {
      if (closed || _disposed || failedGeneration != generation) return;
      final expected = ++generation;
      final previous = subscription;
      subscription = null;
      if (previous != null) {
        unawaited(previous.cancel().catchError((Object _) {}));
      }
      reconnect?.cancel();
      reconnect = Timer(reconnectDelay, () async {
        if (closed || _disposed) return;
        try {
          final response = await _openEvents();
          if (closed || _disposed || expected != generation) {
            await response.stream.listen((_) {}).cancel();
            return;
          }
          attach(response);
        } catch (_) {
          retry(expected);
        }
      });
    };
    attach = (http.StreamedResponse response) {
      final current = ++generation;
      final buffer = StringBuffer();
      subscription = response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (line) {
              if (closed || current != generation) return;
              if (line.startsWith('data:')) {
                if (buffer.isNotEmpty) buffer.write('\n');
                buffer.write(line.substring(5).trimLeft());
              } else if (line.isEmpty && buffer.isNotEmpty) {
                final data = buffer.toString();
                buffer.clear();
                try {
                  Object? decoded = jsonDecode(data);
                  if (decoded is String) decoded = jsonDecode(decoded);
                  final event = _convert(_map(decoded));
                  if (event != null && !closed) output.add(event);
                } catch (_) {
                  // One malformed frame must not terminate an otherwise healthy stream.
                }
              }
            },
            onError: (Object _) => retry(current),
            onDone: () => retry(current),
          );
    };
    output = StreamController<AiRuntimeEvent>(
      onListen: () {
        if (closed || _disposed) return;
        started = true;
        attach(initial);
      },
      onCancel: stop,
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
    );
    _eventClosers.add(stop);
    return output.stream;
  }

  AiRuntimeEvent? _convert(Map<String, dynamic> event) {
    final type = event['type'];
    if (type == 'server.connected') {
      return AiRuntimeEvent(
        type: 'server.connected',
        properties: const {},
        raw: event,
      );
    }
    final data = _map(event['data']);
    final sessionId = data['sessionID'] as String?;
    if (sessionId == null || !_requests.containsKey(sessionId)) return null;
    final prompt = _requests[sessionId]!;
    if (type == 'permission.asked') {
      unawaited(
        _rejectPermission(
          sessionId,
          data['id'] as String,
        ).catchError((Object _) {}),
      );
      return null;
    }
    if (type == 'session.inbox.delivered') {
      _delivered[sessionId] = data['inboxID'] as String;
      return null;
    }
    final requestId = _delivered[sessionId];
    if (requestId == null || requestId != prompt.messageId) return null;
    final properties = <String, dynamic>{
      'sessionID': sessionId,
      'requestID': requestId,
    };
    final responseId = _responseId(requestId);
    String? normalizedType;
    if (type == 'session.step.started') {
      _assistantRequests[data['assistantMessageID'] as String] = requestId;
      try {
        _verifyModel(sessionId, _map(data['model']));
      } catch (error) {
        return AiRuntimeEvent(
          type: 'session.error',
          properties: {...properties, 'error': error},
          raw: event,
        );
      }
      normalizedType = 'message.updated';
      properties['info'] = {
        'id': responseId,
        'role': 'assistant',
        'parentID': requestId,
      };
    } else if (type == 'session.execution.succeeded') {
      normalizedType = 'message.completed';
      properties['messageID'] = responseId;
    } else if (type == 'session.execution.failed' ||
        type == 'session.step.failed') {
      if (type == 'session.step.failed' &&
          _assistantRequests[data['assistantMessageID']] != requestId) {
        return null;
      }
      normalizedType = 'session.error';
      properties['error'] = data['error'];
    } else if (type == 'session.execution.interrupted') {
      normalizedType = 'session.error';
      properties['error'] = {
        'type': 'runtime.interrupted',
        'reason': data['reason'],
      };
    } else if (type == 'session.retry.scheduled') {
      final failure = AiRuntimeGenerationException.fromRuntimeError(
        data['error'] as Object,
      );
      if (failure.kind != AiRuntimeFailureKind.quotaExceeded &&
          failure.kind != AiRuntimeFailureKind.authentication &&
          failure.kind != AiRuntimeFailureKind.permissionDenied) {
        return null;
      }
      normalizedType = 'session.error';
      properties['error'] = failure;
    } else if (type is String &&
        (type.startsWith('session.text.') ||
            type.startsWith('session.reasoning.'))) {
      final partType = type.startsWith('session.text.') ? 'text' : 'reasoning';
      if (_assistantRequests[data['assistantMessageID']] != requestId) {
        return null;
      }
      final partId =
          '${data['assistantMessageID']}:$partType:${data['ordinal']}';
      normalizedType = type.endsWith('.delta')
          ? 'message.part.delta'
          : 'message.part.updated';
      properties.addAll({
        'messageID': responseId,
        'partID': partId,
        'part': {
          'id': partId,
          'messageID': responseId,
          'type': partType,
          if (data['text'] is String) 'text': data['text'],
        },
        if (data['delta'] is String) 'delta': data['delta'],
        'field': 'text',
      });
    }
    if (normalizedType == null) return null;
    return AiRuntimeEvent(
      type: normalizedType,
      properties: properties,
      raw: event,
    );
  }

  Future<Object?> _json(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? query,
  }) async {
    if (_disposed) throw StateError('Runtime client disposed.');
    var uri = endpoint.baseUri.resolve(path);
    if (query != null) uri = uri.replace(queryParameters: query);
    final request = http.Request(method, uri)..headers.addAll(_headers());
    if (body != null) request.body = jsonEncode(body);
    final response = await http.Response.fromStream(
      await _http.send(request).timeout(requestTimeout),
    ).timeout(requestTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AiRuntimeApiException(response.statusCode, response.body);
    }
    return response.body.isEmpty ? null : jsonDecode(response.body);
  }

  Map<String, String> _headers({bool sse = false}) => {
    HttpHeaders.authorizationHeader:
        'Basic ${base64Encode(utf8.encode('${endpoint.username}:${endpoint.password}'))}',
    HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
    HttpHeaders.acceptHeader: sse ? 'text/event-stream' : 'application/json',
  };
  static Map<String, dynamic> _map(Object? value) =>
      value is Map ? Map<String, dynamic>.from(value) : {};
  static Iterable<Map<String, dynamic>> _maps(Object? value) => value is List
      ? value.whereType<Map<Object?, Object?>>().map(_map)
      : const [];
  static String _segment(String value) => Uri.encodeComponent(value);
  static String _session(String id) => '/api/session/${_segment(id)}';
  static String _responseId(String request) => 'assistant:$request';

  @override
  void dispose() {
    _disposed = true;
    for (final close in _eventClosers.toList()) {
      unawaited(close());
    }
    if (_ownsHttp) _http.close();
    _requests.clear();
    _delivered.clear();
    _verified.clear();
    _assistantRequests.clear();
  }
}
