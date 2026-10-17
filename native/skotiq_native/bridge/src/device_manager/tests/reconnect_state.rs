use super::*;

// Hot-plug reconnect: re-apply essential device state.
//
// After an *unplanned* reconnect (the device's connection_state was Error,
// i.e. heartbeat-lost / report_error), `connect_device_internal` must
// re-apply the last commanded camera cooling setpoint and mount tracking
// state — the driver comes back in power-on defaults and would otherwise
// silently warm the sensor / leave the mount parked while the sequence
// "resumes". A *fresh* connect (from Disconnected) must NOT re-apply.

/// Setting tracking records `desired_tracking`; an Error->reconnect replays it.
#[tokio::test]
async fn reconnect_reapplies_mount_tracking() {
    use crate::api::devices::simulation::get_sim_mount;

    let _guard = simulator_singleton_test_lock().lock().await;
    let manager = Arc::new(build_device_manager());
    let device_id = "sim_mount_reapply";
    let info = build_sim_info(device_id, DeviceType::Mount);
    manager.register_device(info.clone(), false).await;
    manager
        .connect_device(device_id)
        .await
        .expect("initial connect should succeed");

    // Operator/sequencer commands tracking on; this records desired state.
    manager
        .mount_set_tracking(device_id, true)
        .await
        .expect("set_tracking should succeed on connected sim mount");
    assert_eq!(
        manager
            .devices
            .read()
            .await
            .get(device_id)
            .unwrap()
            .desired_tracking,
        Some(true),
        "successful set_tracking must record desired_tracking"
    );

    // Simulate a heartbeat-lost disconnect: device goes to Error and the
    // driver loses tracking (sim singleton flipped off).
    manager
        .handle_heartbeat_lost(device_id, true, 5, "simulated yank")
        .await;
    get_sim_mount().write().await.status.tracking = false;
    assert_eq!(
        manager
            .devices
            .read()
            .await
            .get(device_id)
            .unwrap()
            .connection_state,
        ConnectionState::Error
    );

    // Reconnect via the public path (routes through connect_device_internal).
    manager
        .connect_device(device_id)
        .await
        .expect("reconnect should succeed");

    // Essential state must have been replayed onto the driver.
    assert!(
        get_sim_mount().read().await.status.tracking,
        "reconnect must re-apply mount tracking that was active before the disconnect"
    );

    get_sim_mount().write().await.status.tracking = false;
    get_sim_mount().write().await.status.connected = false;
}

/// Setting the cooler records `desired_cooler`; an Error->reconnect replays it.
#[tokio::test]
async fn reconnect_reapplies_camera_cooler() {
    use crate::api::devices::simulation::get_sim_camera;

    let _guard = simulator_singleton_test_lock().lock().await;
    let manager = Arc::new(build_device_manager());
    let device_id = "sim_camera_reapply";
    let info = build_sim_info(device_id, DeviceType::Camera);
    manager.register_device(info.clone(), false).await;
    manager
        .connect_device(device_id)
        .await
        .expect("initial connect should succeed");

    manager
        .camera_set_cooler(device_id, true, Some(-12.0))
        .await
        .expect("set_cooler should succeed on connected sim camera");
    assert_eq!(
        manager
            .devices
            .read()
            .await
            .get(device_id)
            .unwrap()
            .desired_cooler,
        Some((true, Some(-12.0))),
        "successful set_cooler must record desired_cooler"
    );

    // Heartbeat-lost: Error state + driver loses cooler (sim defaults).
    manager
        .handle_heartbeat_lost(device_id, true, 3, "simulated yank")
        .await;
    {
        let mut cam = get_sim_camera().write().await;
        cam.status.cooler_on = false;
        cam.status.target_temp = None;
    }

    manager
        .connect_device(device_id)
        .await
        .expect("reconnect should succeed");

    {
        let cam = get_sim_camera().read().await;
        assert!(cam.status.cooler_on, "reconnect must re-enable the cooler");
        assert_eq!(
            cam.status.target_temp,
            Some(-12.0),
            "reconnect must restore the cooling setpoint"
        );
    }

    let mut cam = get_sim_camera().write().await;
    cam.status.connected = false;
}

/// A *fresh* connect (state was Disconnected, not Error) must NOT replay any
/// recorded desired state — only an unplanned reconnect re-applies.
#[tokio::test]
async fn fresh_connect_does_not_reapply_state() {
    use crate::api::devices::simulation::get_sim_mount;

    let _guard = simulator_singleton_test_lock().lock().await;
    let manager = Arc::new(build_device_manager());
    let device_id = "sim_mount_fresh";
    let info = build_sim_info(device_id, DeviceType::Mount);
    manager.register_device(info.clone(), false).await;
    manager
        .connect_device(device_id)
        .await
        .expect("initial connect should succeed");
    manager
        .mount_set_tracking(device_id, true)
        .await
        .expect("set_tracking should succeed");

    // A clean disconnect (NOT an error): state goes to Disconnected.
    manager
        .disconnect_device(device_id)
        .await
        .expect("disconnect should succeed");
    assert_ne!(
        manager
            .devices
            .read()
            .await
            .get(device_id)
            .unwrap()
            .connection_state,
        ConnectionState::Error,
        "a clean disconnect must not leave the device in Error"
    );
    get_sim_mount().write().await.status.tracking = false;

    // Fresh connect from Disconnected — must NOT auto-resume tracking.
    manager
        .connect_device(device_id)
        .await
        .expect("fresh connect should succeed");
    assert!(
        !get_sim_mount().read().await.status.tracking,
        "a fresh connect must not silently re-apply tracking the user did not re-request"
    );

    get_sim_mount().write().await.status.connected = false;
}

// Cooler setpoint: what actually reaches the driver

/// A native camera that records every `set_cooler` argument it is handed.
///
/// The point of the recording is the second element: whether a setpoint
/// reached the driver at all.
#[derive(Debug, Clone, Default)]
struct RecordingCoolerCamera {
    calls: Arc<std::sync::Mutex<Vec<(bool, Option<f64>)>>>,
}

#[async_trait::async_trait]
impl skotiq_native::traits::NativeDevice for RecordingCoolerCamera {
    fn id(&self) -> &str {
        "native:test:cooler"
    }
    fn name(&self) -> &str {
        "Recording Cooler Camera"
    }
    fn vendor(&self) -> skotiq_native::NativeVendor {
        skotiq_native::NativeVendor::Other("Test".to_string())
    }
    fn is_connected(&self) -> bool {
        true
    }
    async fn connect(&mut self) -> Result<(), skotiq_native::traits::NativeError> {
        Ok(())
    }
    async fn disconnect(&mut self) -> Result<(), skotiq_native::traits::NativeError> {
        Ok(())
    }
}

#[async_trait::async_trait]
impl skotiq_native::traits::NativeCamera for RecordingCoolerCamera {
    fn capabilities(&self) -> skotiq_native::camera::CameraCapabilities {
        skotiq_native::camera::CameraCapabilities {
            can_cool: true,
            ..Default::default()
        }
    }
    async fn get_status(
        &self,
    ) -> Result<skotiq_native::camera::CameraStatus, skotiq_native::traits::NativeError> {
        Ok(skotiq_native::camera::CameraStatus {
            state: skotiq_native::camera::CameraState::Idle,
            sensor_temp: Some(-10.0),
            cooler_power: Some(0.0),
            target_temp: Some(-10.0),
            cooler_on: false,
            gain: 0,
            offset: 0,
            bin_x: 1,
            bin_y: 1,
            exposure_remaining: None,
        })
    }
    async fn start_exposure(
        &mut self,
        _params: skotiq_native::camera::ExposureParams,
    ) -> Result<(), skotiq_native::traits::NativeError> {
        Ok(())
    }
    async fn abort_exposure(&mut self) -> Result<(), skotiq_native::traits::NativeError> {
        Ok(())
    }
    async fn is_exposure_complete(&self) -> Result<bool, skotiq_native::traits::NativeError> {
        Ok(true)
    }
    async fn download_image(
        &mut self,
    ) -> Result<skotiq_native::camera::ImageData, skotiq_native::traits::NativeError> {
        Err(skotiq_native::traits::NativeError::NotSupported)
    }
    async fn set_cooler(
        &mut self,
        enabled: bool,
        target_temp: Option<f64>,
    ) -> Result<(), skotiq_native::traits::NativeError> {
        self.calls
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .push((enabled, target_temp));
        Ok(())
    }
    async fn get_temperature(&self) -> Result<f64, skotiq_native::traits::NativeError> {
        Ok(-10.0)
    }
    async fn get_cooler_power(&self) -> Result<f64, skotiq_native::traits::NativeError> {
        Ok(0.0)
    }
    async fn set_gain(&mut self, _gain: i32) -> Result<(), skotiq_native::traits::NativeError> {
        Ok(())
    }
    async fn get_gain(&self) -> Result<i32, skotiq_native::traits::NativeError> {
        Ok(0)
    }
    async fn set_offset(&mut self, _offset: i32) -> Result<(), skotiq_native::traits::NativeError> {
        Ok(())
    }
    async fn get_offset(&self) -> Result<i32, skotiq_native::traits::NativeError> {
        Ok(0)
    }
    async fn set_binning(
        &mut self,
        _bin_x: i32,
        _bin_y: i32,
    ) -> Result<(), skotiq_native::traits::NativeError> {
        Ok(())
    }
    async fn get_binning(&self) -> Result<(i32, i32), skotiq_native::traits::NativeError> {
        Ok((1, 1))
    }
    async fn set_subframe(
        &mut self,
        _subframe: Option<skotiq_native::camera::SubFrame>,
    ) -> Result<(), skotiq_native::traits::NativeError> {
        Ok(())
    }
    fn get_sensor_info(&self) -> skotiq_native::camera::SensorInfo {
        skotiq_native::camera::SensorInfo {
            width: 4656,
            height: 3520,
            pixel_size_x: 3.8,
            pixel_size_y: 3.8,
            max_adu: 65535,
            bit_depth: 16,
            color: false,
            bayer_pattern: None,
        }
    }
    async fn get_readout_modes(
        &self,
    ) -> Result<Vec<skotiq_native::camera::ReadoutMode>, skotiq_native::traits::NativeError> {
        Ok(Vec::new())
    }
    async fn set_readout_mode(
        &mut self,
        _mode: &skotiq_native::camera::ReadoutMode,
    ) -> Result<(), skotiq_native::traits::NativeError> {
        Ok(())
    }
    async fn get_vendor_features(
        &self,
    ) -> Result<skotiq_native::camera::VendorFeatures, skotiq_native::traits::NativeError> {
        Ok(skotiq_native::camera::VendorFeatures::default())
    }
    async fn get_gain_range(&self) -> Result<(i32, i32), skotiq_native::traits::NativeError> {
        Ok((0, 600))
    }
    async fn get_offset_range(&self) -> Result<(i32, i32), skotiq_native::traits::NativeError> {
        Ok((0, 255))
    }
}

fn build_native_camera_info(id: &str) -> DeviceInfo {
    DeviceInfo {
        id: id.to_string(),
        name: "Recording Cooler Camera".to_string(),
        device_type: DeviceType::Camera,
        driver_type: DriverType::Native,
        description: "Native camera under test".to_string(),
        driver_version: "1.0".to_string(),
        serial_number: None,
        unique_id: None,
        display_name: "Recording Cooler Camera".to_string(),
    }
}

/// `POST /api/camera/cooling {"enabled":false}` carries no setpoint, and the
/// device layer must not substitute one. A fabricated `SetCCDTemperature`
/// throws on a camera reporting `CanSetCCDTemperature = False`, so the cooler
/// cannot be turned off at all — which is what end-of-night warm-up and the
/// safe-rig shutdown both need to do.
#[tokio::test]
async fn turning_the_cooler_off_sends_no_setpoint_to_the_driver() {
    let manager = Arc::new(build_device_manager());
    let device_id = "native:test:cooler_off";
    manager
        .register_device(build_native_camera_info(device_id), false)
        .await;

    let camera = RecordingCoolerCamera::default();
    let calls = camera.calls.clone();
    manager
        .native_cameras
        .write()
        .await
        .insert(device_id.to_string(), Box::new(camera));

    // The exact request the warm-up controller and safe_rig both issue.
    manager
        .camera_set_cooler(device_id, false, None)
        .await
        .expect("turning a cooler off must not fail");

    let recorded = calls.lock().unwrap_or_else(|e| e.into_inner()).clone();
    assert_eq!(
        recorded,
        vec![(false, None)],
        "a cooler-off command must reach the driver with no setpoint; \
             a fabricated default here is what failed on the rig"
    );
}

/// Even a caller that does name a temperature while switching off must not
/// cause a setpoint write: the driver is being told to stop, and on ASCOM
/// the write is a separate property that may not exist.
#[tokio::test]
async fn a_setpoint_supplied_with_a_cooler_off_command_is_dropped() {
    let manager = Arc::new(build_device_manager());
    let device_id = "native:test:cooler_off_with_target";
    manager
        .register_device(build_native_camera_info(device_id), false)
        .await;

    let camera = RecordingCoolerCamera::default();
    let calls = camera.calls.clone();
    manager
        .native_cameras
        .write()
        .await
        .insert(device_id.to_string(), Box::new(camera));

    // The sequencer's WarmCamera instruction ends with exactly this shape:
    // `camera_set_cooler(id, false, 20.0)`.
    manager
        .camera_set_cooler(device_id, false, Some(20.0))
        .await
        .expect("turning a cooler off must not fail");

    let recorded = calls.lock().unwrap_or_else(|e| e.into_inner()).clone();
    assert_eq!(recorded, vec![(false, None)]);

    // …and the recorded desired state (replayed after a USB reconnect)
    // must not resurrect a setpoint the operator never asked for.
    assert_eq!(
        manager
            .devices
            .read()
            .await
            .get(device_id)
            .unwrap()
            .desired_cooler,
        Some((false, None))
    );
}

/// The enable direction is unchanged: the caller's setpoint is passed
/// through verbatim, and an absent one is still not invented.
#[tokio::test]
async fn enabling_passes_the_callers_setpoint_through_unchanged() {
    let manager = Arc::new(build_device_manager());
    let device_id = "native:test:cooler_on";
    manager
        .register_device(build_native_camera_info(device_id), false)
        .await;

    let camera = RecordingCoolerCamera::default();
    let calls = camera.calls.clone();
    manager
        .native_cameras
        .write()
        .await
        .insert(device_id.to_string(), Box::new(camera));

    manager
        .camera_set_cooler(device_id, true, Some(-15.0))
        .await
        .expect("enabling the cooler should succeed");
    manager
        .camera_set_cooler(device_id, true, None)
        .await
        .expect("enabling without a setpoint should succeed");

    let recorded = calls.lock().unwrap_or_else(|e| e.into_inner()).clone();
    assert_eq!(
        recorded,
        vec![(true, Some(-15.0)), (true, None)],
        "no -10C (or any other) default may be substituted for an absent setpoint"
    );
}

/// A pseudo-terminal answering like an OnStep mount: every `#`-terminated
/// command gets `OnStep#`. Returns the slave path the mount opens.
#[cfg(target_os = "linux")]
fn spawn_fake_onstep_pty() -> String {
    use std::io::{Read, Write};
    use std::os::fd::FromRawFd;

    let mut master: libc::c_int = 0;
    let mut slave: libc::c_int = 0;
    // SAFETY: openpty writes two descriptors into the provided ints; the
    // optional name, termios and winsize arguments are null.
    let rc = unsafe {
        libc::openpty(
            &mut master,
            &mut slave,
            std::ptr::null_mut(),
            std::ptr::null(),
            std::ptr::null(),
        )
    };
    assert_eq!(rc, 0, "openpty failed");
    let mut name = [0 as libc::c_char; 256];
    // SAFETY: `name` is a writable buffer of the length passed.
    let rc = unsafe { libc::ttyname_r(slave, name.as_mut_ptr(), name.len()) };
    assert_eq!(rc, 0, "ttyname_r failed");
    // SAFETY: ttyname_r succeeded, so `name` holds a NUL-terminated string.
    let path = unsafe { std::ffi::CStr::from_ptr(name.as_ptr()) }
        .to_string_lossy()
        .into_owned();
    // The slave descriptor stays open (leaked) for the life of the test so the
    // pty survives the mount closing its own handle.

    // SAFETY: `master` is a fresh descriptor this function owns.
    let mut port = unsafe { std::fs::File::from_raw_fd(master) };
    std::thread::spawn(move || {
        let mut buf = [0u8; 64];
        loop {
            match port.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    for _ in buf[..n].iter().filter(|b| **b == b'#') {
                        if port.write_all(b"OnStep#").is_err() {
                            return;
                        }
                    }
                }
            }
        }
    });
    path
}

/// After a heartbeat loss the reconnection loop dispatches a fresh connect.
/// Serial ports open exclusively, so for a native serial mount that connect
/// can only succeed if the instance from before the loss has let go of the
/// port; otherwise every attempt fails against Skotiq's own handle and the
/// mount stays in Error although it is fine.
#[cfg(target_os = "linux")]
#[tokio::test]
async fn a_native_serial_mount_reconnects_after_a_heartbeat_loss() {
    let path = spawn_fake_onstep_pty();
    let manager = Arc::new(build_device_manager());
    let device_id = format!("native:onstep:{}:9600", path);
    let info = build_mount_info(&device_id, DriverType::Native);
    manager.register_device(info.clone(), false).await;

    manager
        .connect_native(&info)
        .await
        .expect("first connect to the fake mount");

    manager
        .handle_heartbeat_lost(&device_id, true, 3, "Device not responding")
        .await;

    let reconnect = manager.connect_native(&info).await;
    assert!(
        reconnect.is_ok(),
        "the reconnect after a heartbeat loss failed: {:?}",
        reconnect
    );
}
