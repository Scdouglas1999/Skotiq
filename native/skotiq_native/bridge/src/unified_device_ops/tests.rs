use super::*;
use crate::api::get_device_manager;
use crate::device::{DeviceInfo, DeviceType, DriverType};
use crate::device_manager::DeviceManager;
use skotiq_device::{
    CameraCapabilities, CameraDriver, CameraState, CameraStatus, DeviceDriver, DriverError,
    ExposureParams, ImageData, ImageMetadata, ReadoutMode, SensorInfo, SubFrame, Vendor,
    VendorFeatures,
};
use std::sync::{
    atomic::{AtomicUsize, Ordering},
    Arc,
};

#[derive(Debug)]
struct InstantCompleteCamera {
    id: String,
    name: String,
    vendor: Vendor,
    exposure_checked: Arc<AtomicUsize>,
    connected: bool,
    completes: bool,
    /// Whether the camera has gain and offset controls; its frames report
    /// gain 0 and offset 0 either way, as the FLI and Atik CCD drivers do.
    controls_gain: bool,
}

impl InstantCompleteCamera {
    fn new(id: String, exposure_checked: Arc<AtomicUsize>) -> Self {
        Self {
            id: id.clone(),
            name: "Instant Complete Camera".to_string(),
            vendor: Vendor::Other("Test".to_string()),
            exposure_checked,
            connected: true,
            completes: true,
            controls_gain: false,
        }
    }

    fn never_completing(id: String) -> Self {
        Self {
            completes: false,
            ..Self::new(id, Arc::new(AtomicUsize::new(0)))
        }
    }
}

#[async_trait::async_trait]
impl DeviceDriver for InstantCompleteCamera {
    fn id(&self) -> &str {
        &self.id
    }

    fn name(&self) -> &str {
        &self.name
    }

    fn vendor(&self) -> Vendor {
        self.vendor.clone()
    }

    fn is_connected(&self) -> bool {
        self.connected
    }

    async fn connect(&mut self) -> Result<(), DriverError> {
        self.connected = true;
        Ok(())
    }

    async fn disconnect(&mut self) -> Result<(), DriverError> {
        self.connected = false;
        Ok(())
    }
}

#[async_trait::async_trait]
impl CameraDriver for InstantCompleteCamera {
    fn capabilities(&self) -> CameraCapabilities {
        CameraCapabilities {
            can_set_gain: self.controls_gain,
            can_set_offset: self.controls_gain,
            ..CameraCapabilities::default()
        }
    }

    async fn get_status(&self) -> Result<CameraStatus, DriverError> {
        Ok(CameraStatus {
            state: CameraState::Idle,
            sensor_temp: None,
            cooler_power: None,
            target_temp: None,
            cooler_on: Some(false),
            gain: 0,
            offset: 0,
            bin_x: 1,
            bin_y: 1,
            exposure_remaining: None,
        })
    }

    async fn start_exposure(&mut self, _params: ExposureParams) -> Result<(), DriverError> {
        Ok(())
    }

    async fn abort_exposure(&mut self) -> Result<(), DriverError> {
        Ok(())
    }

    async fn is_exposure_complete(&self) -> Result<bool, DriverError> {
        self.exposure_checked.fetch_add(1, Ordering::SeqCst);
        Ok(self.completes)
    }

    async fn download_image(&mut self) -> Result<ImageData, DriverError> {
        Ok(ImageData {
            width: 2,
            height: 2,
            data: vec![100, 200, 300, 400],
            bits_per_pixel: 16,
            bayer_pattern: None,
            metadata: ImageMetadata {
                exposure_time: 0.5,
                gain: 0,
                offset: 0,
                bin_x: 1,
                bin_y: 1,
                temperature: None,
                timestamp: chrono::Utc::now(),
                subframe: None,
                readout_mode: None,
                vendor_data: VendorFeatures::default(),
                camera_file: None,
            },
        })
    }

    async fn set_cooler(
        &mut self,
        _enabled: bool,
        _target_temp: Option<f64>,
    ) -> Result<(), DriverError> {
        Ok(())
    }

    async fn get_temperature(&self) -> Result<f64, DriverError> {
        Ok(0.0)
    }

    async fn get_cooler_power(&self) -> Result<f64, DriverError> {
        Ok(0.0)
    }

    async fn set_gain(&mut self, _gain: i32) -> Result<(), DriverError> {
        Ok(())
    }

    async fn get_gain(&self) -> Result<i32, DriverError> {
        Ok(0)
    }

    async fn set_offset(&mut self, _offset: i32) -> Result<(), DriverError> {
        Ok(())
    }

    async fn get_offset(&self) -> Result<i32, DriverError> {
        Ok(0)
    }

    async fn set_binning(&mut self, _bin_x: i32, _bin_y: i32) -> Result<(), DriverError> {
        Ok(())
    }

    async fn get_binning(&self) -> Result<(i32, i32), DriverError> {
        Ok((1, 1))
    }

    async fn set_subframe(&mut self, _subframe: Option<SubFrame>) -> Result<(), DriverError> {
        Ok(())
    }

    fn get_sensor_info(&self) -> SensorInfo {
        SensorInfo {
            width: 2,
            height: 2,
            pixel_size_x: 1.0,
            pixel_size_y: 1.0,
            max_adu: 65535,
            bit_depth: 16,
            color: false,
            bayer_pattern: None,
        }
    }

    async fn get_readout_modes(&self) -> Result<Vec<ReadoutMode>, DriverError> {
        Ok(Vec::new())
    }

    async fn set_readout_mode(&mut self, _mode: &ReadoutMode) -> Result<(), DriverError> {
        Ok(())
    }

    async fn get_vendor_features(&self) -> Result<VendorFeatures, DriverError> {
        Ok(VendorFeatures::default())
    }

    async fn get_gain_range(&self) -> Result<(i32, i32), DriverError> {
        Err(DriverError::NotSupported)
    }

    async fn get_offset_range(&self) -> Result<(i32, i32), DriverError> {
        Err(DriverError::NotSupported)
    }
}

async fn cleanup_test_camera(mgr: &Arc<DeviceManager>, device_id: &str) {
    mgr.unregister_device(device_id).await;
    let mut native_cameras = mgr.native_cameras.write().await;
    native_cameras.remove(device_id);
}

#[tokio::test]
async fn exposure_polling_short_circuits_when_complete() {
    let mgr = get_device_manager();
    let device_id = "native:test_camera_polling".to_string();
    let exposure_checked = Arc::new(AtomicUsize::new(0));

    let info = DeviceInfo {
        id: device_id.clone(),
        name: "Test Camera".to_string(),
        device_type: DeviceType::Camera,
        driver_type: DriverType::Native,
        description: "Test camera".to_string(),
        driver_version: "test".to_string(),
        serial_number: None,
        unique_id: None,
        display_name: "Test Camera".to_string(),
    };

    mgr.register_device(info, false).await;
    {
        let mut native_cameras = mgr.native_cameras.write().await;
        native_cameras.insert(
            device_id.clone(),
            Box::new(InstantCompleteCamera::new(
                device_id.clone(),
                Arc::clone(&exposure_checked),
            )),
        );
    }

    let ops = UnifiedDeviceOps::new(crate::api::get_state().clone());
    let device_id_for_exposure = device_id.clone();
    let timed_result = tokio::time::timeout(std::time::Duration::from_millis(100), async move {
        ops.camera_start_exposure(skotiq_sequencer::ExposureRequest::new(
            &device_id_for_exposure,
            0.5,
        ))
        .await
    })
    .await;
    cleanup_test_camera(mgr, &device_id).await;

    let result = match timed_result {
        Ok(result) => result,
        Err(_) => {
            panic!("Expected exposure to complete without waiting when already complete");
        }
    };

    assert!(
        result.is_ok(),
        "Exposure should succeed when complete immediately"
    );
    assert!(
        exposure_checked.load(Ordering::SeqCst) > 0,
        "Exposure status should be checked at least once"
    );
}

/// The frame of a camera without gain and offset controls records neither,
/// whatever its driver reports and whatever the capture asked for, so its file
/// has no GAIN or OFFSET card. A camera with the controls records its own report.
#[tokio::test]
async fn a_camera_without_gain_control_writes_no_gain_or_offset_card() {
    let mgr = get_device_manager();
    for (device_id, controls_gain, expected) in [
        ("native:test_camera_gainless", false, (None, None)),
        ("native:test_camera_with_gain", true, (Some(0), Some(0))),
    ] {
        let device_id = device_id.to_string();
        mgr.register_device(
            DeviceInfo {
                id: device_id.clone(),
                name: "Test Camera".to_string(),
                device_type: DeviceType::Camera,
                driver_type: DriverType::Native,
                description: "Test camera".to_string(),
                driver_version: "test".to_string(),
                serial_number: None,
                unique_id: None,
                display_name: "Test Camera".to_string(),
            },
            false,
        )
        .await;
        mgr.native_cameras.write().await.insert(
            device_id.clone(),
            Box::new(InstantCompleteCamera {
                controls_gain,
                ..InstantCompleteCamera::new(device_id.clone(), Arc::new(AtomicUsize::new(0)))
            }),
        );

        let ops = UnifiedDeviceOps::new(crate::api::get_state().clone());
        let image = ops
            .camera_start_exposure(
                skotiq_sequencer::ExposureRequest::new(&device_id, 0.5)
                    .gain(Some(120))
                    .offset(Some(30)),
            )
            .await;
        cleanup_test_camera(mgr, &device_id).await;
        let image = image.expect("exposure");
        assert_eq!((image.gain, image.offset), expected, "{device_id}");

        let rig = skotiq_sequencer::RunRig::default();
        let identity = skotiq_sequencer::FrameIdentity::default();
        let ctx = skotiq_sequencer::sample_frame_context(
            &ops,
            &skotiq_sequencer::CaptureFacts {
                rig: &rig,
                identity: &identity,
                commanded_secs: 0.5,
                binning: (1, 1),
                frame_type: "Light",
                exposure_started_at: chrono::Utc::now(),
                filter: (None, None),
                target_name: None,
                set_temp_c: None,
                bayer_pattern: None,
            },
            &image,
        )
        .await;
        let header = build_rich_header(&image, &ctx, None).fits_header();
        assert_eq!(
            header.get_int("GAIN"),
            expected.0.map(i64::from),
            "{device_id}"
        );
        assert_eq!(
            header.get_int("OFFSET"),
            expected.1.map(i64::from),
            "{device_id}"
        );
        let row = skotiq_sequencer::scheduling::FrameCaptureMetadata::from(&ctx);
        assert_eq!((row.gain, row.offset), expected, "{device_id}");
    }
}

#[tokio::test]
async fn an_exposure_given_up_mid_frame_announces_that_it_ended() {
    let mgr = get_device_manager();
    let device_id = "native:test_camera_given_up".to_string();
    mgr.register_device(
        DeviceInfo {
            id: device_id.clone(),
            name: "Test Camera".to_string(),
            device_type: DeviceType::Camera,
            driver_type: DriverType::Native,
            description: "Test camera".to_string(),
            driver_version: "test".to_string(),
            serial_number: None,
            unique_id: None,
            display_name: "Test Camera".to_string(),
        },
        false,
    )
    .await;
    mgr.native_cameras.write().await.insert(
        device_id.clone(),
        Box::new(InstantCompleteCamera::never_completing(device_id.clone())),
    );
    let mut events = crate::api::get_state().event_bus.subscribe();

    // A stopped run drops its exposure future while the camera is exposing.
    let ops = UnifiedDeviceOps::new(crate::api::get_state().clone());
    let given_up = tokio::time::timeout(
        std::time::Duration::from_millis(300),
        ops.camera_start_exposure(skotiq_sequencer::ExposureRequest::new(&device_id, 30.0)),
    )
    .await;
    cleanup_test_camera(mgr, &device_id).await;
    assert!(given_up.is_err(), "the exposure should still be running");

    let mut ended = false;
    while let Ok(event) = events.try_recv() {
        if let crate::event::EventPayload::Imaging(ImagingEvent::ExposureCancelled) = event.payload
        {
            ended = true;
        }
    }
    assert!(ended, "the exposure was announced but its end never was");
}

#[tokio::test]
async fn exposure_polling_times_out_when_driver_never_completes() {
    let poll_count = Arc::new(AtomicUsize::new(0));
    let result = wait_for_camera_exposure_complete(
        "native:test_hung_camera",
        300.0,
        std::time::Duration::from_millis(20),
        exposure_abort_generation("native:test_hung_camera").await,
        crate::api::get_state(),
        || {
            let poll_count = Arc::clone(&poll_count);
            async move {
                poll_count.fetch_add(1, Ordering::SeqCst);
                Ok(false)
            }
        },
    )
    .await;

    let err = result
        .expect_err("hung exposure polling should time out")
        .to_string();
    assert!(
        err.contains("did not complete within"),
        "unexpected timeout error: {err}"
    );
    assert!(
        poll_count.load(Ordering::SeqCst) > 0,
        "exposure status should be polled before timing out"
    );
}

/// The live `UnifiedDeviceOps` must OVERRIDE `device_is_connected` /
/// `connect_device`. The `DeviceOps` trait defaults return `Err("… not
/// supported by this driver")`, which makes every device-disconnect recovery
/// attempt fail instantly on the live path — the single most common
/// unattended-night failure mode, unrecoverable. This asserts the overrides
/// delegate to the `DeviceManager` rather than inheriting the defaults.
#[tokio::test]
async fn reconnect_overrides_are_wired_not_trait_default() {
    let ops = UnifiedDeviceOps::new(crate::api::get_state().clone());

    // Unknown device: the override consults the DeviceManager and reports
    // Ok(false). The trait default would instead return Err("not
    // supported"), so Ok(false) proves the override is in place.
    let connected = ops.device_is_connected("native:does_not_exist").await;
    assert_eq!(
        connected,
        Ok(false),
        "device_is_connected must be overridden (Ok(false) for an unknown \
         device), not the trait-default Err"
    );

    // connect_device on an unknown id errors, but it must be a real
    // DeviceManager "not found" error — NOT the trait-default
    // "connect_device not supported by this driver".
    let connect = ops.connect_device("native:does_not_exist").await;
    assert!(
        connect.is_err(),
        "connecting an unknown device should error"
    );
    let msg = connect.unwrap_err().to_string();
    assert!(
        !msg.contains("not supported by this driver"),
        "connect_device must be overridden; got the trait-default error: {msg}"
    );
}

/// Slew arrival is checked against the mount's read-back, so the target has to
/// be expressed in the frame that read-back is in: of date for a real driver
/// (the send path precesses to it), and for the Simulator whichever frame it
/// is pinned to (of date by default, J2000 under
/// `SKOTIQ_SIM_MOUNT_FRAME=j2000`). Comparing a J2000 target with an of-date read-back failed
/// every sequence's first slew on 2026-09-14 by 16' of RA, and nothing in the
/// bridge pinned the mapping: returning the J2000 target for every driver left
/// every test green.
#[tokio::test]
async fn slew_targets_are_compared_in_the_frame_each_mount_reports() {
    let mgr = get_device_manager();
    let mount = |id: &str, driver_type| DeviceInfo {
        id: id.to_string(),
        name: "Frame Test Mount".to_string(),
        device_type: DeviceType::Mount,
        driver_type,
        description: "Frame test mount".to_string(),
        driver_version: "test".to_string(),
        serial_number: None,
        unique_id: None,
        display_name: "Frame Test Mount".to_string(),
    };
    let real_id = "alpaca:readback_frame_mount";
    let sim_id = "sim_readback_frame_mount";
    mgr.register_device(mount(real_id, DriverType::Alpaca), false)
        .await;
    mgr.register_device(mount(sim_id, DriverType::Simulator), false)
        .await;
    let ops = UnifiedDeviceOps::new(crate::api::get_state().clone());

    // NGC 7380, the target of the 2026-09-14 failure.
    let (ra, dec) = (22.7892, 58.1324);
    let real = ops.mount_readback_frame(real_id, ra, dec).await;
    // The simulator's frame is process-wide; pin each one under the
    // simulator lock, as the frame tests do.
    let (sim_of_date, sim_j2000) = {
        let _serialized = crate::api::devices::simulation::sim_singleton_test_lock()
            .lock()
            .await;
        let of_date = {
            let _frame = crate::device_manager::epoch::SimFrameGuard::pin(
                crate::device_manager::epoch::SimMountFrame::OfDate,
            );
            ops.mount_readback_frame(sim_id, ra, dec).await
        };
        let j2000 = {
            let _frame = crate::device_manager::epoch::SimFrameGuard::pin(
                crate::device_manager::epoch::SimMountFrame::J2000,
            );
            ops.mount_readback_frame(sim_id, ra, dec).await
        };
        (of_date, j2000)
    };
    let unknown = ops
        .mount_readback_frame("alpaca:no_such_mount", ra, dec)
        .await;
    mgr.unregister_device(real_id).await;
    mgr.unregister_device(sim_id).await;

    let (real_ra, real_dec) = real.unwrap();
    let (sent_ra, sent_dec) = crate::device_manager::epoch::j2000_to_jnow(ra, dec);
    assert!(
        ((real_ra - sent_ra) * 15.0 * 60.0).abs() < 0.01
            && ((real_dec - sent_dec) * 60.0).abs() < 0.01,
        "a real mount's target must be precessed exactly as the slew sent it"
    );
    // A quarter century of precession: far outside the 1' arrival tolerance.
    assert!(((real_ra - ra) * 15.0 * 60.0).abs() > 10.0);
    assert!(((real_dec - dec) * 60.0).abs() > 5.0);

    assert_eq!(
        sim_of_date.unwrap(),
        (sent_ra, sent_dec),
        "the default Simulator is an of-date mount and is compared like one"
    );
    assert_eq!(
        sim_j2000.unwrap(),
        (ra, dec),
        "a Simulator pinned to J2000 reads back what it was sent"
    );
    assert_eq!(unknown.unwrap(), (ra, dec));
}
