// split from monolithic api.rs
#![allow(unused_imports)]
// Shared imports inherited from the monolithic api.rs.
use crate::device::*;
use crate::device_manager::DeviceManager;
use crate::error::*;
use crate::event::*;
use crate::state::*;
use crate::storage::{AppSettings, ObserverLocation};
use crate::unified_device_ops::create_unified_device_ops;
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use skotiq_imaging::{
    calculate_airmass, validate_fits_header, validate_image, write_fits, BayerPattern,
    DebayerAlgorithm, FitsHeader, ImageData,
};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::sync::OnceLock;
use std::time::{Duration, Instant};
use tokio::sync::Mutex;
use tokio::sync::RwLock;
// Sibling-module items via the parent's pub use re-exports.
use super::super::*;
use super::*;

// Mount control

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
    mgr.mount_park(&device_id).await.map_err(SkotiqError::from)
}

/// Unpark the mount
pub async fn api_mount_unpark(device_id: String) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.mount_unpark(&device_id)
        .await
        .map_err(SkotiqError::from)
}

/// Abort mount slew
pub async fn mount_abort(device_id: String) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.mount_abort(&device_id).await.map_err(SkotiqError::from)
}

/// Set mount tracking
///
/// A stop sent from here while a run is active is the operator's, so the run
/// is told before the mount stops: it pauses instead of reading the stop as
/// the mount's tracking limit. The run's own commands go through device ops,
/// not this call.
pub async fn api_mount_set_tracking(device_id: String, enabled: u8) -> Result<(), SkotiqError> {
    if enabled == 0 {
        // Never wait on the executor lock to stop a mount.
        if let Ok(executor) = crate::api::sequencer::get_sequence_executor().try_read() {
            executor.note_operator_tracking_stop().await;
        }
    }
    let mgr = get_device_manager();
    mgr.mount_set_tracking(&device_id, enabled != 0)
        .await
        .map_err(SkotiqError::from)
}

/// Set mount tracking rate (0=Sidereal, 1=Lunar, 2=Solar, 3=King)
pub async fn mount_set_tracking_rate(device_id: String, rate: i32) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.mount_set_tracking_rate(&device_id, rate)
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
        target: "skotiq_bridge::api::devices::mount",
        "Pulse guiding {} for {}ms in direction {}",
        device_id,
        duration_ms,
        direction
    );

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

/// Move mount axis at specified rate (degrees/second)
/// axis: 0=RA/Azimuth (primary), 1=Dec/Altitude (secondary)
/// rate: degrees per second (positive = N/E, negative = S/W), 0 to stop
pub async fn mount_move_axis(device_id: String, axis: i32, rate: f64) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.mount_move_axis(&device_id, axis, rate)
        .await
        .map_err(SkotiqError::from)
}

/// Slew mount to alt/az coordinates (altitude in degrees, azimuth in degrees)
pub async fn mount_slew_alt_az(
    device_id: String,
    altitude: f64,
    azimuth: f64,
) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.mount_slew_alt_az(&device_id, altitude, azimuth)
        .await
        .map_err(SkotiqError::from)
}

/// Find mount home position
pub async fn mount_find_home(device_id: String) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.mount_find_home(&device_id)
        .await
        .map_err(SkotiqError::from)
}

/// Store the mount's current position as its park position
pub async fn mount_set_park(device_id: String) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.mount_set_park(&device_id)
        .await
        .map_err(SkotiqError::from)
}

/// Which site/time directions this mount can honour.
///
/// The reconciliation card asks the operator which way to copy; asking about a
/// direction the driver will refuse wastes their decision.
pub async fn mount_site_capabilities(
    device_id: String,
) -> Result<MountSiteCapabilities, SkotiqError> {
    let mgr = get_device_manager();
    mgr.mount_site_capabilities(&device_id)
        .await
        .map_err(SkotiqError::from)
}

/// Read the site the mount itself is configured for.
pub async fn mount_get_site(device_id: String) -> Result<MountSite, SkotiqError> {
    let mgr = get_device_manager();
    mgr.mount_get_site(&device_id)
        .await
        .map_err(SkotiqError::from)
}

/// Write a site into the mount. Longitude is EAST-positive.
pub async fn mount_set_site(
    device_id: String,
    latitude_deg: f64,
    longitude_deg: f64,
    elevation_m: Option<f64>,
) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.mount_set_site(
        &device_id,
        MountSite {
            latitude_deg,
            longitude_deg,
            elevation_m,
        },
    )
    .await
    .map_err(SkotiqError::from)
}

/// Read the mount's clock.
pub async fn mount_get_time(device_id: String) -> Result<MountTimeInfo, SkotiqError> {
    let mgr = get_device_manager();
    mgr.mount_get_time(&device_id)
        .await
        .map_err(SkotiqError::from)
}

/// Write a clock into the mount. `utc_offset_hours` is east of UTC in the
/// ordinary sense (US Eastern Standard is -5.0).
pub async fn mount_set_time(
    device_id: String,
    utc_unix_seconds: i64,
    utc_offset_hours: f64,
) -> Result<(), SkotiqError> {
    let mgr = get_device_manager();
    mgr.mount_set_time(
        &device_id,
        MountTimeInfo {
            utc_unix_seconds,
            utc_offset_hours,
        },
    )
    .await
    .map_err(SkotiqError::from)
}

#[cfg(test)]
mod tests {
    use super::api_mount_set_tracking;
    use crate::api::devices::simulation::{get_sim_mount, sim_singleton_test_lock};
    use crate::api::sequencer::{api_sequencer_start, api_sequencer_stop, get_sequence_executor};
    use crate::device::{DeviceInfo, DeviceType, DriverType};
    use crate::device_manager::get_device_manager;
    use skotiq_sequencer::{
        DelayConfig, ExecutorState, NodeDefinition, NodeType, SequenceDefinition,
    };

    const MOUNT: &str = "sim_mount_1";

    async fn connect_tracking_sim_mount() {
        let info = DeviceInfo {
            id: MOUNT.to_string(),
            name: "Simulated Mount".to_string(),
            device_type: DeviceType::Mount,
            driver_type: DriverType::Simulator,
            description: "Simulator under test".to_string(),
            driver_version: "1.0".to_string(),
            serial_number: None,
            unique_id: None,
            display_name: "Simulated Mount".to_string(),
        };
        let manager = get_device_manager();
        manager.register_device(info.clone(), false).await;
        manager
            .connect_simulator(&info)
            .await
            .expect("the simulator connects");
        let mut mount = get_sim_mount().write().await;
        mount.status.parked = false;
        mount.status.slewing = false;
        mount.status.tracking = true;
    }

    /// Tracking switched off from Skotiq's mount controls (the app and the
    /// headless host both call this function) during a run is the operator's
    /// stop. The run has to hear of it before the mount stops; otherwise a
    /// stop on the west side near transit reads as the mount's tracking limit
    /// and the run flips the mount.
    #[tokio::test]
    async fn a_tracking_stop_from_the_app_during_a_run_is_the_operators() {
        let _serialized = sim_singleton_test_lock().lock().await;
        connect_tracking_sim_mount().await;

        let mut sequence = SequenceDefinition::new("Long wait".to_string());
        sequence.nodes.push(NodeDefinition {
            id: "wait".to_string(),
            name: "Wait".to_string(),
            node_type: NodeType::Delay(DelayConfig { seconds: 120.0 }),
            enabled: true,
            children: vec![],
        });
        sequence.root_node_id = Some("wait".to_string());
        {
            let mut executor = get_sequence_executor().write().await;
            executor.set_device_ops(std::sync::Arc::new(
                skotiq_sequencer::device_ops::NullDeviceOps,
            ));
            // The run's monitor must not read the null mount's tracking and
            // clear the stop before it is checked.
            executor.mount_id = None;
            executor.load_sequence(sequence).expect("sequence loads");
        }
        api_sequencer_start().await.expect("run starts");
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(10);
        while get_sequence_executor().read().await.get_state().await != ExecutorState::Running {
            assert!(
                tokio::time::Instant::now() < deadline,
                "the run never started"
            );
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }

        api_mount_set_tracking(MOUNT.to_string(), 0)
            .await
            .expect("tracking stops");
        let operator_stopped = {
            let executor = get_sequence_executor().read().await;
            let state = executor.trigger_manager().read().await.state();
            let stopped = state.read().await.tracking.operator_stopped();
            stopped
        };
        api_sequencer_stop(None).await.expect("run stops");

        assert!(
            operator_stopped,
            "the run was not told the stop was the operator's"
        );
        assert!(!get_sim_mount().read().await.status.tracking);
    }
}
