//! COM initialization, ASCOM device discovery, and the
//! `AscomDeviceConnection` core wrapper plus RAII cleanup guards.

use crate::com::{ComCall, ComDispatch, ComKind, ComValue, Dispatch};
use crate::connect_verify::{
    verify_connected_readback, CONNECT_VERIFY_POLL, CONNECT_VERIFY_TIMEOUT,
};
use crate::error::{AscomError, AscomResult};
use crate::health::{ConnectionHealth, HealthMonitor};
use crate::AscomDevice;
use std::ptr;
use windows::{
    core::{GUID, PCWSTR, PWSTR},
    Win32::System::{
        Com::{
            CLSIDFromProgID, CoCreateInstance, CoInitializeEx, CoUninitialize, IDispatch,
            CLSCTX_ALL, COINIT_APARTMENTTHREADED, DISPATCH_FLAGS, DISPATCH_METHOD,
            DISPATCH_PROPERTYGET, DISPATCH_PROPERTYPUT, DISPPARAMS, EXCEPINFO,
        },
        Registry::{
            RegCloseKey, RegEnumKeyExW, RegOpenKeyExW, RegQueryValueExW, HKEY, HKEY_CURRENT_USER,
            HKEY_LOCAL_MACHINE, KEY_READ, REG_SZ, REG_VALUE_TYPE,
        },
        Variant::VARIANT,
    },
};

use super::variant::{
    variant_from_arg, variant_to_value, OwnedExcepInfo, OwnedVariant, DISPID_PROPERTYPUT,
};

/// Initialize COM for the current thread
pub fn init_com() -> AscomResult<()> {
    // SAFETY: `CoInitializeEx` is the canonical Windows COM thread-initialization call.
    // No pointer arguments are passed (first arg is `None`); apartment selection is a
    // value-typed `COINIT_*` flag. Result is checked and converted to a `Result`.
    // Pairs with `uninit_com` / `CoUninitialize` on the same thread.
    unsafe {
        CoInitializeEx(None, COINIT_APARTMENTTHREADED).map_err(|e| AscomError::ComInit {
            cause: e.to_string(),
        })
    }
}

/// Uninitialize COM for the current thread
pub fn uninit_com() {
    // SAFETY: `CoUninitialize` takes no arguments and reverses a prior successful
    // `CoInitializeEx` on the same thread. Caller invariant: must be invoked on the
    // STA worker thread that called `init_com`.
    unsafe {
        CoUninitialize();
    }
}

/// Discover ASCOM devices by reading the Windows Registry
pub fn discover_devices(device_type: &str) -> Vec<AscomDevice> {
    let mut devices = Vec::new();

    let reg_path = format!("SOFTWARE\\ASCOM\\{} Drivers", device_type);
    let reg_path_wow = format!("SOFTWARE\\WOW6432Node\\ASCOM\\{} Drivers", device_type);

    for (root, root_name) in [(HKEY_LOCAL_MACHINE, "HKLM"), (HKEY_CURRENT_USER, "HKCU")] {
        for path in [&reg_path, &reg_path_wow] {
            tracing::debug!("Scanning ASCOM registry: {}\\{}", root_name, path);
            if let Some(found) = scan_registry_path(root, root_name, path) {
                for dev in found {
                    push_unique_device(&mut devices, dev);
                }
            }
        }
    }

    // Hot-plug poll re-scans every 4s; debug-level keeps steady-state quiet
    // while preserving one-off enumeration visibility via RUST_LOG=debug.
    tracing::debug!("Found {} ASCOM {} drivers", devices.len(), device_type);
    devices
}

fn push_unique_device(devices: &mut Vec<AscomDevice>, device: AscomDevice) -> bool {
    if devices
        .iter()
        .any(|existing| existing.prog_id == device.prog_id)
    {
        return false;
    }

    devices.push(device);
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ascom_device(prog_id: &str, name: &str) -> AscomDevice {
        AscomDevice {
            prog_id: prog_id.to_string(),
            name: name.to_string(),
            description: name.to_string(),
        }
    }

    #[test]
    fn push_unique_device_deduplicates_by_prog_id() {
        let mut devices = vec![ascom_device("ASCOM.Camera.Driver", "Machine install")];

        assert!(!push_unique_device(
            &mut devices,
            ascom_device("ASCOM.Camera.Driver", "User install")
        ));
        assert_eq!(devices.len(), 1);
        assert_eq!(devices[0].name, "Machine install");

        assert!(push_unique_device(
            &mut devices,
            ascom_device("ASCOM.OtherCamera.Driver", "Other")
        ));
        assert_eq!(devices.len(), 2);
    }
}

fn scan_registry_path(root: HKEY, root_name: &str, reg_path: &str) -> Option<Vec<AscomDevice>> {
    let mut devices = Vec::new();

    // SAFETY: All Win32 registry APIs (`RegOpenKeyExW`, `RegEnumKeyExW`, `RegCloseKey`)
    // are invoked with locally-owned, well-aligned arguments: `reg_path_wide` is a
    // NUL-terminated UTF-16 vector owned by this stack frame, `name_buffer` is a
    // 256-element `[u16]` stack array, and `key` is a stack-allocated `HKEY`. The
    // returned `key` is closed on every path before this scope ends. `get_driver_description`
    // is itself an `unsafe fn` that documents its own preconditions.
    unsafe {
        let mut key: HKEY = HKEY::default();
        let reg_path_wide: Vec<u16> = reg_path.encode_utf16().chain(std::iter::once(0)).collect();

        let result = RegOpenKeyExW(
            root,
            PCWSTR::from_raw(reg_path_wide.as_ptr()),
            0,
            KEY_READ,
            &mut key,
        );

        if result.is_err() {
            tracing::debug!("ASCOM registry key not found: {}\\{}", root_name, reg_path);
            return None;
        }

        let mut index: u32 = 0;
        let mut name_buffer: [u16; 256] = [0; 256];

        loop {
            // Why: `name_buffer` is a statically-sized
            // `[u16; 256]`; `len()` is the literal compile-time constant 256,
            // far inside u32's range. SAFE narrowing.
            let mut name_len = name_buffer.len() as u32;

            let result = RegEnumKeyExW(
                key,
                index,
                PWSTR(name_buffer.as_mut_ptr()),
                &mut name_len,
                None,
                PWSTR::null(),
                None,
                None,
            );

            if result.is_err() {
                break;
            }

            // Why: `name_len` is u32 written by
            // RegEnumKeyExW and on success is bounded by the 256-element
            // input buffer; u32 → usize is widening on every Rust target we
            // support (16-bit usize is unsupported by std).
            let prog_id = String::from_utf16_lossy(&name_buffer[..name_len as usize]);
            // Why: the registry "Description" REG_SZ is
            // optional per the ASCOM Platform convention (some 3rd-party
            // installers only write the ProgID key). Empty string flows
            // through to the equipment-list UI's fallback display logic
            // which substitutes the ProgID itself.
            let registry_description = get_driver_description(&key, &prog_id).unwrap_or_default();

            if !prog_id.is_empty() {
                // NOTE: We intentionally do NOT probe the device here because:
                // 1. Some ASCOM drivers show setup dialogs when COM object is created
                // 2. Probing is slow (creates/destroys COM objects)
                // 3. An unconnected driver answers `Name` with a generic slot label
                //    ("ASI Camera (1)"), so probing here would not improve on the
                //    registry description anyway. The model is only readable after
                //    `Connected = true` — see the device wrappers.

                let name = if registry_description.is_empty() {
                    prog_id.clone()
                } else {
                    registry_description.clone()
                };

                tracing::debug!(
                    "Found ASCOM driver in {}\\{}: {} - {}",
                    root_name,
                    reg_path,
                    prog_id,
                    registry_description
                );

                devices.push(AscomDevice {
                    prog_id: prog_id.clone(),
                    name,
                    description: registry_description,
                });
            }

            index += 1;
        }

        let _ = RegCloseKey(key);
    }

    Some(devices)
}

unsafe fn get_driver_description(parent_key: &HKEY, prog_id: &str) -> Option<String> {
    let mut subkey: HKEY = HKEY::default();
    let prog_id_wide: Vec<u16> = prog_id.encode_utf16().chain(std::iter::once(0)).collect();

    let result = RegOpenKeyExW(
        *parent_key,
        PCWSTR::from_raw(prog_id_wide.as_ptr()),
        0,
        KEY_READ,
        &mut subkey,
    );

    if result.is_err() {
        return None;
    }

    let mut data_type: REG_VALUE_TYPE = REG_VALUE_TYPE(0);
    let mut data_buffer: [u8; 512] = [0; 512];
    // Why: `data_buffer.len()` is the compile-time
    // constant 512, trivially within u32 range. SAFE narrowing.
    let mut data_len = data_buffer.len() as u32;

    let result = RegQueryValueExW(
        subkey,
        PCWSTR::null(),
        None,
        Some(&mut data_type),
        Some(data_buffer.as_mut_ptr()),
        Some(&mut data_len),
    );

    let _ = RegCloseKey(subkey);

    if result.is_ok() && data_type == REG_SZ {
        // Why: `data_len` is u32 (≤512 on success, bounded
        // by the input buffer). u32 → usize widens on every supported Rust
        // target (no 16-bit-usize std target).
        let wide_slice: &[u16] = std::slice::from_raw_parts(
            data_buffer.as_ptr() as *const u16,
            (data_len as usize / 2).saturating_sub(1),
        );
        return Some(String::from_utf16_lossy(wide_slice));
    }

    None
}

/// ASCOM Device wrapper for COM interaction
///
/// This struct provides a safe wrapper around COM IDispatch for ASCOM devices.
/// It includes:
/// - Connection state tracking
/// - Health monitoring for detecting disconnected devices
/// - RAII cleanup via Drop trait
pub struct AscomDeviceConnection {
    // Private on purpose: every driver call goes through
    // `invoke_with_retry`, which owns the `EXCEPINFO`. A hand-rolled `Invoke`
    // passes `None` for `pExcepInfo` and throws away the driver's own account
    // of the failure, so the field stays unreachable outside this file.
    dispatch: IDispatch,
    connected: bool,
    health: HealthMonitor,
    /// ProgID for logging/diagnostics
    prog_id: String,
}

/// A failed `IDispatch::Invoke`, carrying whatever the driver itself said.
///
/// COM reports a refused call twice over: an HRESULT, and — when that HRESULT
/// is `DISP_E_EXCEPTION` — an `EXCEPINFO` the driver fills with a human
/// sentence, the component that raised it, and the underlying error code. The
/// `EXCEPINFO` fields must reach the operator, because `DISP_E_EXCEPTION`
/// alone means nothing more than `Exception occurred. (0x80020009)`.
///
/// Enabling tracking on a parked Pegasus NYX101 returns exactly that bare
/// HRESULT, while the `EXCEPINFO` for the same call carries
/// `bstrSource = ASCOM.PegasusAstroUnityServer`,
/// `bstrDescription = "Object reference not set to an instance of an object."`,
/// `scode = 0x80004003`.
struct InvokeError {
    /// HRESULT-level failure reported by `IDispatch::Invoke` itself.
    hresult: windows::core::Error,
    /// The driver's own account, when it wrote one into `EXCEPINFO`.
    driver: Option<String>,
}

impl std::fmt::Display for InvokeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Prefer the driver's sentence: when a driver bothered to explain
        // itself, that explanation is strictly more useful than the HRESULT,
        // and it already carries the real error code via `scode`.
        match &self.driver {
            Some(driver) => write!(f, "{driver}"),
            None => write!(f, "{}", self.hresult),
        }
    }
}

impl AscomDeviceConnection {
    pub fn new(prog_id: &str) -> AscomResult<Self> {
        // SAFETY: `CLSIDFromProgID` and `CoCreateInstance` are standard Windows COM
        // constructors. `prog_id_wide` is a locally-owned NUL-terminated UTF-16 buffer
        // that outlives the FFI call. CoCreateInstance returns an `IDispatch` whose
        // lifetime is managed by the `windows` crate's `Drop` impl, and apartment
        // requirements are honored by the caller (this runs on the STA worker thread).
        unsafe {
            let prog_id_wide: Vec<u16> = prog_id.encode_utf16().chain(std::iter::once(0)).collect();

            let clsid = CLSIDFromProgID(PCWSTR::from_raw(prog_id_wide.as_ptr())).map_err(|e| {
                AscomError::ClassNotRegistered {
                    prog_id: prog_id.to_string(),
                    cause: e.to_string(),
                }
            })?;

            let dispatch: IDispatch = CoCreateInstance(&clsid, None, CLSCTX_ALL).map_err(|e| {
                AscomError::CreateFailed {
                    prog_id: prog_id.to_string(),
                    cause: e.to_string(),
                }
            })?;

            tracing::info!("Created ASCOM COM object for: {}", prog_id);

            Ok(Self {
                dispatch,
                connected: false,
                health: HealthMonitor::default(),
                prog_id: prog_id.to_string(),
            })
        }
    }

    pub fn get_health(&self) -> ConnectionHealth {
        self.health.get_health()
    }

    /// Check if the device is healthy (responding to commands)
    pub fn is_healthy(&self) -> bool {
        matches!(
            self.health.get_health(),
            ConnectionHealth::Healthy | ConnectionHealth::Unknown
        )
    }

    pub fn connect(&mut self) -> AscomResult<()> {
        ComDispatch::connect(self)
    }

    pub fn disconnect(&mut self) -> AscomResult<()> {
        ComDispatch::disconnect(self)
    }

    pub fn is_connected(&self) -> AscomResult<bool> {
        self.get("Connected")
    }

    pub fn heartbeat(&self) -> AscomResult<()> {
        ComDispatch::heartbeat(self)
    }

    /// Invoke an ASCOM IDispatch member, retrying transient driver exceptions.
    ///
    /// The `EXCEPINFO` is owned here rather than accepted as a parameter, so
    /// no caller can pass `None` and drop the driver's account of a refusal.
    ///
    /// # Safety
    /// `params` and every pointer it contains, plus `pvarresult` when present,
    /// must remain valid for all retry attempts. The caller must also invoke
    /// this on the COM object's owning STA thread.
    unsafe fn invoke_with_retry(
        &self,
        dispid: i32,
        flags: DISPATCH_FLAGS,
        params: &DISPPARAMS,
        pvarresult: Option<*mut VARIANT>,
    ) -> Result<(), InvokeError> {
        const DISP_E_EXCEPTION: u32 = 0x8002_0009;
        const MAX_ATTEMPTS: u32 = 3;

        for attempt in 1..=MAX_ATTEMPTS {
            // Fresh per attempt: a failing driver allocates new BSTRs into this
            // structure every time, and reusing one buffer across attempts
            // would overwrite the prior iteration's pointers without freeing
            // them. The guard's `Drop` runs at the end of each iteration.
            let mut excep_info = OwnedExcepInfo::new();

            let result = self.dispatch.Invoke(
                dispid,
                &GUID::zeroed(),
                0,
                flags,
                params,
                pvarresult,
                Some(excep_info.as_mut() as *mut EXCEPINFO),
                None,
            );

            match result {
                Ok(()) => return Ok(()),
                Err(e) if e.code().0 as u32 == DISP_E_EXCEPTION && attempt < MAX_ATTEMPTS => {
                    tracing::debug!(
                        "ASCOM IDispatch::Invoke returned DISP_E_EXCEPTION for DISPID {} ({}); \
                         retrying (attempt {}/{})",
                        dispid,
                        excep_info
                            .describe()
                            .unwrap_or_else(|| "no driver description".to_string()),
                        attempt + 1,
                        MAX_ATTEMPTS
                    );
                    std::thread::sleep(std::time::Duration::from_millis(60));
                }
                Err(hresult) => {
                    return Err(InvokeError {
                        driver: excep_info.describe(),
                        hresult,
                    })
                }
            }
        }

        unreachable!("bounded IDispatch retry loop always returns")
    }

    fn get_dispid(&self, name: &str) -> windows::core::Result<i32> {
        // SAFETY: `IDispatch::GetIDsOfNames` is invoked with: a zeroed reserved GUID,
        // a locally-owned NUL-terminated UTF-16 buffer (`name_wide`) wrapped in a stack
        // `[PCWSTR; 1]`, a count matching the array length, the locale id 0, and a stack
        // `i32` out-parameter. All pointer arguments outlive the call.
        unsafe {
            let name_wide: Vec<u16> = name.encode_utf16().chain(std::iter::once(0)).collect();
            let names = [PCWSTR::from_raw(name_wide.as_ptr())];
            let mut dispid: i32 = 0;

            self.dispatch
                .GetIDsOfNames(&GUID::zeroed(), names.as_ptr(), 1, 0, &mut dispid)?;

            Ok(dispid)
        }
    }
}

impl ComDispatch for AscomDeviceConnection {
    /// The one path every property read, property write and method call
    /// takes to the driver.
    fn invoke(&self, call: &ComCall<'_>) -> AscomResult<ComValue> {
        let dispid = self
            .get_dispid(call.member)
            .map_err(|e| call.unknown_member(e.to_string()))?;

        // COM takes the arguments in reverse positional order.
        let mut args: Vec<VARIANT> = call.args.iter().rev().map(variant_from_arg).collect();
        let mut dispid_named = DISPID_PROPERTYPUT;

        let (flags, named_args, named_count) = match call.dispatch {
            Dispatch::Get => (DISPATCH_PROPERTYGET, ptr::null_mut(), 0),
            // A property put names its value argument DISPID_PROPERTYPUT.
            Dispatch::Put => (DISPATCH_PROPERTYPUT, &mut dispid_named as *mut i32, 1),
            Dispatch::Method => (DISPATCH_METHOD, ptr::null_mut(), 0),
        };
        let params = DISPPARAMS {
            rgvarg: if args.is_empty() {
                ptr::null_mut()
            } else {
                args.as_mut_ptr()
            },
            rgdispidNamedArgs: named_args,
            // Why: an ASCOM member takes at most a handful of arguments.
            cArgs: args.len() as u32,
            cNamedArgs: named_count,
        };

        // The guard runs `VariantClear` on drop, after the value has been
        // copied out, so a returned BSTR or SAFEARRAY (an image array is about
        // 96 MiB per frame) is released; for a scalar it does nothing.
        let mut result = OwnedVariant::empty();
        let wants_result = call.returns != ComKind::Void;

        // SAFETY: `params` points at `args` (a live Vec whose length is
        // `cArgs`) and, for a put, at the stack-owned `dispid_named`
        // (`cNamedArgs = 1`); with no arguments both pointers are null and
        // both counts 0, the documented empty shape. `result` is a live
        // out-VARIANT. All of them outlive the call, including its retries.
        // Caller invariant: this runs on the COM object's STA thread.
        unsafe {
            self.invoke_with_retry(
                dispid,
                flags,
                &params,
                wants_result.then(|| result.as_mut() as *mut VARIANT),
            )
        }
        .map_err(|e| call.invoke_error(e.to_string()))?;

        if !wants_result {
            return Ok(ComValue::Empty);
        }

        if call.dispatch == Dispatch::Get && call.returns == ComKind::I4 {
            // SAFETY: reads the type tag of the live result VARIANT.
            let vt = unsafe { (*result.get().Anonymous.Anonymous).vt };
            tracing::debug!(
                "ASCOM get_int_property('{}') VARIANT type: {} (VT_I2=2, VT_I4=3, VT_R8=5)",
                call.member,
                vt.0
            );
        }

        // SAFETY: `result` holds the VARIANT the driver just returned;
        // `variant_to_value` checks the type tag before reading any union arm
        // and copies the data into owned Rust values.
        unsafe { variant_to_value(result.get(), call.returns) }
            .map_err(|mismatch| call.type_error(mismatch.vt, mismatch.detail))
    }

    /// Connect, and then CHECK that the driver agrees.
    ///
    /// Setting `Connected = true` without an exception is not evidence that a
    /// device is there. Measured on a real rig 2026-08-09: with no ASI mount
    /// attached, `ASCOM.ASIMount.Telescope` accepted `Connected = true`
    /// silently, then reported `Connected = False`, `Slewing = True`,
    /// `SiderealTime = -1` and RA/Dec/Alt/Az all zero. This function believed
    /// it, so the app announced a connected mount, and every consumer
    /// downstream was handed `slewing: true` for ever — which is the shape that
    /// hangs an unattended run all night on a wait-for-slew that can never
    /// finish. The operator had only picked the wrong driver from a list where
    /// ASCOM advertises installed DRIVERS, not present HARDWARE.
    ///
    /// The read-back is polled rather than instant: ASCOM permits a driver to
    /// take a moment to come up, and rejecting a slow-but-genuine device would
    /// trade one false report for another.
    fn connect(&mut self) -> AscomResult<()> {
        self.health.reset(); // Reset health state on new connection

        // A failed write is already conclusive; only a *silent* write needs
        // verifying. Mark the object down first so every early return below
        // leaves `self.connected` accurate — on a reconnect the field still
        // holds `true` from the last successful session.
        self.connected = false;
        if let Err(e) = self.put("Connected", true) {
            self.health.mark_failed();
            return Err(e);
        }

        let started = std::time::Instant::now();
        let verdict = verify_connected_readback(
            &self.prog_id,
            CONNECT_VERIFY_TIMEOUT,
            CONNECT_VERIFY_POLL,
            || self.get::<bool>("Connected").map_err(|e| e.to_string()),
            std::thread::sleep,
            || started.elapsed(),
        );

        if let Err(message) = verdict {
            // Put the driver back down rather than leaving a half-open handle
            // for the next attempt to fight. Measured against the phantom ASI
            // mount: this write is accepted without an exception, so the
            // cleanup is real and not merely hopeful.
            let _ = self.put("Connected", false);
            // The health monitor was reset to "healthy" at the top of this
            // function. Leaving it there would have `is_healthy()` vouch for a
            // device that just failed to connect. `record_failure()` is NOT
            // enough here: it needs three strikes before it flips the flag, so
            // one call leaves the monitor answering `Unknown`, which
            // `is_healthy()` reads as fine (measured on the phantom ASI Mount,
            // 2026-08-09). A refused connect is conclusive, so say so.
            self.health.mark_failed();
            tracing::warn!("ASCOM device {} failed to come online", self.prog_id);
            return Err(AscomError::NotOnline(message));
        }

        self.connected = true;
        self.health.record_success();
        tracing::info!("ASCOM device {} connected", self.prog_id);
        Ok(())
    }

    fn disconnect(&mut self) -> AscomResult<()> {
        self.put("Connected", false)?;
        self.connected = false;
        tracing::info!("ASCOM device {} disconnected", self.prog_id);
        Ok(())
    }

    /// Perform a heartbeat check by reading the Connected property
    /// This should be called periodically to verify device is still responding
    fn heartbeat(&self) -> AscomResult<()> {
        match self.get::<bool>("Connected") {
            Ok(_) => {
                self.health.record_success();
                Ok(())
            }
            Err(e) => {
                self.health.record_failure();
                Err(e)
            }
        }
    }

    fn health(&self) -> ConnectionHealth {
        self.health.get_health()
    }
}

impl Drop for AscomDeviceConnection {
    fn drop(&mut self) {
        // Why: COM apartment threading requires that property writes (including
        // `Connected = false`) execute on the same STA thread that called
        // `CoInitialize`. Drop runs on whichever thread happens to release the
        // last reference; that is not guaranteed to be the originating STA
        // thread, so issuing a `disconnect()` here can:
        //   - call into a stale apartment proxy (RPC_E_WRONG_THREAD), or
        //   - run after `uninit_com()` has torn down the apartment, or
        //   - race the wrapper-managed disconnect already in flight.
        //
        // Invariant: explicit `disconnect()` MUST be issued on the STA worker
        // thread (see `ascom_wrapper*.rs` worker loops). Drop simply marks the
        // connection as no-longer-tracked and lets COM reference counting
        // release the IDispatch (the IDispatch::Release call IS allowed from
        // any thread per COM rules — only typed method/property calls require
        // the STA).
        if self.connected {
            tracing::warn!(
                "AscomDeviceConnection::drop on {} while still flagged connected — \
                 explicit disconnect was skipped. Wrapper STA worker thread is \
                 expected to issue disconnect before drop.",
                self.prog_id
            );
            self.connected = false;
        }
        tracing::debug!("AscomDeviceConnection::drop - released {}", self.prog_id);
    }
}

// SAFETY: COM objects are apartment-threaded and we manage thread affinity
// ourselves. All COM property/method calls MUST happen from the thread that
// called `CoInitialize` (the STA apartment thread). The wrapper pattern in
// `ascom_wrapper*.rs` enforces this: the typed wrapper struct (e.g.
// `AscomCamera`) is created on, and from then on only ever touched from, the
// owning apartment thread — the process-wide STA worker
// (`ascom_wrapper::sta_worker`) for the camera/mount/filter-wheel classes, or a
// per-device STA worker for the others. Every COM call is dispatched onto that
// thread via a channel, and `Drop` is a no-op, so the wrapper struct is safe to
// move/share across other threads (only its handle moves; the IDispatch is
// released on the apartment thread when the on-thread pump drops it).
unsafe impl Send for AscomDeviceConnection {}
// SAFETY: Same justification as the `Send` impl above — thread affinity is
// enforced by the STA worker pattern in `ascom_wrapper*.rs`; concurrent
// immutable references never reach the underlying IDispatch because every call
// is funneled through a channel onto the apartment thread.
unsafe impl Sync for AscomDeviceConnection {}

/// Cover for the driver's own explanation surviving a failed `IDispatch::Invoke`.
///
/// These tests stand a Rust `IDispatch` in for the driver so the whole path —
/// the public property accessors, `invoke_with_retry`,
/// `OwnedExcepInfo::describe`, and the `String` a caller finally shows an
/// operator — runs for real, with no COM apartment and no hardware.
///
/// The stand-in and its constructors are `pub(crate)` so the device
/// wrappers (`camera`, `switch`, `cover_calibrator`) can drive their own
/// hand-rolled invoke paths through the same refusing driver.
#[cfg(test)]
pub(crate) mod excepinfo_recovery_tests {
    use super::*;
    use crate::com::ComArg;
    use std::mem::ManuallyDrop;
    use std::sync::atomic::{AtomicU32, Ordering};
    use std::sync::Arc;
    use windows::core::{implement, Error, BSTR, HRESULT};
    use windows::Win32::System::Com::{IDispatch_Impl, ITypeInfo};

    const DISP_E_EXCEPTION: HRESULT = HRESULT(0x8002_0009_u32 as i32);
    const E_NOTIMPL: HRESULT = HRESULT(0x8000_4001_u32 as i32);
    /// The `scode` the NYX101 wrote alongside its description.
    const DRIVER_SCODE: i32 = 0x8000_4003_u32 as i32;
    /// ASCOM's `NotImplementedException` base code, used by the read case.
    const ASCOM_NOT_IMPLEMENTED: i32 = 0x8004_0400_u32 as i32;

    /// What the stand-in driver writes into `EXCEPINFO` when it refuses.
    pub(crate) enum Excuse {
        /// A driver that explains itself, as ASCOM intends.
        Spoken {
            source: &'static str,
            description: &'static str,
            scode: i32,
        },
        /// A driver that raises `DISP_E_EXCEPTION` and writes nothing — the
        /// case where a bare HRESULT genuinely is all there is.
        Silent,
    }

    /// An `IDispatch` that refuses every call the way the parked NYX101 did.
    #[implement(IDispatch)]
    struct RefusingDriver {
        excuse: Excuse,
        /// Shared with the test so it can count `Invoke` attempts.
        attempts: Arc<AtomicU32>,
        /// When set, each description names its attempt number, so a test can
        /// prove the reported message came from the LAST attempt.
        number_the_attempts: bool,
    }

    impl IDispatch_Impl for RefusingDriver {
        fn GetTypeInfoCount(&self) -> windows::core::Result<u32> {
            Ok(0)
        }

        fn GetTypeInfo(&self, _itinfo: u32, _lcid: u32) -> windows::core::Result<ITypeInfo> {
            Err(Error::from(E_NOTIMPL))
        }

        fn GetIDsOfNames(
            &self,
            _riid: *const GUID,
            _rgsznames: *const PCWSTR,
            cnames: u32,
            _lcid: u32,
            rgdispid: *mut i32,
        ) -> windows::core::Result<()> {
            // Any DISPID will do — this stand-in refuses every member.
            for i in 0..cnames as isize {
                // SAFETY: `get_dispid` passes a `*mut i32` buffer of at least
                // `cnames` elements (it is always exactly 1 here).
                unsafe { *rgdispid.offset(i) = 0x2A };
            }
            Ok(())
        }

        fn Invoke(
            &self,
            _dispidmember: i32,
            _riid: *const GUID,
            _lcid: u32,
            _wflags: DISPATCH_FLAGS,
            _pdispparams: *const DISPPARAMS,
            _pvarresult: *mut VARIANT,
            pexcepinfo: *mut EXCEPINFO,
            _puargerr: *mut u32,
        ) -> windows::core::Result<()> {
            let attempt = self.attempts.fetch_add(1, Ordering::SeqCst) + 1;

            if let (
                Excuse::Spoken {
                    source,
                    description,
                    scode,
                },
                false,
            ) = (&self.excuse, pexcepinfo.is_null())
            {
                let description = if self.number_the_attempts {
                    format!("{description} (attempt {attempt})")
                } else {
                    (*description).to_string()
                };

                // SAFETY: `pexcepinfo` is the caller's `EXCEPINFO` out-param,
                // checked non-null just above. Writing freshly allocated
                // `BSTR`s is precisely what a real driver does: ownership
                // transfers to the caller, which is the transfer
                // `OwnedExcepInfo` exists to account for. The fields being
                // overwritten are the nulls left by `EXCEPINFO::default()`.
                unsafe {
                    (*pexcepinfo).bstrSource = ManuallyDrop::new(BSTR::from(*source));
                    (*pexcepinfo).bstrDescription =
                        ManuallyDrop::new(BSTR::from(description.as_str()));
                    (*pexcepinfo).scode = *scode;
                }
            }

            Err(Error::from(DISP_E_EXCEPTION))
        }
    }

    /// Build a connection wrapped around the stand-in driver.
    ///
    /// `connected: false` keeps `Drop` quiet — it only warns about a
    /// still-connected handle and never calls into COM.
    pub(crate) fn connection(
        excuse: Excuse,
        number_the_attempts: bool,
    ) -> (AscomDeviceConnection, Arc<AtomicU32>) {
        let attempts = Arc::new(AtomicU32::new(0));
        let dispatch: IDispatch = RefusingDriver {
            excuse,
            attempts: Arc::clone(&attempts),
            number_the_attempts,
        }
        .into();

        let device = AscomDeviceConnection {
            dispatch,
            connected: false,
            health: HealthMonitor::default(),
            prog_id: "ASCOM.PegasusAstroNYX101.Telescope".to_string(),
        };

        (device, attempts)
    }

    pub(crate) fn parked_mount() -> Excuse {
        Excuse::Spoken {
            source: "ASCOM.PegasusAstroUnityServer",
            description: "Cannot set Tracking while the mount is parked",
            scode: DRIVER_SCODE,
        }
    }

    #[test]
    fn property_write_surfaces_the_drivers_explanation() {
        let (device, _) = connection(parked_mount(), false);

        let err = device.put("Tracking", true).unwrap_err().to_string();

        assert!(
            err.contains("Cannot set Tracking while the mount is parked"),
            "the driver's sentence was dropped: {err}"
        );
        assert!(
            err.contains("ASCOM.PegasusAstroUnityServer"),
            "the component that raised it was dropped: {err}"
        );
        assert!(
            err.contains("0x80004003"),
            "the driver's own error code was dropped: {err}"
        );
        // The message must not collapse to the bare
        // "Exception occurred. (0x80020009)" the HRESULT alone would give.
        assert!(
            !err.contains("Exception occurred"),
            "fell back to the bare HRESULT: {err}"
        );
    }

    #[test]
    fn every_typed_property_write_surfaces_it_not_just_bool() {
        // Each setter passed its own `None`, so each lost the description
        // independently. These four are the writes a night depends on:
        // tracking, gain/offset, the cooling setpoint, and the clock.
        let (device, _) = connection(parked_mount(), false);

        for (label, err) in [
            (
                "bool",
                device.put("Tracking", true).unwrap_err().to_string(),
            ),
            ("int", device.put("Gain", 120).unwrap_err().to_string()),
            (
                "double",
                device
                    .put("SetCCDTemperature", -10.0)
                    .unwrap_err()
                    .to_string(),
            ),
            (
                "date",
                device
                    .put("UTCDate", ComArg::Date(45_000.0))
                    .unwrap_err()
                    .to_string(),
            ),
        ] {
            assert!(
                err.contains("Cannot set Tracking while the mount is parked"),
                "{label} setter lost the driver's description: {err}"
            );
        }
    }

    #[test]
    fn property_reads_surface_it_too() {
        // Reads passed the same `None`. A camera that does not implement
        // `Gain` says so in the EXCEPINFO; that is the difference between
        // "your camera has no gain control" and a hex code.
        let (device, _) = connection(
            Excuse::Spoken {
                source: "ASCOM.ASICamera2",
                description: "Property Gain is not implemented by this camera",
                scode: ASCOM_NOT_IMPLEMENTED,
            },
            false,
        );

        let err = device.get::<i32>("Gain").unwrap_err().to_string();

        assert!(
            err.contains("Property Gain is not implemented by this camera"),
            "the getter lost the driver's description: {err}"
        );
        assert!(err.contains("ASCOM.ASICamera2"), "{err}");
    }

    #[test]
    fn a_silent_driver_still_reports_the_hresult() {
        // Not every driver fills in an EXCEPINFO. When none is offered the
        // operator must still get the HRESULT, not an empty tail.
        let (device, attempts) = connection(Excuse::Silent, false);

        let err = device.put("Tracking", true).unwrap_err().to_string();

        assert!(
            err.contains("0x80020009"),
            "expected the raw HRESULT when the driver said nothing: {err}"
        );
        assert_eq!(
            attempts.load(Ordering::SeqCst),
            3,
            "DISP_E_EXCEPTION is retried three times"
        );
    }

    #[test]
    fn the_reported_description_is_the_final_attempts() {
        // `invoke_with_retry` retries DISP_E_EXCEPTION, and each attempt has
        // the driver allocate a fresh pair of BSTRs. Hoisting one EXCEPINFO
        // out of the loop would leak the earlier attempts' strings and risk
        // reporting a stale sentence; a per-attempt guard cannot.
        let (device, attempts) = connection(parked_mount(), true);

        let err = device.put("Tracking", true).unwrap_err().to_string();

        assert_eq!(attempts.load(Ordering::SeqCst), 3);
        assert!(
            err.contains("attempt 3"),
            "expected the final attempt's description: {err}"
        );
        assert!(
            !err.contains("attempt 1"),
            "a stale description leaked into the message: {err}"
        );
    }
}
