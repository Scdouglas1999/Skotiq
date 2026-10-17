# S2 — phd2-crywolf

Batch: the PHD2 cry-wolf the C2 `phd2` topic deferred
(`impl/c2-phd2-registry-split.md` scope item 1, `map/cross-cutting.md` Cluster 3,
`RELEASE-PASS-2026-08-11.md:337-339`). Baseline: HEAD `b07d91c9d` + the committed
C1/B-fix/C2 tree. This is a **behaviour change on purpose**, so: failing test first.

## The defect, reproduced

`api_get_connected_devices()` / `api_is_device_connected()`
(`bridge/src/api/connection.rs:312-321`) read the **DeviceManager** registry.
`api_phd2_connect` registered the guider only in the **AppState** mirror
(`api/phd2.rs:361`, under a comment claiming the opposite: _"This ensures
api_get_connected_devices() returns the guider"_). Grep for `get_device_manager`
in `api/phd2.rs` still found 0 registration hits at HEAD.

So after a successful PHD2 connect the app answered "no guider connected" on
every surface that asks those two APIs, while `get_active_guider_id_for_ops`
(AppState) resolved `phd2_guider` and the sequencer guided through the very same
client all night.

**Failing test at HEAD**, driving the production entry point against a mock PHD2
socket (`api/phd2.rs` → `mod connected_devices_crywolf_tests`):

```
api_get_connected_devices must list the connected PHD2 guider; it listed []
```

A second test found a consequence nobody had named: the PHD2 arm of the generic
disconnect route (`device_manager/connection.rs:912`, added so a PHD2 socket is
torn down when the user disconnects through the normal route) was **dead code** —
`disconnect_device` bails at `Device not found: phd2_guider` twenty lines earlier,
because PHD2 was not in the registry it looks in. At HEAD:

```
assertion `left == right` failed: disconnect_device must find the registered PHD2 guider
  left: Err("Device not found: phd2_guider")
 right: Ok(())
```

Both failures were re-proved after the fix by disabling only the new registration
line and re-running (both fail), then restoring it (all 9 pass).

## The fix

`DeviceManager::register_connected_device(info)` — new, in
`device_manager/connection.rs`. `register_device` inserts as `Disconnected`
because the normal lifecycle is register-then-`connect_device`; a backend that
owns its own out-of-band transport (PHD2's JSON-RPC socket, opened by
`api_phd2_connect`, not by anything in `dispatch/`) has nothing for
`connect_device` to dispatch to and records the already-live connection instead.
`register_device` and the new method both delegate to one private `insert_device`
so the 10-field `ManagedDevice` literal is not duplicated.

`auto_reconnect` is forced false: `reconnection_loop` only picks up devices that
are `auto_reconnect && state == Error` and reconnects them through
`connect_device_internal`, which cannot re-open a transport it does not own.

`api_phd2_connect` now registers the same `DeviceInfo` in **both** registries;
`api_phd2_disconnect` clears both. The removal uses `unregister_device` (a plain
map removal) and never `disconnect_device`, which routes PHD2 ids back into
`api_phd2_disconnect` and would recurse.

## What deliberately did NOT change

- **AppState is untouched.** The C2 log warned that whoever fixes this must
  re-test `hotplug.rs` arbitration because the registries key differently
  (`id` vs `(type, id)`). `hotplug.rs:242` reads
  `get_state().get_all_device_states()` — AppState — and its input is
  bit-identical to before, because the AppState write was kept exactly as it was
  and only a second write was added. `get_active_guider_id_for_ops` and
  `api/storage.rs` likewise read AppState and are unchanged. The two registries
  are not collapsed here; that is the larger refactor the map proposes and it is
  not needed to stop the app lying.
- **The id keying is safe.** DeviceManager keys by `id` alone; `phd2_guider` is a
  single unique id, so there is no `(type, id)` collision to preserve.
- **No Dart edits.** No wire shape changed — `DeviceInfo` is unchanged and no
  `pub` FFI signature was added or altered, so no FRB regeneration (verified:
  `frb_generated.rs` contains **zero** references to `DeviceManager` or
  `register_device`; it compiles unmodified).
- `remote_sync_handler.dart:1271` ("PHD2 is not always listed in
  getConnectedDevices(); avoid clearing the guider chip…") was left in place. It
  is now belt-and-braces rather than load-bearing: `_applyConnectedDevice` will
  set the guider from the device list with the same id/name the PHD2 hydrate path
  uses (`phd2_guider` / `PHD2`), so the two paths agree instead of racing.

## Blast radius checked

- Every consumer of `api_get_connected_devices` filters by `device_type` before
  using an entry — `unified_device_ops.rs:419` (Camera),
  `api/polar_alignment.rs:427/1288` (Camera, Mount),
  `headless_api/handlers/auxiliary_handlers.dart:17`,
  `planetarium_handlers.dart:37/115` (Mount, Camera). A new Guider entry is inert
  to all of them.
- `DeviceManager::get_all_devices` / `get_devices_by_type` have **no** production
  callers (definitions only), so no all-device sweep can now hit PHD2.
- `disconnect_device` leaves ordinary devices registered as `Disconnected`; PHD2
  is fully unregistered by `api_phd2_disconnect`. That asymmetry matches what the
  AppState side already did (`remove_device`) and is what the tests pin.

## Noted, not fixed (could not be made to fail)

`api_connect_device(Guider, <phd2 id>)` (`api/connection.rs:198-228`) launches
PHD2 and then falls through to the generic register+`connect_device`, whose
native dispatch rejects `phd2_guider` with `Invalid device ID format`
(`dispatch/native.rs:33` requires `native:vendor:id`). That route has never
worked for PHD2 and has no live Dart caller — `device_service/connections.dart:655`
routes every PHD2 id to `phd2Connect`, and `:742` routes disconnects to
`phd2Disconnect`. Reaching it in a test requires PHD2 to be installed
(`is_phd2_running` → `launch_phd2` returns early otherwise), so it could not be
reproduced from a test and nothing speculative was added. Recorded for Wave D:
if a live rig can be made to take that route, the fix is to short-circuit PHD2
ids to `api_phd2_connect` rather than letting a failed dispatch flip the
now-`Connected` registry entry to `Error`.

## Tests

New, in `native/skotiq_native/bridge/src/api/phd2.rs`
(`mod connected_devices_crywolf_tests`), both driving the real
`api_phd2_connect` against a mock PHD2 TCP server that answers `get_app_state`
(all `wait_until_ready` needs):

1. `a_connected_phd2_is_visible_to_the_connected_devices_api` — after connect:
   listed by `api_get_connected_devices`, `api_is_device_connected` agrees, and
   the AppState mirror still answers; after `api_phd2_disconnect`: all three
   report it gone. Every answer is sampled BEFORE any assertion and the
   disconnect always runs, so a failure here cannot strand a live client in the
   process-global slot and fail the neighbouring tests instead.
2. `the_generic_disconnect_route_reaches_a_connected_phd2` — `disconnect_device`
   now finds PHD2, returns `Ok`, and the client slot is empty afterwards (proof
   the socket was torn down, not just the bookkeeping cleared).

Supporting: a `PHD2_TEST_SLOT` mutex now serialises every test that touches the
process-global `PHD2_CLIENT`; the two pre-existing `registry_split_tests` that
assert the slot is empty take it too, so they cannot fail at random once a test
in the same binary stores a live client.

## Verification

- `cargo test -p skotiq_bridge --lib phd2` — 9 passed (7 pre-existing + 2 new).
- `cargo test -p skotiq_bridge` — **546 passed, 0 failed, 4 ignored**
  (C2 recorded 544 + the 2 new).
- `cargo build --workspace` — clean.
- `cargo clippy -p skotiq_bridge --all-targets` — 2 warnings, both
  pre-existing and in untouched files (`device_manager/ops/weather.rs:254`,
  `sim_capture.rs:434`) — the same two C2 recorded.
- `rustfmt --check` on the two touched files — clean.
- No GUI harness, no bundle rebuild (Wave D owns live-drive).

## Files touched

- `native/skotiq_native/bridge/src/api/phd2.rs`
- `native/skotiq_native/bridge/src/device_manager/connection.rs`
