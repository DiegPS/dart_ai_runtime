import 'package:dart_ai_runtime/dart_ai_runtime.dart';
import 'package:test/test.dart';

void main() {
  test(
    'cancellation notifies once, supports removal and late subscribers',
    () async {
      final token = ArtifactDownloadCancellationToken();
      var notified = 0;
      token.addListener(() => notified++);
      final remove = token.addListener(() => fail('Removed listener ran'));
      remove();
      final done = token.whenCancelled;
      token.throwIfCancelled();
      token.cancel();
      token.cancel();
      await done;
      expect(token.isCancelled, isTrue);
      expect(notified, 1);
      token.addListener(() => notified++)();
      expect(notified, 2);
      expect(
        token.throwIfCancelled,
        throwsA(isA<ArtifactDownloadCancelledException>()),
      );
      expect(
        const ArtifactDownloadCancelledException().toString(),
        contains('cancelled'),
      );
      expect(
        const ArtifactDownloadException('network unavailable').toString(),
        contains('network unavailable'),
      );
    },
  );

  test(
    'progress is indeterminate without a size and remains within bounds',
    () {
      ArtifactInstallProgress progress(int received, int total) =>
          ArtifactInstallProgress(
            phase: ArtifactInstallPhase.downloading,
            message: 'Downloading',
            receivedBytes: received,
            totalBytes: total,
          );
      expect(progress(0, 0).fraction, isNull);
      expect(progress(5, 10).fraction, .5);
      expect(progress(20, 10).fraction, 1);
      expect(progress(-1, 10).fraction, 0);
    },
  );
}
