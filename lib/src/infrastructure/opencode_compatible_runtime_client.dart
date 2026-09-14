import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../application/runtime_client.dart';
import '../domain/runtime_api_models.dart';
import '../domain/runtime_models.dart';

class OpenCodeCompatibleRuntimeClient
    implements AiRuntimeClient, AiProviderAuthClient {
  OpenCodeCompatibleRuntimeClient({
    required this.endpoint,
    required this.workspaceDirectory,
    http.Client? client,
    this.requestTimeout = const Duration(seconds: 10),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null {
    if (!endpoint.isLoopback) {
      throw ArgumentError.value(
        endpoint.baseUri,
        'endpoint',
        'Local AI runtime endpoints must use loopback.',
      );
    }
  }

  final AiRuntimeEndpoint endpoint;
  final String workspaceDirectory;
  final Duration requestTimeout;
  final http.Client _client;
  final bool _ownsClient;

  @override
  Future<List<AiProviderInfo>> providers() async {
    final body = await _json('GET', '/provider');
    if (body is! Map) {
      throw const FormatException(
        'Runtime provider response is not an object.',
      );
    }
    final root = Map<String, dynamic>.from(body);
    final connected = (root['connected'] as List? ?? const [])
        .map((value) => value.toString())
        .toSet();
    final rawProviders = root['all'] is List
        ? root['all'] as List
        : root['providers'] is List
        ? root['providers'] as List
        : const [];
    return rawProviders
        .whereType<Map>()
        .map((raw) {
          final provider = Map<String, dynamic>.from(raw);
          final id = provider['id']?.toString() ?? '';
          final rawModels = provider['models'];
          final defaults = root['default'];
          final entries = rawModels is Map
              ? rawModels.entries
              : const Iterable<MapEntry<dynamic, dynamic>>.empty();
          return AiProviderInfo(
            id: id,
            name: provider['name']?.toString() ?? id,
            connected: connected.contains(id),
            models: entries
                .where((entry) => entry.value is Map)
                .where((entry) => _supportsText(entry.value as Map))
                .map((entry) {
                  final model = Map<String, dynamic>.from(entry.value as Map);
                  final modelId =
                      model['id']?.toString() ?? entry.key.toString();
                  return AiModelInfo(
                    id: modelId,
                    name: model['name']?.toString() ?? modelId,
                    providerId: id,
                    isDefault: defaults is Map && defaults[id] == modelId,
                    isFree: _isFreeModel(id, modelId, model),
                    supportsReasoning:
                        model['reasoning'] == true ||
                        model['capabilities'] is Map &&
                            (model['capabilities'] as Map)['reasoning'] == true,
                  );
                })
                .toList(growable: false),
          );
        })
        .where((provider) => provider.id.isNotEmpty)
        .toList(growable: false);
  }

  @override
  Future<List<AiAuthMethod>> authMethods() async {
    final body = await _json('GET', '/provider/auth');
    if (body is! Map) return const [];
    final methods = <AiAuthMethod>[];
    for (final entry in body.entries) {
      final values = entry.value is List ? entry.value as List : [entry.value];
      for (var index = 0; index < values.length; index++) {
        final value = values[index];
        if (value is! Map) continue;
        final method = Map<String, dynamic>.from(value);
        methods.add(
          AiAuthMethod(
            providerId: entry.key.toString(),
            type: method['type']?.toString() ?? 'unknown',
            label:
                method['label']?.toString() ??
                method['name']?.toString() ??
                method['type']?.toString() ??
                'Authentication',
            index: index,
            prompts: method['prompts'] is List
                ? (method['prompts'] as List)
                      .whereType<Map>()
                      .map(AiAuthPrompt.fromJson)
                      .toList(growable: false)
                : const [],
          ),
        );
      }
    }
    return methods;
  }

  @override
  Future<void> setApiKey(String providerId, String apiKey) async {
    final normalized = apiKey.trim();
    if (normalized.isEmpty) throw const FormatException('API key is empty.');
    await _empty(
      'PUT',
      '/auth/${_segment(providerId)}',
      body: {'type': 'api', 'key': normalized},
    );
  }

  @override
  Future<AiOAuthAuthorization> beginOAuth(
    String providerId, {
    required int methodIndex,
    Map<String, String> inputs = const {},
  }) async {
    final body = _object(
      await _json(
        'POST',
        '/provider/${_segment(providerId)}/oauth/authorize',
        body: {'method': methodIndex, if (inputs.isNotEmpty) 'inputs': inputs},
      ),
    );
    return AiOAuthAuthorization(
      method: body['method']?.toString() ?? 'auto',
      url: Uri.tryParse(body['url']?.toString() ?? ''),
      instructions: body['instructions']?.toString(),
    );
  }

  @override
  Future<void> completeOAuth(
    String providerId, {
    required int methodIndex,
    String? code,
  }) => _empty(
    'POST',
    '/provider/${_segment(providerId)}/oauth/callback',
    timeout: const Duration(seconds: 85),
    body: {'method': methodIndex, if (code != null) 'code': code.trim()},
  );

  @override
  Future<void> disconnectProvider(String providerId) =>
      _empty('DELETE', '/auth/${_segment(providerId)}');

  @override
  Future<AiSession> createSession({String? title}) async => AiSession.fromJson(
    _object(
      await _json(
        'POST',
        '/session',
        body: title == null ? const {} : {'title': title},
      ),
    ),
  );

  @override
  Future<AiSession> session(String sessionId) async => AiSession.fromJson(
    _object(await _json('GET', '/session/${_segment(sessionId)}')),
  );

  @override
  Future<List<Map<String, dynamic>>> messages(String sessionId) async {
    final body = await _json('GET', '/session/${_segment(sessionId)}/message');
    if (body is! List) {
      throw const FormatException('Runtime messages response is not a list.');
    }
    return body
        .whereType<Map>()
        .map((value) => Map<String, dynamic>.from(value))
        .toList(growable: false);
  }

  @override
  Future<void> promptAsync(String sessionId, AiPrompt prompt) => _empty(
    'POST',
    '/session/${_segment(sessionId)}/prompt_async',
    body: prompt.toJson(),
  );

  @override
  Future<void> abort(String sessionId) =>
      _empty('POST', '/session/${_segment(sessionId)}/abort');

  @override
  Future<void> deleteSession(String sessionId) =>
      _empty('DELETE', '/session/${_segment(sessionId)}');

  @override
  Stream<AiRuntimeEvent> events() async* {
    yield* await connectEvents();
  }

  @override
  Future<Stream<AiRuntimeEvent>> connectEvents() async {
    final request = http.Request('GET', _uri('/event'))
      ..headers.addAll(_headers(acceptSse: true));
    final response = await _client.send(request).timeout(requestTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AiRuntimeApiException(
        response.statusCode,
        await response.stream.bytesToString(),
      );
    }
    return _parseEventStream(response.stream);
  }

  Stream<AiRuntimeEvent> _parseEventStream(Stream<List<int>> input) async* {
    final data = StringBuffer();
    String? eventType;
    await for (final line
        in input.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.isEmpty) {
        final event = _decodeEvent(data, eventType);
        data.clear();
        eventType = null;
        if (event != null) yield event;
      } else if (line.startsWith('event:')) {
        eventType = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        if (data.isNotEmpty) data.write('\n');
        data.write(line.substring(5).trimLeft());
      }
    }
    final finalEvent = _decodeEvent(data, eventType);
    if (finalEvent != null) yield finalEvent;
  }

  static AiRuntimeEvent? _decodeEvent(StringBuffer data, String? eventType) {
    if (data.isEmpty) return null;
    try {
      final decoded = jsonDecode(data.toString());
      if (decoded is! Map) return null;
      final map = Map<String, dynamic>.from(decoded);
      if (!map.containsKey('type') && eventType != null) {
        map['type'] = eventType;
      }
      return AiRuntimeEvent.fromJson(map);
    } on FormatException {
      // One malformed event must not terminate an otherwise healthy stream.
      return null;
    }
  }

  Future<Object?> _json(
    String method,
    String path, {
    Map<String, Object?>? body,
  }) async {
    final response = await _send(method, path, body: body);
    return response.body.isEmpty ? null : jsonDecode(response.body);
  }

  Future<void> _empty(
    String method,
    String path, {
    Map<String, Object?>? body,
    Duration? timeout,
  }) async {
    await _send(method, path, body: body, timeout: timeout);
  }

  Future<http.Response> _send(
    String method,
    String path, {
    Map<String, Object?>? body,
    Duration? timeout,
  }) async {
    final request = http.Request(method, _uri(path))
      ..headers.addAll(_headers())
      ..body = body == null ? '' : jsonEncode(body);
    final effectiveTimeout = timeout ?? requestTimeout;
    final streamed = await _client.send(request).timeout(effectiveTimeout);
    final response = await http.Response.fromStream(streamed)
        .timeout(effectiveTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AiRuntimeApiException(response.statusCode, response.body);
    }
    return response;
  }

  Uri _uri(String path) => endpoint.baseUri
      .resolve(path)
      .replace(queryParameters: {'directory': workspaceDirectory});

  Map<String, String> _headers({bool acceptSse = false}) => {
    HttpHeaders.authorizationHeader:
        'Basic ${base64Encode(utf8.encode('${endpoint.username}:${endpoint.password}'))}',
    HttpHeaders.acceptHeader: acceptSse
        ? 'text/event-stream'
        : 'application/json',
    HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
    endpoint.kind.directoryHeader: workspaceDirectory,
  };

  static String _segment(String value) => Uri.encodeComponent(value);

  static Map<String, dynamic> _object(Object? value) {
    if (value is! Map) {
      throw const FormatException('Runtime response is not an object.');
    }
    return Map<String, dynamic>.from(value);
  }

  static bool _supportsText(Map<dynamic, dynamic> model) {
    if (model['status'] == 'deprecated') return false;
    final capabilities = model['capabilities'];
    final input = capabilities is Map ? capabilities['input'] : null;
    final output = capabilities is Map ? capabilities['output'] : null;
    return (input is! Map || input['text'] != false) &&
        (output is! Map || output['text'] != false);
  }

  static bool _isFreeModel(
    String providerId,
    String modelId,
    Map<String, dynamic> model,
  ) {
    final normalized = '$providerId/$modelId'.toLowerCase();
    if (normalized == 'kilo/kilo-auto/free' || normalized.endsWith(':free')) {
      return true;
    }
    final cost = model['cost'];
    return cost is Map &&
        cost.isNotEmpty &&
        cost['input'] is num &&
        cost['input'] == 0 &&
        cost['output'] is num &&
        cost['output'] == 0;
  }

  @override
  void dispose() {
    if (_ownsClient) _client.close();
  }
}

class AiRuntimeApiException implements Exception {
  const AiRuntimeApiException(this.statusCode, this.body);

  final int statusCode;
  final String body;

  @override
  String toString() => 'Runtime API returned HTTP $statusCode: $body';
}
