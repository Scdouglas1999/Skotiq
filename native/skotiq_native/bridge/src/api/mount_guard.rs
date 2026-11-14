//! The mount motion guard, for the app: its state, its settings and the
//! operator's recovery actions. See `device_manager::motion_guard`.

use crate::device_manager::motion_guard::{self as guard, response, GuardConfig};
use crate::error::SkotiqError;

/// A motion fault: the mount moved with no command from Skotiq.
#[derive(Debug, Clone)]
pub struct MountMotionFaultInfo {
    /// `runaway`, `slewing` or `below_horizon`.
    pub kind: String,
    pub message: String,
    pub detected_at_unix: i64,
    pub rate_deg_per_sec: f64,
    pub ra_hours: f64,
    pub dec_degrees: f64,
    pub altitude_degrees: Option<f64>,
    pub still_moving: bool,
    pub stop_attempts: Vec<String>,
    pub run_paused: bool,
}

/// Why Skotiq no longer trusts the mount's reported position.
#[derive(Debug, Clone)]
pub struct MountPositionUnknownInfo {
    pub reason: String,
    pub message: String,
    pub flagged_at_unix: i64,
    pub run_paused: bool,
}

/// One mount as the guard sees it. A mount with neither a fault nor an
/// unknown position is not listed.
#[derive(Debug, Clone)]
pub struct MountGuardStatus {
    pub device_id: String,
    pub fault: Option<MountMotionFaultInfo>,
    pub position_unknown: Option<MountPositionUnknownInfo>,
    /// Why automatic slews, parks and homes are refused right now.
    pub block_reason: Option<String>,
    pub auto_recovering: bool,
}

/// The guard's settings.
#[derive(Debug, Clone, Copy)]
pub struct MountGuardSettings {
    pub enabled: bool,
    pub min_altitude_degrees: f64,
    pub auto_sync_resume: bool,
    pub solve_mismatch_degrees: f64,
}

/// A recovery plate solve, before the operator decides to sync.
#[derive(Debug, Clone)]
pub struct MountGuardSolve {
    /// The solved position, J2000.
    pub ra_hours: f64,
    pub dec_degrees: f64,
    /// Where the mount says it points.
    pub mount_ra_hours: f64,
    pub mount_dec_degrees: f64,
    pub separation_degrees: f64,
}

/// Every mount with an open motion fault or an unknown position.
pub fn api_mount_guard_get_state() -> Vec<MountGuardStatus> {
    let entries: Vec<(
        String,
        Option<guard::FaultRecord>,
        Option<guard::LostRecord>,
        bool,
    )> = guard::with_registry(|r| {
        r.mounts
            .iter()
            .filter(|(_, e)| e.fault.is_some() || e.lost.is_some())
            .map(|(id, e)| {
                (
                    id.clone(),
                    e.fault.clone(),
                    e.lost.clone(),
                    e.auto_recovering,
                )
            })
            .collect()
    });
    let mut out: Vec<MountGuardStatus> = entries
        .into_iter()
        .map(
            |(device_id, fault, lost, auto_recovering)| MountGuardStatus {
                block_reason: guard::block_reason(&device_id),
                fault: fault.map(|f| MountMotionFaultInfo {
                    kind: f.kind.as_wire().to_string(),
                    message: f.message,
                    detected_at_unix: f.detected_at_unix,
                    rate_deg_per_sec: f.rate_deg_per_sec,
                    ra_hours: f.ra_hours,
                    dec_degrees: f.dec_deg,
                    altitude_degrees: f.altitude_deg,
                    still_moving: f.still_moving,
                    stop_attempts: f.stop_attempts,
                    run_paused: f.run_paused,
                }),
                position_unknown: lost.map(|l| MountPositionUnknownInfo {
                    reason: l.reason.as_wire().to_string(),
                    message: l.message,
                    flagged_at_unix: l.flagged_at_unix,
                    run_paused: l.run_paused,
                }),
                auto_recovering,
                device_id,
            },
        )
        .collect();
    out.sort_by(|a, b| a.device_id.cmp(&b.device_id));
    out
}

pub fn api_mount_guard_get_settings() -> MountGuardSettings {
    let c = guard::config();
    MountGuardSettings {
        enabled: c.enabled,
        min_altitude_degrees: c.min_altitude_deg,
        auto_sync_resume: c.auto_sync_resume,
        solve_mismatch_degrees: c.solve_mismatch_deg,
    }
}

pub fn api_mount_guard_set_settings(settings: MountGuardSettings) {
    let mismatch =
        if settings.solve_mismatch_degrees.is_finite() && settings.solve_mismatch_degrees > 0.0 {
            settings.solve_mismatch_degrees
        } else {
            guard::DEFAULT_SOLVE_MISMATCH_DEG
        };
    guard::set_config(GuardConfig {
        enabled: settings.enabled,
        min_altitude_deg: if settings.min_altitude_degrees.is_finite() {
            settings.min_altitude_degrees.clamp(-10.0, 45.0)
        } else {
            0.0
        },
        auto_sync_resume: settings.auto_sync_resume,
        solve_mismatch_deg: mismatch,
    });
}

/// The operator has checked the mount after it moved on its own.
pub fn api_mount_guard_acknowledge_fault(device_id: String) -> Result<(), SkotiqError> {
    response::acknowledge_fault(&device_id).map_err(SkotiqError::OperationFailed)
}

/// The operator has put the mount at its home position and confirms it.
pub fn api_mount_guard_confirm_rehomed(device_id: String) -> Result<(), SkotiqError> {
    response::confirm_rehomed(&device_id).map_err(SkotiqError::OperationFailed)
}

/// Take a frame and plate solve it blind, for the operator to decide on a
/// sync. `camera_id` defaults to the run's or the profile's camera.
pub async fn api_mount_guard_solve(
    device_id: String,
    camera_id: Option<String>,
    exposure_secs: f64,
) -> Result<MountGuardSolve, SkotiqError> {
    let solve = response::solve_for_recovery(&device_id, camera_id, exposure_secs)
        .await
        .map_err(SkotiqError::OperationFailed)?;
    Ok(MountGuardSolve {
        ra_hours: solve.ra_hours,
        dec_degrees: solve.dec_deg,
        mount_ra_hours: solve.mount_ra_hours,
        mount_dec_degrees: solve.mount_dec_deg,
        separation_degrees: solve.separation_deg,
    })
}

/// Sync the mount to a solved J2000 position the operator accepted, and trust
/// its position again.
pub async fn api_mount_guard_recovery_sync(
    device_id: String,
    ra_hours: f64,
    dec_degrees: f64,
) -> Result<(), SkotiqError> {
    response::recovery_sync(&device_id, ra_hours, dec_degrees)
        .await
        .map_err(SkotiqError::OperationFailed)
}
