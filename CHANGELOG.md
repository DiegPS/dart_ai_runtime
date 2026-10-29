## Unreleased

- Add offline behavioral coverage for authentication, persistence, verified
  installation, process lifecycle/Windows jobs, legacy HTTP/SSE, and downloads.
  Generate LCOV plus a per-file JSON report and enforce a 90% library line gate.
- Allow injecting the OS process starter while retaining explicit environment
  isolation and real child-process lifecycle testing.
- Cancel the download reader when cancellation is requested, releasing silent
  streams promptly and preserving the cancellation exception while flushing
  partial files safely.

- Pin the official OpenCode 2.2.2 Windows x64 distribution with exact size and
  SHA-256, verified against the registry's SHA-512 integrity metadata. Add secure
  tar.gz extraction; preserve the explicit V1 distribution and unchanged Kilo pin.
- Add `OpenCodeV2RuntimeClient` and `createAiRuntimeClient` for native model,
  session, instruction-entry, permission, message-pagination and SSE APIs.
- Keep OpenCode 2's native agent and tool definitions; hold unapproved operations
  for permission and reject them before execution, over SSE or reconciliation.
- Reconnect live-only SSE, correlate turns, combine multi-step answers, validate
  actual response models, and expose response model identity without fallback.
- Start V2 with ephemeral loopback authentication, dedicated private V2 data and
  configuration, and no inherited provider credentials or legacy prompt plugins.
- Add an opt-in Windows end-to-end test that installs the verified distribution
  and checks three real Big Pickle responses, SSE and changing host instructions.
- Cover idle-only execution failures, interrupted turns, repeated pagination
  cursors, and late fragments from previous requests. Cancel silent, unconsumed,
  rejected, and late-arriving SSE connections during disposal.

- Propagate definitive runtime rejections as `AiRuntimeGenerationException`,
  including OpenCode free-tier retry actions and assistant errors without text
  received through SSE or message reconciliation.
- Retire rejected sessions immediately, ignore late events, and bound remote
  cleanup without replacing the original cause or blocking subsequent turns.
- Keep temporary retries and silent-response timeouts; omit raw response bodies
  from HTTP exception diagnostics.

## 0.3.6

- Treat reconciliation attempts as an inactivity budget: correlated text or
  reasoning progress and advancing polling snapshots keep an active response
  alive. Reasoning content remains excluded from visible answers.
- Bound every turn with a configurable three-minute total response deadline.
  Timeout cancels and retires its runtime context; heartbeat and stale-message
  events cannot postpone inactivity detection.
- Retire local context even when runtime cancellation fails, preserving visible
  cancellation metadata and excluding unfinished turns from future prompts.

## 0.3.5

- Await event subscription cleanup before closing its HTTP client. Expected
  transport errors during explicit cancellation no longer escape as unhandled
  asynchronous exceptions; stalled cleanup has a bounded grace period.

## 0.3.4

- Retire the runtime session after cancellation, retaining visible local history
  and restoring only uncancelled messages into the next runtime context. This
  prevents the model from completing a cancelled, unanswered question later.
- Add optional cancellation metadata to persisted conversation messages.

## 0.3.3

- Serialize cancellation after in-flight prompt acknowledgement, so a request
  cannot be admitted after the server has already processed its abort.
- Ignore cancellation results after conversation replacement or disposal.

## 0.3.2

- Correlate each assistant response with the explicit user message ID sent to
  the runtime, in both SSE and polling reconciliation. Late cancelled messages
  can no longer become the next turn's answer.
- Ignore session-wide idle notifications when completing individual turns;
  these can arrive late after cancellation.
- Cover delayed cancelled snapshots, partial current replies, stale SSE and
  message ID serialization with deterministic regression tests.

## 0.3.1

- Preserve the trusted prompt in memory when a provider invokes the system hook
  repeatedly; consume updated host prompts atomically for subsequent turns.
- Serialize concurrent hooks per session and clear cached prompts on session
  deletion. Invalid or missing prompts still fail closed.
- Exercise the generated OpenCode and Kilo JavaScript hooks using Node.js,
  including concurrent retries, new telemetry, isolation and cleanup.

## 0.3.0

- Add managed neutral agents and trusted system-prompt plugins for OpenCode and
  Kilo.
- Add one-shot, session-scoped system prompt transport with strict identifier
  validation and private storage cleanup.
- Preserve one runtime session across consecutive conversation turns while
  refreshing host telemetry on every prompt.
- Add opt-in real inference coverage for multi-turn neutral sessions.
- Serialize process integration tests because upstream runtimes may choose the
  same fallback port when launched concurrently with `--port 0`.

## 0.2.0

- Add framework-neutral, restart-safe conversation orchestration.
- Add strict SSE message correlation with polling reconciliation.
- Add provider authentication coordination with verified outcomes.
- Add safe provider/model selection and persistence contracts.
- Expand live runtime checks to authentication, SSE, and session lifecycle.

## 0.1.0

- Add the common OpenCode/Kilo HTTP and SSE protocol.
- Add pinned and verified Windows x64 runtime installation.
- Separate shared immutable executables from private application state.
- Add isolated process supervision, health checks, and Windows Job Objects.
- Add opt-in real runtime validation without inference.
