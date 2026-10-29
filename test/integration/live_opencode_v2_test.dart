import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_ai_runtime/dart_ai_runtime.dart';
import 'package:test/test.dart';

void main() {
  final enabled =
      Platform.environment['DART_AI_RUNTIME_TEST_OPENCODE_V2'] == '1';
  test(
    'verified OpenCode 2 streams three Big Pickle turns through the library',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'air-opencode-v2-live-',
      );
      final storage = AiRuntimeStorage(
        sharedStoreRoot: Directory.fromUri(root.uri.resolve('shared/')),
        applicationDataRoot: Directory.fromUri(root.uri.resolve('private/')),
        applicationId: 'dart-ai-runtime-v2-test',
      );
      final network = HttpArtifactDownloader();
      final archive =
          Platform.environment['DART_AI_RUNTIME_TEST_OPENCODE_V2_ARTIFACT'];
      final installer = PinnedAiRuntimeInstaller(
        storage: storage,
        downloader: archive == null
            ? network
            : _PrefetchedArchive(File(archive)),
      );
      final processes = LocalAiRuntimeProcessService(storage);
      final health = AiRuntimeHealthClient();
      final supervisor = AiRuntimeSupervisor(
        installer: installer,
        processes: processes,
        health: health,
        allowDownloads: true,
      );
      AiConversationController? conversation;
      final report = <String, Object?>{'turns': <Map<String, Object?>>[]};
      try {
        final endpoint = await supervisor.start(AiRuntimeKind.openCode);
        expect(endpoint.apiVersion, 2);
        expect(
          supervisor.state.version,
          PinnedAiRuntimeCatalog.openCodeV2.version,
        );
        report['version'] = supervisor.state.version;
        final installation = await installer.installed(AiRuntimeKind.openCode);
        report['executable'] = File.fromUri(
          Directory(installation!.directoryPath).uri.resolve('opencode.exe'),
        ).path;
        final client = _ObservedClient(
          endpoint: endpoint,
          workspaceDirectory: storage.workspace(AiRuntimeKind.openCode).path,
        );
        final catalog = await client.providers();
        expect(
          catalog
              .singleWhere((p) => p.id == 'opencode')
              .models
              .singleWhere((m) => m.id == 'big-pickle')
              .isFree,
          isTrue,
        );
        conversation = AiConversationController(
          supervisor: supervisor,
          clientFactory: (_) => client,
        );
        String? session;
        var turn = 0;
        for (final text in [
          'Hola',
          'Salúdame otra vez en español.',
          'Di hola por tercera vez en una frase.',
        ]) {
          final watch = Stopwatch()..start();
          final marker = 'DART_RUNTIME_TURN_${++turn}';
          final deltasBefore = client.deltas;
          final answer = await conversation.sendAndWait(
            text: text,
            providerId: 'opencode',
            modelId: 'big-pickle',
            systemPrompt:
                'Respond briefly in Spanish. Start your answer with exactly $marker. Never use tools.',
            timeout: const Duration(seconds: 45),
          );
          expect(answer.trim(), isNotEmpty);
          expect(
            answer,
            startsWith(marker),
            reason: 'Updated host instructions must reach each turn.',
          );
          expect(answer, isNot(contains('Ã')));
          session ??= conversation.state.sessionId;
          expect(conversation.state.sessionId, session);
          final model = client.responseModel(session!);
          expect(model?['providerID'], 'opencode');
          expect(model?['id'], 'big-pickle');
          expect(
            client.deltas,
            greaterThan(deltasBefore),
            reason: 'A real SSE delta must be observed each turn.',
          );
          (report['turns'] as List<Map<String, Object?>>).add({
            'prompt': text,
            'answer': answer,
            'model': model,
            'elapsedMs': watch.elapsedMilliseconds,
            'sseDeltas': client.deltas - deltasBefore,
          });
        }
        report['outcome'] = 'passed';
        await conversation.clear();
      } catch (error) {
        report['outcome'] = 'failed';
        report['errorType'] = error.runtimeType.toString();
        if (error is AiRuntimeGenerationException) {
          report['kind'] = error.kind.name;
        }
        rethrow;
      } finally {
        await File('.dart_tool/opencode-v2-live-result.json')
            .writeAsString(const JsonEncoder.withIndent('  ').convert(report));
        await conversation?.dispose();
        await supervisor.dispose();
        health.dispose();
        network.dispose();
        for (var attempt = 0; await root.exists(); attempt++) {
          try {
            await root.delete(recursive: true);
          } on PathAccessException {
            if (!Platform.isWindows || attempt >= 20) rethrow;
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        }
      }
    },
    skip: enabled ? false : 'Set DART_AI_RUNTIME_TEST_OPENCODE_V2=1 to allow three real free-model requests.',
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

class _ObservedClient extends OpenCodeV2RuntimeClient {
  _ObservedClient({required super.endpoint, required super.workspaceDirectory});
  int deltas = 0;
  @override
  Future<Stream<AiRuntimeEvent>> connectEvents() async =>
      (await super.connectEvents()).map((event) {
        final part = event.properties['part'];
        if (event.textDelta != null && part is Map && part['type'] == 'text') {
          deltas++;
        }
        return event;
      });
}

class _PrefetchedArchive implements ArtifactDownloader {
  _PrefetchedArchive(this.archive);
  final File archive;
  @override
  Future<void> download(
    ArtifactDownloadRequest request, {
    ArtifactDownloadCancellation? cancellation,
    void Function(ArtifactDownloadProgress)? onProgress,
  }) async {
    cancellation?.throwIfCancelled();
    await archive.copy(request.destinationPath);
    // The normal installer still checks exact bytes and SHA-256 before use.
  }
}
