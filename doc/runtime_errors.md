# Runtime generation errors

OpenCode 2 uses the native adapter described in
[the V2 migration guide](opencode_v2.md). It normalizes native execution failures,
including `provider.free-limit`, into the same typed errors. The V1 contract
verification below is retained as historical regression evidence.

`AiConversationController.sendAndWait` throws `AiRuntimeGenerationException`
when the runtime communicates a generation failure. The same exception is
available in `conversation.state.error` for hosts using `sendMessage`.
`kind` distinguishes `authentication`, `permissionDenied`, `quotaExceeded`,
and `unknown`. `statusCode` is retained when the runtime supplies it.

```dart
try {
  final answer = await conversation.sendAndWait(
    text: 'Hello', providerId: providerId, modelId: modelId, systemPrompt: '',
  );
  showAnswer(answer);
} on AiRuntimeGenerationException catch (error) {
  showLocalizedRuntimeFailure(error.kind); // Host-owned translation.
}
```

`cause` preserves the original runtime error object, or the original retry
status when the runtime only supplies a retry notification. It can contain
provider messages, response bodies, and headers. Do not log it or display it
without host-controlled redaction. Exception `toString()` uses only a fixed
category and numeric HTTP status. `AiRuntimeApiException.body` remains available
for compatibility, but is also excluded from `toString()`.

Rejection stops reconciliation and response timers, invalidates the generation,
retires the session, and completes the response once. Remote cleanup waits for
prompt acknowledgement before aborting and deleting the old session, sharing
a two-second deadline. Cleanup failure does not replace the rejection. A new
request creates an isolated session and restores only uncancelled history.
Cleanup can fail or time out; a server that never acknowledges dispatch may
still retain work until it is stopped by the host's process supervisor.

## Verified upstream contract

Checked against OpenCode **v1.18.32**, the globally installed version on the
development machine. Test payloads are constructed from these versioned sources;
they are not a claimed capture of the previously observed rejection:

- [Session status schema](https://github.com/anomalyco/opencode/blob/v1.18.32/packages/schema/src/session-status-event.ts)
  defines `session.status` with `properties.sessionID` and
  `properties.status = {type: "retry", attempt, message, action?, next}`.
- [Retry classification](https://github.com/anomalyco/opencode/blob/v1.18.32/packages/opencode/src/session/retry.ts)
  produces `action.reason = "free_tier_limit"` for a free quota rejection.
  This is terminal to this library even while OpenCode schedules retries.
- [Session processor](https://github.com/anomalyco/opencode/blob/v1.18.32/packages/opencode/src/session/processor.ts)
  publishes that retry status and, after a terminal failure, publishes
  `session.error` and assigns `assistantMessage.error`.
- [Error definitions](https://github.com/anomalyco/opencode/blob/v1.18.32/packages/core/src/v1/session.ts)
  define `ProviderAuthError` and `APIError` with `data.message`, optional
  `data.statusCode`, and `data.isRetryable`.

The controller checks `message.updated.properties.info.error` and reconciled
`info.error` before requiring any assistant text. HTTP 401 and
`ProviderAuthError` identify authentication rejection; HTTP 403 identifies
permission rejection. Other terminal errors remain `unknown` with their cause.

For runtimes without a structured free-tier action, only the specific wording
`Free usage limit reached.` at the start of a message, or the exact upstream
retry message `Free usage exceeded, subscribe to Go`, is classified as free quota
exhaustion. This English-text fallback is necessarily limited. Generic rate
limits, resource exhaustion, service unavailability, and `account_rate_limit`
retry actions are left to the runtime's retry policy. Silent operations retain
their existing timeouts.

Message events and snapshots retain parent request correlation. Session-wide
failures require an exact session ID; events without a session ID are ignored.
The upstream session status/error contract has no generation ID, so it cannot
distinguish a delayed session-wide notification from an earlier successful turn
in the same reused session. Rejected or cancelled sessions are always retired,
which isolates those notifications from the next request.

## Consumer migration

No method signature changes or new dependencies are required. Update the
consumer's library checkout/version, resolve dependencies, and handle
`AiRuntimeGenerationException.kind` alongside existing timeout/transport errors.
Translate categories in the consumer. Do not interpret a rejection in an
isolated runtime as evidence about the user's interactive OpenCode quota.
No consumer application changes are included in this library correction.
