import '../domain/artifact_models.dart';
import '../domain/runtime_models.dart';

class PinnedAiRuntimeCatalog {
  const PinnedAiRuntimeCatalog();

  AiRuntimeDefinition definition(AiRuntimeKind kind) => switch (kind) {
    AiRuntimeKind.openCode => openCode,
    AiRuntimeKind.kilo => kilo,
  };

  static final openCode = openCodeV2;

  /// The official OpenCode 2 Windows distribution, verified against npm SRI.
  static final openCodeV2 = AiRuntimeDefinition(
    kind: AiRuntimeKind.openCode,
    version: '2.2.2',
    executableName: 'opencode.exe',
    artifact: ArtifactSpec(
      id: 'opencode',
      version: '2.2.2',
      group: 'ai-runtime',
      archiveRoot: 'package/bin',
      payloads: [
        ArtifactPayloadSpec(
          id: 'windows-x64',
          uri: Uri.parse(
            'https://registry.npmjs.org/@opencode/cli-windows-x64/-/cli-windows-x64-2.2.2.tgz',
          ),
          sha256: 'b37348910be48f89873942ee377ccbe239c05814b8f8e9065ef4791c522facdc',
          bytes: 119436377,
          fileName: 'cli-windows-x64-2.2.2.tgz',
          archiveType: ArtifactArchiveType.tarGzip,
        ),
      ],
      requiredPaths: const ['opencode.exe'],
      license: ArtifactLicense(
        name: 'MIT',
        uri: Uri.parse(
          'https://github.com/anomalyco/opencode/blob/dev/LICENSE',
        ),
        notice: 'OpenCode copyright 2025 opencode contributors.',
      ),
    ),
  );

  /// The legacy distribution retained for hosts that explicitly require V1.
  static final openCodeV1 = AiRuntimeDefinition(
    kind: AiRuntimeKind.openCode,
    version: '1.18.27',
    executableName: 'opencode.exe',
    artifact: ArtifactSpec(
      id: 'opencode',
      version: '1.18.27',
      group: 'ai-runtime',
      payloads: [
        ArtifactPayloadSpec(
          id: 'windows-x64',
          uri: Uri.parse(
            'https://github.com/anomalyco/opencode/releases/download/'
            'v1.18.27/opencode-windows-x64.zip',
          ),
          sha256: 'ac26bb6f0309e9a6de279b64dc7bec5e69ab9b79c1a4e2d947d68d213b7eb575',
          bytes: 60644872,
          fileName: 'opencode-windows-x64.zip',
          archiveType: ArtifactArchiveType.zip,
        ),
      ],
      requiredPaths: const ['opencode.exe'],
      license: ArtifactLicense(
        name: 'MIT',
        uri: Uri.parse(
          'https://github.com/anomalyco/opencode/blob/dev/LICENSE',
        ),
        notice: 'OpenCode copyright 2025 opencode contributors.',
      ),
    ),
  );

  static final kilo = AiRuntimeDefinition(
    kind: AiRuntimeKind.kilo,
    version: '7.5.9',
    executableName: 'kilo.exe',
    artifact: ArtifactSpec(
      id: 'kilo',
      version: '7.5.9',
      group: 'ai-runtime',
      payloads: [
        ArtifactPayloadSpec(
          id: 'windows-x64',
          uri: Uri.parse(
            'https://github.com/Kilo-Org/kilocode/releases/download/'
            'v7.5.9/kilo-windows-x64.zip',
          ),
          sha256: 'eacdc26ee3f1af966ef2bf4185e5332917c439f1d55daeb27dabe08ab2561aab',
          bytes: 66444387,
          fileName: 'kilo-windows-x64.zip',
          archiveType: ArtifactArchiveType.zip,
        ),
      ],
      requiredPaths: const ['kilo.exe'],
      license: ArtifactLicense(
        name: 'MIT',
        uri: Uri.parse(
          'https://github.com/Kilo-Org/kilocode/blob/main/LICENSE',
        ),
        notice: 'Kilo Code copyright Kilo Code contributors.',
      ),
    ),
  );
}
