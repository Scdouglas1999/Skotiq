//! Skotiq's Alpaca camera path against OmniSim, the ASCOM Initiative's own
//! Alpaca simulators: an independent ICameraV4 server, not a fake written to
//! agree with Skotiq.
//!
//! Ignored by default. Start OmniSim on loopback with the camera profile the
//! test names (the `osc` profile: RGGB with BayerOffsetX 1, `Gains` index mode
//! ISO 100..1600, `Offset` value mode 0..255, settable cooler, 1200x800,
//! MaxADU 4095), then run with `SKOTIQ_OMNISIM_URL=http://127.0.0.1:<port>`:
//!
//! ```text
//! cargo test --release -p skotiq_bridge omnisim_camera -- --ignored --test-threads=1
//! ```
//!
//! The launcher that keeps OmniSim off the LAN and off the desktop is
//! `~/.cache/ns-untangle/notes/asc-camera-tools/infra.sh` with
//! `camprofile.py osc`.

use super::*;
use skotiq_device::FrameType;
use std::time::Duration;

fn omnisim() -> Option<String> {
    std::env::var("SKOTIQ_OMNISIM_URL").ok()
}

async fn connected_camera(manager: &DeviceManager, base_url: &str) -> String {
    let id = format!("alpaca:{base_url}:camera:0");
    let info = DeviceInfo {
        id: id.clone(),
        name: "Alpaca Camera Sim".to_string(),
        device_type: DeviceType::Camera,
        driver_type: DriverType::Alpaca,
        description: "OmniSim camera".to_string(),
        driver_version: "0.4".to_string(),
        serial_number: None,
        unique_id: None,
        display_name: "Alpaca Camera Sim".to_string(),
    };
    manager
        .connect_alpaca(&info)
        .await
        .expect("connect OmniSim camera");
    manager.devices.write().await.insert(
        id.clone(),
        ManagedDevice {
            info,
            connection_state: ConnectionState::Connected,
            last_error: None,
            reconnect_attempts: 0,
            auto_reconnect: false,
            declared_mount_frame: None,
            last_successful_comm: None,
            heartbeat_deferred_at: None,
            heartbeat_active: false,
            desired_cooler: None,
            desired_tracking: None,
        },
    );
    id
}

/// A member's reply as OmniSim sends it, read past Skotiq's decoding.
async fn raw(base_url: &str, member: &str) -> serde_json::Value {
    let camera = skotiq_alpaca::AlpacaCamera::from_server(base_url, 0);
    camera
        .client()
        .http_client()
        .expect("HTTP client")
        .get(format!("{base_url}/api/v1/camera/0/{member}?ClientID=9"))
        .send()
        .await
        .expect("GET")
        .json::<serde_json::Value>()
        .await
        .expect("JSON")
}

async fn wait_for_frame(manager: &DeviceManager, id: &str) {
    for _ in 0..200 {
        if manager
            .camera_is_exposure_complete(id)
            .await
            .expect("ImageReady")
        {
            return;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!("no frame within 10 s");
}

/// Capabilities come from the camera's own members: an ISO gain list, an
/// offset range, exposure limits, the cooler and the colour pattern.
#[tokio::test]
#[ignore]
async fn capabilities_report_the_cameras_own_controls() {
    let Some(base_url) = omnisim() else { return };
    let manager = build_device_manager();
    let id = connected_camera(&manager, &base_url).await;

    let crate::device_capabilities::DeviceCapabilities::Camera(caps) =
        crate::device_capabilities::alpaca::get_alpaca_capabilities(&id)
            .await
            .expect("capabilities")
    else {
        panic!("not a camera");
    };
    assert!(caps.can_set_gain);
    assert_eq!((caps.gain_min, caps.gain_max), (Some(100), Some(1600)));
    assert!(caps.can_set_offset);
    assert_eq!((caps.offset_min, caps.offset_max), (Some(0), Some(255)));
    assert_eq!(
        (caps.exposure_min, caps.exposure_max),
        (Some(0.001), Some(3600.0))
    );
    assert!(caps.can_set_ccd_temperature && caps.can_set_cooler && caps.can_get_cooler_power);
    assert!(caps.is_color);
    assert_eq!((caps.max_width, caps.max_height), (1200, 800));
}

/// A gain is written as its index in the camera's ISO list and read back as
/// the ISO speed; status reports the driver's own setpoint.
#[tokio::test]
#[ignore]
async fn gain_and_cooler_are_written_and_read_in_the_cameras_terms() {
    let Some(base_url) = omnisim() else { return };
    let manager = build_device_manager();
    let id = connected_camera(&manager, &base_url).await;

    manager.camera_set_gain(&id, 800).await.expect("gain 800");
    assert_eq!(
        raw(&base_url, "gain").await["Value"],
        3,
        "ISO 800 is index 3 on the wire"
    );
    manager.camera_set_gain(&id, 700).await.expect("gain 700");
    assert_eq!(
        raw(&base_url, "gain").await["Value"],
        3,
        "700 snaps to the nearest ISO"
    );
    manager.camera_set_offset(&id, 30).await.expect("offset 30");
    assert!(
        manager.camera_set_offset(&id, 300).await.is_err(),
        "past OffsetMax"
    );

    manager
        .camera_set_cooler(&id, true, Some(-12.0))
        .await
        .expect("cooler on at -12");
    let status = manager.camera_get_status(&id).await.expect("status");
    assert_eq!(status.gain, 800);
    assert_eq!(status.offset, 30);
    assert_eq!(status.target_temp, Some(-12.0));
    assert!(status.cooler_on);
    assert!(status.can_set_gain && status.can_set_offset);

    manager
        .camera_set_cooler(&id, false, Some(5.0))
        .await
        .expect("cooler off");
    assert_eq!(
        raw(&base_url, "setccdtemperature").await["Value"],
        -12.0,
        "switching off sends no setpoint"
    );
    assert_eq!(raw(&base_url, "cooleron").await["Value"], false);
}

/// A binned subframe comes back with the size asked for, row by row as the
/// camera's own `[x][y]` array holds it, with the EXPTIME, gain and binning
/// the camera reports.
#[tokio::test]
#[ignore]
async fn a_binned_subframe_arrives_upright_with_the_cameras_metadata() {
    let Some(base_url) = omnisim() else { return };
    let manager = build_device_manager();
    let id = connected_camera(&manager, &base_url).await;

    let roi = skotiq_device::SubFrame {
        start_x: 20,
        start_y: 10,
        width: 300,
        height: 200,
    };
    manager
        .camera_start_exposure_configured(
            &id,
            0.3,
            Some(400),
            Some(12),
            2,
            2,
            Some(roi),
            FrameType::Light,
        )
        .await
        .expect("start");
    wait_for_frame(&manager, &id).await;
    let image = manager.camera_download_image(&id).await.expect("download");
    assert_eq!((image.width, image.height), (300, 200));

    let reference = raw(&base_url, "imagearray").await;
    let columns = reference["Value"].as_array().expect("[x][y]");
    assert_eq!(columns.len(), 300, "NumX columns");
    for (x, y) in [(0usize, 0usize), (299, 0), (0, 199), (123, 45), (299, 199)] {
        assert_eq!(
            u64::from(image.data[y * 300 + x]),
            columns[x][y].as_u64().unwrap(),
            "pixel ({x}, {y})"
        );
    }
    assert!((image.metadata.exposure_time - 0.3).abs() < 0.05);
    assert_eq!(image.metadata.gain, 400);
    assert_eq!(image.metadata.offset, 12);
    assert_eq!((image.metadata.bin_x, image.metadata.bin_y), (2, 2));
}

/// Darks and biases are started with `Light = false` (a bias at 0 s, below
/// ExposureMin, which only a dark exposure may be); the full frame carries the
/// Bayer pattern the camera's offsets name.
#[tokio::test]
#[ignore]
async fn a_bias_is_taken_dark_at_zero_seconds() {
    let Some(base_url) = omnisim() else { return };
    let manager = build_device_manager();
    let id = connected_camera(&manager, &base_url).await;
    manager
        .camera_start_exposure_configured(&id, 0.0, None, None, 1, 1, None, FrameType::Bias)
        .await
        .expect("a 0 s bias starts");
    wait_for_frame(&manager, &id).await;
    let image = manager.camera_download_image(&id).await.expect("download");
    assert_eq!((image.width, image.height), (1200, 800));
    // RGGB moved one column right by BayerOffsetX = 1.
    assert_eq!(image.bayer_pattern, Some(skotiq_device::BayerPattern::Grbg));
}

/// AbortExposure discards the frame; StopExposure keeps what was collected.
#[tokio::test]
#[ignore]
async fn abort_discards_and_stop_keeps_the_frame() {
    let Some(base_url) = omnisim() else { return };
    let manager = build_device_manager();
    let id = connected_camera(&manager, &base_url).await;

    manager
        .camera_start_exposure_configured(&id, 5.0, None, None, 1, 1, None, FrameType::Light)
        .await
        .expect("start");
    tokio::time::sleep(Duration::from_millis(500)).await;
    manager.camera_abort_exposure(&id).await.expect("abort");
    assert_eq!(
        raw(&base_url, "camerastate").await["Value"],
        0,
        "idle after abort"
    );
    assert_eq!(raw(&base_url, "imageready").await["Value"], false);

    manager
        .camera_start_exposure_configured(&id, 5.0, None, None, 1, 1, None, FrameType::Light)
        .await
        .expect("start");
    tokio::time::sleep(Duration::from_millis(500)).await;
    let camera = skotiq_alpaca::AlpacaCamera::from_server(&base_url, 0);
    assert!(camera.can_stop_exposure().await.unwrap());
    camera.stop_exposure().await.expect("stop");
    wait_for_frame(&manager, &id).await;
    let duration = camera.last_exposure_duration().await.expect("duration");
    assert!(
        duration < 2.0,
        "the stopped frame is the part collected: {duration}"
    );
    let start = camera.last_exposure_start_time().await.expect("start time");
    assert!(
        chrono::NaiveDateTime::parse_from_str(&start, "%Y-%m-%dT%H:%M:%S%.f").is_ok(),
        "FITS-style UTC start: {start}"
    );
}
