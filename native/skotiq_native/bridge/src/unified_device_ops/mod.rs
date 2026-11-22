//! Unified Device Operations Implementation
//!
//! This module is the one and only `DeviceOps` implementation the sequencer
//! runs against. Nothing may add a second one: `set_device_ops` on the
//! process-global executor is last-writer-wins, so two impls means whichever
//! registered last silently owns every device call.
//!
//! # Architecture
//!
//! ```text
//! ┌─────────────────┐
//! │    Sequencer    │
//! └────────┬────────┘
//!          │ uses DeviceOps trait
//!          ▼
//! ┌─────────────────┐
//! │ UnifiedDeviceOps│
//! └────────┬────────┘
//!          │ calls bridge API
//!          ▼
//! ┌─────────────────┐
//! │   Bridge API    │
//! │  (api_* funcs)  │
//! └────────┬────────┘
//!          │ routes by device ID prefix
//!          ▼
//! ┌─────────────────────────────────────────┐
//! │              DeviceManager              │
//! ├────────┬────────┬─────────┬────────────┤
//! │ ASCOM  │ Alpaca │  INDI   │   Native   │
//! │(ascom:)│(alpaca:)│(indi:) │(native:zwo)│
//! └────────┴────────┴─────────┴────────────┘
//! ```
//!
//! # Usage
//!
//! ```rust,ignore
//! use skotiq_bridge::unified_device_ops::create_unified_device_ops;
//!
//! let ops = create_unified_device_ops();
//! executor.set_device_ops(ops);
//! ```
//!
//! # `as`-cast policy
//!
//! Same pattern groupings as `sequencer_ops.rs` (this file is the unified
//! replacement and the cast taxonomy is identical):
//! - **bool → u8** (lines 660, 904): wire encoding.
//! - **Filter wheel index ±1** (lines 815, 817): bounded by slot count.
//! - **star_count usize → u32** (line 544): real frames have ≤ tens of
//!   thousands of stars; saturating cast would catch any pathology.
//! - **Star-count average f64** (line 1300): exact widening.
//! - **Julian Day chrono fields**: computed by
//!   `sequencer/src/meridian.rs::julian_day`, where the per-site reasoning
//!   lives.

use crate::device_manager::get_device_manager;
use crate::state::SharedAppState;
use crate::unified_device_ops::pointing::{altitude_degrees, MountPointing};
// Julian Day and local sidereal time come from the sequencer; this file keeps
// no copy of either.
pub(crate) use crate::device_manager::capture::sequencer_error;
use crate::device_manager::roles::RigRole;
use skotiq_sequencer::{DeviceError, DeviceResult, SiteOps};
use std::sync::Arc;

mod camera;
#[cfg(test)]
mod capture_pins_tests;
mod connection;
mod cover_calibrator;
mod dome;
mod filter_wheel;
mod focuser;
#[cfg(test)]
mod frame_defaults_tests;
mod frame_store;
pub(crate) use frame_store::frame_shape;
#[cfg(test)]
pub(crate) use frame_store::measure_light_frame;
#[cfg(test)]
mod frame_tests;
mod guider;
mod mount;
mod operator;
mod plate_solve;
pub(crate) mod pointing;
#[cfg(test)]
mod pointing_tests;
#[cfg(test)]
mod reopen_reach_tests;
pub(crate) mod rich_header;
#[cfg(test)]
mod rig_grading_tests;
mod rotator;
mod safety;
mod site;
mod solve_diagnostics;
#[cfg(test)]
mod tests;

/// Unified device operations implementation
///
/// This is the recommended DeviceOps implementation for the sequencer.
/// It routes all device operations through the bridge API which handles:
/// - Device ID prefix routing (ascom:, alpaca:, indi:, native:)
/// - Connection state management
/// - Error handling and logging
pub struct UnifiedDeviceOps {
    app_state: SharedAppState,
}

impl UnifiedDeviceOps {
    pub fn new(app_state: SharedAppState) -> Self {
        Self { app_state }
    }

    async fn resolve_safety_device_id(&self, explicit_id: Option<&str>) -> DeviceResult<String> {
        get_device_manager()
            .rig_device(RigRole::RunSafety, explicit_id)
            .await
            .ok_or(DeviceError::NO_SAFETY_DEVICE)
    }

    /// Where the telescope is actually pointing, sampled for the FITS header.
    ///
    /// `FrameContext` only ever carries the TARGET's nominal coordinates, and
    /// only when the sequence has a Target group at all — so a run built the
    /// way the app itself suggests when it warns "No target group found in
    /// sequence" (Slew to Target with custom coordinates) wrote every light
    /// frame with no RA/DEC/OBJCTRA card whatsoever, leaving no record on disk
    /// of where the scope was aimed. Even WITH a target group the numbers were
    /// wrong in kind: an unedited "New Target" sits at 0h/0°, which is where
    /// the sequence meant to go, not where the mount was.
    ///
    /// RA/DEC are by convention the telescope's reported pointing (what MaxIm
    /// DL and N.I.N.A. write there), and that is also the coordinate a later
    /// plate-solve wants as its search hint, so the mount is the right source.
    ///
    /// Best-effort in the same sense as the focuser/rotator telemetry the
    /// exposure path already collects: no connected mount, or a driver that
    /// will not answer, means the keyword is omitted rather than filled with a
    /// plausible-looking lie.
    /// `when` is the instant the horizon frame is evaluated at — the exposure
    /// midpoint for a frame that recorded one. It is NOT when the mount is
    /// read: the RA/Dec below is sampled now, because a tracking mount holds
    /// it, while the altitude derived from it belongs to the light the frame
    /// actually integrated.
    async fn read_mount_pointing(
        &self,
        when: chrono::DateTime<chrono::Utc>,
    ) -> Option<MountPointing> {
        let mount_id = get_device_manager()
            .rig_device(RigRole::FramePointingMount, None)
            .await?;

        match get_device_manager().mount_get_coordinates(&mount_id).await {
            Ok((ra_hours, dec_degrees)) => {
                // Altitude is derived, not read back: `mount_get_status` would
                // report it but costs a full capability sweep per saved frame
                // on ASCOM, and the geometry is exact once the site is known.
                // `None` when the observer location is unset — the writer then
                // omits AIRMASS instead of computing it from a guessed site.
                let altitude_deg = self
                    .get_observer_location()
                    .map(|(lat, lon)| altitude_degrees(ra_hours, dec_degrees, lat, lon, when));
                // The altitude wants the of-date read-back; the RA/DEC cards are
                // read as J2000, so they get the mount's position in J2000.
                let (ra_hours, dec_degrees) =
                    match get_device_manager().mount_frame(&mount_id).await {
                        Some(frame) => frame.mount_to_j2000(ra_hours, dec_degrees),
                        None => return None,
                    };
                Some(MountPointing {
                    ra_hours,
                    dec_degrees,
                    altitude_deg,
                })
            }
            Err(e) => {
                tracing::debug!(
                    "[CAPTURE] mount_get_coordinates({}) failed; RA/DEC omitted from FITS: {}",
                    mount_id,
                    e
                );
                None
            }
        }
    }
}

// Factory function

/// Create a unified DeviceOps instance for the sequencer
///
/// This is the recommended way to get a DeviceOps implementation.
/// It uses the unified implementation that routes through the bridge API.
pub fn create_unified_device_ops() -> Arc<dyn skotiq_sequencer::DeviceOps> {
    Arc::new(UnifiedDeviceOps::new(crate::state::get_state().clone()))
}
