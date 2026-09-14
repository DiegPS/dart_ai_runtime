import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../domain/artifact_models.dart';

class HttpArtifactDownloader implements ArtifactDownloader {
  HttpArtifactDownloader({
    http.Client? client,
    this.connectionTimeout = const Duration(seconds: 20),
    this.inactivityTimeout = const Duration(seconds: 30),
    this.attempts = 3,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;
  final Duration connectionTimeout;
  final Duration inactivityTimeout;
  final int attempts;

  @override
  Future<void> download(
    ArtifactDownloadRequest request, {
    ArtifactDownloadCancellation? cancellation,
    void Function(ArtifactDownloadProgress progress)? onProgress,
  }) async {
    if (request.uri.scheme != 'https') {
      throw const ArtifactDownloadException(
        'Artifact downloads require HTTPS.',
      );
    }
    Object? lastError;
    for (var attempt = 1; attempt <= attempts.clamp(1, 5); attempt++) {
      cancellation?.throwIfCancelled();
      try {
        await _downloadOnce(request, cancellation, onProgress);
        return;
      } on ArtifactDownloadCancelledException {
        rethrow;
      } catch (error) {
        lastError = error;
        if (attempt >= attempts.clamp(1, 5)) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 250 * attempt));
      }
    }
    throw ArtifactDownloadException('Download failed: $lastError');
  }

  Future<void> _downloadOnce(
    ArtifactDownloadRequest request,
    ArtifactDownloadCancellation? cancellation,
    void Function(ArtifactDownloadProgress progress)? onProgress,
  ) async {
    final destination = File(request.destinationPath);
    await destination.parent.create(recursive: true);
    var offset = await destination.exists() ? await destination.length() : 0;
    if (offset > request.expectedBytes) {
      await destination.delete();
      offset = 0;
    }
    if (offset == request.expectedBytes) {
      onProgress?.call(
        ArtifactDownloadProgress(
          receivedBytes: offset,
          totalBytes: request.expectedBytes,
        ),
      );
      return;
    }

    final httpRequest = http.Request('GET', request.uri)
      ..headers.addAll(request.headers);
    if (offset > 0) {
      httpRequest.headers[HttpHeaders.rangeHeader] = 'bytes=$offset-';
    }
    final response = await _client.send(httpRequest).timeout(connectionTimeout);
    if (response.statusCode != HttpStatus.ok &&
        response.statusCode != HttpStatus.partialContent) {
      throw HttpException(
        'Download returned HTTP ${response.statusCode}.',
        uri: request.uri,
      );
    }
    if (offset > 0 && response.statusCode != HttpStatus.partialContent) {
      offset = 0;
    }
    final sink = destination.openWrite(
      mode: offset > 0 ? FileMode.append : FileMode.write,
    );
    var received = offset;
    final cancel = cancellation?.addListener(() {
      unawaited(sink.close());
    });
    try {
      await for (final chunk in response.stream.timeout(inactivityTimeout)) {
        cancellation?.throwIfCancelled();
        sink.add(chunk);
        received += chunk.length;
        if (received > request.expectedBytes) {
          throw const ArtifactDownloadException(
            'Download exceeded its declared size.',
          );
        }
        onProgress?.call(
          ArtifactDownloadProgress(
            receivedBytes: received,
            totalBytes: request.expectedBytes,
          ),
        );
      }
    } finally {
      cancel?.call();
      await sink.flush();
      await sink.close();
    }
    cancellation?.throwIfCancelled();
    if (received != request.expectedBytes) {
      throw ArtifactDownloadException(
        'Download has $received bytes; ${request.expectedBytes} expected.',
      );
    }
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }
}
