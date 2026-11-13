use super::*;
use crate::device_manager::handle::DeviceHandle;
use crate::device_manager::rig::focuser::IndiFocuserHandle;
use crate::event::{EquipmentEvent, EventPayload};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpListener;

const FOCUSER: &str = "Fake Focuser";

/// A client on a loopback server whose one device reads connected and never
/// answers a command, so a disconnect is never confirmed.
async fn server_that_never_answers() -> skotiq_indi::IndiClient {
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let port = listener.local_addr().expect("address").port();
    tokio::spawn(async move {
        let (socket, _) = listener.accept().await.expect("accept");
        let (reader, mut writer) = socket.into_split();
        let mut lines = BufReader::new(reader).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            if line.contains("<getProperties") {
                let definitions = format!(
                    "<defSwitchVector device=\"{FOCUSER}\" name=\"CONNECTION\" state=\"Ok\" \
                     perm=\"rw\" rule=\"OneOfMany\">\
                     <defSwitch name=\"CONNECT\">On</defSwitch>\
                     <defSwitch name=\"DISCONNECT\">Off</defSwitch></defSwitchVector>\n"
                );
                let _ = writer.write_all(definitions.as_bytes()).await;
            }
        }
    });
    let mut client = skotiq_indi::IndiClient::new("127.0.0.1", Some(port));
    client.connect().await.expect("connect");
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(5);
    while !client.is_device_connected(FOCUSER).await {
        assert!(
            tokio::time::Instant::now() < deadline,
            "definitions arrived"
        );
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
    client
}

fn focuser_info(id: &str) -> DeviceInfo {
    DeviceInfo {
        id: id.to_string(),
        name: FOCUSER.to_string(),
        device_type: DeviceType::Focuser,
        driver_type: DriverType::Indi,
        description: "INDI device on 127.0.0.1".to_string(),
        driver_version: "INDI".to_string(),
        serial_number: None,
        unique_id: None,
        display_name: FOCUSER.to_string(),
    }
}

async fn published_disconnected(
    rx: &mut tokio::sync::broadcast::Receiver<crate::event::SkotiqEvent>,
    id: &str,
) -> bool {
    while let Ok(event) = rx.try_recv() {
        if let EventPayload::Equipment(EquipmentEvent::Disconnected { device_id, .. }) =
            &event.payload
        {
            if device_id == id {
                return true;
            }
        }
    }
    false
}

/// A camera or mount on a server Skotiq has no connection to cannot be
/// released, and the disconnect says so, but the device still reads
/// disconnected and the app is told.
#[tokio::test]
async fn an_indi_mount_that_cannot_be_released_is_still_disconnected() {
    let manager = build_device_manager();
    let id = "indi:127.0.0.1:1:Fake Mount";
    let info = build_mount_info(id, DriverType::Indi);
    manager.register_device(info, false).await;
    let mut rx = manager.app_state.event_bus.subscribe();

    let error = manager
        .disconnect_device(id)
        .await
        .expect_err("the release failed");

    assert!(error.contains("not found"), "{error}");
    assert!(published_disconnected(&mut rx, id).await);
    assert_eq!(
        manager
            .devices
            .read()
            .await
            .get(id)
            .map(|d| d.connection_state),
        Some(ConnectionState::Disconnected)
    );
}

/// An INDI focuser is released through its handle like any other device;
/// when the driver never confirms, the device is still disconnected.
#[tokio::test]
async fn an_indi_focuser_whose_driver_never_confirms_is_still_disconnected() {
    let manager = build_device_manager();
    let client = Arc::new(RwLock::new(server_that_never_answers().await));
    let port = client.read().await.port();
    let id = format!("indi:127.0.0.1:{port}:{FOCUSER}");
    let info = focuser_info(&id);
    manager.register_device(info, false).await;
    manager.handles.insert(
        &id,
        DeviceHandle::Focuser(Arc::new(IndiFocuserHandle::new(&id, client, FOCUSER))),
    );
    let mut rx = manager.app_state.event_bus.subscribe();

    let error = manager
        .disconnect_device(&id)
        .await
        .expect_err("the driver never confirmed");

    assert!(error.contains("confirm disconnection"), "{error}");
    assert!(published_disconnected(&mut rx, &id).await);
    assert_eq!(
        manager
            .devices
            .read()
            .await
            .get(id.as_str())
            .map(|d| d.connection_state),
        Some(ConnectionState::Disconnected)
    );
    assert!(manager.handles.get(&id).is_none());
}

/// The heartbeat of an INDI device with a handle goes through the handle,
/// which holds its own server connection.
#[tokio::test]
async fn an_indi_focuser_heartbeat_goes_through_its_handle() {
    let manager = build_device_manager();
    let client = Arc::new(RwLock::new(server_that_never_answers().await));
    let port = client.read().await.port();
    let id = format!("indi:127.0.0.1:{port}:{FOCUSER}");
    manager.handles.insert(
        &id,
        DeviceHandle::Focuser(Arc::new(IndiFocuserHandle::new(&id, client, FOCUSER))),
    );

    let healthy = manager
        .perform_health_check_once(&id, &DeviceType::Focuser, &DriverType::Indi)
        .await;

    assert_eq!(healthy, Ok(true));
}

/// A client on a loopback server that answers getProperties with what
/// INDI's CCD simulator defines once it is connected.
async fn connected_ccd_simulator() -> skotiq_indi::IndiClient {
    let definitions = std::fs::read_to_string(
        std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../indi/tests/drivers/ccd_simulator.after.xml"),
    )
    .expect("the recorded definitions");
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let port = listener.local_addr().expect("address").port();
    tokio::spawn(async move {
        let (socket, _) = listener.accept().await.expect("accept");
        let (reader, mut writer) = socket.into_split();
        let mut lines = BufReader::new(reader).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            if line.contains("<getProperties") {
                let _ = writer.write_all(definitions.as_bytes()).await;
            }
        }
    });
    let mut client = skotiq_indi::IndiClient::new("127.0.0.1", Some(port));
    client.connect().await.expect("connect");
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(5);
    while !client.has_property("CCD Simulator", "CCD_INFO").await {
        assert!(
            tokio::time::Instant::now() < deadline,
            "definitions arrived"
        );
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
    client
}

/// The CCD simulator keeps its default duration (1 s) in CCD_EXPOSURE while
/// it is idle. The status read that value as time left, so a camera that had
/// just connected read "exposing" and every capture was refused until an
/// abort.
#[tokio::test]
async fn an_indi_camera_at_rest_with_a_duration_left_in_ccd_exposure_is_idle() {
    use crate::device_manager::rig::camera::{Camera, IndiCameraHandle};

    let client = std::sync::Arc::new(tokio::sync::RwLock::new(connected_ccd_simulator().await));
    let duration = client
        .read()
        .await
        .get_number("CCD Simulator", "CCD_EXPOSURE", "CCD_EXPOSURE_VALUE")
        .await;
    assert_eq!(duration, Some(1.0), "the recording has the idle duration");

    let camera = IndiCameraHandle::new("indi:127.0.0.1:1:CCD Simulator", client, "CCD Simulator");
    let status = camera.status().await.expect("status");
    assert_eq!(status.state, crate::device::CameraState::Idle);
}

/// A CCD simulator that, when an exposure is started, sends an 8-byte frame
/// and then reports the exposure done, as INDI drivers do; and that sends an
/// unrelated update ten times a second, as a tracking mount on the same
/// connection would.
async fn exposing_ccd_simulator_on_a_busy_connection() -> skotiq_indi::IndiClient {
    let definitions = std::fs::read_to_string(
        std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../indi/tests/drivers/ccd_simulator.after.xml"),
    )
    .expect("the recorded definitions");
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let port = listener.local_addr().expect("address").port();
    tokio::spawn(async move {
        let (socket, _) = listener.accept().await.expect("accept");
        let (reader, writer) = socket.into_split();
        let writer = std::sync::Arc::new(tokio::sync::Mutex::new(writer));
        let chatter = writer.clone();
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                let update = "<setNumberVector device=\"CCD Simulator\" name=\"CCD_TEMPERATURE\" \
                              state=\"Ok\"><oneNumber name=\"CCD_TEMPERATURE_VALUE\">0</oneNumber>\
                              </setNumberVector>\n";
                if chatter.lock().await.write_all(update.as_bytes()).await.is_err() {
                    return;
                }
            }
        });
        let mut lines = BufReader::new(reader).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            if line.contains("<getProperties") {
                let _ = writer.lock().await.write_all(definitions.as_bytes()).await;
            }
            if line.contains("name=\"CCD_EXPOSURE\"") {
                // Eight bytes, four 16-bit pixels: AQACAAMABAA= in base64.
                let frame = "<setBLOBVector device=\"CCD Simulator\" name=\"CCD1\" state=\"Ok\">\
                             <oneBLOB name=\"CCD1\" size=\"8\" format=\".raw\" enclen=\"12\">\
                             AQACAAMABAA=</oneBLOB></setBLOBVector>\n\
                             <setNumberVector device=\"CCD Simulator\" name=\"CCD_EXPOSURE\" \
                             state=\"Ok\"><oneNumber name=\"CCD_EXPOSURE_VALUE\">0</oneNumber>\
                             </setNumberVector>\n";
                let _ = writer.lock().await.write_all(frame.as_bytes()).await;
            }
        }
    });
    let mut client = skotiq_indi::IndiClient::new("127.0.0.1", Some(port));
    client.connect().await.expect("connect");
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(5);
    while !client.has_property("CCD Simulator", "CCD_INFO").await {
        assert!(
            tokio::time::Instant::now() < deadline,
            "definitions arrived"
        );
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
    client
}

/// A driver sends the frame before it reports the exposure done, so the
/// frame is with the connection before anyone waits for it. The wait looked
/// for it there only in a second without any event, and a tracking mount on
/// the same server sends one every second: the frame was never found and the
/// capture failed after 30 s with "Timeout waiting for INDI image BLOB".
#[tokio::test]
async fn an_indi_frame_is_read_while_other_devices_keep_the_connection_busy() {
    use crate::device_manager::rig::camera::{Camera, IndiCameraHandle};

    let client = std::sync::Arc::new(tokio::sync::RwLock::new(
        exposing_ccd_simulator_on_a_busy_connection().await,
    ));
    let camera = IndiCameraHandle::new("indi:127.0.0.1:1:CCD Simulator", client, "CCD Simulator");
    camera
        .start_exposure(1.0, None, None, 1, 1, None, skotiq_device::FrameType::Light)
        .await
        .expect("start");
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(5);
    while !camera.is_exposure_complete().await.expect("poll") {
        assert!(tokio::time::Instant::now() < deadline, "the exposure ended");
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    let frame = tokio::time::timeout(std::time::Duration::from_secs(5), camera.read_frame())
        .await
        .expect("the frame is read at once, not after the 30 s wait")
        .expect("frame");
    assert_eq!(&frame.data[..4], &[1, 2, 3, 4]);
}
