import 'package:air_ai_runtime/air_ai_runtime.dart';
import 'package:test/test.dart';

void main() {
  const catalog = PinnedAiRuntimeCatalog();

  test('pins verified Windows x64 distributions for every runtime', () {
    for (final kind in AiRuntimeKind.values) {
      final runtime = catalog.definition(kind);
      final payload = runtime.artifact.payloads.single;
      expect(runtime.version, isNotEmpty);
      expect(payload.uri.scheme, 'https');
      expect(payload.bytes, greaterThan(50 * 1024 * 1024));
      expect(payload.sha256, matches(RegExp(r'^[a-f0-9]{64}$')));
      expect(runtime.artifact.license.name, 'MIT');
      expect(runtime.artifact.requiredPaths, [runtime.executableName]);
    }
  });

  test('OpenCode and Kilo produce distinct immutable fingerprints', () {
    expect(
      PinnedAiRuntimeCatalog.openCode.artifact.fingerprint,
      isNot(PinnedAiRuntimeCatalog.kilo.artifact.fingerprint),
    );
  });
}
