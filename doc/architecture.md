# Architecture

`dart_ai_runtime` applies a domain/application/infrastructure split.

```text
Host application UI and preferences
                |
                v
       AiRuntimeSupervisor
        /       |        \
       v        v         v
 installer   process    health
     |          |          |
 shared      private     loopback
 binaries    app data      API
```

Domain models contain no filesystem, HTTP, process, or application-framework
dependencies. Application interfaces define the lifecycle and client ports.
Infrastructure adapters implement verified artifacts, native processes, and
the OpenCode-compatible protocol.

Framework-neutral application controllers sit above that protocol:

- `AiConversationController` owns session continuity, SSE correlation,
  cancellation generations, polling reconciliation, and endpoint changes.
- `AiModelSelectionController` owns catalog validation and prevents implicit
  selection of paid models.
- `AiProviderConnectionController` coordinates API-key and OAuth flows and
  verifies their outcome against the provider catalog.

Persistence and downloading remain injected ports. A Flutter host may use
SharedPreferences or a background downloader without introducing Flutter into
the runtime package.

The package does not own conversation presentation, provider-selection policy,
user consent, application settings, prompt construction, or business context.
Those responsibilities remain in Airstream, GodSense, or another host.

## Trust boundaries

1. A catalog entry pins the release URI, expected bytes, SHA-256 and license.
2. Downloads remain unavailable to consumers until verification succeeds.
3. ZIP entries cannot escape the staging directory.
4. Installation is promoted atomically into a fingerprinted directory.
5. File locks serialize installation across independent host processes.
6. The executable is shared read-only by convention; its mutable XDG roots are
   private to the host application.
7. The runtime binds to loopback and receives a random in-memory password.
8. Provider credentials from the parent environment are not inherited.
9. Runtime API clients reject non-loopback endpoints.

## Package evolution

The public Dart package follows semantic versioning. Runtime versions are
independent and pinned by `PinnedAiRuntimeCatalog`. Updating OpenCode or Kilo is
a catalog change with updated size, digest, compatibility tests, and notices;
it does not overwrite an existing version or fingerprint.
