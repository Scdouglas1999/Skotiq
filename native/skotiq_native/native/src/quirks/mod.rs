//! Vendor Quirks Database
//!
//! This module provides a centralized database of known device and vendor quirks,
//! along with workarounds that should be applied automatically.
//!
//! ## Overview
//!
//! Many astronomy devices have known bugs or require workarounds due to:
//! - SDK bugs that report incorrect values
//! - Firmware issues that require specific timing
//! - Hardware variations that need special handling
//! - Discovery race conditions that can cause crashes
//!
//! Rather than scattering workarounds throughout the codebase, this module
//! provides a centralized registry that can be queried before/after operations.
//!
//! ## Usage
//!
//! ```rust,ignore
//! use skotiq_native::quirks::{get_quirks_for_device, Quirk};
//!
//! let quirks = get_quirks_for_device("native:zwo:ASI294MC");
//! for quirk in &quirks {
//!     match quirk {
//!         Quirk::Temperature(TemperatureQuirk::ScaleFactor(factor)) => {
//!             // Apply temperature scaling
//!             raw_temp = raw_temp / factor;
//!         }
//!         _ => {}
//!     }
//! }
//! ```

mod database;
mod types;

pub use database::*;
pub use types::*;

use crate::NativeVendor;
use std::collections::HashMap;
use std::sync::{Arc, RwLock};

/// Global quirk registry with runtime overrides
static QUIRK_REGISTRY: std::sync::OnceLock<Arc<RwLock<QuirkRegistry>>> = std::sync::OnceLock::new();

/// Initialize or get the global quirk registry
fn get_registry() -> &'static Arc<RwLock<QuirkRegistry>> {
    QUIRK_REGISTRY.get_or_init(|| Arc::new(RwLock::new(QuirkRegistry::new())))
}

/// Registry that combines built-in quirks with runtime overrides
pub struct QuirkRegistry {
    /// Runtime overrides that take precedence over built-in quirks
    overrides: HashMap<String, Vec<Quirk>>,
    /// Devices for which quirks should be disabled (for testing)
    disabled_devices: std::collections::HashSet<String>,
}

impl QuirkRegistry {
    fn new() -> Self {
        Self {
            overrides: HashMap::new(),
            disabled_devices: std::collections::HashSet::new(),
        }
    }
}

/// Every quirk that applies to `device_id` (e.g. `native:zwo:ASI294MC Pro`), in
/// descending priority: a runtime override wins outright, otherwise the built-in
/// database is consulted device ID first, then model pattern, then vendor.
pub fn get_quirks_for_device(device_id: &str) -> Vec<Quirk> {
    let registry = get_registry().read().unwrap_or_else(|e| e.into_inner());

    // Check if quirks are disabled for this device
    if registry.disabled_devices.contains(device_id) {
        tracing::debug!("Quirks disabled for device: {}", device_id);
        return Vec::new();
    }

    // Check for runtime overrides first
    if let Some(overrides) = registry.overrides.get(device_id) {
        tracing::debug!(
            "Using {} runtime override quirks for device: {}",
            overrides.len(),
            device_id
        );
        return overrides.clone();
    }

    drop(registry); // Release the lock before calling the database

    // Get quirks from the built-in database
    database::get_device_quirks(device_id)
}

/// Vendor-wide quirks, applying to every device from that vendor.
pub fn get_quirks_for_vendor(vendor: &NativeVendor) -> Vec<Quirk> {
    database::get_vendor_quirks(vendor)
}

/// Replace a device's quirks at runtime, taking precedence over the built-in
/// database so a configuration can be tried without a code change.
pub fn set_quirk_overrides(device_id: &str, quirks: Vec<Quirk>) {
    let mut registry = get_registry().write().unwrap_or_else(|e| e.into_inner());
    tracing::info!(
        "Setting {} quirk overrides for device: {}",
        quirks.len(),
        device_id
    );
    registry.overrides.insert(device_id.to_string(), quirks);
}

/// Clear runtime quirk overrides for a device.
///
/// After clearing, the device will use the built-in quirks again.
pub fn clear_quirk_overrides(device_id: &str) {
    let mut registry = get_registry().write().unwrap_or_else(|e| e.into_inner());
    tracing::info!("Clearing quirk overrides for device: {}", device_id);
    registry.overrides.remove(device_id);
}

/// Disable all quirks for a device.
///
/// This is useful for testing to ensure quirks are actually being applied.
pub fn disable_quirks_for_device(device_id: &str) {
    let mut registry = get_registry().write().unwrap_or_else(|e| e.into_inner());
    tracing::info!("Disabling all quirks for device: {}", device_id);
    registry.disabled_devices.insert(device_id.to_string());
}

/// Re-enable quirks for a device after they were disabled.
pub fn enable_quirks_for_device(device_id: &str) {
    let mut registry = get_registry().write().unwrap_or_else(|e| e.into_inner());
    tracing::info!("Re-enabling quirks for device: {}", device_id);
    registry.disabled_devices.remove(device_id);
}

/// Correct a raw SDK temperature by every temperature quirk the device carries.
pub fn apply_temperature_quirks(device_id: &str, raw_temp: f64) -> f64 {
    let quirks = get_quirks_for_device(device_id);
    let mut temp = raw_temp;

    for quirk in quirks {
        if let Quirk::Temperature(temp_quirk) = quirk {
            match temp_quirk {
                TemperatureQuirk::ScaleFactor(factor) => {
                    let old_temp = temp;
                    temp /= factor;
                    tracing::trace!(
                        "Applied temperature scale factor {} to {}: {} -> {}",
                        factor,
                        device_id,
                        old_temp,
                        temp
                    );
                }
                TemperatureQuirk::Offset(offset) => {
                    let old_temp = temp;
                    temp += offset;
                    tracing::trace!(
                        "Applied temperature offset {} to {}: {} -> {}",
                        offset,
                        device_id,
                        old_temp,
                        temp
                    );
                }
                TemperatureQuirk::Inverted => {
                    let old_temp = temp;
                    temp = -temp;
                    tracing::trace!(
                        "Applied temperature inversion to {}: {} -> {}",
                        device_id,
                        old_temp,
                        temp
                    );
                }
                TemperatureQuirk::SkipFirstRead => {
                    // This quirk is handled at the caller level
                    tracing::trace!(
                        "Temperature SkipFirstRead quirk noted for {} (handled by caller)",
                        device_id
                    );
                }
                TemperatureQuirk::RequiresDelayMs(delay_ms) => {
                    // This quirk is handled at the caller level
                    tracing::trace!(
                        "Temperature requires {}ms delay for {} (handled by caller)",
                        delay_ms,
                        device_id
                    );
                }
            }
        }
    }

    temp
}

/// Look up the settle delay required before trusting a temperature read.
///
/// Callers should apply this before issuing the SDK read. The helper returns
/// only `RequiresDelayMs`; scale/offset/inversion corrections are handled by
/// `apply_temperature_quirks` after the raw value is available.
pub fn get_temperature_delay_ms(device_id: &str) -> Option<u64> {
    let quirks = get_quirks_for_device(device_id);
    for quirk in quirks {
        if let Quirk::Temperature(TemperatureQuirk::RequiresDelayMs(ms)) = quirk {
            return Some(ms);
        }
    }
    None
}

/// Return true when the driver's first temperature read after connect must be discarded.
pub fn should_skip_first_temperature_read(device_id: &str) -> bool {
    get_quirks_for_device(device_id)
        .iter()
        .any(|q| matches!(q, Quirk::Temperature(TemperatureQuirk::SkipFirstRead)))
}

/// Look up the cooler target range declared for a device.
pub fn get_cooler_range(device_id: &str) -> Option<(f64, f64)> {
    let quirks = get_quirks_for_device(device_id);
    for quirk in quirks {
        if let Quirk::Camera(CameraQuirk::CoolerRange { min_temp, max_temp }) = quirk {
            return Some((min_temp, max_temp));
        }
    }
    None
}

/// Look up the focuser step size (microns per motor step) declared for a device.
///
/// Vendor SDKs that omit this datum (notably ZWO EAF) require a per-model lookup
/// so the focus-model micron axis matches mechanical reality. The first matching
/// `FocuserStepSizeMicrons` quirk is returned; absence means the SDK is expected
/// to supply the value or the caller must surface an explicit error.
pub fn get_focuser_step_size_um(device_id: &str) -> Option<f64> {
    let quirks = get_quirks_for_device(device_id);
    for quirk in quirks {
        if let Quirk::Position(PositionQuirk::FocuserStepSizeMicrons(um)) = quirk {
            return Some(um);
        }
    }
    None
}

/// Look up the `DelayAfterMoveMs` position quirk for a device.
///
/// Used by filter wheel and rotator drivers whose firmware briefly reports a
/// stale position immediately after a move completes. Returns the first
/// matching delay; absence means no quirk is registered for this device and
/// the caller may skip the post-move settle.
pub fn get_position_delay_after_move_ms(device_id: &str) -> Option<u64> {
    let quirks = get_quirks_for_device(device_id);
    for quirk in quirks {
        if let Quirk::Position(PositionQuirk::DelayAfterMoveMs(ms)) = quirk {
            return Some(ms);
        }
    }
    None
}

/// Delay in milliseconds a device requires after `operation`, or `None` when it
/// declares no timing quirk for that operation.
pub fn get_timing_delay(device_id: &str, operation: &str) -> Option<u64> {
    let quirks = get_quirks_for_device(device_id);

    for quirk in quirks {
        if let Quirk::Timing(timing_quirk) = quirk {
            match &timing_quirk {
                TimingQuirk::DelayAfterOperation {
                    operation_name,
                    delay_ms,
                } => {
                    if operation_name == operation {
                        return Some(*delay_ms);
                    }
                }
                TimingQuirk::DelayAfterConnect(delay_ms) if operation == "connect" => {
                    return Some(*delay_ms);
                }
                TimingQuirk::DelayAfterDisconnect(delay_ms) if operation == "disconnect" => {
                    return Some(*delay_ms);
                }
                TimingQuirk::DelayBetweenCommands(delay_ms) if operation == "command" => {
                    return Some(*delay_ms);
                }
                _ => {}
            }
        }
    }

    None
}

/// Discovery operations to skip for a vendor, because some SDKs crash when they
/// are performed during enumeration.
pub fn get_discovery_skip_operations(vendor: &NativeVendor) -> Vec<String> {
    let quirks = get_quirks_for_vendor(vendor);
    let mut skip_ops = Vec::new();

    for quirk in quirks {
        if let Quirk::Discovery(discovery_quirk) = quirk {
            match discovery_quirk {
                DiscoveryQuirk::SkipOperation(op) => {
                    skip_ops.push(op);
                }
                DiscoveryQuirk::SkipOperations(ops) => {
                    skip_ops.extend(ops);
                }
                _ => {}
            }
        }
    }

    skip_ops
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    /// Serializes tests that read or mutate the process-global `QUIRK_REGISTRY`
    /// under the shared `native:zwo:ASI294MC Pro` key: one test disables quirks
    /// for that key while another asserts they are non-empty, so unserialized
    /// they race on the transient disabled window. Poisoning is recovered from
    /// because a panic in one test must not wedge the rest.
    static REGISTRY_GUARD: Mutex<()> = Mutex::new(());

    fn registry_guard() -> std::sync::MutexGuard<'static, ()> {
        REGISTRY_GUARD.lock().unwrap_or_else(|e| e.into_inner())
    }

    #[test]
    fn test_get_zwo_quirks() {
        let _guard = registry_guard();
        let quirks = get_quirks_for_device("native:zwo:ASI294MC Pro");
        assert!(!quirks.is_empty(), "ZWO ASI294 should have model quirks");

        // The ZWO ASI driver divides `ASI_TEMPERATURE` by 10 inline, so the
        // temperature ScaleFactor quirk was intentionally removed from the
        // database (would have double-scaled). The ASI294-specific
        // `SkipFirstRead` quirk must still be present.
        let has_skip_first = quirks
            .iter()
            .any(|q| matches!(q, Quirk::Temperature(TemperatureQuirk::SkipFirstRead)));
        assert!(
            has_skip_first,
            "ASI294 should retain its SkipFirstRead temperature quirk"
        );
    }

    #[test]
    fn test_get_qhy_quirks() {
        let quirks = get_quirks_for_vendor(&NativeVendor::Qhy);
        assert!(!quirks.is_empty(), "QHY should have vendor quirks");

        // Check for discovery protection
        let has_discovery_protection = quirks.iter().any(|q| matches!(q, Quirk::Discovery(_)));
        assert!(
            has_discovery_protection,
            "QHY should have discovery protection"
        );
    }

    #[test]
    fn test_apply_temperature_quirks_passthrough_for_zwo() {
        // The ZWO ASI driver already divides ASI_TEMPERATURE by 10 inline (see
        // `vendor/zwo.rs` ~828/1162), so the database intentionally has no
        // ScaleFactor quirk for ZWO cameras. apply_temperature_quirks must
        // therefore be a no-op for ZWO cameras to avoid double-scaling.
        let _guard = registry_guard();
        let raw_temp = 20.0;
        let corrected = apply_temperature_quirks("native:zwo:ASI294MC Pro", raw_temp);
        assert!(
            (corrected - 20.0).abs() < 0.01,
            "ZWO temperature must not be re-scaled by quirks layer: got {}",
            corrected
        );
    }

    #[test]
    fn test_apply_temperature_quirks_with_runtime_override() {
        // When a runtime override declares a ScaleFactor, the helper must apply
        // it — this is the wire-up that diagnostics and per-device tuning rely
        // on.
        let device_id = "test:scale:device";
        set_quirk_overrides(
            device_id,
            vec![Quirk::Temperature(TemperatureQuirk::ScaleFactor(10.0))],
        );

        let corrected = apply_temperature_quirks(device_id, 200.0);
        assert!(
            (corrected - 20.0).abs() < 0.01,
            "ScaleFactor override should scale temperature: got {}",
            corrected
        );

        clear_quirk_overrides(device_id);
    }

    #[test]
    fn test_get_temperature_delay_player_one_vendor_wide() {
        let delay = get_temperature_delay_ms("native:playerone:0");
        assert_eq!(
            delay,
            Some(50),
            "Player One vendor-wide temperature settle delay must be exposed"
        );
    }

    #[test]
    fn test_should_skip_first_temperature_read_zwo_asi294() {
        assert!(
            should_skip_first_temperature_read("native:zwo:ZWO ASI294MC Pro"),
            "ASI294 first temperature read quirk must be exposed"
        );
    }

    #[test]
    fn test_get_cooler_range_qhy268() {
        assert_eq!(
            get_cooler_range("native:qhy:QHY268M-123"),
            Some((-35.0, 25.0)),
            "QHY268 cooler range quirk must be exposed"
        );
    }

    #[test]
    fn test_get_position_delay_after_move_ms_zwo_efw() {
        // ZWO EFW filter wheels carry a 500ms DelayAfterMoveMs quirk that
        // `ZwoFilterWheel::move_to_position` consumes after a successful
        // EFWSetPosition. This test guards the lookup contract that wiring
        // depends on.
        let delay = get_position_delay_after_move_ms("native:zwo:efw:0");
        assert_eq!(
            delay,
            Some(500),
            "ZWO EFW must declare a 500ms post-move settle delay"
        );
    }

    #[test]
    fn test_get_timing_delay_zwo_asi533_connect() {
        // ASI533 cameras carry a 200ms DelayAfterConnect quirk that
        // `ZwoCamera::connect` consumes after open+init.
        let delay = get_timing_delay("native:zwo:ZWO ASI533MC Pro", "connect");
        assert_eq!(
            delay,
            Some(200),
            "ASI533 must declare a 200ms post-connect settle delay"
        );
    }

    #[test]
    fn test_get_timing_delay_other_zwo_camera_no_connect_quirk() {
        // Cameras without a DelayAfterConnect entry must return None so the
        // caller knows to skip the sleep, not silently apply a default.
        let delay = get_timing_delay("native:zwo:ZWO ASI294MC Pro", "connect");
        assert_eq!(
            delay, None,
            "ASI294 must not carry a DelayAfterConnect quirk"
        );
    }

    #[test]
    fn test_quirk_overrides() {
        let device_id = "test:device:1";

        // Initially should have no quirks
        let quirks = get_quirks_for_device(device_id);
        assert!(quirks.is_empty());

        // Set override
        set_quirk_overrides(
            device_id,
            vec![Quirk::Temperature(TemperatureQuirk::ScaleFactor(5.0))],
        );

        let quirks = get_quirks_for_device(device_id);
        assert_eq!(quirks.len(), 1);

        // Clear override
        clear_quirk_overrides(device_id);
        let quirks = get_quirks_for_device(device_id);
        assert!(quirks.is_empty());
    }

    #[test]
    fn test_disable_quirks() {
        let _guard = registry_guard();
        let device_id = "native:zwo:ASI294MC Pro";

        // Should have quirks by default (model-specific SkipFirstRead)
        let quirks = get_quirks_for_device(device_id);
        assert!(!quirks.is_empty(), "ZWO device should have vendor quirks");

        // Disable quirks
        disable_quirks_for_device(device_id);
        let quirks = get_quirks_for_device(device_id);
        assert!(quirks.is_empty(), "Quirks should be disabled");

        // Re-enable
        enable_quirks_for_device(device_id);
        let quirks = get_quirks_for_device(device_id);
        assert!(!quirks.is_empty(), "Quirks should be re-enabled");
    }
}
