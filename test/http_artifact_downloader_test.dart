import 'dart:io';

import 'package:dart_ai_runtime/dart_ai_runtime.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
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
