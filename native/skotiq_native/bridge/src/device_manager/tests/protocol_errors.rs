//! A device that answers in its protocol that it cannot do what was asked
//! reaches the caller as that kind of failure, not as a generic fault.

use super::*;
use crate::device::DriverType;
use crate::dispatch::error::DeviceOpError;
use crate::error::SkotiqError;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

/// An Alpaca server that answers every request with Alpaca error
/// `error_number`. Returns the server's base URL.
async fn alpaca_server_failing_with(error_number: i32, message: &'static str) -> String {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind fake Alpaca server");
    let address = listener.local_addr().expect("read listener address");
    tokio::spawn(async move {
        loop {
            let Ok((mut socket, _)) = listener.accept().await else {
                return;
            };
            tokio::spawn(async move {
                let mut request = vec![0_u8; 8192];
                if socket.read(&mut request).await.unwrap_or(0) == 0 {
                    return;
                }
                let body = serde_json::json!({
                    "ClientTransactionID": 0,
                    "ServerTransactionID": 1,
                    "ErrorNumber": error_number,
                    "ErrorMessage": message,
                })
                .to_string();
                let reply = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\
                     Content-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                );
                let _ = socket.write_all(reply.as_bytes()).await;
            });
        }
    });
    format!("http://{address}")
}

async fn register_alpaca_mount(manager: &DeviceManager, device_id: &str, base_url: &str) {
    manager.devices.write().await.insert(
        device_id.to_string(),
        ManagedDevice {
            info: build_mount_info(device_id, DriverType::Alpaca),
            connection_state: ConnectionState::Connected,
            last_error: None,
            reconnect_attempts: 0,
            auto_reconnect: false,
            last_successful_comm: None,
            heartbeat_deferred_at: None,
            heartbeat_active: false,
            desired_cooler: None,
            desired_tracking: None,
            declared_mount_frame: None,
        },
    );
    manager.hold_alpaca_mount(
        device_id,
        skotiq_alpaca::AlpacaTelescope::from_server(base_url, 0),
    );
}

/// Alpaca `NotConnected` (0x407): the driver behind the server lost its
/// device. The headless API answers 409 for that, and the sequencer reconnects
/// the mount instead of failing the run.
#[tokio::test]
async fn an_alpaca_mount_that_reports_not_connected_is_not_connected() {
    let base_url = alpaca_server_failing_with(0x407, "Telescope is not connected").await;
    let manager = build_device_manager();
    let device_id = "alpaca:protocol-errors-not-connected";
    register_alpaca_mount(&manager, device_id, &base_url).await;

    let error = manager
        .mount_slew(device_id, 5.5, 22.0)
        .await
        .expect_err("the server refuses the slew");
    assert!(
        matches!(error, DeviceOpError::NotConnected { .. }),
        "{error:?}"
    );
    assert!(
        error.to_string().contains("Telescope is not connected"),
        "the driver's own words stay in the message: {error}"
    );
    assert!(matches!(
        SkotiqError::from(error),
        SkotiqError::NotConnected(_)
    ));
}

/// Alpaca `NotImplemented` (0x400) and `InvalidValue` (0x401) are requests the
/// device refuses every time: 501 and 400, not a 500 a client retries.
#[tokio::test]
async fn an_alpaca_mount_that_refuses_the_request_says_why() {
    let manager = build_device_manager();

    let base_url = alpaca_server_failing_with(0x400, "Method not implemented").await;
    let unsupported = "alpaca:protocol-errors-not-implemented";
    register_alpaca_mount(&manager, unsupported, &base_url).await;
    let error = manager
        .mount_slew(unsupported, 5.5, 22.0)
        .await
        .expect_err("the server refuses the slew");
    assert!(
        matches!(error, DeviceOpError::Unsupported { .. }),
        "{error:?}"
    );
    assert!(
        error.to_string().contains("Method not implemented"),
        "{error}"
    );

    let base_url = alpaca_server_failing_with(0x401, "Declination out of range").await;
    let invalid = "alpaca:protocol-errors-invalid-value";
    register_alpaca_mount(&manager, invalid, &base_url).await;
    let error = manager
        .mount_slew(invalid, 5.5, 22.0)
        .await
        .expect_err("the server refuses the slew");
    assert!(
        matches!(error, DeviceOpError::InvalidParameter { .. }),
        "{error:?}"
    );
    assert!(
        error.to_string().contains("Declination out of range"),
        "{error}"
    );
}

/// A fake Alpaca telescope that has every status member but `AtHome` and
/// `SiderealTime`, which it answers with `NotImplemented`.
async fn alpaca_telescope_without_home_and_sidereal_time() -> String {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind fake Alpaca server");
    let address = listener.local_addr().expect("read listener address");
    tokio::spawn(async move {
        loop {
            let Ok((mut socket, _)) = listener.accept().await else {
                return;
            };
            tokio::spawn(async move {
                let mut request = vec![0_u8; 8192];
                let read = socket.read(&mut request).await.unwrap_or(0);
                let request = String::from_utf8_lossy(&request[..read]).to_string();
                let path = request.split_whitespace().nth(1).unwrap_or("");
                let member = path
                    .split('?')
                    .next()
                    .and_then(|p| p.rsplit('/').next())
                    .unwrap_or("");
                let (error, value) = match member {
                    "athome" | "siderealtime" => (0x400, serde_json::Value::Null),
                    "rightascension" | "declination" | "altitude" | "azimuth" => {
                        (0, serde_json::json!(1.5))
                    }
                    "trackingrate" | "sideofpier" => (0, serde_json::json!(0)),
                    "trackingrates" => (0, serde_json::json!([0])),
                    _ => (0, serde_json::json!(false)),
                };
                let body = serde_json::json!({
                    "ClientTransactionID": 0,
                    "ServerTransactionID": 1,
                    "ErrorNumber": error,
                    "ErrorMessage": if error == 0 { "" } else { "Property not implemented" },
                    "Value": value,
                })
                .to_string();
                let reply = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\
                     Content-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                );
                let _ = socket.write_all(reply.as_bytes()).await;
            });
        }
    });
    format!("http://{address}")
}

/// A reading an Alpaca telescope does not have was reported as a failed
/// read, in the server's error text, where every other protocol says the
/// mount has no such reading.
#[tokio::test]
async fn a_reading_an_alpaca_mount_does_not_have_is_unsupported_not_an_error() {
    use crate::device::{mount_status_field, FieldAvailability};

    let base_url = alpaca_telescope_without_home_and_sidereal_time().await;
    let manager = build_device_manager();
    let device_id = "alpaca:protocol-errors-missing-readings";
    register_alpaca_mount(&manager, device_id, &base_url).await;

    let status = manager
        .mount(device_id)
        .await
        .expect("the mount")
        .status()
        .await
        .expect("status");
    assert_eq!(status.at_home, None);
    assert_eq!(status.sidereal_time, None);
    for field in [
        mount_status_field::AT_HOME,
        mount_status_field::SIDEREAL_TIME,
    ] {
        assert!(
            matches!(
                status.availability.get(field),
                Some(FieldAvailability::Unsupported)
            ),
            "{field}: {:?}",
            status.availability.get(field)
        );
    }
    assert!(
        matches!(
            status.availability.get(mount_status_field::ALTITUDE),
            Some(FieldAvailability::Available)
        ),
        "{:?}",
        status.availability
    );
    assert_eq!(status.altitude, Some(1.5));
}

/// An Alpaca server that is gone (nothing listens at its address) was a
/// hardware fault, a 500 a client retries, although the device is simply
/// not there any more: 409, and the sequencer reconnects.
#[tokio::test]
async fn an_alpaca_mount_whose_server_is_gone_is_not_connected() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind");
    let base_url = format!("http://{}", listener.local_addr().expect("address"));
    drop(listener);
    let manager = build_device_manager();
    let device_id = "alpaca:protocol-errors-server-gone";
    register_alpaca_mount(&manager, device_id, &base_url).await;

    let error = manager
        .mount(device_id)
        .await
        .expect("the mount")
        .coordinates()
        .await
        .expect_err("nothing answers");
    assert!(
        matches!(error, DeviceOpError::NotConnected { .. }),
        "{error:?}"
    );
    assert!(
        error.to_string().contains("Connection refused"),
        "the client's own words stay in the message: {error}"
    );
}
