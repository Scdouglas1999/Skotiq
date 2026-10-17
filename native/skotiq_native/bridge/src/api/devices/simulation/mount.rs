use super::*;

/// Simulated mount state
pub(crate) static SIM_MOUNT: OnceLock<Arc<RwLock<SimulatedMount>>> = OnceLock::new();

#[flutter_rust_bridge::frb]
pub struct SimulatedMount {
    pub status: MountStatus,
}

impl Default for SimulatedMount {
    fn default() -> Self {
        // Simulator pretends to be a fully-capable mount: every optional field
        // is reported `Available` so UI rendering paths exercise the populated
        // case during development without needing real hardware.
        use crate::device::{mount_status_field as f, FieldAvailability};
        let mut availability = std::collections::HashMap::new();
        availability.insert(f::AT_HOME.to_string(), FieldAvailability::Available);
        availability.insert(f::SIDE_OF_PIER.to_string(), FieldAvailability::Available);
        availability.insert(f::ALTITUDE.to_string(), FieldAvailability::Available);
        availability.insert(f::AZIMUTH.to_string(), FieldAvailability::Available);
        availability.insert(f::SIDEREAL_TIME.to_string(), FieldAvailability::Available);
        availability.insert(f::TRACKING_RATE.to_string(), FieldAvailability::Available);
        Self {
            status: MountStatus {
                connected: false,
                tracking: false,
                slewing: false,
                parked: true,
                at_home: Some(false),
                side_of_pier: Some(PierSide::Unknown),
                right_ascension: 0.0,
                declination: 0.0,
                // The horizon frame is NOT a property of the mount: it needs
                // an observing site and the current time. Every read goes
                // through `sim_gate::apply_derived_mount_telemetry`, which
                // computes these when a site is configured and sets them to
                // `None` when there is not — so a stored `Some(0.0)` here was
                // only ever a stand-in that could leak out as a claim that the
                // tube is on the horizon at sidereal time zero.
                altitude: None,
                azimuth: None,
                sidereal_time: None,
                tracking_rate: Some(TrackingRate::Sidereal),
                can_park: true,
                can_slew: true,
                can_sync: true,
                can_pulse_guide: true,
                can_set_tracking_rate: true,
                availability,
            },
        }
    }
}

pub(crate) fn get_sim_mount() -> &'static Arc<RwLock<SimulatedMount>> {
    SIM_MOUNT.get_or_init(|| Arc::new(RwLock::new(SimulatedMount::default())))
}

/// Simulated slew rate, degrees of arc per second.
///
/// Far brisker than real hardware (a good GEM manages 3-6 °/s) for the same
/// reason the cooler ramp is: the motion has to COMPLETE inside a test or a
/// sequence node's budget. It still consumes observable time, which is the
/// point — a slew that snaps to the target never reports `slewing`, and every
/// wait-for-motion path in the app then completes before the mount has moved.
pub(crate) const SIM_SLEW_DEG_PER_SEC: f64 = 180.0;

/// Floor on how long any commanded slew takes.
///
/// A meridian flip re-slews to the SAME coordinates, so a pure
/// distance/rate model would make the largest mechanical motion a GEM
/// performs finish instantly.
pub(crate) const SIM_MIN_SLEW_SECS: f64 = 0.2;

/// How long the simulated mount keeps reporting `slewing` AFTER its axes have
/// reached the commanded coordinates.
///
/// Real drivers hold `Slewing` true through a mechanical settle: the axes
/// arrive, the tube rings down, and only then does the driver report idle.
/// Without a tail here `slewing` falls to false in the very same status read
/// that first reports the target coordinates, making "arrived" and "stopped
/// moving" one event that no caller can observe out of order. Every
/// wait-for-motion path in the app — the sequencer's
/// `wait_for_mount_idle_with_progress`, centering's
/// `wait_for_centering_correction_slew` (and the
/// `CenteringSlewTimeoutException` behind it), the polar-alignment poll and
/// the post-flip guiding settle — is then satisfied on its first poll.
///
/// Sized in the same family as [`SIM_CALIBRATOR_SETTLE_SECS`]: long enough
/// that a poller has to go round at least once more, short enough that it
/// still fits inside a sequence node's budget.
pub(crate) const SIM_SLEW_SETTLE_SECS: f64 = 0.6;

/// Extra arc a slew covers when it also crosses the mount to the other side of
/// the pier: the tube swings through roughly half a turn of the RA axis on top
/// of whatever the coordinate change asks for.
pub(crate) const SIM_FLIP_TRAVERSE_DEG: f64 = 180.0;

/// An in-flight simulated slew.
///
/// Kept out of [`SimulatedMount`] because that struct is mirrored to Dart by
/// flutter_rust_bridge and Dart has no use for the interpolation state.
#[derive(Debug, Clone, Copy)]
pub(crate) struct SimSlew {
    pub(crate) start: std::time::Instant,
    pub(crate) duration_secs: f64,
    pub(crate) from: (f64, f64),
    pub(crate) to: (f64, f64),
    pub(crate) to_pier: PierSide,
}

pub(crate) static SIM_SLEW: OnceLock<Arc<RwLock<Option<SimSlew>>>> = OnceLock::new();

pub(crate) fn sim_slew() -> &'static Arc<RwLock<Option<SimSlew>>> {
    SIM_SLEW.get_or_init(|| Arc::new(RwLock::new(None)))
}

/// Great-circle separation between two equatorial positions, in degrees.
pub(crate) fn angular_separation_deg(from: (f64, f64), to: (f64, f64)) -> f64 {
    let (ra1, dec1) = ((from.0 * 15.0).to_radians(), from.1.to_radians());
    let (ra2, dec2) = ((to.0 * 15.0).to_radians(), to.1.to_radians());
    let cos_sep = dec1.sin() * dec2.sin() + dec1.cos() * dec2.cos() * (ra2 - ra1).cos();
    cos_sep.clamp(-1.0, 1.0).acos().to_degrees()
}

/// How long a slew covering `separation_deg` takes, given whether it also
/// crosses the pier.
pub(crate) fn sim_slew_duration_secs(separation_deg: f64, crosses_pier: bool) -> f64 {
    let arc = separation_deg
        + if crosses_pier {
            SIM_FLIP_TRAVERSE_DEG
        } else {
            0.0
        };
    (arc / SIM_SLEW_DEG_PER_SEC).max(SIM_MIN_SLEW_SECS)
}

/// Interpolate right ascension the short way around the 24h wrap, so a slew
/// from 23h to 1h travels two hours forward rather than 22 hours backward.
pub(crate) fn interpolate_ra(from: f64, to: f64, fraction: f64) -> f64 {
    let mut delta = (to - from).rem_euclid(24.0);
    if delta > 12.0 {
        delta -= 24.0;
    }
    (from + delta * fraction).rem_euclid(24.0)
}

/// The side of the pier a German equatorial ends up on after slewing to `ra`,
/// given the local sidereal time at the moment the slew is commanded.
///
/// Pier side is MECHANICAL STATE, not a projection of where the mount is
/// pointing: a GEM tracks straight through the meridian without flipping, so
/// the side only changes when a slew puts it on the other one. Deriving it from
/// the current pointing instead made it change with the clock while the mount
/// stood still, and made a meridian flip — whose entire signature is "the side
/// changed" — impossible to detect, because re-slewing to the same coordinates
/// re-derived the same answer.
pub(crate) fn pier_side_after_slew_to(ra_hours: f64, lst_hours: f64) -> PierSide {
    match skotiq_sequencer::meridian::expected_pier_side(
        skotiq_sequencer::meridian::hour_angle(ra_hours, lst_hours),
    ) {
        skotiq_sequencer::meridian::PierSide::East => PierSide::East,
        skotiq_sequencer::meridian::PierSide::West => PierSide::West,
        skotiq_sequencer::meridian::PierSide::Unknown => PierSide::Unknown,
    }
}

/// Local sidereal time now for the configured site, if there is one.
pub(crate) fn sim_local_sidereal_time(now: chrono::DateTime<chrono::Utc>) -> Option<f64> {
    let longitude = crate::api::get_state()
        .get_observer_location()
        .ok()
        .flatten()?
        .longitude;
    Some(skotiq_sequencer::meridian::local_sidereal_time(
        skotiq_sequencer::meridian::julian_day(&now),
        longitude,
    ))
}

/// Start a simulated slew to `(ra, dec)`, deciding the pier side it will land
/// on from the local sidereal time at `now`.
///
/// Without a configured site there is no hour angle and therefore no honest
/// answer for the pier side, so the mount keeps the side it was already on.
pub(crate) async fn begin_sim_slew(ra: f64, dec: f64, now: chrono::DateTime<chrono::Utc>) {
    let (from, current_pier) = {
        let mount = get_sim_mount().read().await;
        (
            (mount.status.right_ascension, mount.status.declination),
            mount.status.side_of_pier.unwrap_or(PierSide::Unknown),
        )
    };
    let to_pier = match sim_local_sidereal_time(now) {
        Some(lst) => pier_side_after_slew_to(ra, lst),
        None => current_pier,
    };
    let duration_secs = sim_slew_duration_secs(
        angular_separation_deg(from, (ra, dec)),
        to_pier != current_pier && current_pier != PierSide::Unknown,
    );

    *sim_slew().write().await = Some(SimSlew {
        start: std::time::Instant::now(),
        duration_secs,
        from,
        to: (ra, dec),
        to_pier,
    });
    let mut mount = get_sim_mount().write().await;
    mount.status.slewing = true;
    mount.status.parked = false;
    mount.status.at_home = Some(false);
}

/// Advance an in-flight slew to now, updating the mount's pointing and, on
/// arrival, its pier side.
///
/// Called from every simulated mount status read, which is what makes the
/// motion observable to a caller polling `slewing`.
pub(crate) async fn advance_sim_slew() {
    let Some(slew) = *sim_slew().read().await else {
        return;
    };
    let elapsed_secs = slew.start.elapsed().as_secs_f64();
    let fraction = if slew.duration_secs > 0.0 {
        (elapsed_secs / slew.duration_secs).clamp(0.0, 1.0)
    } else {
        1.0
    };

    let mut mount = get_sim_mount().write().await;
    if fraction >= 1.0 {
        // The axes are on target and the pier side is committed from here on,
        // but the driver does not report idle until the settle tail expires —
        // see SIM_SLEW_SETTLE_SECS for why "arrived" and "stopped" must be two
        // observable events rather than one.
        mount.status.right_ascension = slew.to.0;
        mount.status.declination = slew.to.1;
        mount.status.side_of_pier = Some(slew.to_pier);
        if elapsed_secs >= slew.duration_secs + SIM_SLEW_SETTLE_SECS {
            mount.status.slewing = false;
            drop(mount);
            *sim_slew().write().await = None;
        } else {
            mount.status.slewing = true;
        }
    } else {
        mount.status.right_ascension = interpolate_ra(slew.from.0, slew.to.0, fraction);
        mount.status.declination = slew.from.1 + (slew.to.1 - slew.from.1) * fraction;
        mount.status.slewing = true;
    }
}

/// Drop any in-flight slew, leaving the mount wherever it had reached.
///
/// Abort/stop/park all need this: without it the interpolation would carry the
/// mount on to the target it was told to stop travelling to.
pub(crate) async fn cancel_sim_slew() {
    *sim_slew().write().await = None;
}

/// Whether a commanded slew — including its [`SIM_SLEW_SETTLE_SECS`] tail — is
/// still in flight as of the last [`advance_sim_slew`].
///
/// Reads only: callers reach this through `sim_gate::require_mount_connected`,
/// which has already advanced the motion under the fault gate. Advancing again
/// here would let a caller step a mount that `sim_faults` has deliberately
/// stalled.
pub(crate) async fn sim_slew_in_flight() -> bool {
    sim_slew().read().await.is_some()
}

/// The equatorial coordinates a parked simulated mount reports.
///
/// A parked German equatorial sits with the counterweights down pointing at the
/// celestial pole, which is a fixed point in the horizon frame — altitude
/// equals the site latitude and azimuth is due pole, whatever the time. Park
/// therefore moves RA/Dec to the pole: leaving them at the previous target
/// makes a parked mount report the altitude of whatever it was last imaging,
/// still tracking the sky.
pub(crate) fn sim_park_position() -> (f64, f64) {
    let southern = crate::api::get_state()
        .get_observer_location()
        .ok()
        .flatten()
        .is_some_and(|site| site.latitude < 0.0);
    (0.0, if southern { -90.0 } else { 90.0 })
}

/// Get mount status
pub async fn api_get_mount_status(device_id: String) -> Result<MountStatus, SkotiqError> {
    let mgr = get_device_manager();
    mgr.mount_get_status(&device_id)
        .await
        .map_err(SkotiqError::from)
}

/// Slew mount to coordinates
pub async fn api_mount_slew_to_coordinates(
    device_id: String,
    ra: f64,
    dec: f64,
) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.mount_slew(&device_id, ra, dec)
        .await
        .map_err(SkotiqError::from)
}

/// Sync mount to coordinates
pub async fn api_mount_sync_to_coordinates(
    device_id: String,
    ra: f64,
    dec: f64,
) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.mount_sync(&device_id, ra, dec)
        .await
        .map_err(SkotiqError::from)
}

/// Park the mount
pub async fn api_mount_park(device_id: String) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.mount_park(&device_id)
        .await
        .map_err(SkotiqError::from)
}

/// Unpark the mount
pub async fn api_mount_unpark(device_id: String) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.mount_unpark(&device_id)
        .await
        .map_err(SkotiqError::from)
}

/// Set mount tracking
pub async fn api_mount_set_tracking(device_id: String, enabled: u8) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.mount_set_tracking(&device_id, enabled != 0)
        .await
        .map_err(SkotiqError::from)
}

/// Slew mount to alt/az coordinates (simulator handler)
pub async fn api_mount_slew_alt_az(
    device_id: String,
    altitude: f64,
    azimuth: f64,
) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.mount_slew_alt_az(&device_id, altitude, azimuth)
        .await
        .map_err(SkotiqError::from)
}

/// Find mount home position (simulator handler)
pub async fn api_mount_find_home(device_id: String) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.mount_find_home(&device_id)
        .await
        .map_err(SkotiqError::from)
}

/// Pulse guide the mount in a direction for a duration
pub async fn api_mount_pulse_guide(
    device_id: String,
    direction: String,
    duration_ms: i32,
) -> Result<(), SkotiqError> {
    tracing::info!(
        "Pulse guiding {} for {}ms in direction {}",
        device_id,
        duration_ms,
        direction
    );

    // Validate direction
    match direction.to_lowercase().as_str() {
        "north" | "n" | "south" | "s" | "east" | "e" | "west" | "w" => {}
        _ => {
            return Err(SkotiqError::InvalidParameter(format!(
                "Unknown direction: {}",
                direction
            )))
        }
    };

    let mgr = get_device_manager();
    mgr.mount_pulse_guide(&device_id, direction, duration_ms as u32)
        .await
        .map_err(SkotiqError::from)
}
