//! A run that loses each of its devices for a moment finishes on its own.
//!
//! A power box behind the camera, wheel and focuser dropped
//! and came back, and the run needed a person. The owner: "the app should be
//! able to recover completely autonomously through any device loss". Each
//! device here drops once mid-run, answering "not connected" until the
//! run's recovery connects it again, and the run must reach Completed with
//! no manual step and never sit paused.

use super::*;
use crate::device_ops::{DeviceError, DeviceKind, DeviceResult, NullDeviceOps};
use std::collections::{HashMap, HashSet};
use std::sync::Mutex as StdMutex;

const CAMERA: &str = "cam-drop";
const MOUNT: &str = "mount-drop";
const WHEEL: &str = "wheel-drop";
const FOCUSER: &str = "focuser-drop";
const GUIDER: &str = "guider";

/// Null devices, each of which drops once at its `drop_at`-th operation.
struct DroppingOps {
    inner: NullDeviceOps,
    drop_at: HashMap<DeviceKind, u32>,
    calls: StdMutex<HashMap<DeviceKind, u32>>,
    down: StdMutex<HashSet<String>>,
    dropped: StdMutex<Vec<String>>,
    reconnected: StdMutex<Vec<String>>,
    /// Where the mount was last sent; it arrives at once.
    pointing: StdMutex<(f64, f64)>,
}

impl DroppingOps {
    fn new(drop_at: &[(DeviceKind, u32)]) -> Self {
        Self {
            inner: NullDeviceOps,
            drop_at: drop_at.iter().copied().collect(),
            calls: Default::default(),
            down: Default::default(),
            dropped: Default::default(),
            reconnected: Default::default(),
            pointing: StdMutex::new((12.0, 45.0)),
        }
    }

    /// Count an operation on `device_id`; fail it while the device is down.
    fn gate(&self, kind: DeviceKind, device_id: &str) -> DeviceResult<()> {
        let call = {
            let mut calls = self.calls.lock().unwrap();
            let call = calls.entry(kind).or_default();
            *call += 1;
            *call
        };
        if self.drop_at.get(&kind) == Some(&call) {
            self.down.lock().unwrap().insert(device_id.to_string());
            self.dropped.lock().unwrap().push(device_id.to_string());
        }
        if self.down.lock().unwrap().contains(device_id) {
            return Err(DeviceError::NotConnected {
                device: kind,
                message: format!("{device_id} dropped off the bus"),
            });
        }
        Ok(())
    }
}

#[async_trait::async_trait]
impl crate::device_ops::ConnectionOps for DroppingOps {
    async fn device_answers(&self, device_id: &str) -> DeviceResult<bool> {
        Ok(!self.down.lock().unwrap().contains(device_id))
    }

    async fn connect_device(&self, device_id: &str) -> DeviceResult<()> {
        if self.down.lock().unwrap().remove(device_id) {
            self.reconnected.lock().unwrap().push(device_id.to_string());
        }
        Ok(())
    }
}

crate::forward_device_ops!(
    DroppingOps => inner: RotatorOps, DomeOps, CoverCalibratorOps, SafetyOps,
    PlateSolveOps, FrameStoreOps, OperatorNotifyOps
);

impl crate::device_ops::SiteOps for DroppingOps {
    fn get_observer_location(&self) -> Option<(f64, f64)> {
        Some((40.0, -75.0))
    }
}

#[async_trait::async_trait]
impl crate::device_ops::MountOps for DroppingOps {
    async fn mount_slew_to_coordinates(
        &self,
        mount_id: &str,
        ra_hours: f64,
        dec_degrees: f64,
    ) -> crate::device_ops::DeviceResult<()> {
        *self.pointing.lock().unwrap() = (ra_hours, dec_degrees);
        self.inner
            .mount_slew_to_coordinates(mount_id, ra_hours, dec_degrees)
            .await
    }
    async fn mount_abort_slew(&self, mount_id: &str) -> crate::device_ops::DeviceResult<()> {
        self.inner.mount_abort_slew(mount_id).await
    }
    async fn mount_get_coordinates(
        &self,
        _mount_id: &str,
    ) -> crate::device_ops::DeviceResult<(f64, f64)> {
        Ok(*self.pointing.lock().unwrap())
    }
    async fn mount_readback_frame(
        &self,
        mount_id: &str,
        ra_hours: f64,
        dec_degrees: f64,
    ) -> crate::device_ops::DeviceResult<(f64, f64)> {
        self.inner
            .mount_readback_frame(mount_id, ra_hours, dec_degrees)
            .await
    }
    async fn mount_readback_to_j2000(
        &self,
        mount_id: &str,
        ra_hours: f64,
        dec_degrees: f64,
    ) -> crate::device_ops::DeviceResult<(f64, f64)> {
        self.inner
            .mount_readback_to_j2000(mount_id, ra_hours, dec_degrees)
            .await
    }
    async fn mount_sync(
        &self,
        mount_id: &str,
        ra_hours: f64,
        dec_degrees: f64,
    ) -> crate::device_ops::DeviceResult<()> {
        self.inner.mount_sync(mount_id, ra_hours, dec_degrees).await
    }
    async fn mount_park(&self, mount_id: &str) -> crate::device_ops::DeviceResult<()> {
        self.inner.mount_park(mount_id).await
    }
    async fn mount_unpark(&self, mount_id: &str) -> crate::device_ops::DeviceResult<()> {
        self.gate(crate::device_ops::DeviceKind::Mount, mount_id)?;
        self.inner.mount_unpark(mount_id).await
    }
    async fn mount_find_home(&self, mount_id: &str) -> crate::device_ops::DeviceResult<()> {
        self.inner.mount_find_home(mount_id).await
    }
    async fn mount_is_at_home(&self, mount_id: &str) -> crate::device_ops::DeviceResult<bool> {
        self.inner.mount_is_at_home(mount_id).await
    }
    async fn mount_is_slewing(&self, mount_id: &str) -> crate::device_ops::DeviceResult<bool> {
        self.inner.mount_is_slewing(mount_id).await
    }
    async fn mount_slew_state(&self, mount_id: &str) -> crate::slew_arrival::SlewSample {
        self.inner.mount_slew_state(mount_id).await
    }
    async fn mount_is_parked(&self, mount_id: &str) -> crate::device_ops::DeviceResult<bool> {
        self.gate(crate::device_ops::DeviceKind::Mount, mount_id)?;
        self.inner.mount_is_parked(mount_id).await
    }
    async fn mount_can_flip(&self, mount_id: &str) -> crate::device_ops::DeviceResult<bool> {
        self.inner.mount_can_flip(mount_id).await
    }
    async fn mount_side_of_pier(
        &self,
        mount_id: &str,
    ) -> crate::device_ops::DeviceResult<crate::meridian::PierSide> {
        self.inner.mount_side_of_pier(mount_id).await
    }
    async fn mount_is_tracking(&self, mount_id: &str) -> crate::device_ops::DeviceResult<bool> {
        self.inner.mount_is_tracking(mount_id).await
    }
    async fn mount_set_tracking(
        &self,
        mount_id: &str,
        enabled: bool,
    ) -> crate::device_ops::DeviceResult<()> {
        self.inner.mount_set_tracking(mount_id, enabled).await
    }
    async fn mount_move_axis(
        &self,
        mount_id: &str,
        axis: i32,
        rate_deg_per_sec: f64,
    ) -> crate::device_ops::DeviceResult<()> {
        self.inner
            .mount_move_axis(mount_id, axis, rate_deg_per_sec)
            .await
    }
    async fn request_mount_fault_hold(&self, mount_id: &str, message: &str) {
        self.inner.request_mount_fault_hold(mount_id, message).await
    }
}

#[async_trait::async_trait]
impl crate::device_ops::CameraOps for DroppingOps {
    async fn camera_start_exposure(
        &self,
        request: crate::device_ops::ExposureRequest<'_>,
    ) -> crate::device_ops::DeviceResult<crate::device_ops::ImageData> {
        self.gate(crate::device_ops::DeviceKind::Camera, request.camera_id)?;
        self.inner.camera_start_exposure(request).await
    }
    async fn camera_abort_exposure(&self, camera_id: &str) -> crate::device_ops::DeviceResult<()> {
        self.inner.camera_abort_exposure(camera_id).await
    }
    async fn camera_set_cooler(
        &self,
        camera_id: &str,
        enabled: bool,
        target_temp: f64,
    ) -> crate::device_ops::DeviceResult<()> {
        self.inner
            .camera_set_cooler(camera_id, enabled, target_temp)
            .await
    }
    async fn camera_get_temperature(
        &self,
        camera_id: &str,
    ) -> crate::device_ops::DeviceResult<f64> {
        self.inner.camera_get_temperature(camera_id).await
    }
    async fn camera_get_cooler_power(
        &self,
        camera_id: &str,
    ) -> crate::device_ops::DeviceResult<f64> {
        self.inner.camera_get_cooler_power(camera_id).await
    }
    async fn camera_get_cooler_on(
        &self,
        camera_id: &str,
    ) -> crate::device_ops::DeviceResult<Option<bool>> {
        self.inner.camera_get_cooler_on(camera_id).await
    }
    async fn camera_get_cooler_setpoint(
        &self,
        camera_id: &str,
    ) -> crate::device_ops::DeviceResult<Option<f64>> {
        self.inner.camera_get_cooler_setpoint(camera_id).await
    }
    async fn camera_get_pixel_size_um(
        &self,
        camera_id: &str,
    ) -> crate::device_ops::DeviceResult<Option<(f64, f64)>> {
        self.inner.camera_get_pixel_size_um(camera_id).await
    }
    async fn camera_get_model(
        &self,
        camera_id: &str,
    ) -> crate::device_ops::DeviceResult<Option<String>> {
        self.inner.camera_get_model(camera_id).await
    }
    async fn camera_get_iso_speeds(
        &self,
        camera_id: &str,
    ) -> crate::device_ops::DeviceResult<Vec<i32>> {
        self.inner.camera_get_iso_speeds(camera_id).await
    }
}

#[async_trait::async_trait]
impl crate::device_ops::FilterWheelOps for DroppingOps {
    async fn filterwheel_set_position(
        &self,
        fw_id: &str,
        position: i32,
    ) -> crate::device_ops::DeviceResult<()> {
        self.gate(crate::device_ops::DeviceKind::FilterWheel, fw_id)?;
        self.inner.filterwheel_set_position(fw_id, position).await
    }
    async fn filterwheel_get_position(&self, fw_id: &str) -> crate::device_ops::DeviceResult<i32> {
        self.inner.filterwheel_get_position(fw_id).await
    }
    async fn filterwheel_get_names(
        &self,
        fw_id: &str,
    ) -> crate::device_ops::DeviceResult<Vec<String>> {
        self.inner.filterwheel_get_names(fw_id).await
    }
    async fn filterwheel_set_filter_by_name(
        &self,
        fw_id: &str,
        name: &str,
    ) -> crate::device_ops::DeviceResult<i32> {
        self.gate(crate::device_ops::DeviceKind::FilterWheel, fw_id)?;
        self.inner.filterwheel_set_filter_by_name(fw_id, name).await
    }
}

#[async_trait::async_trait]
impl crate::device_ops::GuiderOps for DroppingOps {
    async fn guider_dither(
        &self,
        pixels: f64,
        settle_pixels: f64,
        settle_time: f64,
        settle_timeout: f64,
        ra_only: bool,
    ) -> crate::device_ops::DeviceResult<()> {
        self.inner
            .guider_dither(pixels, settle_pixels, settle_time, settle_timeout, ra_only)
            .await
    }
    async fn guider_get_status(
        &self,
    ) -> crate::device_ops::DeviceResult<crate::device_ops::GuidingStatus> {
        self.inner.guider_get_status().await
    }
    async fn guider_is_active(&self) -> crate::device_ops::DeviceResult<bool> {
        self.inner.guider_is_active().await
    }
    async fn guider_get_calibration(
        &self,
    ) -> crate::device_ops::DeviceResult<crate::device_ops::GuidingCalibration> {
        self.inner.guider_get_calibration().await
    }
    async fn guider_start(
        &self,
        settle_pixels: f64,
        settle_time: f64,
        settle_timeout: f64,
    ) -> crate::device_ops::DeviceResult<()> {
        self.gate(crate::device_ops::DeviceKind::Guider, GUIDER)?;
        self.inner
            .guider_start(settle_pixels, settle_time, settle_timeout)
            .await
    }
    async fn guider_select_fresh_star(&self) -> crate::device_ops::DeviceResult<()> {
        self.inner.guider_select_fresh_star().await
    }
    async fn guider_select_fresh_star_above(
        &self,
        floor: crate::device_ops::GuideStarFloor,
    ) -> crate::device_ops::DeviceResult<()> {
        self.inner.guider_select_fresh_star_above(floor).await
    }
    async fn guider_star_quality(
        &self,
    ) -> crate::device_ops::DeviceResult<Option<crate::device_ops::GuideStarQuality>> {
        self.inner.guider_star_quality().await
    }
    async fn guider_stop(&self) -> crate::device_ops::DeviceResult<()> {
        self.inner.guider_stop().await
    }
    async fn guider_note_stop_reason(&self, reason: Option<crate::GuidingStopReason>) {
        self.inner.guider_note_stop_reason(reason).await
    }
}

#[async_trait::async_trait]
impl crate::device_ops::FocuserOps for DroppingOps {
    async fn focuser_move_to(
        &self,
        focuser_id: &str,
        position: i32,
    ) -> crate::device_ops::DeviceResult<()> {
        self.gate(crate::device_ops::DeviceKind::Focuser, focuser_id)?;
        self.inner.focuser_move_to(focuser_id, position).await
    }
    async fn focuser_get_position(&self, focuser_id: &str) -> crate::device_ops::DeviceResult<i32> {
        self.gate(crate::device_ops::DeviceKind::Focuser, focuser_id)?;
        self.inner.focuser_get_position(focuser_id).await
    }
    async fn focuser_is_moving(&self, focuser_id: &str) -> crate::device_ops::DeviceResult<bool> {
        self.inner.focuser_is_moving(focuser_id).await
    }
    async fn focuser_get_temperature(
        &self,
        focuser_id: &str,
    ) -> crate::device_ops::DeviceResult<Option<f64>> {
        self.inner.focuser_get_temperature(focuser_id).await
    }
    async fn focuser_halt(&self, focuser_id: &str) -> crate::device_ops::DeviceResult<()> {
        self.inner.focuser_halt(focuser_id).await
    }
}

fn node(id: &str, node_type: crate::NodeType, children: &[&str]) -> crate::NodeDefinition {
    crate::NodeDefinition {
        id: id.to_string(),
        name: id.to_string(),
        node_type,
        enabled: true,
        children: children.iter().map(|c| c.to_string()).collect(),
    }
}

/// Unpark, start guiding, change filter, then four frames: each device drops
/// once along the way.
fn dropping_run_sequence() -> SequenceDefinition {
    let mut sequence = SequenceDefinition::new("Drops".to_string());
    sequence.nodes = vec![
        node(
            "target",
            crate::NodeType::TargetHeader(crate::TargetHeaderConfig {
                target_name: "M 1".to_string(),
                ra_hours: 5.575,
                dec_degrees: 22.01,
                ..Default::default()
            }),
            &["unpark", "guide", "filter", "expose"],
        ),
        node("unpark", crate::NodeType::Unpark, &[]),
        node(
            "guide",
            crate::NodeType::StartGuiding(crate::StartGuidingConfig::default()),
            &[],
        ),
        node(
            "filter",
            crate::NodeType::ChangeFilter(crate::FilterConfig {
                filter_index: Some(1),
                ..Default::default()
            }),
            &[],
        ),
        node(
            "expose",
            crate::NodeType::TakeExposure(crate::ExposureConfig {
                count: 4,
                duration_secs: 0.01,
                frame_type: crate::FrameType::Dark,
                ..Default::default()
            }),
            &[],
        ),
    ];
    sequence.root_node_id = Some("target".to_string());
    sequence
}

/// Run the sequence against `ops` until it ends; the states it passed
/// through and how it ended.
async fn run_unattended(ops: Arc<DroppingOps>) {
    let dir = std::env::temp_dir().join(format!("sk-drops-{}", uuid::Uuid::new_v4()));
    let mut executor = SequenceExecutor::new();
    executor.set_device_ops(ops.clone());
    executor
        .load_sequence(dropping_run_sequence())
        .expect("loads");
    executor.set_save_path(Some(dir.clone()));
    executor.set_devices(
        Some(CAMERA.to_string()),
        Some(MOUNT.to_string()),
        Some(FOCUSER.to_string()),
        Some(WHEEL.to_string()),
        None,
    );
    let mut events = executor.handle().subscribe();
    executor.start().await.expect("starts");

    let mut states = Vec::new();
    let finished = tokio::time::timeout(std::time::Duration::from_secs(120), async {
        loop {
            let state = executor.get_state().await;
            if states.last() != Some(&state) {
                states.push(state);
            }
            if matches!(
                state,
                ExecutorState::Completed | ExecutorState::Failed | ExecutorState::Idle
            ) {
                return state;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
    })
    .await;
    let progress = executor.get_progress();
    executor.stop().await.ok();
    let _ = std::fs::remove_dir_all(&dir);

    let mut seen = Vec::new();
    while let Ok(event) = events.try_recv() {
        let text = format!("{event:?}");
        if !text.contains("Progress") {
            seen.push(text);
        }
    }
    let dropped = ops.dropped.lock().unwrap().clone();
    let reconnected = ops.reconnected.lock().unwrap().clone();
    assert_eq!(
        finished.ok(),
        Some(ExecutorState::Completed),
        "states {states:?}, dropped {dropped:?}, reconnected {reconnected:?}, message {:?}, events {seen:#?}",
        progress.message
    );
    assert!(
        !states.contains(&ExecutorState::Paused),
        "the run never sat paused: {states:?}"
    );
}

/// The same run with nothing dropping completes: the baseline the drops are
/// measured against.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_run_completes_when_nothing_drops() {
    run_unattended(Arc::new(DroppingOps::new(&[]))).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_run_whose_devices_each_drop_once_finishes_unattended() {
    let ops = Arc::new(DroppingOps::new(&[
        (DeviceKind::Mount, 1),
        (DeviceKind::Guider, 1),
        (DeviceKind::FilterWheel, 1),
        (DeviceKind::Camera, 2),
        (DeviceKind::Focuser, 1),
    ]));
    run_unattended(ops.clone()).await;
    let dropped = ops.dropped.lock().unwrap().clone();
    let reconnected = ops.reconnected.lock().unwrap().clone();
    for device in [MOUNT, GUIDER, WHEEL, CAMERA, FOCUSER] {
        assert!(
            dropped.contains(&device.to_string()),
            "{device} dropped: {dropped:?}"
        );
    }
    // Every device the run drives by role is reconnected by its recovery. A
    // guider that fails to start leaves the run imaging unguided (a guiding
    // problem only notifies); guiding is tried again before a later frame.
    for device in [MOUNT, WHEEL, CAMERA, FOCUSER] {
        assert!(
            reconnected.contains(&device.to_string()),
            "{device} was reconnected by the run: {reconnected:?}"
        );
    }
}
