use crate::device_capabilities::cache::{capability_cache, invalidate_capability_cache_for_device};
use crate::device_capabilities::get_device_capabilities;
use crate::device_capabilities::types::{
    CameraCapabilities, CameraRecommendedSettings, DeviceCapabilities, MountCapabilities,
    RotatorCapabilities,
};
use serde::Serialize;

fn test_info(
    id: &str,
    device_type: crate::device::DeviceType,
    driver_type: crate::device::DriverType,
) -> crate::device::DeviceInfo {
    crate::device::DeviceInfo {
        id: id.to_string(),
        name: id.to_string(),
        device_type,
        driver_type,
        description: "Test device".to_string(),
        driver_version: "test".to_string(),
        serial_number: None,
        unique_id: None,
        display_name: id.to_string(),
    }
}

async fn register_test_device(
    id: &str,
    device_type: crate::device::DeviceType,
    driver_type: crate::device::DriverType,
    connection_state: crate::device::ConnectionState,
) {
    let manager = crate::device_manager::get_device_manager();
    manager.devices.write().await.insert(
        id.to_string(),
        crate::device_manager::ManagedDevice {
            info: test_info(id, device_type, driver_type),
            connection_state,
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
    invalidate_capability_cache_for_device(id).await;
}

#[tokio::test]
async fn capability_cache_stores_and_invalidates_by_device() {
    let device_id = "native:zwo:900022";
    register_test_device(
        device_id,
        crate::device::DeviceType::Camera,
        crate::device::DriverType::Native,
        crate::device::ConnectionState::Connected,
    )
    .await;
    let manager = crate::device_manager::get_device_manager();
    manager.hold_vendor_camera(device_id, Box::new(FakeRangedCamera));

    let caps = get_device_capabilities(device_id)
        .await
        .expect("a connected camera's capabilities should resolve");
    assert!(matches!(caps, DeviceCapabilities::Camera(_)));
    assert!(capability_cache().lock().await.contains_key(device_id));

    invalidate_capability_cache_for_device(device_id).await;
    assert!(!capability_cache().lock().await.contains_key(device_id));

    manager.handles.remove(device_id);
    manager.devices.write().await.remove(device_id);
}

/// A camera that is registered but not connected has nothing real to report,
/// and reading what it supports must not open it behind the app's back: the
/// read answers "not connected" and never reaches the device.
#[tokio::test]
async fn an_alpaca_camera_that_is_not_connected_is_not_opened_to_read_its_capabilities() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("listener");
    let port = listener.local_addr().expect("address").port();
    let device_id = format!("alpaca:http://127.0.0.1:{port}:camera:0");
    register_test_device(
        &device_id,
        crate::device::DeviceType::Camera,
        crate::device::DriverType::Alpaca,
        crate::device::ConnectionState::Disconnected,
    )
    .await;

    let result = tokio::time::timeout(
        std::time::Duration::from_secs(5),
        get_device_capabilities(&device_id),
    )
    .await
    .expect("the read waited on the camera");
    let contacted = tokio::time::timeout(std::time::Duration::from_millis(200), listener.accept())
        .await
        .is_ok();
    crate::device_manager::get_device_manager()
        .devices
        .write()
        .await
        .remove(&device_id);

    assert!(
        matches!(result, Err(crate::error::SkotiqError::NotConnected(_))),
        "{result:?}"
    );
    assert!(!contacted, "the capability read opened the camera");
}

/// The simulator answers as a real camera and mount do: nothing until it is
/// connected.
#[tokio::test]
async fn a_simulated_camera_and_mount_that_are_not_connected_report_no_capabilities() {
    let _serialized = crate::simulator::sim_singleton_test_lock().lock().await;
    crate::simulator::mount::get_sim_mount()
        .write()
        .await
        .status
        .connected = false;
    for (device_id, device_type) in [
        ("sim_camera_90031", crate::device::DeviceType::Camera),
        ("sim_mount_90031", crate::device::DeviceType::Mount),
    ] {
        register_test_device(
            device_id,
            device_type,
            crate::device::DriverType::Simulator,
            crate::device::ConnectionState::Disconnected,
        )
        .await;
        let result = get_device_capabilities(device_id).await;
        crate::device_manager::get_device_manager()
            .devices
            .write()
            .await
            .remove(device_id);
        assert!(
            matches!(result, Err(crate::error::SkotiqError::NotConnected(_))),
            "{device_id}: {result:?}"
        );
    }
}

// Cooler-range / pulse-guide-range / angle-range capability fields

/// Minimal native camera whose SDK exposes a regulated-cooling range but no
/// recommended setpoint — mirrors the ZWO shape that C2 will wire through
/// the real driver. Only the methods the capability read touches need
/// realistic values; the rest return benign defaults.
#[derive(Debug)]
struct FakeRangedCamera;

#[async_trait::async_trait]
impl skotiq_device::DeviceDriver for FakeRangedCamera {
    fn id(&self) -> &str {
        "native:zwo:900021"
    }
    fn name(&self) -> &str {
        "Fake Ranged Camera"
    }
    fn vendor(&self) -> skotiq_device::Vendor {
        skotiq_device::Vendor::Other("Test".to_string())
    }
    fn is_connected(&self) -> bool {
        true
    }
    async fn connect(&mut self) -> Result<(), skotiq_device::DriverError> {
        Ok(())
    }
    async fn disconnect(&mut self) -> Result<(), skotiq_device::DriverError> {
        Ok(())
    }
}

#[async_trait::async_trait]
impl skotiq_device::CameraDriver for FakeRangedCamera {
    fn capabilities(&self) -> skotiq_device::CameraCapabilities {
        skotiq_device::CameraCapabilities {
            can_cool: true,
            ..Default::default()
        }
    }

    async fn get_status(&self) -> Result<skotiq_device::CameraStatus, skotiq_device::DriverError> {
        Ok(skotiq_device::CameraStatus {
            state: skotiq_device::CameraState::Idle,
            sensor_temp: Some(-5.0),
            cooler_power: Some(40.0),
            target_temp: Some(-10.0),
            cooler_on: Some(true),
            gain: 100,
            offset: 30,
            bin_x: 1,
            bin_y: 1,
            exposure_remaining: None,
        })
    }

    async fn start_exposure(
        &mut self,
        _params: skotiq_device::ExposureParams,
    ) -> Result<(), skotiq_device::DriverError> {
        Ok(())
    }
    async fn abort_exposure(&mut self) -> Result<(), skotiq_device::DriverError> {
        Ok(())
    }
    async fn is_exposure_complete(&self) -> Result<bool, skotiq_device::DriverError> {
        Ok(true)
    }
    async fn download_image(
        &mut self,
    ) -> Result<skotiq_device::ImageData, skotiq_device::DriverError> {
        Err(skotiq_device::DriverError::NotSupported)
    }
    async fn set_cooler(
        &mut self,
        _enabled: bool,
        _target_temp: Option<f64>,
    ) -> Result<(), skotiq_device::DriverError> {
        Ok(())
    }
    async fn get_temperature(&self) -> Result<f64, skotiq_device::DriverError> {
        Ok(-5.0)
    }
    async fn get_cooler_power(&self) -> Result<f64, skotiq_device::DriverError> {
        Ok(40.0)
    }
    async fn set_gain(&mut self, _gain: i32) -> Result<(), skotiq_device::DriverError> {
        Ok(())
    }
    async fn get_gain(&self) -> Result<i32, skotiq_device::DriverError> {
        Ok(100)
    }
    async fn set_offset(&mut self, _offset: i32) -> Result<(), skotiq_device::DriverError> {
        Ok(())
    }
    async fn get_offset(&self) -> Result<i32, skotiq_device::DriverError> {
        Ok(30)
    }
    async fn set_binning(
        &mut self,
        _bin_x: i32,
        _bin_y: i32,
    ) -> Result<(), skotiq_device::DriverError> {
        Ok(())
    }
    async fn get_binning(&self) -> Result<(i32, i32), skotiq_device::DriverError> {
        Ok((1, 1))
    }
    async fn set_subframe(
        &mut self,
        _subframe: Option<skotiq_device::SubFrame>,
    ) -> Result<(), skotiq_device::DriverError> {
        Ok(())
    }
    fn get_sensor_info(&self) -> skotiq_device::SensorInfo {
        skotiq_device::SensorInfo {
            width: 6248,
            height: 4176,
            pixel_size_x: 3.76,
            pixel_size_y: 3.76,
            max_adu: 65535,
            bit_depth: 16,
            color: false,
            bayer_pattern: None,
            saturation_adu: None,
        }
    }
    async fn get_readout_modes(
        &self,
    ) -> Result<Vec<skotiq_device::ReadoutMode>, skotiq_device::DriverError> {
        Ok(Vec::new())
    }
    async fn set_readout_mode(
        &mut self,
        _mode: &skotiq_device::ReadoutMode,
    ) -> Result<(), skotiq_device::DriverError> {
        Ok(())
    }
    async fn get_vendor_features(
        &self,
    ) -> Result<skotiq_device::VendorFeatures, skotiq_device::DriverError> {
        Ok(skotiq_device::VendorFeatures::default())
    }
    async fn get_gain_range(&self) -> Result<(i32, i32), skotiq_device::DriverError> {
        Ok((0, 600))
    }
    async fn get_offset_range(&self) -> Result<(i32, i32), skotiq_device::DriverError> {
        Ok((0, 255))
    }

    // The seam C1 adds and C2 will override for real ZWO hardware: report a
    // concrete achievable cooling range.
    async fn get_cooler_temp_range(
        &self,
    ) -> Result<Option<(f64, f64)>, skotiq_device::DriverError> {
        Ok(Some((-45.0, 35.0)))
    }
}

#[tokio::test]
async fn native_camera_capabilities_map_cooler_temp_range_from_trait() {
    let device_id = "native:zwo:900021";
    register_test_device(
        device_id,
        crate::device::DeviceType::Camera,
        crate::device::DriverType::Native,
        crate::device::ConnectionState::Connected,
    )
    .await;
    crate::device_manager::get_device_manager()
        .hold_vendor_camera(device_id, Box::new(FakeRangedCamera));

    let caps = get_device_capabilities(device_id)
        .await
        .expect("native camera capabilities should resolve");

    match caps {
        DeviceCapabilities::Camera(caps) => {
            // The trait override flows through the camera's handle into the
            // bridge struct.
            assert_eq!(caps.cooler_min_temp_c, Some(-45.0));
            assert_eq!(caps.cooler_max_temp_c, Some(35.0));
            assert!(caps.can_set_ccd_temperature);
        }
        other => panic!("expected camera capabilities, got {other:?}"),
    }

    crate::device_manager::get_device_manager()
        .handles
        .remove(device_id);
    crate::device_manager::get_device_manager()
        .devices
        .write()
        .await
        .remove(device_id);
    invalidate_capability_cache_for_device(device_id).await;
}

#[test]
fn camera_capabilities_roundtrip_preserves_cooler_range() {
    let caps = CameraCapabilities {
        can_set_ccd_temperature: true,
        cooler_min_temp_c: Some(-40.0),
        cooler_max_temp_c: Some(40.0),
        ..Default::default()
    };
    let json = serde_json::to_string(&caps).expect("serialize");
    let back: CameraCapabilities = serde_json::from_str(&json).expect("deserialize");
    assert_eq!(back.cooler_min_temp_c, Some(-40.0));
    assert_eq!(back.cooler_max_temp_c, Some(40.0));
    assert!(back.can_set_ccd_temperature);
}

#[test]
fn mount_capabilities_roundtrip_preserves_pulse_guide_range() {
    let caps = MountCapabilities {
        can_pulse_guide: true,
        min_pulse_guide_ms: Some(1.0),
        max_pulse_guide_ms: Some(8000.0),
        ..Default::default()
    };
    let json = serde_json::to_string(&caps).expect("serialize");
    let back: MountCapabilities = serde_json::from_str(&json).expect("deserialize");
    assert_eq!(back.min_pulse_guide_ms, Some(1.0));
    assert_eq!(back.max_pulse_guide_ms, Some(8000.0));
    assert!(back.can_pulse_guide);
}

#[test]
fn rotator_capabilities_roundtrip_preserves_angle_range() {
    let caps = RotatorCapabilities {
        can_move_absolute: true,
        min_angle_deg: Some(0.0),
        max_angle_deg: Some(360.0),
        ..Default::default()
    };
    let json = serde_json::to_string(&caps).expect("serialize");
    let back: RotatorCapabilities = serde_json::from_str(&json).expect("deserialize");
    assert_eq!(back.min_angle_deg, Some(0.0));
    assert_eq!(back.max_angle_deg, Some(360.0));
    assert!(back.can_move_absolute);
}

/// Serialize `value`, strip the named keys to simulate a JSON document
/// persisted before those keys existed, and return the re-encoded string.
/// This proves the back-compat contract without hard-coding the (large,
/// evolving) set of pre-existing mandatory fields into each test.
fn json_without_keys<T: Serialize>(value: &T, keys: &[&str]) -> String {
    let mut obj = match serde_json::to_value(value).expect("serialize to value") {
        serde_json::Value::Object(map) => map,
        other => panic!("expected a JSON object, got {other:?}"),
    };
    for key in keys {
        assert!(
            obj.remove(*key).is_some(),
            "expected new field {key} to be present before stripping"
        );
    }
    serde_json::to_string(&obj).expect("re-serialize")
}

#[test]
fn camera_capabilities_backcompat_missing_cooler_range_is_none() {
    // A persisted JSON object from before these fields existed must
    // deserialize cleanly with the new fields as None (back-compat).
    let json = json_without_keys(
        &CameraCapabilities {
            max_width: 4096,
            cooler_min_temp_c: Some(-40.0),
            cooler_max_temp_c: Some(40.0),
            ..Default::default()
        },
        &["cooler_min_temp_c", "cooler_max_temp_c"],
    );
    let caps: CameraCapabilities = serde_json::from_str(&json).expect("deserialize");
    assert_eq!(caps.cooler_min_temp_c, None);
    assert_eq!(caps.cooler_max_temp_c, None);
    assert_eq!(caps.max_width, 4096);
}

#[test]
fn mount_capabilities_backcompat_missing_pulse_range_is_none() {
    let json = json_without_keys(
        &MountCapabilities {
            can_pulse_guide: true,
            min_pulse_guide_ms: Some(1.0),
            max_pulse_guide_ms: Some(8000.0),
            ..Default::default()
        },
        &["min_pulse_guide_ms", "max_pulse_guide_ms"],
    );
    let caps: MountCapabilities = serde_json::from_str(&json).expect("deserialize");
    assert_eq!(caps.min_pulse_guide_ms, None);
    assert_eq!(caps.max_pulse_guide_ms, None);
    assert!(caps.can_pulse_guide);
}

#[test]
fn rotator_capabilities_backcompat_missing_angle_range_is_none() {
    let json = json_without_keys(
        &RotatorCapabilities {
            can_move_absolute: true,
            min_angle_deg: Some(0.0),
            max_angle_deg: Some(360.0),
            ..Default::default()
        },
        &["min_angle_deg", "max_angle_deg"],
    );
    let caps: RotatorCapabilities = serde_json::from_str(&json).expect("deserialize");
    assert_eq!(caps.min_angle_deg, None);
    assert_eq!(caps.max_angle_deg, None);
    assert!(caps.can_move_absolute);
}

#[test]
fn recommended_settings_from_native_maps_cooling_setpoint() {
    let native = skotiq_device::CameraRecommendedSettings {
        unity_gain: Some(100),
        hcg_gain: None,
        default_offset: Some(30),
        recommended_cooling_setpoint_c: Some(-10.0),
        notes: "test".to_string(),
    };
    let bridge: CameraRecommendedSettings = native.into();
    assert_eq!(bridge.unity_gain, Some(100));
    assert_eq!(bridge.default_offset, Some(30));
    assert_eq!(bridge.recommended_cooling_setpoint_c, Some(-10.0));
    assert_eq!(bridge.notes, "test");
}
