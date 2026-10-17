//! Protocol-neutral "ASCOM-Common" metadata probe trait and shared helper.
//!
//! Every typed device wrapper in this crate — whether the underlying transport
//! is Alpaca (HTTP) or ASCOM (Windows COM) — exposes the same four
//! identification properties:
//!
//! | Method                 | ASCOM-Common endpoint | Returns               |
//! |------------------------|-----------------------|-----------------------|
//! | `interface_version()`  | `InterfaceVersion`    | `i32` (ASCOM Vn)      |
//! | `driver_version()`     | `DriverVersion`       | `String` (vendor str) |
//! | `driver_info()`        | `DriverInfo`          | `String` (vendor str) |
//! | `supported_actions()`  | `SupportedActions`    | `Vec<String>`         |
//!
//! These four properties are defined by the ASCOM standard and are present on
//! every conforming driver regardless of role (camera, mount, focuser, …) or
//! transport. This trait formalizes the shared contract so a single generic
//! helper can replace the per-arm fan-out in both
//! `dispatch/alpaca.rs::query_alpaca_api_version` (10 arms) and
//! `dispatch/ascom.rs::query_ascom_api_version` (7 arms).
//!
//! The actual `impl DeviceCommonMetadata for ...` blocks live next to each
//! protocol's wrappers:
//! * [`crate::dispatch::alpaca_device_common`] — the 10 Alpaca typed wrappers.
//! * [`crate::dispatch::ascom_device_common`] — the 7 ASCOM typed wrappers
//!   (camera, mount, focuser, filter wheel, dome, switch, cover calibrator).
//!
//! # What this trait deliberately does NOT abstract
//!
//! This is the **read-only metadata probe** surface. It is NOT a general
//! "device" trait — it intentionally omits:
//!
//! * **Lifecycle** (`connect`/`disconnect`/`is_connected`) — those exist on
//!   the wrappers but their use is coupled to the bridge's per-device-type
//!   storage maps; abstracting them here would not actually reduce duplication.
//! * **Heartbeat** — Alpaca wrappers expose `heartbeat()` (returns RTT in ms)
//!   for some roles and `is_connected()` for others; ASCOM wrappers vary
//!   between `heartbeat()` returning `()`, returning a typed health enum, and
//!   `get_tracking()`-as-probe for mounts. That heterogeneity is real, not
//!   accidental; forcing it into the trait would smush a genuine distinction.
//! * **Operational properties** (`can_slew`, `camera_x_size`, …) — these
//!   differ per device role and are precisely what makes the typed wrappers
//!   distinct. They belong on the concrete types, not the common trait.
//!
//! # `supported_actions` silent-fallback policy
//!
//! `supported_actions()` is mapped to an empty `Vec` inside [`fetch_api_version`]
//! when the probe fails because per the ASCOM/Alpaca specification, drivers
//! that do not implement the optional `ISupportedActions` interface
//! legitimately return either Alpaca error `0x40C` (`ActionNotImplemented`) or
//! ASCOM `PropertyNotImplementedException` (HRESULT `0x80040400`). The
//! documented semantics for "this driver advertises no custom actions" is an
//! empty list, which is exactly what `Vec::default()` provides. The discarded
//! error still reaches the log through a `tracing::warn!`, so the fallback is
//! observable even though it does not propagate — one loud-on-loss site for
//! every Alpaca and ASCOM caller.

use crate::device::DeviceApiVersion;

/// Read-only ASCOM-Common identification probe for a typed device wrapper.
///
/// See the module-level docs for what this trait does and does not abstract.
/// Every method maps 1:1 to an ASCOM-Common property and is safe to call
/// without exclusive access — Alpaca impls delegate to the stateless
/// `AlpacaHttpClient`; ASCOM impls dispatch over the wrapper's worker-thread
/// `mpsc` so the `&self` receiver suffices despite the underlying COM
/// apartment being single-threaded.
///
/// All four methods return `Result<_, String>` — the bridge dispatch layer
/// works in stringified errors throughout, so ASCOM impls that natively
/// return `NativeError` convert via `e.to_string()` at the impl boundary.
pub(crate) trait DeviceCommonMetadata {
    /// ASCOM `InterfaceVersion` — small positive integer (currently 1..=4)
    /// per the ASCOM spec. `Err` means the property is missing or the
    /// request failed.
    fn interface_version(&self) -> impl std::future::Future<Output = Result<i32, String>> + Send;

    /// ASCOM `DriverVersion` — free-form vendor version string. `Err` means
    /// the property is missing or the request failed.
    fn driver_version(&self) -> impl std::future::Future<Output = Result<String, String>> + Send;

    /// ASCOM `DriverInfo` — free-form vendor-supplied description. `Err`
    /// means the property is missing or the request failed.
    fn driver_info(&self) -> impl std::future::Future<Output = Result<String, String>> + Send;

    /// ASCOM `SupportedActions` — list of custom action names exposed by the
    /// driver. `Err` means the driver does not implement `ISupportedActions`
    /// (Alpaca `0x40C` / ASCOM `PropertyNotImplementedException`) or the
    /// request failed.
    fn supported_actions(
        &self,
    ) -> impl std::future::Future<Output = Result<Vec<String>, String>> + Send;
}

/// Build a [`DeviceApiVersion`] by probing the four ASCOM-Common properties
/// of a typed device wrapper, regardless of transport.
///
/// `build` is the protocol-specific constructor —
/// [`DeviceApiVersion::from_alpaca`] for Alpaca devices and
/// [`DeviceApiVersion::from_ascom`] for ASCOM devices. Both constructors
/// share the same signature; only the `DriverType` tag and `protocol_version`
/// field differ, so the probe body is identical and the closure parameter is
/// the only thing that varies across the two call sites.
///
/// # Silent-fallback semantics
///
/// * `interface_version` → `1` (ASCOM V1 baseline) when the probe fails. The
///   ASCOM spec mandates that every conforming driver implements at least V1
///   for its device type, so this is the floor not a guess.
/// * `driver_version` / `driver_info` → `None` when the probe fails. The UI
///   renders missing values as "Unknown".
/// * `supported_actions` → empty `Vec` when the probe fails, with a
///   `tracing::warn!` carrying the discarded error so the loss is visible. The
///   documented ASCOM-optional default semantics ("driver has no custom
///   actions") are preserved.
///
/// Errors here are not surfaced as `Err` because at the call site any
/// individual probe failure is already documented (per the module docstring)
/// as a valid "missing optional property" signal — propagating it would break
/// the equipment-compatibility-matrix UI for partially-conforming drivers.
/// Connection-absence is still a hard `Err` at the dispatch layer above.
pub(crate) async fn fetch_api_version<T, F>(
    device: &T,
    device_id: &str,
    build: F,
) -> DeviceApiVersion
where
    T: DeviceCommonMetadata + ?Sized,
    F: FnOnce(String, i32, Option<String>, Option<String>, Vec<String>) -> DeviceApiVersion,
{
    let interface_version = device.interface_version().await.ok();
    let driver_version = device.driver_version().await.ok();
    let driver_info = device.driver_info().await.ok();
    let supported_actions = match device.supported_actions().await {
        Ok(actions) => actions,
        Err(e) => {
            // ASCOM `ISupportedActions` is OPTIONAL; missing → empty list per
            // spec. Default rather than propagate (per the module-level
            // silent-fallback policy), but warn with the discarded error so an
            // operator reading the log can tell "driver lacks ISupportedActions
            // (expected)" from "transport error masquerading as missing actions
            // (bug)".
            tracing::warn!(
                device_id = %device_id,
                error = %e,
                "supported_actions probe failed; treating as empty (ASCOM-optional). \
                 If this is a known legacy driver, expect this once per session; otherwise check transport."
            );
            Vec::new()
        }
    };

    build(
        device_id.to_string(),
        interface_version.unwrap_or(1),
        driver_version,
        driver_info,
        supported_actions,
    )
}
