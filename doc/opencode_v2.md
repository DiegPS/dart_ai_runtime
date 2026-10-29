# OpenCode 2 integration

## Result and demonstrated causes

The Windows end-to-end test now installs the verified official OpenCode **2.2.2**
distribution, starts it through `LocalAiRuntimeProcessService` and
`AiRuntimeSupervisor`, and sends three turns through `AiConversationController`
and the native Dart HTTP/SSE adapter. It checks actual assistant model identity,
SSE deltas, complete answers, session reuse, UTF-8, and changing host instructions.
The sanitized real-run evidence is stored in
[`evidence/opencode_v2_windows.json`](evidence/opencode_v2_windows.json).

The original library pinned OpenCode 1.18.27. The machine also had Bun's
1.18.32 and Volta's 1.19.5; PATH selected Bun. No running interactive executable
was present during this investigation, so the historical screenshot's exact
executable/version cannot be recovered from that image. All are distinct from
the verified V2 binary used for this test. The original library already called
the official local server; it did not call OpenCode Console directly.

There were two integration problems:

1. The old pin and `/session`, `/provider`, `/event` contracts target V1.
   [Upstream's free-tier notice](https://github.com/anomalyco/opencode/issues/59387)
   says V1 no longer supports free models. The
   [migration guide](https://opencode.ai/v2/docs/migrate-v1) documents the server
   and plugin API changes.
2. A controlled V2 comparison reproduced the quota-labelled rejection with all
   tools denied at definition time. Keeping the native tools under `ask`
   permission produced a real Big Pickle answer over the same native API,
   including with private runtime data. A default native session and the
   official CLI also answered. This demonstrates a configuration-dependent
   rejection, not exhaustion of all the user's quota. The hosted service's
   internal reason for using `FreeUsageLimitError` in that case is not proven.

The correction retains the official native agent and its tool definitions.
It adds host context using instruction entries and gates unauthorized operations
with OpenCode's permission system. It never copies provider credentials,
fabricates official-client headers, changes provider endpoints, or substitutes
another model. Actual provider limits can still reject a future request.

## Host migration

Use the version-aware factory in the consumer's existing controller setup:

```dart
final conversation = AiConversationController(
  supervisor: supervisor,
  clientFactory: (endpoint) => createAiRuntimeClient(
    endpoint: endpoint,
    workspaceDirectory: storage.workspace(endpoint.kind).path,
    systemPromptService: processes.systemPromptService,
  ),
);

final answer = await conversation.sendAndWait(
  text: 'Hola',
  providerId: 'opencode',
  modelId: 'big-pickle',
  systemPrompt: 'Respond briefly in Spanish. Never use tools.',
);
```

The default `PinnedAiRuntimeInstaller` now resolves V2. Set `allowDownloads:
true` on the supervisor to install it when absent. Its 119,436,377-byte npm
archive is pinned to SHA-256
`b37348910be48f89873942ee377ccbe239c05814b8f8e9065ef4791c522facdc`.
It was cross-checked against the official package's SHA-512 SRI before use.
Extraction rejects traversal and symbolic links, and retains immutable version
and fingerprint directories. No Pub cache edits are needed.

Managed endpoints carry `apiVersion`. Health uses `/api/info`, including version
and PID identity checks, for V2 and `/global/health` for V1/Kilo. The legacy
`OpenCodeCompatibleRuntimeClient` now rejects V2 endpoints immediately with a
migration instruction. The new factory selects the appropriate adapter.

V2 data/config/cache/state live in dedicated `v2` subdirectories below the
application's existing private directories. Old V1 files and user-global
installations are preserved. V1 prompt plugins are not loaded in V2, external
plugins and automatic updates are disabled for the managed V2 server, and
provider credentials are excluded from its parent environment.

The supervisor reuses its ready process and serializes concurrent starts.
One conversation reuses one native session across turns. Independent apps keep
their own private state. No global executable or PATH was replaced during
verification; the official binary was downloaded under this repository and
then installed by the real pinned installer into test-owned storage.

## Permissions and protocol details

`toolPermissions: {'*': false}` preserves its promise that no operation is
authorized. V2 translates this to native `ask` gates and replies `reject` to
pending permission requests, rather than stripping the server's tools.
If SSE is lost, reconciliation also finds and rejects pending requests. A failed
denial leaves the operation waiting; the client never grants it permission.
Explicit `true` entries map to native `allow` action patterns; V1 tool names
must be migrated to V2 action patterns before enabling operations.

Host `systemPrompt` values become API-managed instruction entries, updated
before each prompt. They supplement the native agent's instructions. They do
not replace OpenCode's complete system prompt. Exact neutral-agent replacement
remains supported for V1/Kilo through the existing bridge. To opt into V1,
pass `runtimeDefinitions: {AiRuntimeKind.openCode:
PinnedAiRuntimeCatalog.openCodeV1}` to the installer; this does not restore
free-model availability on V1.

The native adapter combines assistant steps for the correlated user request and
finishes only on execution success or the corresponding idle snapshot. It
separates reasoning and visible text, reconnects SSE, and uses ordered paginated
snapshots to recover missed live events. Native event IDs and per-user request
IDs prevent stale message fragments from contaminating a later turn. Actual
provider/model identity is checked on step starts and snapshots. A mismatch
fails the generation; `responseModel(sessionId)` exposes the verified identity.

V2 provider credential setup uses OpenCode's own integration mechanisms. The
existing OAuth/API-key controller remains available for V1/Kilo; a Dart adapter
for the new V2 integration/OAuth API is not included. Big Pickle verification
uses its built-in free provider and requires no credential import.

## Reproduce

The normal suite is offline and does not contact a provider:

```powershell
dart analyze
dart test
```

Opt into three real requests with the pinned free Big Pickle model:

```powershell
$env:DART_AI_RUNTIME_TEST_OPENCODE_V2='1'
dart test test/integration/live_opencode_v2_test.dart
```

The test checks the live catalog for zero input/output cost before inference.
Its SSE assertion counts visible text deltas only, excluding reasoning, so
polling alone cannot satisfy the streaming check. The closing validation passed
111 offline tests (5 opt-in checks skipped), static analysis, and three real
Big Pickle turns with updated instructions and visible SSE text on Windows.
An optional `DART_AI_RUNTIME_TEST_OPENCODE_V2_ARTIFACT` path can supply an already
downloaded archive; exact byte count and SHA-256 verification still run. Results
are written to `.dart_tool/opencode-v2-live-result.json`, excluding credentials.
The test stops its process and removes its own temporary storage.

Native contracts were checked against the official
[HTTP API](https://opencode.ai/v2/docs/api),
[client guide](https://opencode.ai/v2/docs/build/client), and public session-event
and permission schemas. No Flutter app build, purchase, publication, deployment,
or push is part of this change.
