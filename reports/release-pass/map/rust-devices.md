# Release-pass map — Rust device crates (indi / alpaca / ascom / native)

Subsystem: `native/skotiq_native/{indi,alpaca,ascom,native}/src/`
Mode: read-only mapping. No source file was edited.
Date: 2026-08-11. Branch: `audit/end-to-end-campaign` @ b07d91c9d.

All line counts below were taken with `wc -l`. **None of these files is generated** —
there is no `frb_generated` / `*.g.*` file anywhere under these four crates (the only
generated Rust in the workspace is `bridge/src/frb_generated.rs`, which is out of scope).
Every file listed is hand-written.

---

## 1. OVERSIZED FILES (Rust threshold ~1500 lines)

Fifteen files qualify. Ten of them are vendor drivers that share **one identical internal
shape**, so §1.2 gives a single reusable recipe rather than repeating it ten times.

| File | Lines |
|---|---|
| `native/skotiq_native/indi/src/client.rs` | 4146 |
| `native/skotiq_native/native/src/vendor/zwo.rs` | 3928 |
| `native/skotiq_native/native/src/vendor/qhy.rs` | 3015 |
| `native/skotiq_native/native/src/vendor/fujifilm.rs` | 2976 |
| `native/skotiq_native/native/src/vendor/gphoto2.rs` | 2973 |
| `native/skotiq_native/alpaca/src/camera.rs` | 2391 |
| `native/skotiq_native/native/src/vendor/touptek.rs` | 2295 |
| `native/skotiq_native/native/src/vendor/atik.rs` | 2135 |
| `native/skotiq_native/native/src/vendor/player_one.rs` | 2134 |
| `native/skotiq_native/native/src/vendor/fli.rs` | 1947 |
| `native/skotiq_native/native/src/vendor/svbony.rs` | 1853 |
| `native/skotiq_native/native/src/vendor/moravian.rs` | 1807 |
| `native/skotiq_native/alpaca/src/client.rs` | 1767 |
| `native/skotiq_native/native/src/vendor/lx200.rs` | 1651 |
| `native/skotiq_native/ascom/src/windows/connection.rs` | 1601 |

### 1.1 `indi/src/client.rs` — 4146 lines

**Why it is big.** One `impl IndiClient` block spans lines 587–2710 (2123 lines) and
contains *four* separable concerns: connection lifecycle, the XML stream parser, the
property get/set API, and the keepalive/reconnect supervisor. The single largest unit is
`reader_task_with_timeout` at **lines 1060–1799 — a 739-line function** holding the whole
XML state machine in one `loop { match read_result { … } }`. A further 1252 lines
(2894–4146) are the `#[cfg(test)] mod tests`.

**Split plan** (module directory; all names below are new files under `indi/src/client/`,
with `indi/src/client.rs` becoming `indi/src/client/mod.rs`):

| New file | Moves from `client.rs` | Contents |
|---|---|---|
| `client/mod.rs` | 1–56, 265–586, 587–774, 1799–1902, 2888–2893 | `IndiClient` struct + `new`/`with_*_config` ctors + config accessors + `subscribe`/`clear_blob`/`take_blob` + `connect`/`disconnect`/`is_connected`/`send_command` + `impl Default`. Declares the submodules and re-exports everything currently `pub` so the crate's public surface is byte-identical. |
| `client/config.rs` | 286–443 | `ReaderStatus`, `ReaderTaskConfig` (+`Default`,`impl`), `ProtocolConfig` (+`Default`), `ReconnectionConfig` (+`Default`,`impl`). Pure data; no dependencies on the rest. |
| `client/event.rs` | 33–38, 114–170, 265–283 | `INDI_PROTOCOL_VERSIONS`, `DEFAULT_PROTOCOL_VERSION`, `EVENT_CHANNEL_CAPACITY`, `IndiEvent`, `send_indi_event`, `NumberLimits`, the four map type aliases. |
| `client/jitter.rs` | 48–113 | `JitterRng`, `make_jitter_rng`, `jitter_sample`. Self-contained. |
| `client/xml.rs` | 171–264, 444–543, 2710–2887 | The parse helpers: `parse_indi_number_attribute`, `parse_indi_usize_attribute`, `parse_indi_number_value`, `parse_indi_light_state_value`, `XmlContextKind`, `XmlContext`, `refresh_xml_context_mirrors`, `classify_indi_tag`, `parse_switch_rule`, `switch_rule_requires_exclusive_vector`, `map_get_2`/`map_get_mut_2`/`map_contains_2`/`map_get_3`, `get_attribute`, `parse_state`, `parse_perm`, `detect_blob_format`, `validate_blob_format`, `resolve_blob_format`, `is_version_compatible`. Mark each `pub(super)`. |
| `client/reader.rs` | 894–1799 | `writer_task`, `supervised_reader_task`, `reader_task_with_timeout`. All three are already *associated functions that take no `&self`* — they receive every piece of shared state as an `Arc` argument (see the 12-parameter signature at 1060–1073). **They can move verbatim as free `pub(super) async fn`s** with no borrow-checker work; only the `Self::` call prefixes at 808 and 856 change. |
| `client/reader/parse_loop.rs` | 1182–1798 (the match arms) | Optional second-stage split. Each arm becomes a free fn taking a `&mut ParserState` struct that owns the 8 loop-locals declared at 1098–1119 (`xml_stack`, `current_device`, `current_property`, `current_element`, `current_blob_format`, `current_blob_active`, `current_blob_size`, `blob_start_time`): `on_start_or_empty` (1182–1532), `on_text` (1533–1631), `on_end` (1632–1724), `on_eof` (1725–1734). This is the only part of the plan that needs real refactoring judgement; stage it after the file-level split lands and tests are green. |
| `client/properties.rs` | 1902–2400 | The read/write property API: `get_devices`, `get_properties`, `get_property`, `get_property_value`, `get_number_limits`, `get_number`, `get_switch`, `get_property_state`, `get_property_permission`, `is_property_busy`, `has_property`, `get_light_state`, `enable_blob`, `check_write_permission`, `validate_number_limits`, `get_property_last_update_ms`, `get_switch_rule`, `set_switch`, `set_switch_exclusive`, `set_number`, `set_numbers`, `set_text`, `connect_device`, `disconnect_device`, `is_device_connected`, `get_filter_names`, `wait_for_property_state`, `wait_for_property_not_busy`. Written as a second `impl IndiClient` block — Rust allows inherent impls split across modules of the same crate, so **no visibility changes are needed**. |
| `client/health.rs` | 1847–1901, 2400–2710 | `is_connected`, `reader_status`, `is_reader_healthy`, `reader_consecutive_failures`, `is_reader_failed_permanently`, `reset_reader_failures`, `send_keepalive`, `check_keepalive`, `do_keepalive_check`, `is_keepalive_in_progress`, `time_since_last_keepalive_response_ms`, `is_connection_healthy`, `reconnect_with_backoff`, `is_reconnecting`, `recover_reader`, `can_reconnect`, `reconnect_attempts`, `request_version`, `check_version_compatibility`. Also a second `impl IndiClient` block. |
| `client/tests.rs` | 2894–4146 | The whole `mod tests`. Include with `#[cfg(test)] mod tests;` from `mod.rs`. Note the test-only parser harness at 3907–3960 needs `pub(super)` access to `reader_task_with_timeout`. |

**Stays put:** the `IndiClient` struct definition (544–586) and its field list — every other
module reaches it through `&self`/`&mut self`.

**What must not change:** `IndiClient`'s fields stay private; `mod.rs` must `pub use` the
same set of names `indi/src/lib.rs` currently re-exports, or every consumer in `bridge/`
breaks. Verify with `cargo check -p skotiq_indi` plus a `git diff` of the crate's
public paths.

Result: no file above ~900 lines; the 739-line parse function becomes the only remaining
outlier and is isolated for the follow-up stage.

### 1.2 The ten vendor drivers — one recipe

`zwo.rs` (3928), `qhy.rs` (3015), `fujifilm.rs` (2976), `gphoto2.rs` (2973),
`touptek.rs` (2295), `atik.rs` (2135), `player_one.rs` (2134), `fli.rs` (1947),
`svbony.rs` (1853), `moravian.rs` (1807), `lx200.rs` (1651).

**Why they are big.** Every one of these files already contains explicit banner comments
delimiting the *same five sections* (verified in all ten — e.g. `atik.rs:18/102/634/859`,
`player_one.rs:58/85/255/638/1617/1988`, `fli.rs:17/59/423/606/1415/1686`,
`svbony.rs:22/253/520/619/1744`, `moravian.rs:35/100/153/287/400/521/531/1629`):

1. **FFI types + constants** — `#[repr(C)]` structs, error enums, `type … = unsafe extern "C" fn`.
2. **SDK loader** — the `…Sdk` struct of function pointers plus `load()`/`get()`.
3. **Discovery + SDK status** — `discover_devices`, `is_sdk_available`, `get_sdk_status`, `sdk_version`.
4. **Device implementations** — one `pub struct XCamera` + `impl NativeDevice` + `impl NativeCamera`, and in six files a *second and third* device (focuser / filter wheel) in the same file.
5. **`#[cfg(test)] mod tests`.**

**Uniform split plan.** For each vendor `V`, replace `native/src/vendor/V.rs` with a
directory `native/src/vendor/V/`:

| New file | Contents |
|---|---|
| `V/mod.rs` | `mod` declarations + the `pub use` list. Must re-export exactly the names `native/src/vendor/mod.rs` and `native/src/discovery.rs` reference today (`discover_devices`, `discover_focusers`, `discover_filter_wheels`, `is_sdk_available`, `get_sdk_status`, `sdk_version`, the device structs, the `*DiscoveryInfo` structs). |
| `V/ffi.rs` | Section 1 verbatim. Everything `pub(super)`. |
| `V/sdk.rs` | Section 2 verbatim — the `…Sdk` struct, its `load`/`get`, the `static OnceLock`, the error-code mapper (`check_asi_error` / `check_qhy_error` / `check_poa_error` / `check_artemis_error` / `check_gp_error` / `check_xapi_error`), and the `sdk_version_from_sdk` helper. |
| `V/discovery.rs` | Section 3 verbatim. |
| `V/camera.rs` | The camera struct + both its trait impls + its private `impl` block. |
| `V/focuser.rs` | Only for `zwo` (EAF, 2153–2909) and `fli` (1415–1685). |
| `V/filter_wheel.rs` | Only for `zwo` (EFW, 2910–3596), `qhy` (2237–2803), `player_one` (1708–1987), `fli` (1686–1929), `atik` (1889–2134). |
| `V/tests.rs` | Section 5. |

**Per-file section boundaries already confirmed** (use these as the cut lines):

- `zwo.rs`: ffi 51–228 + 2153–2317 + 2910–3033; sdk 229–441 + 2187–2356 + 2942–3033; camera 442–2004; discovery 2005–2152 + 2723–2909 + 3433–3596; focuser 2358–2722; filter_wheel 3034–3432; tests 3597–3928.
- `qhy.rs`: ffi 49–226; sdk 227–763 (**note the hand-rolled loader at 310–551 — see D1**); camera 765–2042; discovery 2043–2236 + 2625–2803; filter_wheel 2237–2624; tests 2804–3015.
- `fujifilm.rs`: ffi 43–392; model table 393–560; sdk 561–908; discovery 909–1002; camera 1003–2156; raw helpers 2157–2250; tests 2251–2976.
- `gphoto2.rs`: ffi 46–290; sdk 291–611; discovery 574–697; camera 698–2626; helpers 2627–2789; tests 2790–2973.
- `touptek.rs`: ffi 32–247; sdk 248–689 (multi-brand — justified, see D1); tests-1 690–893; discovery 894–1057; camera 1058–2295. (Touptek has *two* `mod tests` regions; keep both in `V/tests.rs`.)
- `atik.rs`: ffi 18–189; sdk 190–633; discovery 634–858; camera 859–1888; filter_wheel 1889–2134.
- `player_one.rs`: ffi 58–254; sdk 255–637; camera 638–1616; discovery 1617–1762; filter_wheel 1763–1987; tests 1988–2134.
- `fli.rs`: ffi 17–127; sdk 128–422; discovery 423–605; camera 606–1414; focuser 1415–1685; filter_wheel 1686–1929; tests 1930–1947.
- `svbony.rs`: ffi 22–252; sdk 253–519; discovery 520–618; camera 619–1743; tests 1744–1853.
- `moravian.rs`: ffi 35–152; sdk 153–286; roi helpers 287–399; discovery 400–520; camera 521–1628; tests 1629–1807.
- `lx200.rs`: protocol/constants 1–477; mount 478–1245; discovery 1246–1530; tests 1531–1651.

**Sequencing.** Do `zwo.rs` first — it is the largest, it is the only vendor already on the
shared `load_vendor_sdk!` macro, and it contains three devices, so it exercises every branch
of the recipe. Land it, confirm `cargo test -p skotiq_native` is unchanged, then batch
the rest.

### 1.3 `alpaca/src/camera.rs` — 2391 lines

**Why it is big.** Three unrelated things: (a) ~90 one-line HTTP property wrappers on
`AlpacaCamera` (lines 219–1155), (b) two *complete wire-format decoders* — the JSON
`ImageArray` decoder (1156–1444) and the binary `ImageBytes` decoder (1445–1870), and
(c) 520 lines of decoder tests (1871–2391).

**Split plan** — `alpaca/src/camera.rs` → `alpaca/src/camera/`:

- `camera/mod.rs` ← 1–1155. `CameraState`, `SensorType`, `CameraStatus`, `CameraCapabilities`, `CameraSensorInfo`, `CameraSubframe`, `CameraFullStatus`, `ImageArrayElementType`, `ImageArrayResult`, `AlpacaCamera` + ctors + all property accessors + `wait_for_image_ready` / `wait_for_idle` / `get_status` / `get_capabilities` / `get_sensor_info` / `get_subframe` / `get_full_status`. Declares `mod image_array; mod image_bytes;`.
- `camera/image_array.rs` ← 1156–1444 + tests 1871–2068. `parse_rank2`, `parse_rank3`, `decode_pixel`, `clamp_i64_to_u16`, `clamp_f64_to_u16`, `shorten_json`. These are currently private file-scope `fn`s; make them `pub(super)`.
- `camera/image_bytes.rs` ← 1445–1870 + tests 2069–2391. `IMAGE_BYTES_HEADER_SIZE`, `read_i32_le`, `read_u32_le`, `transmission_type_from_code`, `transmission_element_size`, `decode_wire_sample`, and the ImageBytes header parser.
- Move `download_image_data`, `download_image_data_typed` and `download_image_array_full_typed` (616–797) into `camera/download.rs` — they are the only members of the property-wrapper impl that touch the decoders, and keeping them next to `mod.rs` forces `mod.rs` to import both decoder modules.

`ImageArrayElementType` must stay in `mod.rs` (both decoders use it) and be `pub(super)`-visible.

### 1.4 `alpaca/src/client.rs` — 1767 lines

**Why it is big.** Error type + two config types + retry policy + the HTTP client + a
builder + 360 lines of tests, all in one file. Section boundaries are clean.

**Split plan** — `alpaca/src/client.rs` → `alpaca/src/client/`:

- `client/error.rs` ← 17–228. `AlpacaError`, `impl AlpacaError`, `From<reqwest::Error>`, `From<serde_json::Error>`, `From<AlpacaError> for String`.
- `client/config.rs` ← 229–458. `TimeoutConfig` (+`Default`, the seven `for_*` presets), `RetryConfig` (+`Default`, `delay_for_attempt`, `delay_for_retry_error`, `no_retry`), `rand_simple`, `parse_retry_after_header`, `parse_retry_after_value`.
- `client/version.rs` ← 460–514. `ApiVersion`, `as_str`, `negotiate`.
- `client/mod.rs` ← 13–16, 491–533, 534–1344. `NEXT_CLIENT_ID`, `decode_put_response`, `AlpacaResponse<T>`, `ApiVersionsResponse`, `AlpacaClient` and its impl.
- `client/builder.rs` ← 1346–1405. `AlpacaClientBuilder`.
- `client/tests.rs` ← 1406–1767.

While in there, apply D4 (collapse the five duplicated verb methods) — the split makes the
duplication visible in one 200-line file rather than spread over 1300.

### 1.5 `ascom/src/windows/connection.rs` — 1601 lines

**Why it is big.** Registry scanning, COM lifecycle, ~30 typed `IDispatch` invoke wrappers,
a mock trait, and three RAII guard types. This whole tree is `#[cfg(windows)]`, so nothing
here is exercised by the Linux CI gates — split it carefully and verify on the Windows runner.

**Split plan** — `ascom/src/windows/connection.rs` → `ascom/src/windows/connection/`:

- `connection/registry.rs` ← 33–318. `init_com`, `uninit_com`, `discover_devices`, `push_unique_device`, `scan_registry_path`, `get_driver_description`, `probe_device_name` (**but see DC1 — `probe_device_name` should be deleted, not moved**), and the `mod tests` at 90–120.
- `connection/mod.rs` ← 319–1105, 1133–1205. `AscomDeviceConnection`, `InvokeError`, `Display`, the full typed-invoke impl, `Drop`, the `unsafe impl Send/Sync`.
- `connection/backend.rs` ← 1106–1132. `AscomConnectionBackend` trait + `mockall` attribute + the `impl … for AscomDeviceConnection`.
- `connection/guards.rs` ← 1206–1335. `AscomOperationGuard`, `AscomDisconnectable`, `AscomCleanupGuard` (**see DC6 — all three are dead; prefer deleting this file over creating it**).
- `connection/tests.rs` ← 1336–1601.

If DC1 and DC6 are actioned first the file drops to ~1150 lines and the split becomes
optional; do the dead-code removal first and re-measure.

---

## 2. DUPLICATION

### D1 — Vendor SDK loading: one shared macro, nine hand-rolled copies (large)

`native/src/vendor/sdk_loader.rs` is the canonical layer. It provides
`vendor_library_candidates()` (path search), `open_vendor_library()` (first-that-loads walk
with per-path tracing, `sdk_loader.rs:212`), `resolve_vendor_symbol()` (typed per-symbol
error), and the `load_vendor_sdk!` macro (`sdk_loader.rs:348`) that assembles all three into
a `OnceLock<Option<Sdk>>`.

**Only `zwo.rs` uses it** — three times (`zwo.rs:297`, `2210`, `2965`). Confirmed with
`grep -ln "load_vendor_sdk!" native/src/vendor/*.rs` → `mod.rs`, `sdk_loader.rs`, `zwo.rs`.

Nine vendors instead hand-roll their own load loop with a raw `libloading::Library::new`:
`fujifilm.rs:710`, `fli.rs:199`, `moravian.rs:192`, `player_one.rs:339` and `:398`,
`gphoto2.rs:352`, `atik.rs:265`, `touptek.rs:331`, `svbony.rs:373`, and `qhy.rs`
(`load_qhy_sdk` at `qhy.rs:346–551`, with its own `resolve_qhy_symbol` at `qhy.rs:331`).
`sdk_loader.rs:174` even documents the consequence: *"most vendors use their own
`Library::new`, not `open_vendor_library`"*.

Three concrete costs, not just tidiness:

1. **Lost diagnostics.** The hand-rolled loaders resolve symbols with
   `*lib.get(b"POAGetCameraCount\0").ok()?` (`player_one.rs:401` and ~40 sibling lines).
   A missing symbol makes `load()` return `None` with **no log naming which symbol failed** —
   the user sees "SDK not found" for an SDK that is present but a version too old.
   `resolve_vendor_symbol` returns `VendorLoadError::SymbolNotFound { vendor, library, symbol }`.
2. **Abandoned candidate paths.** In `player_one.rs:396–420` the `?` on a symbol lookup
   returns from `load()` *out of the `for path in &lib_paths` loop*, so a first candidate
   that loads but is missing one symbol prevents the later candidates from ever being tried.
   `open_vendor_library` separates "did the library open" from "did the symbols resolve".
3. **libusb pre-load skipped.** `ensure_libusb_global()` is called from exactly two places
   (`sdk_loader.rs:218` inside `open_vendor_library`, and `discovery.rs:95`). Any vendor SDK
   opened outside `discover_all_devices` — i.e. at connect time — misses it.

**Canonical survivor:** `sdk_loader::load_vendor_sdk!`.
**Merges into it:** the loader sections of `fujifilm`, `fli`, `moravian`, `player_one`,
`gphoto2`, `atik`, `svbony`, `qhy`. Each becomes a `candidate_paths` fn + one macro invocation.
**Justified exception:** `touptek.rs:248–512` genuinely needs custom `OnceLock` keying
(a `HashMap<brand, Sdk>` for the ~10 rebrands in `TOUPTEK_BRANDS`); it should keep its own
loader but be refactored to call `sdk_loader::open_vendor_library` + `resolve_vendor_symbol`
for the two primitives (`sdk_loader.rs:155–163` explicitly documents this composition path).

Effort: large. Do it one vendor per commit; each is mechanical and independently testable
against `native/tests/native_driver_tests.rs`.

### D2 — Five implementations of "what is this camera's full-scale ADU" (medium)

| Location | Signature | Body |
|---|---|---|
| `zwo.rs:431` | `raw16_container_max_adu(bit_depth)` | left-justify into 16-bit container |
| `player_one.rs:476` | `raw16_container_max_adu(bit_depth)` | **byte-identical to zwo's** |
| `svbony.rs:167` | `container_max_adu(image_type, bit_depth)` | same expression in the `Raw16` arm; `Raw8` ⇒ 255 |
| `qhy.rs:672` | `container_max_adu(container_bits, actual_bits, high_aligned)` | the general form — subsumes all three above |
| `touptek.rs:633` | `max_adu_from_bit_depth(bit_depth)` | right-justified `(1<<bd)-1` |
| `fujifilm.rs:2204` | `resolve_max_adu(measured_white_level, bit_depth)` | right-justified, prefers a measured white level |
| `gphoto2.rs:2783` | `resolve_max_adu(measured_white_level, bit_depth)` | **byte-identical to fujifilm's** |

The duplicated *tests* travel with them: `raw16_container_max_adu_accounts_for_left_justification`,
`…_is_a_reachable_u16_sample`, `…_unknown_bit_depth_falls_back_to_container`,
`…_agrees_with_pipeline_saturation_threshold` appear in `zwo.rs:3610/3672/3692/3701`,
`player_one.rs:2004/2019/2040/2053` and `svbony.rs:1756/1771/1818` — roughly 180 lines of
copy-pasted test.

**Canonical survivors — two functions, both in `native/src/camera.rs`** (which already owns
the `bit_depth` vs `max_adu` contract doc at `camera.rs:118–153`):

- `pub fn container_max_adu(container_bits: u32, actual_bits: Option<u32>, high_aligned: bool) -> u32` — lift QHY's body verbatim.
- `pub fn resolve_max_adu(measured_white_level: Option<u32>, bit_depth: u32) -> u32` — lift fujifilm's body verbatim.

**Call-site rewrites, with the two behaviour deltas an implementer must not miss:**

- zwo `raw16_container_max_adu(bd)` → `container_max_adu(16, Some(bd), true)`. Equivalent for all inputs (`bd == 0` and `bd >= 16` both fall through QHY's `filter(|b| (1..container_bits).contains(b))` to `container_max`).
- player_one: same rewrite.
- svbony `container_max_adu(Raw8, _)` → `container_max_adu(8, None, false)` = 255 ✅; `container_max_adu(Raw16, bd)` → `container_max_adu(16, Some(bd), true)` ✅.
- **touptek `max_adu_from_bit_depth(bd)` → `container_max_adu(bd, None, false)` changes behaviour when `bd > 16`**: the current fn returns `(1<<bd)-1` (and `u32::MAX` at `bd >= 32`), the shared one clamps the container to 16 and returns 65535. `Ogmacam_get_RawFormat` reports 8/10/12/14/16 in practice, so this is unreachable today — but state it in the commit message rather than discover it later.
- fujifilm / gphoto2 → the shared `resolve_max_adu`, unchanged.

Then delete the duplicated test modules, keeping **one** copy next to the shared functions.
Effort: medium (touching 7 files, but each edit is 1–3 lines).

### D3 — Alpaca per-device boilerplate ×10 (medium)

Every `alpaca/src/<device>.rs` opens with the same block: `new`, `with_config`,
`from_server`, `builder`, `connect`, `disconnect`, `is_connected`, `validate_connection`,
`heartbeat`, `name`, `description`, `driver_version`, `driver_info`, `interface_version`,
`supported_actions`.

Proof: `diff` of `focuser.rs:30–135` against `rotator.rs:26–131` produces **six hunks, all of
which are the literal words "Focuser"→"Rotator"** (the struct name, two `AlpacaDeviceType`
constants, two doc comments, one section comment). 106 identical lines × 10 device modules.

Files: `camera.rs:219–322`, `telescope.rs:207–307`, `dome.rs:50–139`, `focuser.rs:35–134`,
`rotator.rs:31–130`, `filterwheel.rs:30–130`, `switch.rs:12–69`,
`covercalibrator.rs:90–170`, `safetymonitor.rs:36–162`, `observingconditions.rs:12–73`.

The copies have **already drifted**, which is the real cost:
- `dome.rs`, `switch.rs`, `covercalibrator.rs`, `observingconditions.rs` have **no `validate_connection` and no `heartbeat`** — the other six do. So `perform_alpaca_health_check` cannot heartbeat a dome.
- `safetymonitor.rs` grew a private variant set (`is_connected_typed:102`, `driver_version_typed:142`) the other nine lack.

**Canonical survivor:** a new `alpaca/src/common.rs` exposing
`macro_rules! alpaca_common_device! { $Struct, $DeviceType, $label }` that emits the fifteen
methods. Each device module then reads:

```rust
pub struct AlpacaFocuser { client: AlpacaClient }
alpaca_common_device!(AlpacaFocuser, Focuser, "focuser");
// … only the focuser-specific methods follow
```

A macro (rather than a trait) keeps the inherent-method call sites in `bridge/` unchanged —
`focuser.name().await` still resolves without importing a trait. Implementers must add the
four missing `validate_connection`/`heartbeat` pairs as part of the merge and note that as a
deliberate behaviour *addition*.

Effort: medium. ~950 lines removed.

### D4 — `AlpacaClient`'s five copy-pasted HTTP verb methods (small)

`get_quick` (917–952), `get_long` (956–991), `get_very_long` (1090–1136), `put_long`
(996–1042), `put_very_long` (1043–1089) in `alpaca/src/client.rs`. `get_quick` and
`get_long` are **byte-identical apart from line 921 vs 960** (`create_quick_timeout_client()`
vs `create_long_timeout_client()`); the two PUT variants likewise.

**Canonical survivor:** one private
`async fn request_with_client<T>(&self, client: &Client, method: Method, endpoint: &str, params: &[(&str,&str)]) -> Result<T, AlpacaError>`
holding the URL build + status check + `AlpacaResponse` unwrap + `DeviceError` mapping. The
five public methods become 3-line wrappers. (Two of the five are dead — see DC4 — so delete
those rather than rewrap them.)

There is a second, larger façade duplication in the same file: `get`/`get_typed`,
`put`/`put_typed`, `is_connected`/`is_connected_typed`, `connect`/`connect_typed`,
`disconnect`/`disconnect_typed`, `get_name`/`get_name_typed`,
`get_description`/`get_description_typed`, `get_driver_version`/`get_driver_version_typed`
(1137–1204). Each `String`-returning method is `self.X_typed().await.map_err(Into::into)`.
That is a *deliberate* legacy shim — `From<AlpacaError> for String` exists at `client.rs:221` —
but the crate has never finished the migration: `alpaca/src/telescope.rs`, `dome.rs`,
`focuser.rs` etc. still return `Result<_, String>` throughout. Recommendation: leave the
shim in place for this release, and record "finish the `AlpacaError` migration and delete the
`String` façade" as a post-release item — it is a wide, low-risk-per-site but high-site-count
change that would churn every `bridge/src/real_device_ops.rs` call site.

Effort: small for the verb methods; large for the error façade (defer).

### D5 — INDI device wrapper boilerplate ×10 (small)

`indi/src/{camera,mount,focuser,filterwheel,rotator,dome,weather,safetymonitor,covercalibrator,switch_device}.rs`
each declare the identical struct and the identical first four methods. Verified identical
between `rotator.rs:13–48` and `focuser.rs:13–48` (only doc-comment nouns differ):

```rust
pub struct IndiX { client: Arc<RwLock<IndiClient>>, device_name: String }
impl IndiX {
    pub fn new(client: Arc<RwLock<IndiClient>>, device_name: &str) -> Self { … }
    pub fn device_name(&self) -> &str { &self.device_name }
    pub async fn connect(&self) -> IndiResult<()> { … }        // write().await + connect_device
    pub async fn disconnect(&self) -> IndiResult<()> { … }
    pub async fn is_connected(&self) -> bool { … }
}
```

**Canonical survivor:** `macro_rules! indi_device_common!` in `indi/src/lib.rs` (or a new
`indi/src/device_common.rs`), invoked once per module. ~350 lines removed. Same
macro-not-trait reasoning as D3.

Effort: small.

### D6 — `alpaca/src/guard.rs`: six identical `disconnect_sync` impls (small)

`guard.rs:23, 49, 73, 97, 121, 145` — `impl AlpacaConnectable for {AlpacaCamera,
AlpacaTelescope, AlpacaFocuser, AlpacaFilterWheel, AlpacaRotator, AlpacaDome}`, running to
line 169. Each body is the same 20 lines: read
`base_url`/`device_number`, `std::thread::spawn`, build a `current_thread` Tokio runtime,
`AlpacaDevice::from_server(TYPE, …)`, `T::new(&device)`, `disconnect().await`. Only the
`AlpacaDeviceType` constant and the local variable name differ.

**Canonical survivor:** one generic helper
`fn spawn_disconnect(device_type: AlpacaDeviceType, base_url: String, device_number: u32)`
plus a 3-line `impl_alpaca_connectable!(AlpacaCamera, Camera);` macro.
Note DC2/DC3 first — five of the six impls have no reachable caller, so deleting may beat
deduplicating.

### D7 — `is_sdk_available` / `get_sdk_status` / `sdk_version` triple ×7 (small)

`zwo.rs:2017/2022` (+ EAF `2732/2737/2772`, EFW `3443/3448/3466`), `qhy.rs:2072`,
`atik.rs:832/837/855`, `fli.rs:573/578/602`, `svbony.rs:585/590/615`,
`player_one.rs:1634/627`. All follow the identical shape
`get_sdk().is_ok()` / `match get_sdk() { Ok(sdk) => (true, version(sdk).unwrap_or(default)), Err(e) => (false, format!("SDK not available: {e}")) }`.

**Canonical survivor:** extend `load_vendor_sdk!` (D1) to emit
`is_available()`, `status()` and `version()` on the generated `Sdk` type, given a
`version_fn:` argument. Then each vendor keeps only the SDK-specific `version_fn`. Do this
as part of D1, not separately.

### D8 — Atik: `require_efw_api` + N `unwrap()`s repeated six times (small)

`atik.rs:602–603`, `764–765`, `1956–1960`, `2037`, `2069`, `2086`, `2107`. Every site is
`require_efw_api(sdk)?;` followed by 1–5 `sdk.efw_*.unwrap()` lines.
**These are NOT live panics** — I traced all seven sites and each is dominated by a
`require_efw_api` check (`atik.rs:506`) or an early return (`atik.rs:759`), and
`efw_index_for_serial` (601) has exactly one caller (1970) which checks first. So this is a
readability/robustness item, not a defect.

**Canonical survivor:** `fn efw_api(sdk: &AtikSdk) -> Result<EfwApi, NativeError>` returning a
`#[derive(Copy)] struct EfwApi { is_present: ArtemisEFWIsPresent, … }` with non-`Option`
fields. Callers do `let efw = efw_api(sdk)?;` once and the `unwrap()`s vanish structurally.

### D9 — `CoolerState` declared twice (trivial)

`zwo.rs:399–414` and `player_one.rs:71–83`. Identical struct `{ enabled: bool, target_c: f64 }`;
the `Default` bodies differ only in `target_c` (`-10.0` vs `0.0`). Move to
`native/src/camera.rs` as `pub struct CachedCoolerState` with
`fn with_default_target(target_c: f64) -> Self`.

### D10 — ZWO EAF/EFW candidate-path functions (trivial)

`zwo.rs:2187–2204` and `zwo.rs:2942–2959` differ only in the library base name
(`EAF_focuser` vs `EFW_filter`). Replace both with one
`fn simple_zwo_candidates(base: &str) -> Vec<PathBuf>` (or add
`sdk_loader::simple_vendor_candidates(base_name)` and let other vendors use it too).

---

## 3. SUSPECTED CROSS-PACKAGE DUPLICATION (one line each — for the cross-cutting agent)

- `packages/skotiq_bridge/lib/src/ascom_client.dart` implements ASCOM registry discovery (`discoverAscomDrivers:49`), the chooser (`showAscomChooser:469`) and COM invocation (`callMethod`) in Dart over win32 FFI — a second implementation of `ascom/src/windows/connection.rs::discover_devices:55` and `AscomDeviceConnection`.
- Six separate timeout/retry policy types: `ascom/src/windows/timeout.rs:5 TimeoutConfig`, `alpaca/src/client.rs:229 TimeoutConfig`, `alpaca/src/client.rs:338 RetryConfig`, `indi/src/lib.rs:216 IndiTimeoutConfig`, `indi/src/client.rs:382 ReconnectionConfig`, `native/src/traits.rs:30 NativeTimeoutConfig`, plus `bridge/src/timeout_ops.rs:299 RetryConfig`.
- The per-frame full-image statistics scan exists twice: `native/src/vendor/zwo.rs:1453–1470` and `bridge/src/api/imaging.rs:1052–1074` — both labelled `DIAGNOSTIC`, both scanning every pixel and logging at `info`/`error`.
- Device-discovery aggregation and de-duplication appears in `native/src/discovery.rs:90+` (vendor SDKs), `indi/src/discovery.rs`, `alpaca/src/discovery.rs`, and again in `bridge/src/api/discovery.rs` (1489 lines).
- `native/src/camera.rs` `SensorInfo` / `ImageData` / `BayerPattern` almost certainly restate types in `bridge/src/device_capabilities.rs` (4296 lines) and the FRB-exported imaging types.
- The `max_adu` / saturation-ceiling contract (D2) has a consumer-side twin in `imaging/src/stats.rs` — the duplicated test `raw16_container_max_adu_agrees_with_pipeline_saturation_threshold` exists precisely to keep the two in sync by hand.
- The Bayer-pattern-from-vendor-enum mapping is written inline seven times (`zwo.rs:1520`, `zwo.rs:1788`, `player_one.rs:1312`, `player_one.rs:1539`, `svbony.rs:907`, `qhy.rs:994`, `gphoto2.rs:1859`) plus two named fns (`touptek.rs:583`, `moravian.rs:380`), and a normalisation of the same enum probably exists in `imaging/`.

---

## 4. DEAD CODE

Method note: every claim below was checked with a repo-wide `grep` excluding `target/`,
`graphify-out/`, `.git/`. FRB exports, headless routes and registry lookups were considered —
none of these crates is FRB-exported directly (only `bridge/` is), and none is published
(`skotiq_alpaca` etc. are path dependencies), so `pub` does not imply an external caller.

### DC1 — `ascom::probe_device_name` (high confidence)

`ascom/src/windows/connection.rs:275–318` (44 lines).
Evidence: `grep -rn "probe_device_name(" --exclude-dir=target .` returns exactly **two** hits —
the definition (`:275`) and a comment (`:189`). The only other mentions are the two
re-exports (`ascom/src/lib.rs:88`, `ascom/src/windows/mod.rs:31`) and a doc comment in
`bridge/src/device_manager/connection.rs:612` which explicitly explains **why it cannot be
used**: *"an unconnected `ASCOM.ASICamera2.Camera` answers `Name = "ASI Camera (1)"` … so the
existing `skotiq_ascom::probe_device_name` helper — which reads `Name` without
connecting — cannot supply it."*

This directly touches open task **L36 ("ASCOM devices report their ProgID, never their
model")**. Either delete the helper, or make it read `Name` *after* `Connected = true` and
wire it — but do not leave a helper whose own consumers document it as unusable.

### DC2 — `AlpacaConnectionGuard` and `TelescopeOperationGuard` (high confidence)

`alpaca/src/guard.rs:194–229` (struct 194, impl 199, `Drop` 220) and `:306–344` (struct 306,
impl 312, `Drop` 333) — ~90 lines including their `Drop` impls.
Evidence: `grep -rn "AlpacaConnectionGuard\|TelescopeOperationGuard" --exclude-dir=target
--exclude-dir=graphify-out .` returns only the definitions and `alpaca/src/lib.rs:28
pub use guard::*;`. Zero construction sites anywhere in `bridge/`, `sequencer/`, `imaging/`,
`apps/`, `packages/`, or any test.

Note the sibling `with_alpaca_connection` (`guard.rs:251–304`) **is** live — 12 call sites in
`bridge/src/real_device_ops.rs:580,633,686,739,785,823,861,900,947,998,1043,1087`. Do not
delete `guard.rs` wholesale.

### DC3 — Five of six `AlpacaConnectable` impls are unreached (medium confidence)

`guard.rs:23` (Camera), `:73` (Focuser), `:97` (FilterWheel), `:121` (Rotator), `:145` (Dome).
The trait is consumed only by `AlpacaConnectionGuard` (dead, DC2), `TelescopeOperationGuard`
(dead, DC2) and `with_alpaca_connection` — and every one of the 12 `with_alpaca_connection`
call sites passes `&mount` (an `AlpacaTelescope`). So only `impl … for AlpacaTelescope`
(`:49`) is reachable.

Marked medium rather than high because these are trait impls, and a future caller could reach
them without any new code. Recommendation: keep the trait + telescope impl, delete the other
five (~100 lines), and re-add on demand — the dedup in D6 makes re-adding a one-liner.

### DC4 — `AlpacaClient::get_long` and `get_very_long` (high confidence)

`alpaca/src/client.rs:956–991` and `:1090–1136` (~85 lines).
Evidence: `grep -rn "\.get_long\|\.get_very_long" --exclude-dir=target .` returns nothing
outside the definitions. Their PUT counterparts *are* used (`put_long` from
`covercalibrator.rs:200,211`, `focuser.rs:207`, `dome.rs:222,244,255,273`,
`telescope.rs:603,614,642,673,692`; `put_very_long` from `dome.rs:233,288`).
Delete both; `create_very_long_timeout_client` (`:682`) then has one remaining caller
(`put_very_long`).

### DC5 — Six `Native*` device traits with zero production implementors (high confidence)

`native/src/traits.rs`: `NativeRotator` (698–741), `NativeDome` (743–822),
`NativeCoverCalibrator` (824–857), `NativeSwitch` (859–877), `NativeWeather` (879–911),
`NativeSafetyMonitor` (913–919). ~230 lines.

Evidence, two independent proofs:

1. **No implementors.** Enumerating `impl Native* for *` across `native/src/vendor/*.rs`
   yields only `NativeDevice`, `NativeCamera`, `NativeMount`, `NativeFocuser`,
   `NativeFilterWheel`. A scoped grep across `bridge/src`, `native/src`, `sequencer/src`,
   `imaging/src` for `Native{Dome,Weather,SafetyMonitor,Rotator,CoverCalibrator,Switch} for`
   returns **three** hits, all `#[cfg(test)]` fakes inside `bridge/src/device_capabilities.rs`
   (`FakeNativeRotator:3389`, `FakeNativeSwitch:3469`, `FakeNativeCoverCalibrator:3598`).
   `NativeDome`, `NativeWeather` and `NativeSafetyMonitor` have **no implementor at all**,
   not even a test fake.
2. **The registries can never be non-empty.** In `bridge/src/`, counting `insert(` against
   each registry field: `native_cameras`=2, `native_mounts`=1, `native_focusers`=1,
   `native_filter_wheels`=1 — but `native_rotators`=0, `native_domes`=0, `native_weather`=0,
   `native_safety_monitors`=0, `native_switches`=0, `native_cover_calibrators`=0.
   `native_domes` is constructed empty at `bridge/src/device_manager/mod.rs:797,869,1328`,
   and then only `read()`/`get()`/`get_mut()`/`remove()` at 18 sites
   (`ops/dome.rs:94,187,311,412,508,609,696,965,1171,1255,1341`,
   `dispatch/native.rs:432`, `device_capabilities.rs:2863`,
   `device_manager/connection.rs:967`).

Consequence beyond the dead lines: every "native dome / rotator / weather / safety monitor"
branch in `bridge/src/device_manager/ops/*.rs` and `bridge/src/dispatch/native.rs` is
unreachable, and a user selecting a native-backend dome silently gets the not-found path.
That is a *cross-package* cleanup — flag it to the bridge mapper — but the traits themselves
are in this subsystem and are the right anchor for the decision: either delete the six traits
+ their bridge registries + dispatch branches, or accept them as a documented extension point
and say so in a module comment.

### DC6 — `AscomOperationGuard`, `AscomDisconnectable`, `AscomCleanupGuard` (high confidence)

`ascom/src/windows/connection.rs:1206–1335` (~130 lines).
Evidence: repo-wide grep finds only the definitions, two re-export lines
(`ascom/src/lib.rs:93,99,108`, `ascom/src/windows/mod.rs:31–32`), and two changelog entries.
Zero construction sites. Delete.

(Contrast: `AscomConnectionBackend` at `:1107` is **not** dead — `ascom/tests/fake_ascom_driver_test.rs`
uses the generated `MockAscomConnectionBackend`. But it has no *production* consumer: the
`ascom/src/windows/{camera,mount,focuser,…}.rs` modules hold a concrete
`AscomDeviceConnection`, not `&dyn AscomConnectionBackend`, so the testability the trait was
added for — see `docs/releases/v2.6.0-release-notes.md:731` — was never realised. Worth a
decision, not a deletion.)

### DC7 — `_pending_number_limits` in the INDI reader (high confidence)

`indi/src/client.rs:1115` (declared), `:1357` (assigned a 4-tuple containing **three cloned
`String`s** plus a `NumberLimits`), `:1630` (reset to `None`). **Never read.** The code even
carries `#[allow(unused_assignments)]` at `:1114` and the comment "currently unused but
preserved for future use".

This is dead code *and* a per-element allocation on the hottest parsing path: every
`defNumber` element in every property definition allocates three Strings that are discarded.
Delete the variable and lines 1355–1362.

---

## 5. PERF RISKS

### P5.1 — INDI BLOB path copies a full frame four times and base64-decodes it on the reader task — **HIGH**

`indi/src/client.rs:1533–1625`. For every image an INDI camera delivers:

1. `:1544` `let text = e.unescape().unwrap_or_default().to_string();` — the entire base64
   payload becomes an owned `String`. A 62 MP 16-bit frame is ~124 MB raw ⇒ ~165 MB of base64.
2. `:1556` `text.clone()` is inserted into `property_values` — a **second full copy, retained**.
3. `:1569` `BASE64.decode(text.trim())` — a multi-hundred-millisecond **CPU-bound decode
   executed inline on the async reader task**, with no `spawn_blocking`. While it runs, this
   client's reader cannot service keepalives, and any other task on that Tokio worker stalls.
4. `:1589` `data.clone()` into `latest_blobs` — third copy.
5. `:1600` `data` moved into `IndiEvent::BlobReceived` on the broadcast channel — fourth copy,
   plus one clone per additional subscriber.

Peak transient ≈ 4× frame size. Fix shape: decode into a single `Arc<[u8]>`, share it between
`latest_blobs` and the event, and move the decode to `tokio::task::spawn_blocking`.

**Retention half of the same finding:** `property_values` is inserted at `:1551` and the only
removal in the whole file is `self.property_values.write().await.clear()` at `:1813`, inside
`disconnect()` (verified: `grep -n property_values indi/src/client.rs` shows insert/read/clear
and nothing else). So the base64 text of the most recent frame per
`(device, property, element)` is held for the entire session. `take_blob` (`:766`) removes from
`latest_blobs` only — it does not touch `property_values`. Skip the `property_values` insert
entirely when `current_blob_active` is true.

### P5.2 — Broadcast ring can pin several decoded frames — **MEDIUM**

`indi/src/client.rs:38` `const EVENT_CHANNEL_CAPACITY: usize = 1024;`. A `tokio::broadcast`
ring retains its last N values even after every receiver has consumed them. Since
`IndiEvent::BlobReceived` carries an owned `Vec<u8>` of a full frame (`:1600`), every blob
event stays resident until 1024 further events push it out. During an exposure sequence
INDI emits a handful of blob events among thousands of small property updates, so a few
hundred MB can sit in the ring. Sending `Arc<[u8]>` (P5.1) reduces this to one shared
allocation; a dedicated small-capacity blob channel would remove it entirely.

### P5.3 — ZWO scans every pixel four times per frame, at `info` level, under the SDK mutex — **HIGH**

`native/src/vendor/zwo.rs:1455–1470`, inside `download_image` and **while
`zwo_camera_mutex()` is held** (acquired at `:1399`):

```rust
let min_val = data.iter().min()…;             // pass 1
let max_val = data.iter().max()…;             // pass 2
let sum: u64 = data.iter().map(|&x| x as u64).sum();   // pass 3
let non_zero_count = data.iter().filter(|&&x| x != 0).count(); // pass 4
tracing::info!("ZWO DIAGNOSTIC: Raw buffer stats …");
```

Four full passes over `Vec<u16>` per frame. On an ASI6200 (62 MP) that is ~250 M element
visits and ~500 MB of memory traffic every exposure, blocking every other ZWO SDK call
(including the filter wheel and EAF, which share the vendor mutex family) for the duration.
The block is labelled `DIAGNOSTIC` and its comment says it was added "to debug mid-gray image
issue" — it is leftover instrumentation, not a feature.

Fix: fold min/max/sum/non-zero into **one** pass and put the whole block behind
`if tracing::enabled!(tracing::Level::DEBUG)`, or delete it (`bridge/src/api/imaging.rs:1052`
already computes the same statistics downstream — see §3).

### P5.4 — Serial mount discovery blocks a Tokio worker for tens of seconds — **HIGH**

`native/src/vendor/lx200.rs:1259 pub async fn discover_mounts()` contains
`std::thread::sleep(Duration::from_millis(200))` at `:1336`, `:1365`, `:1424`, `:1492` and
`std::thread::sleep(50ms)` at `:1517`, plus blocking `serialport::…open()` with a 500 ms
timeout (`:1299`) and blocking `port.read()`. The loop is
`for port in available_ports() { for baud in DISCOVERY_BAUD_RATES { … } }` with
`DISCOVERY_BAUD_RATES = [115200, 57600, 19200, 9600]` (`lx200.rs:30`). Four ports × four
bauds × ≈1.1 s ≈ **17 s of a fully blocked async worker thread**.

Same shape: `native/src/vendor/skywatcher.rs:861 discover_mounts` (`sleep` at `:921`, `:954`;
`SYNSCAN_DISCOVERY_BAUD_RATES` at `:28`) and `native/src/vendor/ioptron.rs` (`sleep` at
`:882`, `:924`).

These are `.await`ed directly with no `spawn_blocking`: `native/src/discovery.rs:643`
(skywatcher), `:671` (ioptron), `:698` (lx200). Only `qhy.rs` uses `spawn_blocking`
(`:2165`, `:2755`) — zero other vendor files do.

Fix: wrap each serial-scan body in `tokio::task::spawn_blocking`, or convert the sleeps to
`tokio::time::sleep().await` **and** move the blocking serial IO off the runtime. The first
is the smaller change.

### P5.5 — A fresh `reqwest::Client` per Alpaca health check — **MEDIUM**

`alpaca/src/client.rs:664–689` — `create_long_timeout_client`, `create_quick_timeout_client`,
`create_very_long_timeout_client` each call `Client::builder().…build()`, which constructs a
new connection pool, DNS resolver and TLS config. They are called per-request at `:921`,
`:1048`, `:1094`, and — the hot one — at `:1217` (`validate_connection`), `:1270`
(`heartbeat`) and `:1303` (`detect_api_versions`).

`heartbeat()` is the periodic device health probe: `bridge/src/dispatch/alpaca.rs:337` (camera),
`:358` (mount), `:379` (focuser) inside `perform_alpaca_health_check`. So every health tick,
for every Alpaca device, builds and drops a whole HTTP client and cannot reuse the keep-alive
connection.

The file itself documents that this was already fixed once for image download —
`client.rs:640–644`: *"§5.12 — image-download paths previously built a fresh `reqwest::Client`
per frame, forcing a TLS handshake + new TCP session every shot. Callers should reuse this
pooled client and override only the per-request timeout via `RequestBuilder::timeout(...)`."*
The heartbeat/validate/version paths were not migrated.

Fix: delete the three factories and use `self.standard_http_client()?` +
`RequestBuilder::timeout(…)`, exactly as the §5.12 comment prescribes.

### P5.6 — Three `String` clones per XML element in the INDI reader — **LOW/MEDIUM**

`indi/src/client.rs:1197–1199`:
```rust
let snapshot_device_before = current_device.clone();
let snapshot_property_before = current_property.clone();
let snapshot_element_before = current_element.clone();
```
executed for **every** `Start`/`Empty` XML event. INDI is chatty — during an exposure a
driver emits hundreds of `setNumberVector`/`setSwitchVector` messages per second, each with
several child elements. Three heap allocations per element is measurable but not dominant;
listed for completeness because the fix is cheap (keep `Rc<str>`/indices into an interned
table, or snapshot only when the frame kind can actually mutate the mirrors). Adjacent:
DC7's three more clones per `defNumber`.

### P5.7 — `disconnect_sync` spawns an OS thread and builds a Tokio runtime per drop — **LOW**

`alpaca/src/guard.rs:30,54,78,102,126,150`. Each `Drop` path does
`std::thread::spawn(|| { Builder::new_current_thread().enable_all().build()… })`. On a
failure storm (`with_alpaca_connection` cleans up on every `Err`) this spawns one OS thread
plus one runtime per failed operation, unbounded and unjoined. Low impact because the live
path is telescope-only and failures are rare — but it is a thread leak under repeated
mount-comms failures, which is exactly the scenario in which it fires.

---

## 6. RELIABILITY RISKS

### R6.1 — `IndiClient::disconnect()` leaks the last decoded frame

`indi/src/client.rs:1811–1815` clears `devices`, `properties`, `property_values` and
`number_limits` — but **not `latest_blobs`** and not `property_updated_ms`. So the decoded
pixel buffer of the last exposure (tens to hundreds of MB) survives disconnect and stays
alive for as long as the `IndiClient` does; and after a reconnect,
`get_property_last_update_ms` (`:2060`) returns pre-disconnect timestamps for any property
the server has not yet re-defined, which any staleness check will read as "fresh".

### R6.2 — The INDI writer task can die while `is_connected()` still reports true

`indi/src/client.rs:894–905`. `writer_task` is spawned detached at `:808` (JoinHandle
dropped). On a socket write error it logs and `break`s out of the loop — it does **not**
touch `self.connected`, does not emit an `IndiEvent`, and does not signal the reader. Meanwhile
`is_connected()` (`:1847`) reads only the `connected: AtomicBool`, which is set false solely
by `supervised_reader_task` or `disconnect()`. A half-open TCP connection (write side dead,
read side quiet) therefore leaves the client reporting connected while every subsequent
`send_command` fails with `ChannelClosed` (`:1890`). This is the "app states something
untrue" shape recorded in the cry-wolf memory. Fix: have `writer_task` clear `connected` and
emit `IndiEvent::ConnectionStateChanged(false)` before returning.

### R6.3 — Hand-rolled SDK loaders swallow the reason a load failed

`native/src/vendor/player_one.rs:396–420` (and the same pattern in `fujifilm.rs:710`,
`fli.rs:199`, `moravian.rs:192`, `gphoto2.rs:352`, `atik.rs:265`, `touptek.rs:331`,
`svbony.rs:373`, `qhy.rs:346`). `*lib.get(b"POAGetCameraCount\0").ok()?` turns "symbol
missing" into `None` with no log line naming the symbol, and — because the `?` returns out of
the `for path in &lib_paths` loop — abandons the remaining candidate paths. A user with an
installed-but-outdated SDK gets "SDK not found". `sdk_loader::resolve_vendor_symbol`
(`sdk_loader.rs:250+`) already returns `VendorLoadError::SymbolNotFound { vendor, library,
symbol }`. See D1 — the fix and the dedup are the same work.

### R6.4 — `discover_all_devices` holds a global mutex across every vendor probe, with no timeout

`native/src/discovery.rs:96` acquires `get_discovery_mutex().lock().await` and holds it
across every vendor's `discover_devices().await` (ZWO at `:123`, then QHY, Player One,
SVBony, Atik, FLI, ToupTek, Moravian, GPhoto2, Fujifilm, SkyWatcher `:643`, iOptron `:671`,
LX200 `:698`). Combined with P5.4 a single wedged serial port or hung vendor SDK blocks
*all* future discovery for the process lifetime, with no per-vendor `tokio::time::timeout`.
Add a per-vendor timeout inside the loop (the mutex is genuinely required — most vendor SDKs
are not thread-safe — so bound each probe rather than removing the lock).

### R6.5 — `AlpacaCamera::get_full_status` documents a round-trip reduction it does not deliver

`alpaca/src/camera.rs:991–1010`. The comment reads *"Query all status properties in parallel
for maximum efficiency / This reduces the number of network round-trips from ~16 to 1"*, but
the body is `tokio::join!` over sixteen independent `self.<property>()` calls — sixteen HTTP
requests, issued concurrently, not one. Against a single-threaded ASCOM Remote / OmniSim
server they also serialise. Low severity, but it is a false statement in a comment that
future work will trust; either correct the comment or implement it against Alpaca's
`devicestate` multi-property endpoint.

### R6.6 — `assert_eq!(device.device_type, …)` in every Alpaca constructor

18 sites: `camera.rs:226,238`, `telescope.rs:208,220`, `focuser.rs:36,48`, `rotator.rs:32,44`,
`filterwheel.rs:31,43`, `dome.rs:51,63`, `covercalibrator.rs:91,103`,
`safetymonitor.rs:37,49`, `switch.rs:13`, `observingconditions.rs:13`.
**Currently unreachable** — every construction site goes through `from_server`, which builds
the `AlpacaDevice` with the matching type itself, or through `guard.rs` which does the same.
Recorded as a latent hazard only: these are the constructors D3's macro will emit, so the
merge is the natural moment to convert them to a `debug_assert!` or a `Result`. **Do not file
this as a live panic.**

---

## 7. TOP PRIORITIES (ordered)

1. **P5.1 + R6.1** — INDI BLOB path: one `Arc<[u8]>`, `spawn_blocking` the base64 decode, skip the `property_values` insert for blobs, clear `latest_blobs` in `disconnect()`. Biggest single memory/latency win in the subsystem and it sits on the exposure path.
2. **P5.3** — delete or debug-gate the per-frame four-pass `DIAGNOSTIC` scan in `zwo.rs:1455`; it runs under the ZWO SDK mutex on the most-used camera brand.
3. **P5.4** — `spawn_blocking` the three serial mount-discovery scans (`lx200`, `skywatcher`, `ioptron`); today device discovery blocks an async worker for ~17 s.
4. **DC5** — decide the fate of the six unimplemented `Native*` traits and the six bridge registries that can never be populated; this is a whole unreachable device backend.
5. **D1** — migrate the nine hand-rolled vendor SDK loaders onto `load_vendor_sdk!` (fixes R6.3 and D7 as a side effect). Largest structural win; do one vendor per commit.
6. **§1.2** — split the ten oversized vendor drivers using the uniform five-section recipe, starting with `zwo.rs`. Prerequisite for anyone reviewing D1 or P5.3.
7. **§1.1** — split `indi/src/client.rs` (4146 → ~9 files under 900). The `reader_task_with_timeout` extraction is mechanical because the function already takes all state as `Arc` parameters.
8. **DC1/DC2/DC4/DC6/DC7 + R6.2** — the small dead-code sweep (~350 lines) plus the writer-task connected-state fix; cheap, and DC1 unblocks a decision on open task L36.
