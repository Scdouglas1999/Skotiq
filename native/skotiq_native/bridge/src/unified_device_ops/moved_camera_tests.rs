//! A run's camera that came back at another id (rig, Nov 8 2026:
//! `native:zwo:1` came back as `native:zwo:0`). The run keeps the id it
//! started with; the device manager follows the camera to its new id and the
//! run's frames and reopens reach it there. Which camera an id leads to is
//! decided by what the camera says it is, never by its position.

use super::*;
use crate::device::{DeviceInfo, DeviceType, DriverType};
use crate::device_manager::get_device_manager;
use crate::simulator::camera::{
    reset_sim_camera_bus, unplug_sim_camera, SIM_GUIDE_CAMERA_ID, SIM_GUIDE_SENSOR_W,
    SIM_IMAGING_CAMERA_ID,
};
use crate::simulator::frame::SIM_W;
use skotiq_sequencer::{DeviceError, ExposureRequest};

const IMAGING: &str = "Simulated Camera";
const GUIDE: &str = "Simulated Guide Camera";

fn sim_camera(id: &str) -> DeviceInfo {
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
    }
}

async fn clean_bus() {
    let mgr = get_device_manager();
    for id in [SIM_IMAGING_CAMERA_ID, SIM_GUIDE_CAMERA_ID] {
        let _ = mgr.disconnect_device(id).await;
        mgr.unregister_device(id).await;
    }
    reset_sim_camera_bus();
    crate::discovery::forget().await;
}

/// The imaging camera connected at its id; with `guide_registered`, the
/// guide camera too, at its own.
async fn connect_rig(guide_registered: bool) {
    let mgr = get_device_manager();
    mgr.register_device(sim_camera(SIM_IMAGING_CAMERA_ID), false)
        .await;
    mgr.connect_device_expecting(SIM_IMAGING_CAMERA_ID, Some(IMAGING))
        .await
        .expect("the imaging camera connects");
    if guide_registered {
        mgr.register_device(sim_camera(SIM_GUIDE_CAMERA_ID), false)
            .await;
        mgr.connect_device_expecting(SIM_GUIDE_CAMERA_ID, Some(GUIDE))
            .await
            .expect("the guide camera connects");
    }
}

/// The hub drops and the two cameras re-enumerate in the other order; the
/// imaging camera's reconnect at its old id is refused and looked for
/// elsewhere.
async fn hub_drops_and_cameras_reorder() {
    let mgr = get_device_manager();
    unplug_sim_camera(SIM_IMAGING_CAMERA_ID, true).await;
    mgr.mark_lost(SIM_IMAGING_CAMERA_ID, false, "the hub dropped")
        .await;
    mgr.attempt_reconnect(SIM_IMAGING_CAMERA_ID, &sim_camera(SIM_IMAGING_CAMERA_ID))
        .await;
}

fn broken_session() -> DeviceError {
    DeviceError::SessionLost("ZWO camera reported a failed exposure".to_string())
}

/// The width of a frame the run takes at `id`, or the error.
async fn frame_width(id: &str) -> Result<u32, String> {
    create_unified_device_ops()
        .camera_start_exposure(ExposureRequest::new(id, 0.05))
        .await
        .map(|frame| frame.width)
        .map_err(|e| e.to_string())
}

/// The run's camera retry after the hub drop reopens the camera where it is
/// now, and the next frame is taken there, on the imaging camera. Before,
/// the reopen went to the old id, where the guide camera now answers, was
/// refused, and the run gave the camera up as lost.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_runs_camera_that_came_back_at_another_id_is_followed() {
    let _serialized = crate::simulator::sim_singleton_test_lock().lock().await;
    clean_bus().await;
    connect_rig(false).await;
    hub_drops_and_cameras_reorder().await;
    let mgr = get_device_manager();
    assert!(
        mgr.is_connected(SIM_GUIDE_CAMERA_ID).await,
        "the imaging camera is connected where it went"
    );

    let reopened = create_unified_device_ops()
        .reopen_camera_after(SIM_IMAGING_CAMERA_ID, &broken_session())
        .await;
    let frame = frame_width(SIM_IMAGING_CAMERA_ID).await;
    let answers = create_unified_device_ops()
        .device_answers(SIM_IMAGING_CAMERA_ID)
        .await;
    clean_bus().await;

    assert_eq!(
        reopened.map_err(|e| e.to_string()),
        Ok(true),
        "the run's reopen reaches the camera at its new id"
    );
    assert_eq!(frame, Ok(SIM_W as u32), "the frame is the imaging camera's");
    assert_eq!(answers.map_err(|e| e.to_string()), Ok(true));
}

/// Both cameras are known and trade places: neither is connected at the
/// other's id, nothing maps one id to the other, and the run's frame at the
/// imaging camera's id is never taken on the guide camera.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn two_known_cameras_that_trade_ids_are_not_mapped_onto_each_other() {
    let _serialized = crate::simulator::sim_singleton_test_lock().lock().await;
    clean_bus().await;
    connect_rig(true).await;
    hub_drops_and_cameras_reorder().await;
    let mgr = get_device_manager();
    mgr.mark_lost(SIM_GUIDE_CAMERA_ID, false, "the hub dropped")
        .await;
    mgr.attempt_reconnect(SIM_GUIDE_CAMERA_ID, &sim_camera(SIM_GUIDE_CAMERA_ID))
        .await;

    let imaging_resolves_to = mgr.current_id(SIM_IMAGING_CAMERA_ID);
    let guide_resolves_to = mgr.current_id(SIM_GUIDE_CAMERA_ID);
    let reopened = create_unified_device_ops()
        .reopen_camera_after(SIM_IMAGING_CAMERA_ID, &broken_session())
        .await;
    let frame = frame_width(SIM_IMAGING_CAMERA_ID).await;
    clean_bus().await;

    assert_eq!(imaging_resolves_to, SIM_IMAGING_CAMERA_ID);
    assert_eq!(guide_resolves_to, SIM_GUIDE_CAMERA_ID);
    assert!(
        reopened.is_err(),
        "the guide camera is not opened as the imaging camera: {reopened:?}"
    );
    assert!(
        frame.is_err(),
        "no frame on the guide camera at the imaging camera's id: {frame:?}"
    );
}

/// After the imaging camera was followed to the guide camera's id, the
/// guide camera is connected by hand at the imaging camera's old id. That id
/// is the guide camera's now: a frame asked of it is the guide camera's, not
/// sent on to the imaging camera.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_old_id_connected_again_as_another_camera_is_its_own() {
    let _serialized = crate::simulator::sim_singleton_test_lock().lock().await;
    clean_bus().await;
    connect_rig(false).await;
    hub_drops_and_cameras_reorder().await;
    let mgr = get_device_manager();
    let followed = mgr.current_id(SIM_IMAGING_CAMERA_ID);

    let reconnected = mgr
        .connect_device_expecting(SIM_IMAGING_CAMERA_ID, Some(GUIDE))
        .await;
    let resolves_to = mgr.current_id(SIM_IMAGING_CAMERA_ID);
    let frame = frame_width(SIM_IMAGING_CAMERA_ID).await;
    let imaging_frame = frame_width(SIM_GUIDE_CAMERA_ID).await;
    clean_bus().await;

    assert_eq!(followed, SIM_GUIDE_CAMERA_ID);
    reconnected.expect("the guide camera connects at the old id");
    assert_eq!(resolves_to, SIM_IMAGING_CAMERA_ID, "the mapping is dropped");
    assert_eq!(frame, Ok(SIM_GUIDE_SENSOR_W), "the guide camera's frame");
    assert_eq!(imaging_frame, Ok(SIM_W as u32));
}

/// After the follow, the cameras trade places again and the guide camera is
/// connected at the id the imaging camera had moved to. That id no longer
/// holds the imaging camera: the run's frame is not sent there.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_new_id_that_holds_another_camera_is_not_followed() {
    let _serialized = crate::simulator::sim_singleton_test_lock().lock().await;
    clean_bus().await;
    connect_rig(false).await;
    hub_drops_and_cameras_reorder().await;
    let mgr = get_device_manager();
    let followed = mgr.current_id(SIM_IMAGING_CAMERA_ID);

    unplug_sim_camera(SIM_GUIDE_CAMERA_ID, true).await;
    let reconnected = mgr
        .connect_device_expecting(SIM_GUIDE_CAMERA_ID, Some(GUIDE))
        .await;
    let resolves_to = mgr.current_id(SIM_IMAGING_CAMERA_ID);
    let frame = frame_width(SIM_IMAGING_CAMERA_ID).await;
    clean_bus().await;

    assert_eq!(followed, SIM_GUIDE_CAMERA_ID);
    reconnected.expect("the guide camera connects at its own id again");
    assert_eq!(resolves_to, SIM_IMAGING_CAMERA_ID, "the mapping is dropped");
    assert_ne!(
        frame,
        Ok(SIM_GUIDE_SENSOR_W),
        "no frame on the guide camera for the imaging camera"
    );
}
