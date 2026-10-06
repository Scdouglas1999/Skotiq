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
//! use nightshade_bridge::unified_device_ops::create_unified_device_ops;
//!
//! let ops = create_unified_device_ops();
//! executor.set_device_ops(ops);
//! ```
//!
//! # `as`-cast policy
//!
//! Same pattern groupings as `sequencer_ops.rs` (this file is the unified
//! replacement and the cast taxonomy is identical):
//! - **Pixel histogram u16 → usize index** (line 548): u16 max 65535 fits
//!   any supported usize.
//! - **Image normalize u16 → f64** (line 505): exact widening.
//! - **bool → u8** (lines 660, 904): wire encoding.
//! - **Filter wheel index ±1** (lines 815, 817): bounded by slot count.
//! - **star_count usize → u32** (line 544): real frames have ≤ tens of
//!   thousands of stars; saturating cast would catch any pathology.
//! - **Star-count average f64** (line 1300): exact widening.
//! - **Julian Day chrono fields**: computed by
//!   `sequencer/src/meridian.rs::julian_day`, where the per-site reasoning
//!   lives.

/// Prefix marking a capture that failed *image validation* rather than failing
/// in the driver or the transport.
///
/// The `DeviceOps` trait signs its errors as bare `String` (`DeviceResult<T> =
/// Result<T, String>`), so a caller cannot otherwise tell "the camera worked and
/// the frame is unusable" apart from "the camera broke". That distinction
/// matters at the HTTP boundary: a completely saturated frame is a normal,
/// operator-actionable outcome (shorten the exposure) and must not be reported
/// as an internal server fault. `api::imaging` matches this prefix to promote
/// the error to [`NightshadeError::ExposureFailed`], which the headless API maps
/// to 422 instead of 500.
///
/// Producer and consumer live in the same crate and share this constant so the
/// two cannot drift apart.
pub(crate) const IMAGE_VALIDATION_FAILED_PREFIX: &str = "Image validation failed: ";

fn median_from_sorted_f64(sorted: &[f64]) -> Option<f64> {
    if sorted.is_empty() {
        return None;
    }

    let mid = sorted.len() / 2;
    if sorted.len() % 2 == 0 {
        Some((sorted[mid - 1] + sorted[mid]) / 2.0)
    } else {
        Some(sorted[mid])
    }
}

use crate::adaptive_polling::{AdaptivePoller, PollerPreset};
use crate::api::*;
use crate::device::DeviceType;
use crate::event::*;
use crate::filter_matching::find_filter_match;
use crate::state::SharedAppState;
use crate::FitsWriteHeader;
use async_trait::async_trait;
// Julian Day and local sidereal time come from the sequencer; this file keeps
// no copy of either.
use nightshade_sequencer::meridian::{julian_day, local_sidereal_time};
use nightshade_sequencer::{
    CameraSubframe, DeviceOps, DeviceResult, GuidingCalibration, GuidingStatus, ImageData,
    PlateSolveResult, PolarAlignResult,
};
use std::collections::HashMap;
use std::sync::{Arc, OnceLock};
use tokio::sync::Mutex;

pub(crate) mod device_ops;
pub(crate) mod exposure_wait;
pub(crate) use exposure_wait::*;
pub(crate) mod pointing;
pub(crate) use pointing::*;
#[cfg(test)]
mod frame_tests;
#[cfg(test)]
mod pointing_tests;
pub(crate) mod rich_header;
#[cfg(test)]
mod rig_grading_tests;
pub(crate) use rich_header::*;
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
        if let Some(id) = explicit_id {
            return Ok(id.to_string());
        }

        if let Some(id) = get_device_manager()
            .first_connected_device_id(DeviceType::SafetyMonitor)
            .await
        {
            return Ok(id);
        }

        // Audit C1: the profile now persists a SafetyMonitor selection. Prefer
        // that over falling through to a weather device so sequencer safety
        // checks consult the dedicated sensor instead of inferring safe/unsafe
        // from a weather station.
        if let Some(id) = self
            .app_state
            .get_profile_device_id(DeviceType::SafetyMonitor)
            .await
        {
            return Ok(id);
        }

        if let Some(id) = self
            .app_state
            .get_profile_device_id(DeviceType::Weather)
            .await
        {
            return Ok(id);
        }

        Err(
            "No safety monitor or weather device configured for sequencer safety checks"
                .to_string(),
        )
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
            .first_connected_device_id(DeviceType::Mount)
            .await?;

        match mount_get_coordinates(mount_id.clone()).await {
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
                let (ra_hours, dec_degrees) = match get_device_manager().get_device(&mount_id).await
                {
                    Some(device) => crate::device_manager::epoch::mount_frame_to_j2000(
                        device.info.driver_type,
                        ra_hours,
                        dec_degrees,
                    ),
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
pub fn create_unified_device_ops() -> Arc<dyn nightshade_sequencer::DeviceOps> {
    Arc::new(UnifiedDeviceOps::new(crate::api::get_state().clone()))
}

/// Create a unified DeviceOps instance with a specific app state
pub fn create_unified_device_ops_with_state(
    app_state: SharedAppState,
) -> Arc<dyn nightshade_sequencer::DeviceOps> {
    Arc::new(UnifiedDeviceOps::new(app_state))
}
