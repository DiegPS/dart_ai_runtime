# dart_ai_runtime

Reusable Dart infrastructure for local OpenCode-compatible AI runtimes. It
extracts the runtime behavior proven in GodSense without depending on GodSense,
Airstream, Flutter widgets, Riverpod, or application preferences.

## Capabilities

- Pinned OpenCode and Kilo Windows x64 distributions.
- HTTPS downloads with retries and resume support.
- Exact byte-count and SHA-256 verification.
- Safe ZIP/tar.gz extraction and immutable, content-addressed installations.
- In-process and cross-process locking for applications sharing one store.
- Dynamic loopback ports and ephemeral Basic Auth credentials.
- Sanitized child environments that do not inherit provider credentials.
- Windows Job Objects that terminate child processes when the host closes.
- Health checks, provider/model discovery, OAuth/API-key endpoints, sessions,
  asynchronous prompts, cancellation, history, and SSE events.
- A supervisor that guarantees only one active runtime per host instance.
- Restart-safe conversation orchestration with SSE correlation and polling
  reconciliation.
- Framework-neutral provider authentication and safe model selection
  controllers.
- Native OpenCode 2 agents with host instruction entries and permission requests
  rejected before unauthorized operations execute.
- Managed neutral agents for V1/Kilo, with tools denied by default.
- One-shot, private system-prompt transport keyed by runtime session, allowing
  live host context to change on every turn.

Downloads are deliberately dependency-injected through `ArtifactDownloader`.
The package includes a simple resumable HTTP implementation, but host
applications may provide background, platform-native, or enterprise download
implementations without changing the runtime layer.

## Storage contract

Runtime binaries are recoverable, immutable resources and may be shared by a
publisher's applications. Runtime configuration, provider credentials,
sessions, cache, state, temporary files, and workspaces remain private to each
application.

```text
sharedStoreRoot/
  artifacts/ai-runtime/opencode/versions/2.2.2/<fingerprint>/
  artifacts/ai-runtime/kilo/versions/7.5.9/<fingerprint>/
  downloads/
  locks/

applicationDataRoot/
  ai/opencode/{data,cache,config,state,temp,workspace}/
  ai/kilo/{data,cache,config,state,temp,workspace}/
```

There is deliberately no shared `active.json`. Every application pins and
resolves an exact artifact version and fingerprint, so one product can upgrade
without silently changing another product's executable.

For unpackaged Windows applications:

```dart
final storage = AiRuntimeStorage.windowsUnpackaged(
  publisherDirectoryName: 'DiegPS',
  applicationId: 'airstream',
);
```

For Microsoft Store/MSIX applications, resolve the publisher cache folder in
the host application and pass it as `sharedStoreRoot`. Windows package
manifests must declare the same `windows.publisherCacheFolders` entry. Do not
assume that a normal `%LOCALAPPDATA%` path is shared across packaged apps.

## Minimal host integration

```dart
final storage = AiRuntimeStorage(
  sharedStoreRoot: publisherCacheDirectory,
  applicationDataRoot: airstreamPrivateDirectory,
  applicationId: 'airstream',
);
final downloader = HttpArtifactDownloader();
final installer = PinnedAiRuntimeInstaller(
  storage: storage,
  downloader: downloader,
);
final health = AiRuntimeHealthClient();
final processes = LocalAiRuntimeProcessService(storage);
final supervisor = AiRuntimeSupervisor(
  installer: installer,
  processes: processes,
  health: health,
  allowDownloads: true,
);

final endpoint = await supervisor.start(AiRuntimeKind.openCode);
final client = createAiRuntimeClient(
  endpoint: endpoint,
  workspaceDirectory: storage.workspace(endpoint.kind).path,
  systemPromptService: processes.systemPromptService,
);
final providers = await client.providers();
```

OpenCode now pins **2.2.2** and uses its native `/api/*` contract. Use
`createAiRuntimeClient` in host factories so OpenCode 2 and Kilo/V1 select the
correct adapter. See [OpenCode 2 migration and real validation](doc/opencode_v2.md).

For complete conversation handling, construct `AiConversationController` with
the supervisor and a client factory. It opens SSE before dispatching, rejects
events from previous turns, reconciles missed events through the message API,
invalidates sessions after a process restart, and discards late events after
cancellation. UI frameworks consume its `states` stream.

The default inactivity budget is 100 reconciliation intervals of 600 ms.
Correlated text or reasoning progress and advancing polling snapshots reset
that budget; heartbeats and stale messages do not. Reasoning is never included
in the visible answer. `responseTimeout` independently limits a turn to three
minutes by default. A timeout retires the session and marks the unfinished
turn cancelled locally, even if the runtime cannot acknowledge cancellation.
`sendAndWait(timeout: ...)` retains its separate caller-supplied deadline.

The controller creates one runtime session lazily and reuses it for every
consecutive prompt until cancellation, timeout, `clear`, a runtime restart, or disposal. Reusing the
session avoids another runtime start, health check, client setup, and session
creation. The model still processes its conversation history for each turn, so
the exact latency improvement depends on provider-side prompt caching and the
selected model.

The host may supply a different `systemPrompt` on every call. OpenCode 2 stores
it as a native instruction entry that supplements the agent's instructions.
The native agent and tool definitions remain intact, while unapproved operations
wait for permission and are rejected by the client, including after SSE loss.
This differs from replacing the complete coding system prompt.

For V1/Kilo, with `systemPromptService` configured as above, the client writes that value to a
private one-shot file keyed by session ID. The trusted plugin consumes and
deletes it while assembling the model request. This is necessary because the
OpenCode-compatible system transformation hook does not receive the HTTP
`system` field in its transform input.

V1/Kilo managed neutral mode fails closed if the private runtime configuration lists
another external plugin or contains an auto-loaded `.js`/`.ts` plugin. This
prevents an unrelated plugin from silently adding instructions or tools. Hosts
that intentionally need arbitrary upstream plugins must construct
`LocalAiRuntimeProcessService` with `enableNeutralSystemPrompts: false` and then
own the resulting prompt and tool security model themselves.

```dart
final conversation = AiConversationController(
  supervisor: supervisor,
  clientFactory: (endpoint) => createAiRuntimeClient(
    endpoint: endpoint,
    workspaceDirectory: storage.workspace(endpoint.kind).path,
    systemPromptService: processes.systemPromptService,
  ),
);

final first = await conversation.sendAndWait(
  text: 'Hola',
  providerId: 'opencode',
  modelId: 'big-pickle',
  systemPrompt: 'Respond briefly in Spanish. Never use tools.',
);
final second = await conversation.sendAndWait(
  text: 'Salúdame otra vez.',
  providerId: 'opencode',
  modelId: 'big-pickle',
  systemPrompt: 'Respond briefly in Spanish. Never use tools.',
);
```

Both calls use the same `conversation.state.sessionId`. Create separate
controllers for independent simultaneous conversations. Calls within one
controller are serialized; starting a second generation while one is active
throws a `StateError`.

For V1/Kilo, neutral prompt replacement controls which host instructions and tools reach the
model; it does not make model output factually correct. Applications such as a
game coach should provide structured, patch-specific facts and validate any
item, ability, price, or statistical claim before presenting it as authoritative.

`AiModelSelectionController` never chooses a paid model automatically and
prefers `kilo/kilo-auto/free` when available. For V1/Kilo, `AiProviderConnectionController`
validates OAuth responses and confirms every connection or disconnection
against the runtime provider catalog. Persistence is supplied by host-owned
`AiModelSelectionStore` and `AiConversationHistoryStore` adapters.

The host owns `client`, `health`, `downloader`, and `supervisor` and must dispose
them when its application scope ends.

Tools are denied by default in `AiPrompt`. A host must explicitly opt into tool
patterns and remains responsible for communicating the security implications
to its users.

V2 permission patterns are native action patterns, rather than V1 tool names.
Provider credential setup for V2 uses OpenCode's own integration mechanisms;
the legacy OAuth/API-key controller is unchanged for V1/Kilo.

## Migration rule

Legacy GodSense runtime directories and personal OpenCode/Kilo installations
must not be adopted merely because an executable exists. An integration should
either re-download the pinned archive or import only after validating a trusted
release-specific executable digest. Old private runtime data must remain under
the original application's ownership and must never be copied to another app.

## Validation

Line coverage is checked against a **90%** minimum for `lib/`, including native
Windows process handling. See [testing and coverage](doc/testing.md) for the
reproducible commands, report scope, and measured results.

```powershell
dart run coverage:test_with_coverage
dart run tool/check_coverage.dart
```

Runtime rejections are exposed as `AiRuntimeGenerationException`, including
failures received before assistant text. See [error handling and migration](doc/runtime_errors.md)
for categories, cleanup guarantees, verified upstream contracts, and limitations.

```powershell
dart format --output=none --set-exit-if-changed lib test
dart analyze
dart test
```

Real process checks are opt-in and never perform inference:

```powershell
$env:DART_AI_RUNTIME_TEST_OPENCODE_EXE='C:\path\to\opencode.exe'
$env:DART_AI_RUNTIME_TEST_KILO_EXE='C:\path\to\kilo.exe'
dart test test\integration\live_runtime_process_test.dart
```

Real multi-turn inference is separately opt-in because it contacts the selected
provider and may be subject to its terms, retention policy, rate limits, and
costs:

The recommended OpenCode 2 test installs the verified pin and checks three real
Big Pickle responses, SSE, model identity, and changing host instructions:

```powershell
$env:DART_AI_RUNTIME_TEST_OPENCODE_V2='1'
dart test test\integration\live_opencode_v2_test.dart
```

The older neutral-plugin test below is for V1/Kilo. OpenCode V1 free-model
availability is no longer supported by upstream:

```powershell
$env:DART_AI_RUNTIME_TEST_INFERENCE='1'
$env:DART_AI_RUNTIME_TEST_OPENCODE_EXE='C:\path\to\opencode.exe'
$env:DART_AI_RUNTIME_TEST_KILO_EXE='C:\path\to\kilo.exe'
dart test test\integration\live_neutral_session_test.dart
```

## Third-party runtimes

The generated-plugin regression tests require Node.js 22 or newer on `PATH`.
They execute the actual JavaScript hooks without contacting an AI provider.

OpenCode and Kilo are independent projects distributed under the MIT License.
Applications using this package must surface and preserve their upstream
copyright and license notices. `dart_ai_runtime` is not affiliated with or
endorsed by either project. Runtime providers and models may have separate
prices, terms, and privacy policies; a free runtime does not guarantee free
inference.
