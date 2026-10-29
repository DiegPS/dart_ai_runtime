# Testing and coverage

The library's minimum is **90% executable line coverage across `lib/`**.
The metric covers all implementation files, including the Windows process and
job-object adapters. No coverage-ignore directives or implementation exclusions
were added to reach the target. Abstract ports and exports have no executable
lines; tests and developer tools are outside the library's denominator.

## Reproduce

Run from the repository root using the Dart SDK declared in `pubspec.yaml`:

```powershell
dart pub get
dart analyze
dart run coverage:test_with_coverage
if ($LASTEXITCODE -ne 0) { throw 'Coverage test run failed.' }
dart run tool/check_coverage.dart
if ($LASTEXITCODE -ne 0) { throw 'Library coverage is below its minimum.' }
```

`coverage` is a development dependency. The collection command runs the test
suite with VM instrumentation and writes `coverage/coverage.json` and
`coverage/lcov.info`. The checker merges duplicate source/line records, measures
only paths inside `lib/`, rejects malformed/empty reports, and writes
`coverage/summary.json` with totals, per-file percentages, and uncovered lines.
It exits nonzero below the threshold; the comparison uses the exact fraction,
not a rounded display value. Its parser and threshold behavior have unit tests.

To inspect a different report or set a stricter local minimum:

```powershell
dart run tool/check_coverage.dart coverage/lcov.info 95
```

Transient coverage files are ignored by Git. A sanitized snapshot of the final
Windows measurement is tracked in
[`evidence/coverage_windows.json`](evidence/coverage_windows.json).

## Scope and fixtures

The default suite does not require provider access or an installed OpenCode
binary. Its model/provider controllers use deterministic ports, HTTP downloads
use in-memory response streams, and pinned installations use test-owned PE
fixtures checked by the real size/digest validator.

Process tests inject only the process-start boundary. They run a small local
Dart program through the actual OS process implementation, exercising stdout,
stderr, invalid UTF-8, readiness, premature exit, idempotent stop and Windows job
cleanup. The same explicit sanitized environment and loopback arguments are
asserted. The process starter defaults to `Process.start` in production.

Coverage testing found and fixed cancellation of a download stalled between
chunks: the reader is now cancelled, while the file sink remains open until its
buffer is flushed. This avoids a long wait and a cleanup error replacing the
original cancellation. There are regressions for cancellation, timeouts, resume,
ignored range requests, size mismatches and retry limits.

Real OpenCode/Kilo checks remain opt-in and are omitted from the ordinary
coverage run. Leave all `DART_AI_RUNTIME_TEST_*` opt-in environment variables
unset when reproducing this offline measurement. The three-turn real Big Pickle
test and its separate evidence are documented in [the V2 guide](opencode_v2.md).
Line coverage does not imply 90% branch coverage or prove every possible OS
failure. Rare native failure paths remain visible as uncovered lines in LCOV.
