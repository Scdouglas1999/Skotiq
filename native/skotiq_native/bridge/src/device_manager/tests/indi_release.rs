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
/// released, and the disconnect says so, but the device still leaves the
/// connected list and the app is told.
#[tokio::test]
async fn an_indi_mount_that_cannot_be_released_is_still_disconnected() {
    let manager = build_device_manager();
    let id = "indi:127.0.0.1:1:Fake Mount";
    let info = build_mount_info(id, DriverType::Indi);
    manager.register_device(info.clone(), false).await;
    manager
        .app_state
        .register_device(info, ConnectionState::Connected)
        .await;
    let mut rx = manager.app_state.event_bus.subscribe();

    let error = manager
        .disconnect_device(id)
        .await
        .expect_err("the release failed");

    assert!(error.contains("not found"), "{error}");
    assert!(published_disconnected(&mut rx, id).await);
    assert!(manager
        .app_state
        .get_device(DeviceType::Mount, id)
        .await
        .is_none());
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
    manager.register_device(info.clone(), false).await;
    manager
        .app_state
        .register_device(info, ConnectionState::Connected)
        .await;
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
    assert!(manager
        .app_state
        .get_device(DeviceType::Focuser, &id)
        .await
        .is_none());
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
