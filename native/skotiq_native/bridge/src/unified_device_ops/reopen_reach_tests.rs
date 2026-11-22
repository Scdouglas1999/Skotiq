//! Which broken camera sessions the device layer reopens by itself, for
//! every frame taker alike, and which reach the frame's caller.
//!
//! The device layer reopens a camera whose session broke when the start is
//! refused or the exposure ends failed, and [`CameraOps::camera_start_exposure`]
//! takes the frame once more on the reopened camera. A break during the
//! download, a second break on that one retake, and a transient fault are
//! returned to the caller: only a caller with the run's camera retries
//! (`skotiq_sequencer` `CameraRetries`) reopens and retries then.

use super::*;
use crate::device::{DeviceInfo, DeviceType, DriverType};
use crate::device_manager::get_device_manager;
use crate::simulator::faults::{self, Effect, FaultSpec, Trigger};
use skotiq_sequencer::ExposureRequest;

/// The words a ZWO camera's broken session fails with.
const ZWO_FAILED: &str = "ZWO camera reported a failed exposure";

async fn connect_sim_camera(id: &str) {
    let mgr = get_device_manager();
    mgr.register_device(
        DeviceInfo {
            id: id.to_string(),
            name: "Simulated Camera".to_string(),
            device_type: DeviceType::Camera,
            driver_type: DriverType::Simulator,
            description: "Simulated camera".to_string(),
            driver_version: "1.0".to_string(),
            serial_number: None,
            unique_id: None,
            display_name: "Simulated Camera".to_string(),
        },
        false,
    )
    .await;
    mgr.connect_device(id).await.expect("connect");
}

async fn frame_after(id: &str, key: &str, times: u32, message: &str) -> (bool, u64) {
    let mgr = get_device_manager();
    let before = mgr.reopen_count(id);
    faults::arm(
        key,
        FaultSpec::new(Trigger::Times(times), Effect::Error(message.to_string())),
    );
    let result = create_unified_device_ops()
        .camera_start_exposure(ExposureRequest::new(id, 0.05))
        .await;
    faults::clear(key);
    (result.is_ok(), mgr.reopen_count(id) - before)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_device_layer_reopens_one_break_at_start_or_completion_and_no_other() {
    let _serialized = crate::simulator::sim_singleton_test_lock().lock().await;
    let id = "sim_camera_reopen_reach";
    connect_sim_camera(id).await;

    assert_eq!(
        frame_after(id, "camera.exposure_status", 1, ZWO_FAILED).await,
        (true, 1),
        "an exposure that ends failed: reopened, the frame taken again"
    );
    assert_eq!(
        frame_after(id, "camera.start", 1, ZWO_FAILED).await,
        (true, 1),
        "a refused start: reopened, the start sent again"
    );
    assert_eq!(
        frame_after(id, "camera.download", 1, ZWO_FAILED).await,
        (false, 0),
        "a break during the download reaches the caller, camera not reopened"
    );
    assert_eq!(
        frame_after(id, "camera.exposure_status", 2, ZWO_FAILED).await,
        (false, 2),
        "a second break on the retake reaches the caller"
    );
    assert_eq!(
        frame_after(id, "camera.download", 1, "USB transfer timed out").await,
        (false, 0),
        "a transient fault reaches the caller"
    );

    get_device_manager()
        .disconnect_device(id)
        .await
        .expect("disconnect");
}
