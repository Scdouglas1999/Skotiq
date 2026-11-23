# CI failure patterns

Read this before pushing a branch that has to pass CI, and above all before a release. One full CI run takes about 1h45m. The Dart Tests job decides the time, so each failure you only find on GitHub costs another run of that length.

The patterns below come from the CI history: 400 runs of the CI workflow from May to November 2026 (283 failed, 74 passed, 42 canceled), samples of their logs, and the commits that fixed them. Every pattern has recurred. Most fail only on GitHub because a hosted runner differs from this desktop in a few fixed ways:

- Runners are slow, with 2 to 4 cores and other load on them.
- Their clock is UTC.
- Windows runners use `\` paths, CRLF unless told otherwise, and lock open files.
- They use the pinned Flutter but the newest stable Rust.
- Their network is real but sometimes rate-limited.

Which jobs failed, counted per failed job:

| Job | Failures | Usual cause |
|---|---|---|
| Rust Tests (windows) | 162 | Path separators in test fixtures, then new clippy lints |
| Dart Tests | 187 | Timing and teardown races, wall-clock and time-zone tests |
| Code Coverage (merged into Dart Tests in 9.2) | 149 | Same tests as Dart Tests |
| Rust Tests (linux) | 142 | New clippy lints, time-dependent sequencer tests |
| Launch Gate, Analyze | 139, 138 | Behavioral-audit register and placeholder baseline not synced |
| Format Check | 74 | Dart or Rust files not formatted with the CI toolchain |
| Cargo Duplicate Versions | 63 | Duplicate-version baseline not updated after a dependency change |
| Build Test (Desktop) | 71 | Dependency API changes, Windows-only code, macOS runner shortage |

## Before you push

1. Run the gate locally: `dart run tools/production/gate.dart --out <dir>`, or `--stage <stage>` for the stages your change touches. It runs the same checks as CI's jobs (`docs/ci-gates.md`). A green gate on this desktop still leaves the GitHub-only patterns below.
2. After any edit, sync the audit inputs: `melos run audit:behavioral:sync`, `audit:placeholders:sync`, the architecture baseline, and `behavioral_audit.dart --carry-edited` for edited lines. Moving a line that the register tracks fails Launch Gate and Analyze even when nothing else changed.
3. Format with the pinned toolchain: Flutter 3.44.1 (`FLUTTER_VERSION` in `.github/workflows/ci.yml`) and `cargo fmt`. A newer local Dart formats some code differently.
4. After any `Cargo.toml` or `Cargo.lock` change, regenerate `duplicate-versions-baseline.txt` with `LC_ALL=C sort`.
5. Review your new tests for the patterns below. They are cheap to spot when you read for them and expensive to find on GitHub.

## Tests that race on a slow runner

This is the most common cause of a Dart failure that passes locally.

- **Work still running after the test ends.** A test waits for the first visible result, but the code started more work it never awaited: a background load, a report write, a stream listener. On a slow runner that work is still writing when teardown deletes the temporary folder or closes the database. Signs:
  - `This test failed after it had already completed`
  - `SqliteException(5): database is locked`
  - `FileSystemException: Deletion failed ... Directory not empty`

  Wait for everything the code under test starts, not just the first state change. For example, the session-review tests now wait for `loadingSmartData` as well as `loading` (9.2).
- **Fixed waits and short polling caps.** A loop like `for (i < 50) await delayed(10ms)` gives up after half a second, which a loaded runner can exceed. Poll for the condition with a generous cap, or await the future directly.
- **Async setup checked too early.** A helper that waits for one marker can return before what the test needs has arrived. The INDI frame-type test waited for `CCD_INFO`, but `CCD_FRAME_TYPE` came 86 lines later in the same recording, so on a slow macOS runner the camera exposed before it knew the frame type (9.2). Wait for the last thing the code needs.
- **Timing measurements.** Performance and repaint-count tests fail under load (`shell_clock_repaint`, the defect-map speed test). Take the fastest of several runs, or assert counts that don't depend on speed.
- **Shared state between tests.** The quirks registry and libfli model tests failed non-deterministically until they were serialized or given their own process.

## Wall clock and time zone

CI runs in UTC, and the date changes from run to run. Tests that read `DateTime.now()` or the computer's zone pass on some days and fail on others. Recurring cases:

- **Smart Night windows:**
  - "starts at now once the night is under way";
  - the remaining-window tests;
  - the midnight-sun dialog ("Sun does not set" found 0 widgets);
  - the evening-target conflict test ("a block that outlasts the target").
- **Sequencer:** the night timeline providers, twilight bands, and `a_mid_run_location_change_reaches_the_altitude_dawn_and_meridian_inputs`, which failed in 14 sampled runs.
- **Fixtures across daylight-saving changes:** the altitude-stop fixture, and fixtures that held only in a western time zone.

- **Fake timers with the real clock.** `testWidgets` and `fakeAsync` move timers but not `DateTime.now()`. Code that schedules a timer from the real clock can misbehave under fake time, and only when the real clock happens to be near a boundary. In `AlignedTicker`, each fire recomputed a tiny delay to the same minute boundary, so the shell clock rebuilt 3 to 6 times in a test that allows 2. Fixed in 9.2: each tick now aims one period past the boundary it served. Inject the clock (`now:`) or make the schedule independent of how far the real clock has moved.

Give each test a fixed instant and an explicit site or zone, not the machine's. Run a time-sensitive test with `TZ=UTC` and with a far zone such as `TZ=Pacific/Auckland` before pushing.

## Windows

Rust Tests (windows) is the most-failed job. Check these whenever a test touches files, paths or processes:

- **Path separators.**
  - A path compared as text against a `/`-joined string fails on Windows. The sim-capture guard failed this way for weeks. So did all twelve DepthLock store tests, the largest single block in the log sample.
  - Build expected paths with `Path::join` or `p.join`, or normalize separators before comparing.
- **Line endings.** `.gitattributes` checks text out with LF on Windows too. Keep it that way so goldens, generated files and source scans compare the same.
- **POSIX-only behavior.** Permission bits, deleting an open file, renaming over an open file, and the child processes a test starts (`sh`, `sleep`) don't exist or behave differently on Windows. Skip those cases on Windows or use something that exists on both.
- **Sockets.** A socket accepted from a non-blocking `TcpListener` stays non-blocking on Windows (on Linux it doesn't), and a read timeout doesn't change that. A test server that polls `accept()` gets `WouldBlock` (os error 10035) from its first read. Call `stream.set_nonblocking(false)` after the accept. The PHD2 stalled-connection test failed this way.
- **Code that only builds for Windows.** `#[cfg(windows)]` code and Windows-only imports compile only on the Windows runner. A green Linux build proves nothing about them. Run `cargo clippy --target x86_64-pc-windows-gnu` locally for a type check.

## Toolchain drift

- **Rust stable is not pinned.** CI uses `dtolnay/rust-toolchain@stable` with clippy `-D warnings`, so each new stable release can add lints that fail CI on unchanged code. Examples: `chunks_exact` with a constant size (181 sampled errors), `#[must_use]` without a message, overindented doc lists. If your local `rustc` is older than current stable, expect new clippy errors on CI, and run `rustup update` before a release.
- **Dependency API changes.** Build Test failed on `libloading::AsSymbolName`, the removed `quick_xml` `trim_text` and `check_end_names`, and the `sha2` `update` bounds. These came from dependency upgrades that were only built on Linux. Rebuild every target after changing `Cargo.lock`, because the Windows build pulls in different features.
- **Node version.** CI uses Node 24, and this desktop has Node 26. On Node 24, `node --test test/` treats the bare directory as a script to run and fails with `MODULE_NOT_FOUND`, while Node 26 runs the tests inside it. Name test files with a pattern node expands itself (`node --test 'test/*_test.js'`) (9.2).

## Job deadlines and runner capacity

- **Test suites outgrow their timeouts.** Timeouts were raised in 6.0, 8.0 and 9.1 as the Dart and Rust suites grew. A canceled job with "exceeded the maximum execution time" is a timeout, not a test failure. Raise the limit in `ci.yml` together with the change that added the tests.
- **macOS runners.** "The job was not acquired by Runner of type hosted" means GitHub had no macOS arm64 runner. The macOS checks aren't required by branch protection or `scripts/release_gate.py`. Re-run them, but don't treat them as code failures.
- **Rate limits.** `Too Many Requests` or `Failed to download archive` while fetching an action is GitHub-side. Re-run the job.
- **Real network calls in tests.** Some tests still reach outside services. Map tiles from services.arcgisonline.com returned 400 on CI. A test should use a fake server or be tagged so CI skips it.

## Reading a failed run

- **The Dart Tests summary can hide the failing test.** It may say `5836 tests passed, 1 failed` while every visible line shows a pass, because an error after a test completes isn't always printed by the GitHub reporter. Download the `dart-test-results` artifact and look for `"type":"error"` events or a `testDone` whose result isn't `success` in `<package>/test-results.json`. The error event names the test and gives the stack.
- **Annotations rarely name the cause.** "Process completed with exit code 1" is all most failed jobs show. Fetch the job log with `gh api --allow-escape-sequences repos/<owner>/<repo>/actions/jobs/<id>/logs`, strip the color codes, then search it:
  - `---- <test> stdout ----` and `panicked at` for Rust tests;
  - `FAIL` lines from the gate summary.
- **Fix every red job in one push.** Read every red job before pushing a fix. Each push restarts the whole run, and an earlier run of a superseded commit can be canceled to free runners.

## Release workflow

Release failures have been rarer (5 of the last 60 runs):

- `docs/release/vX.Y.Z.md` was missing when the tag was pushed (7.0.0).
- The Linux and Windows package builds failed in 6.0.0 and 6.2.0.

The tag has to be on a commit of `main` whose required checks are all green. Run `scripts/release_gate.py` locally, and keep `version.yaml`, both pubspecs, `installer.iss` and `link_version.dart` in step: `version_consistency_audit.dart` checks them.
