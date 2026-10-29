import 'dart:async';
import 'dart:io';

import 'package:dart_ai_runtime/dart_ai_runtime.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  for (final local in [
    <int>[1, 2, 3, 4, 5],
    <int>[8, 8],
  ]) {
    test(
      'replaces local bytes when oversized or the server ignores Range: ${local.length}',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'air-download-replace-',
        );
        addTearDown(() => root.delete(recursive: true));
        final destination = File(p.join(root.path, 'runtime.zip'));
        await destination.writeAsBytes(local);
        final transport = MockClient((request) async {
          expect(
            request.headers['range'],
            local.length > 3 ? isNull : 'bytes=2-',
          );
          return http.Response.bytes([1, 2, 3], 200);
        });
        addTearDown(transport.close);
        await HttpArtifactDownloader(client: transport).download(
          ArtifactDownloadRequest(
            id: 'test',
            uri: Uri.parse('https://example.test/runtime'),
            destinationPath: destination.path,
            expectedBytes: 3,
          ),
        );
        expect(await destination.readAsBytes(), [1, 2, 3]);
      },
    );
  }

  test('already complete downloads do not access the network', () async {
    final root = await Directory.systemTemp.createTemp(
      'air-download-complete-',
    );
    addTearDown(() => root.delete(recursive: true));
    final destination = File(p.join(root.path, 'runtime.zip'));
    await destination.writeAsBytes([1]);
    final progress = <ArtifactDownloadProgress>[];
    final transport = MockClient(
      (_) async => throw StateError('Must not download'),
    );
    addTearDown(transport.close);
    await HttpArtifactDownloader(client: transport).download(
      ArtifactDownloadRequest(
        id: 'test',
        uri: Uri.parse('https://example.test/runtime'),
        destinationPath: destination.path,
        expectedBytes: 1,
      ),
      onProgress: progress.add,
    );
    expect(progress.single.receivedBytes, 1);
  });

  for (final responseSize in [1, 4]) {
    test(
      'rejects a response with $responseSize bytes when exactly 3 were pinned',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'air-download-size-',
        );
        addTearDown(() => root.delete(recursive: true));
        final transport = MockClient(
          (_) async =>
              http.Response.bytes(List<int>.filled(responseSize, 1), 200),
        );
        addTearDown(transport.close);
        await expectLater(
          HttpArtifactDownloader(client: transport, attempts: 1).download(
            ArtifactDownloadRequest(
              id: 'test',
              uri: Uri.parse('https://example.test/runtime'),
              destinationPath: p.join(root.path, 'runtime.zip'),
              expectedBytes: 3,
            ),
          ),
          throwsA(isA<ArtifactDownloadException>()),
        );
      },
    );
  }

  test(
    'retries transient HTTP failures and reports final failure without looping',
    () async {
      final root = await Directory.systemTemp.createTemp('air-download-retry-');
      addTearDown(() => root.delete(recursive: true));
      var calls = 0;
      final transport = MockClient(
        (_) async => ++calls == 1
            ? http.Response('unavailable', 503)
            : http.Response.bytes([1], 200),
      );
      addTearDown(transport.close);
      final request = ArtifactDownloadRequest(
        id: 'test',
        uri: Uri.parse('https://example.test/runtime'),
        destinationPath: p.join(root.path, 'runtime.zip'),
        expectedBytes: 1,
      );
      await HttpArtifactDownloader(
        client: transport,
        attempts: 2,
      ).download(request);
      expect(calls, 2);
      final failed = MockClient((_) async => http.Response('', 403));
      addTearDown(failed.close);
      await File(request.destinationPath).delete();
      await expectLater(
        HttpArtifactDownloader(client: failed, attempts: 1).download(request),
        throwsA(isA<HttpException>()),
      );
    },
  );

  test('cancellation interrupts a silent stream and preserves the cancellation error', () async {
    final root = await Directory.systemTemp.createTemp('air-download-cancel-');
    addTearDown(() => root.delete(recursive: true));
    final chunks = StreamController<List<int>>();
    addTearDown(chunks.close);
    final transport = MockClient.streaming(
      (_, _) async => http.StreamedResponse(chunks.stream, 200),
    );
    addTearDown(transport.close);
    final token = ArtifactDownloadCancellationToken();
    final started = Completer<void>();
    final pending = HttpArtifactDownloader(client: transport, attempts: 1)
        .download(
          ArtifactDownloadRequest(
            id: 'test',
            uri: Uri.parse('https://example.test/runtime'),
            destinationPath: p.join(root.path, 'runtime.zip'),
            expectedBytes: 10,
          ),
          cancellation: token,
          onProgress: (_) {
            if (!started.isCompleted) started.complete();
          },
        );
    final cancelled = expectLater(
      pending,
      throwsA(isA<ArtifactDownloadCancelledException>()),
    );
    chunks.add([1]);
    await started.future;
    token.cancel();
    await cancelled.timeout(const Duration(seconds: 1));
  });

  test(
    'inactivity has a bounded timeout and pre-cancelled requests do not start',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'air-download-silent-',
      );
      addTearDown(() => root.delete(recursive: true));
      final chunks = StreamController<List<int>>();
      addTearDown(chunks.close);
      final transport = MockClient.streaming(
        (_, _) async => http.StreamedResponse(chunks.stream, 200),
      );
      addTearDown(transport.close);
      final request = ArtifactDownloadRequest(
        id: 'test',
        uri: Uri.parse('https://example.test/runtime'),
        destinationPath: p.join(root.path, 'runtime.zip'),
        expectedBytes: 10,
      );
      await expectLater(
        HttpArtifactDownloader(
          client: transport,
          attempts: 1,
          inactivityTimeout: const Duration(milliseconds: 15),
        ).download(request),
        throwsA(isA<TimeoutException>()),
      );
      final token = ArtifactDownloadCancellationToken()..cancel();
      await expectLater(
        HttpArtifactDownloader(client: transport)
            .download(request, cancellation: token),
        throwsA(isA<ArtifactDownloadCancelledException>()),
      );
      HttpArtifactDownloader().dispose();
    },
  );
  test('resumes a partial HTTPS download with a Range request', () async {
    final root = await Directory.systemTemp.createTemp('air-download-test-');
    addTearDown(() => root.delete(recursive: true));
    final destination = File(p.join(root.path, 'runtime.zip'));
    await destination.writeAsBytes([1, 2, 3]);
    final transport = MockClient((request) async {
      expect(request.headers[HttpHeaders.rangeHeader], 'bytes=3-');
      return http.Response.bytes([4, 5, 6], HttpStatus.partialContent);
    });
    final downloader = HttpArtifactDownloader(client: transport);

    await downloader.download(
      ArtifactDownloadRequest(
        id: 'runtime',
        uri: Uri.parse('https://example.test/runtime.zip'),
        destinationPath: destination.path,
        expectedBytes: 6,
      ),
    );

    expect(await destination.readAsBytes(), [1, 2, 3, 4, 5, 6]);
  });

  test('rejects non-HTTPS downloads before transport', () async {
    final downloader = HttpArtifactDownloader(
      client: MockClient((_) async => throw StateError('must not be called')),
    );

    await expectLater(
      downloader.download(
        ArtifactDownloadRequest(
          id: 'runtime',
          uri: Uri.parse('http://example.test/runtime.zip'),
          destinationPath: 'unused',
          expectedBytes: 1,
        ),
      ),
      throwsA(isA<ArtifactDownloadException>()),
    );
  });
}
