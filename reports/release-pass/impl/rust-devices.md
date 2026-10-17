# Impl log — batch `rust-devices`

Baseline: b07d91c9d. Scope confirmed pristine at start
(`git status --porcelain -- native/skotiq_native/{indi,alpaca,ascom,native}` empty),
so no predecessor work to reconcile.

Items (adjudicated):
1. INDI BLOB path — Arc<[u8]>, spawn_blocking decode, skip property_values for blobs, clear latest_blobs in disconnect().
2. ZWO per-frame four-pass DIAGNOSTIC scan.
3. spawn_blocking the three serial mount-discovery scans.
4. Migrate nine hand-rolled vendor SDK loaders onto load_vendor_sdk!.
5. Dead-code sweep + writer-task connected-state fix.

## Progress

### Item 1 — INDI BLOB path (DONE, one sub-item blocked)

Tests written first; observed failing against the pre-fix code
(`cargo test -p skotiq_indi --lib`, 111 passed / 3 failed):
- `client::tests::test_parser_does_not_retain_blob_base64_in_property_values`
  → `BLOB base64 payload was retained in property_values: {("CCD","CCD1","Image"): "/9j/4AAA"}`
- `client::tests::test_disconnect_clears_cached_blobs_and_update_timestamps`
  → `cached BLOB survived disconnect`
- `client::tests::test_writer_task_marks_disconnected_on_write_error`
  → `writer task died without clearing the connected flag` (item 5's R6.2, done here
  because it shares the same file/test run)

Changes in `indi/src/client.rs`:
- `Event::Text` arm: BLOB bodies no longer go into `property_values` (non-BLOB text is
  now *moved* in, dropping the old `text.clone()` too). `property_updated_ms` still
  records the arrival, which the new test asserts.
- base64 decode moved to `tokio::task::spawn_blocking`; `JoinError` handled explicitly.
- `disconnect()` now clears `latest_blobs` and `property_updated_ms` (R6.1).
- `writer_task` takes `connected` + `event_tx`; on a write error it clears `connected`
  (via `swap`, so it fires once) and emits `Error` + `ConnectionStateChanged(false)`.
  A closed command channel — the ordinary `disconnect()` path — is unaffected
  (`test_writer_task_clean_shutdown_leaves_connected_untouched`).
- DC7: `_pending_number_limits` and its 3-String-per-`defNumber` allocation deleted;
  `elem_name`/`limits` are now moved into `number_limits` instead of cloned.
- Test harness: `drive_parser_full` added, exposing the decoded-BLOB cache;
  `drive_parser_with_updates`/`drive_parser` now delegate to it.

BLOCKED sub-item: "share one `Arc<[u8]>`". `IndiEvent::BlobReceived.data` is `Vec<u8>`
and is consumed outside my scope by `bridge/src/device_manager/ops/camera.rs:1055,1079`
through `let build_image = |data: Vec<u8>| -> ImageData` (:932); `take_blob`'s
`Option<Vec<u8>>` is consumed at :1071/:1074. Changing the element type to `Arc<[u8]>`
requires editing `bridge/`, which is another agent's scope. Everything else in item 1
landed. Result: `cargo test -p skotiq_indi` → 114 passed, 0 failed (+2 doc-tests).

### Item 2 — ZWO per-frame DIAGNOSTIC scan (DONE)

`native/src/vendor/zwo.rs`: the four-pass `info!`-level scan inside `download_image`
(held under `zwo_camera_mutex()`) is replaced by `FrameBufferStats::of`, one pass,
behind `tracing::enabled!(tracing::Level::DEBUG)` — zero cost at the default level.
The "every pixel identical" warning is kept inside the gate.
Parity tests (`cargo test -p skotiq_native --lib`, all green):
- `vendor::zwo::tests::frame_buffer_stats_match_the_four_pass_definition` (asserts
  min/max/mean/non-zero equal what the four separate iterator passes produced)
- `vendor::zwo::tests::frame_buffer_stats_of_a_flat_frame_report_equal_bounds`
- `vendor::zwo::tests::frame_buffer_stats_of_an_empty_buffer_is_none`

### Item 3 — serial mount-discovery scans (DONE)

Added `vendor::run_serial_scan(vendor, scan)` in `native/src/vendor/mod.rs`
(`spawn_blocking` + `JoinError` → `NativeError::SdkError`). `lx200`, `skywatcher` and
`ioptron` `discover_mounts()` are now three-line async wrappers over a private
blocking `scan_serial_ports()`; the scan bodies moved unchanged (verified no `.await`
existed inside any of them).
Test `vendor::tests::serial_scan_leaves_the_async_runtime_free_to_make_progress` runs a
200 ms synchronous scan on a `current_thread` runtime alongside a 20 ms timer and
asserts the timer completes first. Proven to fail against the inline shape:
`left: ["scan"] right: ["timer", "scan"]` — "the runtime was blocked for the duration
of the serial scan". Restored, green. Plus `serial_scan_propagates_the_scan_error`.

### Item 5 — dead-code sweep + writer-task fix (DONE)

Zero callers re-proved fresh, repo-wide (`grep -rn <symbol> packages apps native tools docs`
minus `target/`/`graphify-out/`/`build/`), plus an explicit check of
`{ascom,alpaca,native,indi,bridge}/tests/`. Every hit was a definition, a re-export line
or a doc comment; no headless route, FRB export, registry or string lookup reaches them.

- DC1 `ascom::probe_device_name` (~44 lines) deleted. Its only non-definition mention was
  `bridge/src/device_manager/connection.rs:612`, a doc comment explaining why it *cannot*
  be used. The discovery-loop NOTE that pointed users at it now states the real reason
  probing there is useless (an unconnected driver answers `Name` with a slot label).
- DC6 `AscomOperationGuard` / `AscomDisconnectable` / `AscomCleanupGuard` (124 lines).
- DC2 `AlpacaConnectionGuard` / `TelescopeOperationGuard` (107 lines). `with_alpaca_connection`
  and `AlpacaConnectable` kept — 12 live call sites in `bridge/src/real_device_ops.rs`.
  (DC3, the five unreached `AlpacaConnectable` impls, is not in my adjudicated list —
  left alone.)
- DC4 `AlpacaClient::get_long` / `get_very_long` (85 lines). `put_long` / `put_very_long`
  are live and untouched.
- DC7 `_pending_number_limits` — see item 1.
- Barrel edits, one atomic Edit per line: `ascom/src/lib.rs` ×4, `ascom/src/windows/mod.rs` ×1.
- R6.2 writer-task fix + its two tests — see item 1.

`cargo check -p skotiq_ascom --target x86_64-pc-windows-msvc` passes, so the ASCOM
deletions are verified on the platform that actually compiles that tree (Linux `cfg`s it out).

### Item 4 — vendor SDK loader migration (PARTIAL: 7 of 9 loaders)

`load_vendor_sdk!` was extended first, so no migration had to retype an FFI signature:
- a symbol's type may now be any `ty` — the vendor's existing `type FLIOpen = unsafe
  extern "C" fn(..)` alias goes straight in. Backward compatible: zwo's three existing
  inline-signature invocations are unchanged.
- new `optional_symbols: { .. }` section generates `Option<Fn>` fields resolved with
  `.ok()`, so an entry point a vendor added late (Atik EFW, `POAGetSDKVersion`,
  `gp_library_version`, `ArtemisRefreshDevicesCount`) can never fail the whole load.
- the singleton now stores `Result<Sdk, String>`, adding `get_or_reason()`,
  `load_error()` and `is_available()`. `get() -> Option<&'static Self>` is unchanged.

Migrated: `fli`, `svbony`, `moravian`, `atik`, `player_one` (both the camera and the
Phoenix filter-wheel SDK), `gphoto2`. With `zwo` that is 8 of the 11 loaders and 7 of the
9 the work order listed.

What each migration buys, beyond the dedup:
- `open_vendor_library` calls `ensure_libusb_global()`, so an SDK opened at *connect* time
  (not just inside `discover_all_devices`) now gets the libusb pre-load. SVBony is the SDK
  that aborts the process without it.
- symbol failures now carry `VendorLoadError::SymbolNotFound { vendor, library, symbol }`
  instead of `player_one`/`gphoto2`'s `.ok()?`, which returned `None` with no symbol name.
- `player_one`'s `?` on a symbol lookup used to return out of the `for path in &lib_paths`
  loop, so a first candidate that opened but lacked one symbol prevented later candidates
  from ever being tried. `open_vendor_library` separates opening from resolving.
- `moravian` gained the exe-relative / bundle `lib/` search (it only tried bare names).

Transcription safety — the risk that matters, since none of this is testable without the
vendor hardware. For all five newly-migrated vendor files I diffed the extracted
`field -> C symbol` map against the same map recovered from the b07d91c9d source:

    fli 35/35 IDENTICAL MAPPING     svbony 19/19 IDENTICAL MAPPING
    moravian 17/17 IDENTICAL        atik 38/38 IDENTICAL
    player_one 29/29 IDENTICAL      gphoto2 36/36 symbol sets EQUAL

Signatures were lifted as the vendors' own type aliases (fli/svbony/moravian/atik) or
copied verbatim out of the existing struct definitions (player_one/gphoto2); no signature
was retyped by hand. Candidate-path lists were moved verbatim and spot-checked against the
baseline diff (e.g. all seven PlayerOnePW paths).

NOT migrated, with reasons:
- `touptek` — the work order's own documented exception: it needs `HashMap<brand, Sdk>`
  keying for ~10 rebrands, which the macro's single `OnceLock` cannot express. Left
  hand-rolled; the module note now records that it should compose `open_vendor_library` +
  `resolve_symbol` instead.
- `qhy` — has a bespoke `resolve_qhy_symbol` plus a second `SDK_INITIALIZED` latch that
  sequences `InitQHYCCDResource` against symbol resolution; folding that into the macro
  changes initialization ordering on a device I cannot exercise. Left for a follow-up.
- `fujifilm` — Windows-only. `cargo check -p skotiq_native --target
  x86_64-pc-windows-msvc` cannot run here (`cc-rs: failed to find tool "lib.exe"`), so a
  migration would be unverifiable even for compilation. Left untouched.

Tests: `vendor::sdk_loader::tests::generated_loader_reports_why_an_absent_sdk_failed`,
`...::generated_loader_accepts_a_type_alias_signature`,
`...::optional_symbols_do_not_appear_in_the_required_list`,
`vendor::atik::sdk_loader_tests::efw_entry_points_stay_optional` (asserts no `efw_*` or
`refresh_devices_count` entry became mandatory — promoting one would make every
pre-EFW Atik SDK fail to load, hiding the camera too).

## Final state

- `cargo test -p skotiq_indi -p skotiq_alpaca -p skotiq_native -p skotiq_ascom`
  → 114 / 56 / 160 / 11 + integration + doc-tests, 0 failed.
- `cargo check --workspace --all-targets` → Finished, no errors or warnings (bridge included).
- `cargo clippy` on the four crates → clean.
- `cargo fmt -- --check` on the four crates → clean.
- `cargo check -p skotiq_ascom --target x86_64-pc-windows-msvc` → Finished.
- No `*.tmp.*` files in scope.
