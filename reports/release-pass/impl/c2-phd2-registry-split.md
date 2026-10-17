# C2 — phd2-registry-split

Topic: "the PHD2 registry split named in the map (separate the client registry from
the guider-state registry)". Baseline `b07d91c9d` + the C1/B-fix tree. Behaviour-preserving
consolidation only.

## Scope decision, up front

The map's cross-cutting **Cluster 3** is titled "PHD2 registry" but is really two
different things wearing one name:

1. **`DeviceManager.devices` vs `AppState.devices`** — the cry-wolf bug where
   `api_get_connected_devices()` reads the DeviceManager registry while PHD2 registers
   only into `AppState`, so the app says "no guider connected" while the sequencer guides
   through it (`map/cross-cutting.md:196-240`).
   **NOT DONE HERE — deliberately.** Making PHD2 register through
   `DeviceManager::register_device` changes what `api_get_connected_devices` and
   `api_is_device_connected` return, i.e. it is the bug fix, not a refactor.
   Adjudication item 5 routes behaviour-adjacent items to a failing-test-first bug batch,
   and the C2 charter is explicit that behaviour-preserving is the whole point. The
   `c2-device-registry` agent reached the same conclusion independently and recorded it
   BLOCKED (`impl/c2-device-registry.md`, scope item 2). Recorded again here so the two
   logs agree; whoever fixes the cry-wolf must also re-test `hotplug.rs` arbitration,
   because the two registries key differently (`id` vs `(type, id)`).

2. **The duplication *inside* the PHD2 stack** — the client registry and the
   guider-state registry are each re-derived at every call site instead of being asked.
   That is mechanical, behaviour-preserving, and is what this batch did.

## What was consolidated

### Rust — `native/skotiq_native/bridge/src/api/phd2.rs`

| new canonical symbol | replaces | call sites re-pointed |
|---|---|---|
| `phd2_client()` (private async accessor over `PHD2_CLIENT`) | the verbatim 4-line block `let mut storage = get_phd2_storage().write().await; let client = storage.as_mut().ok_or_else(\|\| SkotiqError::NotConnected("PHD2".to_string()))?;` | **21** |
| `resolve_guider_backend()` + `enum GuiderBackend { Phd2, Builtin }` | the verbatim `if is_phd2_device_id(…) { return … } if device_id == builtin_guider::device_id() { return … } Err(OperationFailed("Unsupported guider device: {}"))` chain | **11** (`api_guider_start_guiding`, `_stop`, `_dither`, `_loop`, `_find_star`, `_set_lock_position`, `_get_lock_position`, `_deselect_star`, `_get_star_image`, `_get_status`, `_get_calibration`) |
| `pub(crate) const PHD2_DEVICE_ID` | the `"phd2_guider"` string literal | **7** — `phd2.rs` ×5 (`get_active_guider_id_for_ops` ×2, `connection_failed` ×2, the `DeviceInfo.id`, `remove_device`), `api/connection.rs:278` (`is_phd2_device_id`), `api/discovery.rs:799` (the discovery `DeviceInfo.id`) |

`phd2_client()` returns `tokio::sync::RwLockMappedWriteGuard<'static, Phd2Client>` via
`RwLockWriteGuard::try_map`, so the lock is held for exactly the same span as the
`storage` binding it replaces. `api_phd2_dither` still drops the guard before the
multi-second settle wait (`drop(storage)` → `drop(client)`); a test asserts the lock is
released on the error path too, since `try_map` returns the guard inside its `Err`.

### Dart — `packages/skotiq_core`

`isPhd2WireToken(String)` (`lib/src/utils/device_id.dart`) is now the single source of
truth for the four PHD2 id spellings. It is the old private `_isPhd2Token` promoted and
documented; its 4 in-file callers are unchanged, and
`isPhd2GuiderDeviceId` (`lib/src/services/phd2_status_poll.dart:46`) now delegates to it
instead of carrying its own copy of the list. Not exported from the package barrel — the
normalizing wrappers stay the public API, so no package surface changed.

## Divergences preserved, NOT unified (the mad_sigma standard)

1. **`isPhd2DeviceId` vs `isPhd2GuiderDeviceId` normalize differently.**
   `isPhd2DeviceId` does `isPhd2WireToken(id.trim().toLowerCase())`;
   `isPhd2GuiderDeviceId` matches exactly and tolerates `null`. So `'PHD2_GUIDER'` and
   `'  phd2  '` are PHD2 to the first and not to the second. Only the token list was
   shared; both wrappers keep their own normalization, and
   `test/utils/phd2_registry_parity_test.dart` pins the disagreement explicitly
   ("they DISAGREE on un-normalized input, on purpose") so a later cleanup that collapses
   them fails in CI rather than widening the remote-sync PHD2 short-circuit.

2. **The two PHD2 `DeviceInfo` literals genuinely differ** — `api/phd2.rs` (post-connect)
   uses `name: "PHD2"`, `driver_version: ""`, `description: "PHD2 Guiding at {host}:{port}"`;
   `api/discovery.rs` uses `name: "PHD2 Guiding"`, `driver_version: "PHD2"`,
   `description: "PHD2 Guiding (Running|Installed)"`. Three of nine fields differ, and the
   difference is meaningful (one describes a live socket, the other an offer). Only the
   **id** was consolidated onto `PHD2_DEVICE_ID`; no `phd2_device_info()` builder was
   introduced, because parameterizing three of nine fields buys nothing and would invite a
   future "harmonization" that changes what the equipment list shows.

3. **`equipment_status_widget.dart:345` and `guider_step.dart:200` were left alone.**
   They look like the token list but are not: the first is a driver-type heuristic
   (`lower.contains('phd2') || lower.contains('phd 2')` — deliberately fuzzy, matches ids
   `isPhd2WireToken` rejects), the second is a prefix-only onboarding check
   (`!guiderId.startsWith('phd2:')`, which does not accept `phd2_guider`). Unifying either
   would change behaviour.

## Skipped — owner-decision zone

`packages/skotiq_bridge/lib/src/bridge_stub.dart:71` (`_isPhd2DeviceId`) is a fourth
copy of the token list, and `bridge_stub/guiding_operations.dart` re-derives the
`normalizedDeviceId == 'phd2_guider'` backend choice at 9 sites. Both live in the Dart
fallback device stack that `RELEASE-PASS-2026-08-11.md` § "Owner decisions" lists as
delete-or-document (2,656 lines). Not touched. If the owner keeps that stack, those sites
should be re-pointed at `isPhd2WireToken` / a Dart twin of `resolve_guider_backend` in a
follow-up.

## Parity tests added

- `native/skotiq_native/bridge/src/api/phd2.rs` → `mod registry_split_tests` (6 tests):
  all four PHD2 spellings plus the degenerate `"phd2:"` resolve to `GuiderBackend::Phd2`;
  the built-in id resolves to `Builtin`; unknown ids reproduce the retired error string
  **verbatim** for the empty id, the `phd2x-not-really-phd2` near-miss, an ASCOM id, and
  the case-flipped `PHD2_GUIDER` (case-sensitivity was and stays exact);
  `phd2_client()` yields `NotConnected("PHD2")` — the client id, not the device id — with
  an empty slot, and releases the write lock on that error path (a 2 s timeout would
  catch a leaked guard).
- `packages/skotiq_core/test/utils/phd2_registry_parity_test.dart` (10 tests):
  the shared token list, the two wrappers' shared acceptances/rejections, their deliberate
  disagreement, `null` handling, and `canonicalGuiderId` round-tripping.

## Verification

- `cargo build -p skotiq_bridge` — clean, no new warnings.
- `cargo test -p skotiq_bridge` — **544 passed, 0 failed, 4 ignored**, of which 6 are
  the new parity tests. Includes `device_manager::tests::disconnect_phd2_via_generic_route_calls_phd2_disconnect`,
  which pins `is_phd2_device_id` over the same four spellings.
- `cargo test -p skotiq_imaging phd2` — 12 passed; the C1/B-fix framing, settle-waiter
  and JSON-RPC tests are untouched and green.
- `cargo clippy -p skotiq_bridge --all-targets` — the only 2 warnings are pre-existing
  and in files this batch did not touch (`device_manager/ops/weather.rs:254`,
  `sim_capture.rs:434`).
- `cargo fmt -p skotiq_bridge -- --check` — clean.
- `flutter test` on `test/utils/phd2_registry_parity_test.dart`,
  `test/utils/device_id_test.dart`, `test/services/phd2_status_poll_test.dart` — 40 passed.
- `flutter test` (full `skotiq_core` suite) — **5771 passed, 4 skipped, 0 failed**.
- `flutter analyze lib test` (skotiq_core) — 2 pre-existing infos in
  `test/database/restore_clears_recovery_marker_test.dart`, unrelated.
- `dart format --set-exit-if-changed` on the 3 touched Dart files — clean.

## FRB

No regeneration needed and none attempted: no `pub` signature changed. `PHD2_DEVICE_ID` is
`pub(crate)`, `phd2_client` / `resolve_guider_backend` / `GuiderBackend` are private, so
none of them reach the FRB surface. `frb_generated.rs` still compiles unmodified and still
carries all 55 `api_guider_*` references.

## Files touched

- `native/skotiq_native/bridge/src/api/phd2.rs`
- `native/skotiq_native/bridge/src/api/connection.rs`
- `native/skotiq_native/bridge/src/api/discovery.rs`
- `packages/skotiq_core/lib/src/utils/device_id.dart`
- `packages/skotiq_core/lib/src/services/phd2_status_poll.dart`
- `packages/skotiq_core/test/utils/phd2_registry_parity_test.dart` (new)
