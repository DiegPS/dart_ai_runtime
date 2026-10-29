import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../application/runtime_services.dart';
import '../domain/runtime_models.dart';

class AiRuntimeHealthClient implements AiRuntimeHealthService {
  AiRuntimeHealthClient({http.Client? client})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;

  @override
  Future<AiRuntimeHealth> waitUntilReady(
    AiRuntimeEndpoint endpoint, {
    Duration timeout = const Duration(seconds: 25),
  }) async {
    if (!endpoint.isLoopback) {
      return const AiRuntimeHealth(
        healthy: false,
        message: 'Runtime endpoint is not bound to loopback.',
      );
    }
    final deadline = DateTime.now().add(timeout);
    Object? lastError;
    while (DateTime.now().isBefore(deadline)) {
      try {
        final response = await _client
            .get(
              endpoint.baseUri.resolve(
                endpoint.apiVersion == 2 ? '/api/info' : '/global/health',
              ),
              headers: {
                HttpHeaders.authorizationHeader:
                    'Basic ${base64Encode(utf8.encode('${endpoint.username}:${endpoint.password}'))}',
              },
            )
            .timeout(const Duration(seconds: 2));
        if (response.statusCode == HttpStatus.ok) {
          final decoded = jsonDecode(response.body);
          if (decoded is Map &&
              (endpoint.apiVersion == 2
                  ? decoded['version'] is String &&
                        (decoded['version'] as String).startsWith('2.') &&
                        decoded['pid'] == endpoint.pid
                  : decoded['healthy'] == true)) {
            return AiRuntimeHealth(
              healthy: true,
              version: decoded['version']?.toString(),
            );
          }
          lastError = 'Health response did not report healthy=true.';
        } else {
          lastError = 'Health returned HTTP ${response.statusCode}.';
        }
      } catch (error) {
        lastError = error;
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    return AiRuntimeHealth(
      healthy: false,
      message: 'Runtime did not become healthy: $lastError',
    );
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }
}
