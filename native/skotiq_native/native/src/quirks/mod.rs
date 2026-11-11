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

use skotiq_device::Vendor;

/// Every quirk that applies to `device_id` (e.g. `native:zwo:ASI294MC Pro`):
/// the database is consulted device ID first, then model pattern, then vendor.
pub fn get_quirks_for_device(device_id: &str) -> Vec<Quirk> {
    database::get_device_quirks(device_id)
}

/// Vendor-wide quirks, applying to every device from that vendor.
pub fn get_quirks_for_vendor(vendor: &Vendor) -> Vec<Quirk> {
    database::get_vendor_quirks(vendor)
}

/// Look up the settle delay required before trusting a temperature read.
///
/// Callers should apply this before issuing the SDK read.
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

/// Delay in milliseconds a device requires after connecting, or `None` when
/// it declares none.
pub fn get_connect_delay_ms(device_id: &str) -> Option<u64> {
    get_quirks_for_device(device_id)
        .into_iter()
        .find_map(|quirk| match quirk {
            Quirk::Timing(TimingQuirk::DelayAfterConnect(delay_ms)) => Some(delay_ms),
            _ => None,
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_get_zwo_quirks() {
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
        let quirks = get_quirks_for_vendor(&Vendor::Qhy);
        assert!(!quirks.is_empty(), "QHY should have vendor quirks");

        let has_discovery_protection = quirks.iter().any(|q| matches!(q, Quirk::Discovery(_)));
        assert!(
            has_discovery_protection,
            "QHY should have discovery protection"
        );
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
    fn test_get_connect_delay_zwo_asi533() {
        // ASI533 cameras carry a 200ms DelayAfterConnect quirk that
        // `ZwoCamera::connect` consumes after open+init.
        let delay = get_connect_delay_ms("native:zwo:ZWO ASI533MC Pro");
        assert_eq!(
            delay,
            Some(200),
            "ASI533 must declare a 200ms post-connect settle delay"
        );
    }

    #[test]
    fn test_get_connect_delay_other_zwo_camera_has_none() {
        // Cameras without a DelayAfterConnect entry must return None so the
        // caller knows to skip the sleep, not silently apply a default.
        let delay = get_connect_delay_ms("native:zwo:ZWO ASI294MC Pro");
        assert_eq!(
            delay, None,
            "ASI294 must not carry a DelayAfterConnect quirk"
        );
    }
}
