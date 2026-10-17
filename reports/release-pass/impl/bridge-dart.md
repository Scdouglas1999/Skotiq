# Implementation log — batch `bridge-dart`

Scope: `packages/skotiq_bridge/**` (+ its test dir).
Work order: `reports/release-pass/map/bridge-dart.md`.
Baseline for every "before" claim: commit `b07d91c9d`.

Environment note that shapes two items below: **the native library cannot be
loaded under `flutter test` on this tree.** `DynamicLibrary.open` succeeds on
both the release-bundle and `target/debug` `libskotiq_bridge.so`, but
`RustLib.init()` then rejects it:

    Bad state: Content hash on Dart side (-1463207610) is different from
    Rust side (1439742888), indicating out-of-sync code.

(Other agents are editing Rust this wave, so no built `.so` matches the
checked-in `frb_generated.dart`.) `NativeBridge.isNativeAvailable` is therefore
`false` in every unit test, and any branch gated on `_nativeAvailable == true`
is unreachable from a Dart test. This corrects the previous session's log entry,
which claimed the native branch had been driven under `LD_LIBRARY_PATH`; it had
not.

Final state: `flutter analyze` clean, `flutter test` **123 passed**,
`dart format --set-exit-if-changed` clean over every touched file.

---

## Item 1 — DELETE the shadow Dart INDI discovery (DONE)

Re-proved fresh before keeping the deletion:

* Production caller is the **generated/Rust** function —
  `skotiq_core/lib/src/backend/ffi_backend/discovery_camera_operations.dart:44`
  calls `bridge_api.apiDiscoverIndiAtAddress(host:, port:)`, a top-level call.
* The headless route `apps/desktop/.../device_discovery_handlers.dart:226` goes
  through `backend.discoverIndiAtAddress`, i.e. the same FFI backend path.
* `grep -rn "NativeBridge\.apiDiscoverIndiAtAddress\b" --include=*.dart packages apps server tools`
  → zero hits.

Deleted: the facade entry, the impl and `_parseIndiDevices`
(`discovery_operations.dart`, −187 lines, pure removal — the diff adds nothing),
and `test/indi_discovery_parsing_test.dart` (203 lines, its only caller).
`import 'package:xml/xml.dart'` dropped from `bridge_stub.dart`.

Not done, and worth a Rust-side follow-up: the XML fixtures were **not** ported
to a `#[test]` against `indi/src/discovery.rs infer_device_type`. `native/**` is
outside this batch's scope.

## Item 2 — DELETE `test/fakes/` (DONE, with a scope correction)

`fake_native_bridge.dart` (1400), `fake_native_bridge_test.dart` (305) and
`fakes.dart` (8) are gone. Re-proof:

* `grep -rn "FakeNativeBridge\|fake_native_bridge"` over `packages apps server tools`
  now returns only a stale comment in
  `packages/skotiq_app/test/harness/mock_backend.dart:13-21`, which explains
  why the fake was *not* used. That file is another batch's scope; flagged, not
  touched.
* The `../fakes/fakes.dart` imports that grep turns up in `skotiq_core/test/`
  resolve to **skotiq_core's own** `test/fakes/fakes.dart`, a different file.

**Correction to the item as written:** `test/fakes/` cannot be deleted
*entirely*. `test/fakes/fake_phd2_server.dart` has three live consumers
(`phd2_rpc_test.dart`, `phd2_event_parsing_test.dart`, and the new
`phd2_framing_test.dart`). That part of the item is a false positive; the three
files the work order §3.1 actually names are all deleted.

## Item 3 — DELETE the zero-caller `NativeBridge` facade members (DONE, 36 of 40)

Re-proved each of the 40 names fresh with
`grep -rn "NativeBridge\.<name>\b" --include=*.dart packages apps server tools`,
excluding the facade file itself: all 40 had zero callers. Also checked the
generated-API shadowing the work order called out — e.g. `mountMoveAxis` and
`mountAbort` reach `bridge_api.mountMoveAxis`, never the facade.

Deleted: 36 facade entries and their impls across `equipment_operations`,
`connection_operations`, `storage_and_image_operations`, `runtime_operations`,
`sequencer_operations` and `guiding_operations`. `import 'package:ffi/ffi.dart'`
went with `getNativeVersion`. Three empty section headers left behind by the
deletions were removed (`Session Management`, `Autofocus`, `Image Processing` /
`Cleanup`).

Impls retained for the three the item names as **Keep**:
`sequencerSubscribeEvents` (called by `sequencerStart`),
`invalidateDiscoveryCache` (`runtime_operations.dart:341`, and the public
`discoverDevices` doc points at it), `isNativeAvailable` (live caller at
`apps/desktop/lib/desktop_logging_init.dart:118`). All three keep their facade
entries too, so the "Keep" reads true under either interpretation.

**Four of the 40 retained, with reasons:**

| Member | Why it stayed |
|---|---|
| `phd2AutoSelectStar` | `_NativeBridgeImplementation` is private, so the facade is the only seam through which item 6's fix can be tested at all. Deleting it would retire the fix instead of landing it. |
| `getSequencerState` | Sole reader of `_sequencerState`. |
| `isSimulationMode` | Sole reader of `_simulationMode`. |
| `loadedSequenceJson` | Sole reader of `_loadedSequenceJson`. |

The last three were deleted first, and the analyzer immediately reported all
three impls as `unused_element` — deleting those too leaves three write-only
fields, which is exactly the §3.4 hazard this pass removes, and unwinding
*those* means editing the six sequencer lifecycle methods that item 7 fences off
as "verbatim". Retaining five lines of delegation is the behaviour-preserving
call. Marked in the source with a one-line reason each.

Also removed as unused package dependencies (their only importers were deleted
above): `xml` (INDI parsing, item 1) and `ffi` (`getNativeVersion`, item 3).
`apps/desktop` declares its own `ffi`; nothing outside the bridge imported
`package:xml`.

## Item 4 — DELETE `_initializeDefaultStates` (DONE)

`_initializeDefaultStates()` and its call site are gone, along with
`_cameraStatus` / `_mountStatus` / `_focuserStatus` / `_filterWheelStatus` and
the three getters. `grep` over `lib/` for those field and getter names now
returns nothing but the unrelated `getCameraStatus`-family methods. The
fabricated 4144×2822 sensor and 7-slot LRGB+SHO wheel are no longer in the tree.

## Item 5 — BUG: `Phd2Client` receive buffer (DONE)

Test first: `test/phd2_framing_test.dart` (4 tests), plus `sendChunk` /
`sendRawBytes` on `test/fakes/fake_phd2_server.dart` so one JSON frame can be
put on the wire as two real TCP segments.

**Verified against the baseline myself** by restoring
`git show b07d91c9d:.../phd2_client.dart` over the fixed file:

    00:06 +0 -4: Some tests failed.
      an event split across two TCP segments is parsed                [E]
      an RPC reply split across two TCP segments completes            [E]
      a frame split mid multi-byte UTF-8 character survives           [E]
      a whole-frame UTF-8 payload is decoded, not byte-widened        [E]

Fix (kept from the previous session, reviewed line by line):
`_rxBuffer` promoted from a per-packet local to a field; a chunked
`Utf8Decoder(allowMalformed: true)` feeds it through `_StringBufferSink`,
replacing `String.fromCharCodes` (which byte-widened every non-ASCII
character); `_processBuffer()` splits on `\r\n` and carries the trailing partial
line forward in the field; `_resetReceiveBuffer()` runs from `_handleDisconnect`
so a reconnect never resumes mid-frame or mid-character.

Post-fix: 4/4 pass; `phd2_event_parsing_test.dart` and `phd2_rpc_test.dart` pass
unchanged.

## Item 6 — BUG: inverted guard in `phd2AutoSelectStar` (DONE, test replaced)

The defect is real and provable: at baseline,
`guiding_operations.dart:545` is `if (_nativeAvailable) { _nativeBridgeRequired('phd2AutoSelectStar'); }`
— the only unnegated `_nativeAvailable` guard in the package — so on every build
where the native library loads, the method throws
`Operation "phd2AutoSelectStar" requires the native bridge.`

The previous session's behavioural test **does not fail against the baseline**;
I ran it, and it passes, because `_nativeAvailable` is `false` under
`flutter test` (see the environment note above) so the inverted branch is never
entered. Rather than claim a proof I could not reproduce, I replaced it with a
test that pins the guard's *polarity* from the source and does fail:

`test/native_guard_contract_test.dart` →
`native-availability guard polarity › every _nativeBridgeRequired sits under a negated guard`.

Against the baseline file on the tree:

    Expected: empty
      Actual: ['lib/src/bridge_stub/guiding_operations.dart:545: if (_nativeAvailable) {']

After restoring the fix: 2/2 pass. The behavioural test is kept as the second
case in the same file — it pins the reachable half (the refusal must name PHD2
connectivity, not a missing bridge) and its docstring says plainly which half it
covers.

Fix: the inverted guard is dropped. There is no `apiPhd2AutoSelectStar` in the
generated API, so the Dart client is the only implementation in either mode; the
doc comment now says so.

## Item 7 — REFACTOR: `_native<T>` helper in `sequencer_operations.dart` (DONE)

Added `_native<T>(String op, Future<T> Function() body, {String? okLog})` as a
private member of the existing `_NativeBridgeSequencerOperations` extension — in
place, no new part file, no split. 24 pass-through methods collapsed onto it;
**1057 → 615 lines**.

Left verbatim (11): `sequencerSubscribeEvents`, `sequencerLoadJson`,
`sequencerStart`, `sequencerPause`, `sequencerResume`, `sequencerStop`,
`sequencerReset`, `sequencerResumeFromCheckpoint`, `sequencerSetSimulationMode`
(all mutate Dart-side state), plus `sequencerGetStatus` and
`sequencerGetCheckpointInfo` (progress computation / FRB→local type mapping).
`getSequencerState`, `isSimulationMode`, `loadedSequenceJson` have no try/catch
and are untouched.

Behaviour-preservation evidence:

1. **Every native call is still there.** Diffing the sorted set of
   `gen_api.api*` call sites before/after, the only differences are the four
   methods item 3 deleted (`apiEventStream`,
   `apiSequencerClearDefaultAdaptiveExposure`,
   `apiSequencerUpdateDefaultAdaptiveExposure`, `apiSequencerUpdateSkyBrightness`).
   No call was dropped, added or swapped.
2. **Argument wiring is unchanged.** Diffing the sorted set of `name: value,`
   pairs before/after leaves only lines belonging to the deleted methods and to
   four calls that became single-line (`configJson:`, `enabled:`,
   `everyNFrames:`), each checked by eye.
3. **New parity test** — `test/sequencer_native_guard_parity_test.dart`, 36
   tests: all 35 sequencer operations (24 collapsed + 11 verbatim) must still
   fail closed *under their own name*, which is the one thing the string-keyed
   helper can silently get wrong. All pass.
   Proved the test bites: renaming one op to `'sequencerSaveCheckpointX'` gives
   `00:00 +23 -1: ... sequencerSaveCheckpoint refuses under its own name [E]`.
   Reverted immediately.

Deliberate, documented behaviour change: the failure log text for the 24
collapsed methods moves from a bespoke phrase (`'Error setting sequencer
devices: $e'`) to `'Error in <op>: $e'`, per the work order's prescribed helper
signature. Grepped first — nothing outside `bridge_stub/` asserts on those
strings. Success-log text is preserved verbatim via `okLog`.

## Left untouched, as instructed

The Dart fallback device stack (`phd2_client`, `alpaca_client`, `ascom_client`,
`utils/retry`, `utils/circuit_breaker`, `rolling_rms_calculator`) — owner
decision pending on work-order §2.2. Item 5's fix lands inside `phd2_client`
because it was named as a BUG item, but nothing was deleted there.

## Not attempted / handed on

* Work-order §3.3 (`_connectAscomDevice` unreachable, `AscomDeviceClient` dead)
  is part of the §2.2 fallback-stack decision and was not in this batch's item
  list.
* §5.3 (`ImageStats.mad` populated from `stdDev`) is now moot in the facade —
  `apiGetImageStats` was deleted under item 3 — but the same mapping may exist
  elsewhere; not checked outside this package.
* Stale comment in `packages/skotiq_app/test/harness/mock_backend.dart:13-21`
  refers to the now-deleted `FakeNativeBridge`. Other batch's scope.
