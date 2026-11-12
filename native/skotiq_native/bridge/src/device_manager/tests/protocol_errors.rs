//! A device that answers in its protocol that it cannot do what was asked
//! reaches the caller as that kind of failure, not as a generic fault.

use super::*;
use crate::dispatch::DeviceOpError;
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
        },
    );
    manager.alpaca_mounts.write().await.insert(
        device_id.to_string(),
        Arc::new(skotiq_alpaca::AlpacaTelescope::from_server(base_url, 0)),
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
