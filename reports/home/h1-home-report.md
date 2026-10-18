# H1: mount Home command

Base: `9b96d59bf` (worktree `~/.cache/ns-worktrees/skotiq-h1-home`). The final sha is in the commit log; this report is part of the last commit.

## What was already there

Parts of a mount home path existed before this work: `DeviceManager::mount_find_home`, the `mount_find_home` bridge function, `DeviceBackend.mountFindHome`, `POST /api/mount/find-home`, `MountCommandService.findHome`, and a Home button in the Equipment mount card. These were the gaps:

- The simulator teleported to the pole and reported `AtHome` instantly. It did not stop tracking, and a parked simulator could be homed (it came out unparked).
- No layer checked for a parked mount. ASCOM and Alpaca drivers that unpark on `FindHome` would have been unparked without the operator asking.
- ASCOM status always reported `at_home` as unsupported, because the wrapper never read `AtHome`.
- The ASCOM wrapper waited on `long_slew()` and not on the existing `Timeouts::find_home()`. A driver with `CanFindHome = false` came back as a 500-class hardware fault.
- Native vendor mounts never advertised `can_find_home`, even OnStep, which implements it. iOptron had no home at all.
- INDI reported a home in progress as idle. Only the coordinate vector's Busy state counted as slewing.
- The Dart side marked the mount slewing, called the driver, and then reported "Mount homing complete" as soon as the call returned. It also cleared the parked flag.
- The Imaging › Mount tab had no Home button. The Equipment card had Home after Track, and it was not disabled for a parked mount.
- `MountCommandService.abortSlew` ran through the one-command-at-a-time gate. While a slew or home held that gate, Abort slew was refused with "Another mount command is already in progress".

## Layers touched

### Native drivers (`native/skotiq_native`)
- `native/src/traits.rs`: new `NativeMount::can_find_home()`, default `false`, kept beside the `NotSupported` default of `find_home`.
- `native/src/vendor/lx200/mount_ops.rs`: OnStep advertises home (`:hF#`); Meade does not.
- `native/src/vendor/ioptron.rs`: `find_home` sends `:MH#` (go to zero position) and requires the `1` reply. `can_find_home` is true. `at_home` stays unsupported, because the existing `:GAS#` parser is not one I would trust for a home flag.
- `indi/src/mount.rs`: `try_is_slewing` is also true while `TELESCOPE_HOME` is Busy.

### Bridge
- `device_manager/ops/mount/park.rs`: `mount_find_home` now checks two things for every driver before anything moves:
  - `mount_can_find_home`, a new op with a live per-driver read: ASCOM capabilities, Alpaca `canfindhome`, INDI `TELESCOPE_HOME.GO`, native `can_find_home()`, simulator true. If it fails the result is `Unsupported`.
  - Parked, read through `mount_get_status`. If parked the result is the new `DeviceOpError::InvalidState`, which reaches Dart as `SkotiqError::DeviceBusy` (HTTP 409).
- The ASCOM arm now takes a read guard. `find_home` is `&self`, and the COM worker serializes the call.
- `ascom_wrapper/mount.rs`:
  - New `AtHome` command and `at_home()`.
  - `find_home` uses `Timeouts::find_home()`, and maps `CanFindHome = false` to `NativeError::NotSupported`.
  - Three wrapper tests on the existing test seam.
- `device_manager/ops/mount/status.rs`: ASCOM status reports `AtHome`.
- `device_capabilities/native.rs`: native mounts publish `can_find_home`.
- Simulator, in `api/devices/simulation/mount.rs` and the park, slew and tracking arms:
  - Home is a timed motion (`begin_sim_home`) to `sim_home_position()`. That is the pole of the configured site's hemisphere, with counterweights down, the same pose as park.
  - It keeps the pier side and switches tracking off.
  - It reports `AtHome` only after the settle. An abort part-way leaves `AtHome` false.
  - Park, axis moves and turning tracking on clear `AtHome`.
- `dispatch/error.rs`: new `InvalidState` variant.
- Bindings: regenerated with the repo's codegen command (from `scripts/dev.sh`): `CC=clang CPATH="$(clang -print-resource-dir)/include:/usr/include" flutter_rust_bridge_codegen generate`. Only doc comments changed in the generated Dart. The regeneration also refreshed a stale comment in `api/polar_alignment/run_loop.dart` that was not part of this work.

### Sequencer: Park node exists, so "Home mount" was added
- `NodeType::HomeMount` is added through the same registry as Park and Unpark.
- `DeviceOps` gains `mount_find_home` and `mount_is_at_home`. Their defaults fail closed. `UnifiedDeviceOps` implements both.
- `execute_home_mount`:
  - refuses a parked mount;
  - requires motion within 15 s;
  - waits up to 300 s for the mount to stop;
  - then reports at home, a failure (stopped but not at home), or unconfirmed (the driver cannot report AtHome);
  - aborts on cancel.
- Wire serialization is `{"type":"HomeMount"}`. Dart has `HomeMountNode` with an encoder, decoder, palette entry "Home mount", validation, diff and editor support. There are Rust and Dart tests.
- Bug found on the way: saving a Park, Unpark, Stop guiding or Home mount step that has a comment threw "Cannot modify unmodifiable map" in `node_encoder.dart`. Fixed, with a regression test.
- Not added on purpose: Smart Night, the scheduler engine, templates, snippets and the NINA import. Nothing inserts a home step on its own.

### Dart core (`packages/skotiq_core`)
- New `services/mount_home_watcher.dart` (`MountHomeWatcher`). It holds the rule from the rig data below, and is the same rule as the sequencer node.
- `DeviceService.findMountHome()` now returns a `MountHomeOutcome` (`confirmed` or `unconfirmed`), and throws `MountHomeException` otherwise. In order, it:
  1. reads the status and refuses a parked mount;
  2. starts an `OperationType.homeMount` operation ("Homing…", which can be canceled);
  3. sends Home and watches.
  It never touches the parked flag. If the driver ignored the command it aborts best-effort.
- `MountState` gains `isAtHome`, read from the poll, `isHoming`, and `homeUnconfirmed`. The poll clears `homeUnconfirmed` once the mount slews, parks, or reports AtHome.
- Abort slew clears `isHoming`. The watcher reads that flag and ends the home as canceled.
- `canFindHome` was already on `MountCapabilities`, and `atHome` was already on `MountStatus`.

### App (`packages/skotiq_app`)
- `MountCommandService.findHome()`:
  - Checks the capability first, then refuses a parked mount ("…Unpark it before sending it home.").
  - Success messages: "Mount is at home", or for an unconfirmed home "The mount moved and stopped, but its driver cannot confirm it is at home".
  - The disabled reasons live in `MountCommandService.homeUnavailableReason`, which every Home control uses.
- `abortSlew()` no longer takes the exclusive command slot, so it reaches a home or slew in progress.
- Imaging › Mount tab:
  - The rows are now [Stop/Start tracking, Abort slew], [Park/Unpark, **Home**], [Polar alignment].
  - Home is a small secondary button with the lucide `home` icon. When it is disabled, a `SkotiqTooltip` and a semantics hint give the reason.
  - While homing, the status chip reads "Homing" and Park, tracking, slew and sync are disabled. Abort slew stays live.
  - The Status readout reads Parked, At home, Home (unconfirmed) or Ready.
- `_ActionPairs` used integer flex and could hand a cell a fraction of a pixel less than its label needs. "Home" beside "Unpark" was cut off at 160 px. Each cell now gets its measured width plus a proportional share of the slack.
- Equipment › Devices mount card:
  - Actions are now Park, **Home**, Track, Flip. Home is inline beside Park, and Track moved behind the overflow menu at narrow widths.
  - Home and Park are disabled while homing.
  - `_ActionButton` takes an optional tooltip.
  - The State metric shows Homing, At home or Home (unconfirmed).
- Operation status bar: a Homing entry with a cancel button that calls Abort slew.

### Headless API (`apps/desktop/lib/headless_api/`)
- `POST /api/mount/home` → `handleMountHome`:
  - 400 `capability_unsupported` when the mount cannot home.
  - 409 `mount_parked` when the mount is parked. It is never unparked.
  - 409 `capabilities_unavailable` when the mount reports no capabilities.
  - 200 `{status: "homing", commandId}` when the driver accepts the command.
- `POST /api/mount/find-home` is kept as an alias on the same handler.
- Both paths are added to: the high-risk tier and audit actions (`mount_home`), session ownership, the endpoint catalog, `route_metadata_test.dart` and `tools/production/headless_route_policy_audit.dart`.

## Rig finding: a driver that accepts Home and does not move

Data the coordinator collected on the owner's PegasusAstro NYX-101 (ASCOM, driver 2.10.4752.497):
- `CanFindHome` was true, and `FindHome` returned in 0.2 s.
- For 4 minutes after that, Slewing stayed false, Dec stayed at 8.01°, and RA changed only with sidereal time.
- `AtHome` stayed false, and Skotiq reported `at_home` as unsupported.

So a returned call is not a home. The Dart watcher and the sequencer node both apply this rule:
- **Motion** is any of: `Slewing` true; Dec moving more than 0.1°; or RA and hour angle both moving more than 0.1°. A stopped mount either holds RA (tracking) or holds hour angle (not tracking). Only turning axes change both, so the NYX-101's sidereal RA drift does not count.
- **No motion within 15 s** (`MountHomeWatcher.defaultMotionStartWindow` and `HOME_MOTION_START_WINDOW`, with the reason in a comment): the home fails with "The mount's driver accepted Home but the mount didn't move." The app sends a best-effort abort.
- **Motion, then stopped, and AtHome supported**: true is confirmed; false is a failure ("The mount stopped but does not report being at home").
- **Motion, then stopped, and AtHome unsupported**: success, marked unconfirmed in the result message, the Imaging status readout and the Equipment state metric.
- **Still moving after 5 min**: failure.
- Tests cover both the no-motion case (a replay of the NYX-101 numbers, plus a fake backend through the app service) and the unconfirmed case, in Dart and in the sequencer.

The headless route answers once the driver accepts Home, the same as park, so it doesn't block an HTTP request for up to 5 minutes. The phone and remote desktop run the same `DeviceService` watcher against `GET /api/mount/status`, so they get the same verdict.

## Decisions
- Home is never automatic. The only callers are the Imaging button, the Equipment button, the HTTP route, and a sequencer node the user places. There are no shutdown, safety, recovery or template call sites.
- Homing never parks and never unparks. Tracking is left as the driver leaves it. ASCOM stops it; the simulator mirrors that.
- The parked check is in three places: the device manager (all FFI and sequencer callers), the HTTP handler (an explicit 409 with a message) and the app service. A race between them still ends in a refusal and never an unpark.
- `/api/mount/find-home` stays as an alias. `NetworkBackend.mountFindHome` keeps posting to it, so a newer client still works against an older desktop.

## Commands and exit codes
Unless noted, everything ran with `TMPDIR=$HOME/.cache/ns-tmp/h1-home` and `CARGO_TARGET_DIR=$HOME/.cache/ns-tmp/h1-home/target`.

| Command | Exit | Result |
|---|---|---|
| `melos bootstrap` | 0 | |
| `flutter_rust_bridge_codegen generate` (CC=clang, CPATH as in `scripts/dev.sh`) | 0 | |
| `cargo fmt --all -- --check` | 0 | |
| `cargo clippy --locked --all-features -p skotiq_bridge -p skotiq_native -p skotiq_indi -p skotiq_sequencer --all-targets -- -D warnings -D clippy::result_unit_err -D clippy::await_holding_lock -D clippy::undocumented_unsafe_blocks` | 0 | |
| `cargo test -j 8 -p skotiq_bridge -p skotiq_native -p skotiq_indi -p skotiq_sequencer` | 0 | bridge 756 passed (6 ignored), sequencer 1093 lib + integration, native 220, indi 121; all green |
| `melos run analyze` | 0 | |
| `dart format --output=none --set-exit-if-changed .` in skotiq_core, skotiq_app, apps/desktop and skotiq_bridge | 0 each | |
| `flutter test --exclude-tags golden --concurrency=6` in skotiq_core | 0 | 6904 passed, 4 skipped |
| `flutter test --exclude-tags golden --concurrency=6` in skotiq_app | 0 | 4604 passed |
| `flutter test --exclude-tags golden --concurrency=6` in apps/desktop | 0 | 1311 passed |
| `flutter test --tags golden` in skotiq_app | 0 | 23 passed, no golden changed or regenerated |
| `dart run tools/production/headless_route_policy_audit.dart` | 0 | 0 issues |
| `dart run tools/production/behavioral_audit.dart … --fail-on-unregistered --fail-on-open` | 1 | see below |

The behavioral audit exits 1 at base `9b96d59bf` as well, with the same 51 unregistered findings (checked on a `git archive` of HEAD). All of them are in files this work did not touch. This work moved five registered rows: four in `unified_device_ops/device_ops.rs` and one in `executor/preflight.rs`. Those rows were re-pointed to the new line numbers, and no finding in a touched file is left unregistered.

## Left over
- **Windows-only code not compiled here.** The ASCOM wrapper changes and their three tests are under `#[cfg(windows)]`, so nothing in this Linux build compiled them. They need the Windows CI job, or a build on the imaging laptop.
- **ASCOM V3 FindHome blocks the COM worker.** `FindHome` is synchronous in ITelescopeV3, so Abort slew can only reach the driver once the call returns. The COM worker is shared, so other ASCOM devices also wait for the duration. Park has the same limit. ASCOM Platform 7 drivers that home asynchronously are not affected.
- **AtHome not read on INDI or iOptron.** INDI has no standard at-home property, and iOptron's `:GAS#` parser does not look trustworthy for a home flag. A home on either is reported as unconfirmed.
- **Already-home mount without AtHome.** A mount that is already at home but whose driver cannot report AtHome has nothing to move. The watcher reports that as "didn't move", which cannot be told apart from the NYX-101 case.
- **Never run on a real mount.** Home has not been tried on the NYX-101 or any other real hardware. The NYX-101 is expected to give the "didn't move" error.
