//! The simulated mount speaks coordinates of date, like the rig does.
//!
//! These drive the real instruction code through the real device layer and the
//! simulator, so a J2000/of-date mix anywhere between a sequence node and the
//! mount shows up here the way it shows up under the sky. Before the simulator
//! was made an of-date mount, the slew-validation defect of 2026-09-14 (every
//! target slew "missed" by the precession offset) passed every one of them.

use super::*;
use crate::api::devices::simulation::{get_sim_mount, sim_singleton_test_lock};
use crate::device::{DeviceInfo, DeviceType, DriverType};
use crate::device_manager::epoch::{
    j2000_to_jnow, jnow_to_j2000, SimFrameGuard as FrameGuard, SimMountFrame,
};
use nightshade_sequencer::instructions::InstructionContext;
use nightshade_sequencer::{Binning, SlewConfig};
use std::sync::atomic::AtomicBool;

/// NGC 7380, the target of the night the defect was found, J2000.
const NGC7380_J2000: (f64, f64) = (22.7892, 58.1324);

async fn attach_sim_mount(device_id: &str) {
    let info = DeviceInfo {
        id: device_id.to_string(),
        name: "Simulated Mount".to_string(),
        device_type: DeviceType::Mount,
        driver_type: DriverType::Simulator,
        description: "Simulated mount".to_string(),
        driver_version: "1.0".to_string(),
        serial_number: None,
        unique_id: None,
        display_name: "Simulated Mount".to_string(),
    };
    get_device_manager().register_device(info, false).await;
    crate::api::devices::simulation::cancel_sim_slew().await;
    let mut mount = get_sim_mount().write().await;
    mount.status.connected = true;
    mount.status.parked = false;
    mount.status.tracking = true;
    mount.status.slewing = false;
}

/// The context a TargetHeader hands a Slew node: J2000 target, mount only.
fn target_context(mount_id: &str, target: (f64, f64)) -> InstructionContext {
    InstructionContext {
        node_id: "frame-test-slew".to_string(),
        target_ra: Some(target.0),
        target_dec: Some(target.1),
        target_name: Some("NGC 7380".to_string()),
        target_rotation: None,
        current_filter: None,
        current_binning: Binning::One,
        cancellation_token: Arc::new(AtomicBool::new(false)),
        camera_id: None,
        mount_id: Some(mount_id.to_string()),
        focuser_id: None,
        filterwheel_id: None,
        rotator_id: None,
        dome_id: None,
        cover_calibrator_id: None,
        save_path: None,
        latitude: None,
        longitude: None,
        device_ops: create_unified_device_ops(),
        trigger_state: None,
        filter_focus_offsets: std::collections::HashMap::new(),
        event_tx: None,
        recovery_request_tx: None,
        session_id: String::new(),
        target_id: None,
        mosaic_panel: None,
        current_filter_index: None,
        set_temp_c: None,
        bayer_pattern: None,
        observer_name: None,
        site_elevation_m: None,
        camera_make: None,
        camera_model: None,
        telescope_name: None,
        telescope_focal_length_mm: None,
        telescope_aperture_mm: None,
        last_plate_solve: Arc::new(tokio::sync::RwLock::new(None)),
        hfr_baseline: Arc::new(tokio::sync::RwLock::new(None)),
        hfr_baseline_samples: Arc::new(tokio::sync::RwLock::new(Vec::new())),
        consecutive_rejects: Arc::new(std::sync::atomic::AtomicU32::new(0)),
        frames_accepted: Arc::new(std::sync::atomic::AtomicU32::new(0)),
        frames_rejected: Arc::new(std::sync::atomic::AtomicU32::new(0)),
        default_quality_check: None,
        reject_folder_path: None,
        defect_map_apply: Arc::new(tokio::sync::RwLock::new(None)),
        forensics_history: Arc::new(tokio::sync::RwLock::new(std::collections::VecDeque::new())),
        current_sky_brightness_mag: Arc::new(tokio::sync::RwLock::new(None)),
        cloud_motion_snapshot: Arc::new(tokio::sync::RwLock::new(
            nightshade_sequencer::CloudMotionSnapshot::default(),
        )),
        current_wind_kph: Arc::new(tokio::sync::RwLock::new(None)),
        current_sensor_temp_c: Arc::new(tokio::sync::RwLock::new(None)),
        decision_tx: None,
        active_sequence_run_id: Arc::new(parking_lot::RwLock::new(None)),
        device_disconnect_recovery_pending: Arc::new(AtomicBool::new(false)),
        dither_barrier: None,
    }
}

fn separation_arcmin(a: (f64, f64), b: (f64, f64)) -> f64 {
    let mut dra = (a.0 - b.0).rem_euclid(24.0);
    if dra > 12.0 {
        dra -= 24.0;
    }
    (dra * 15.0 * a.1.to_radians().cos()).hypot(a.1 - b.1) * 60.0
}

/// A Slew node aimed at a J2000 target lands, and validates, on an of-date
/// mount. This is the rig's 2026-09-14 failure run on the simulator: with the
/// validation fix in `execute_slew` reverted, this test fails with the same
/// "Slew position validation failed" miss of ~16' RA / ~8' Dec.
#[tokio::test]
async fn a_target_slew_validates_on_an_of_date_simulated_mount() {
    let _serialized = sim_singleton_test_lock().lock().await;
    let _frame = FrameGuard::pin(SimMountFrame::OfDate);
    let mount_id = "sim_mount_frame_slew";
    attach_sim_mount(mount_id).await;

    let ctx = target_context(mount_id, NGC7380_J2000);
    let result =
        nightshade_sequencer::instructions::execute_slew(&SlewConfig::default(), &ctx, None).await;
    assert!(
        result.status == nightshade_sequencer::NodeStatus::Success,
        "a slew that landed on target was reported as a failure: {:?}",
        result.message
    );

    // The mount holds the target of date, ~22' from the J2000 numbers, exactly
    // as the owner's OnStep did (22.8070h/58.2738deg in September 2026).
    let status = get_sim_mount().read().await.status.clone();
    let stored = (status.right_ascension, status.declination);
    let expected = j2000_to_jnow(NGC7380_J2000.0, NGC7380_J2000.1);
    assert!(
        separation_arcmin(stored, expected) < 0.05,
        "the simulated mount stored {stored:?}, not the of-date target {expected:?}"
    );
    assert!(
        separation_arcmin(stored, NGC7380_J2000) > 10.0,
        "the simulated mount stored J2000 numbers {stored:?}; it is not behaving like a JNow mount"
    );
    // And the stars it is looking at are the J2000 target's.
    let seen = jnow_to_j2000(stored.0, stored.1);
    assert!(separation_arcmin(seen, NGC7380_J2000) < 0.05);
}

/// A sync with J2000 coordinates (what plate-solve centering sends) leaves the
/// simulator holding the of-date position, the same frame a slew uses — sync
/// and slew feeding the mount different frames would skew every centering pass.
#[tokio::test]
async fn a_sync_stores_the_same_frame_a_slew_does() {
    let _serialized = sim_singleton_test_lock().lock().await;
    let _frame = FrameGuard::pin(SimMountFrame::OfDate);
    let mount_id = "sim_mount_frame_sync";
    attach_sim_mount(mount_id).await;

    get_device_manager()
        .mount_sync(mount_id, NGC7380_J2000.0, NGC7380_J2000.1)
        .await
        .expect("sync");
    let (ra, dec) = get_device_manager()
        .mount_get_coordinates(mount_id)
        .await
        .expect("read back");
    let expected = j2000_to_jnow(NGC7380_J2000.0, NGC7380_J2000.1);
    assert!(
        separation_arcmin((ra, dec), expected) < 0.05,
        "sync stored ({ra}, {dec}), expected of-date {expected:?}"
    );
}

/// `NIGHTSHADE_SIM_MOUNT_FRAME=j2000` keeps the old behaviour: what is sent is
/// what reads back, and validation still agrees with the send path.
#[tokio::test]
async fn the_j2000_pin_round_trips_catalog_numbers() {
    let _serialized = sim_singleton_test_lock().lock().await;
    let _frame = FrameGuard::pin(SimMountFrame::J2000);
    let mount_id = "sim_mount_frame_j2000";
    attach_sim_mount(mount_id).await;

    let ctx = target_context(mount_id, NGC7380_J2000);
    let result =
        nightshade_sequencer::instructions::execute_slew(&SlewConfig::default(), &ctx, None).await;
    assert!(
        result.status == nightshade_sequencer::NodeStatus::Success,
        "{:?}",
        result.message
    );
    let status = get_sim_mount().read().await.status.clone();
    assert!(separation_arcmin((status.right_ascension, status.declination), NGC7380_J2000) < 0.05);
}
