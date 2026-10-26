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
