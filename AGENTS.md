# Repository Guidelines

## Scope

This package owns reusable local AI runtime contracts and implementations:
version-pinned artifacts, verified installation, isolated process lifecycle,
health checks, and the common OpenCode/Kilo HTTP and SSE API.

It must not depend on GodSense, Airstream, Riverpod, Flutter widgets, or an
application-specific preferences implementation.

## Structure

- `lib/src/domain/` contains immutable public models.
- `lib/src/application/` contains ports and orchestration.
- `lib/src/infrastructure/` contains HTTP, filesystem, and process adapters.
- `test/` mirrors those areas.

## Commands

- `dart pub get`
- `dart format lib test`
- `dart analyze`
- `dart test`

## Compatibility and safety

- Preserve API compatibility with both OpenCode and Kilo where possible.
- Bind managed runtimes only to loopback with ephemeral credentials.
- Never inherit provider credentials from the parent process environment.
- Verify pinned downloads with exact byte counts and SHA-256 before use.
- Keep shared runtime binaries immutable and application runtime data private.
