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
