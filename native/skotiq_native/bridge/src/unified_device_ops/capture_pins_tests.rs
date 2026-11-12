//! What a captured frame publishes to the last-image store, pinned on fixed
//! frames: statistics, star count and shape, histogram bins and the RGBA
//! display buffer, through the Imaging screen's entry point and through the
//! sequencer's.
//!
//! The frames are a real rig crop (`test-fixtures/rig-2026-09-14`), once as a
//! mono sensor and once read as a GRBG colour sensor, delivered by a camera
//! driver that hands back exactly those samples.

use super::*;
use crate::api::get_device_manager;
use crate::device::{DeviceInfo, DriverType};
use skotiq_device::{
    BayerPattern, CameraCapabilities, CameraDriver, CameraState, CameraStatus, DeviceDriver,
    DriverError, ExposureParams, ImageData as DeviceImageData, ImageMetadata, ReadoutMode,
    SensorInfo, SubFrame, Vendor, VendorFeatures,
};

#[derive(Debug)]
struct FixedFrameCamera {
    id: String,
    frame: Arc<(u32, u32, Vec<u16>)>,
    bayer_pattern: Option<BayerPattern>,
}

#[async_trait::async_trait]
impl DeviceDriver for FixedFrameCamera {
    fn id(&self) -> &str {
        &self.id
    }

    fn name(&self) -> &str {
        "Fixed Frame Camera"
    }

    fn vendor(&self) -> Vendor {
        Vendor::Other("Test".to_string())
    }

    fn is_connected(&self) -> bool {
        true
    }

    async fn connect(&mut self) -> Result<(), DriverError> {
        Ok(())
    }

    async fn disconnect(&mut self) -> Result<(), DriverError> {
        Ok(())
    }
}

#[async_trait::async_trait]
impl CameraDriver for FixedFrameCamera {
    fn capabilities(&self) -> CameraCapabilities {
        CameraCapabilities::default()
    }

    async fn get_status(&self) -> Result<CameraStatus, DriverError> {
        Ok(CameraStatus {
            state: CameraState::Idle,
            sensor_temp: None,
            cooler_power: None,
            target_temp: None,
            cooler_on: false,
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
        Ok(true)
    }

    async fn download_image(&mut self) -> Result<DeviceImageData, DriverError> {
        let (width, height, data) = &*self.frame;
        Ok(DeviceImageData {
            width: *width,
            height: *height,
            data: data.clone(),
            bits_per_pixel: 16,
            bayer_pattern: self.bayer_pattern,
            metadata: ImageMetadata {
                exposure_time: 2.0,
                gain: 139,
                offset: 21,
                bin_x: 1,
                bin_y: 1,
                temperature: Some(-10.0),
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
        Ok(-10.0)
    }

    async fn get_cooler_power(&self) -> Result<f64, DriverError> {
        Ok(0.0)
    }

    async fn set_gain(&mut self, _gain: i32) -> Result<(), DriverError> {
        Ok(())
    }

    async fn get_gain(&self) -> Result<i32, DriverError> {
        Ok(139)
    }

    async fn set_offset(&mut self, _offset: i32) -> Result<(), DriverError> {
        Ok(())
    }

    async fn get_offset(&self) -> Result<i32, DriverError> {
        Ok(21)
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
        let (width, height, _) = &*self.frame;
        SensorInfo {
            width: *width,
            height: *height,
            pixel_size_x: 3.8,
            pixel_size_y: 3.8,
            max_adu: 65535,
            bit_depth: 16,
            color: self.bayer_pattern.is_some(),
            bayer_pattern: self.bayer_pattern,
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

fn rig_crop() -> (u32, u32, Vec<u16>) {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../test-fixtures/rig-2026-09-14/focused_L_0005.fits");
    let (image, _) = skotiq_imaging::read_frame(&path).expect("read rig crop");
    let data = image
        .data
        .as_chunks::<2>()
        .0
        .iter()
        .map(|b| u16::from_le_bytes(*b))
        .collect();
    (image.width, image.height, data)
}

/// A frame the size of the owner's ASI1600 (4656x3520), tiled from the crop.
fn full_sensor_frame() -> (u32, u32, Vec<u16>) {
    let (cw, ch, crop) = rig_crop();
    let (width, height) = (4656u32, 3520u32);
    let mut data = Vec::with_capacity((width * height) as usize);
    for y in 0..height {
        let row = (y % ch) as usize * cw as usize;
        for x in 0..width {
            data.push(crop[row + (x % cw) as usize]);
        }
    }
    (width, height, data)
}

async fn connect_fixed_camera(
    device_id: &str,
    frame: Arc<(u32, u32, Vec<u16>)>,
    bayer_pattern: Option<BayerPattern>,
) {
    let mgr = get_device_manager();
    mgr.register_device(
        DeviceInfo {
            id: device_id.to_string(),
            name: "Fixed Frame Camera".to_string(),
            device_type: DeviceType::Camera,
            driver_type: DriverType::Native,
            description: "Fixed frame camera".to_string(),
            driver_version: "test".to_string(),
            serial_number: None,
            unique_id: None,
            display_name: "Fixed Frame Camera".to_string(),
        },
        false,
    )
    .await;
    mgr.native_cameras.write().await.insert(
        device_id.to_string(),
        Box::new(FixedFrameCamera {
            id: device_id.to_string(),
            frame,
            bayer_pattern,
        }),
    );
}

async fn disconnect_fixed_camera(device_id: &str) {
    let mgr = get_device_manager();
    mgr.unregister_device(device_id).await;
    mgr.native_cameras.write().await.remove(device_id);
    let _ = crate::api::api_clear_device_image(device_id.to_string()).await;
}

fn fnv1a(bytes: impl IntoIterator<Item = u8>) -> u64 {
    bytes
        .into_iter()
        .fold(0xcbf2_9ce4_8422_2325_u64, |hash, byte| {
            (hash ^ u64::from(byte)).wrapping_mul(0x0100_0000_01b3)
        })
}

/// Everything the store publishes for the device's last frame, as text.
async fn stored_frame_digest(device_id: &str) -> String {
    let display = crate::api::api_get_last_image(device_id.to_string())
        .await
        .expect("a frame is stored");
    let raw = crate::api::api_get_last_raw_image_data(device_id.to_string())
        .await
        .expect("raw samples are stored");
    let s = &display.stats;
    format!(
        "{}x{} color={} exposure={:?}\n\
         stats min={:?} max={:?} mean={:?} median={:?} std_dev={:?}\n\
         stars={} hfr={:?} fwhm={:?} eccentricity={:?}\n\
         histogram={:016x} display={:016x} display_len={} raw={:016x}",
        display.width,
        display.height,
        display.is_color,
        display.exposure_time,
        s.min,
        s.max,
        s.mean,
        s.median,
        s.std_dev,
        s.star_count,
        s.hfr,
        s.fwhm,
        s.eccentricity,
        fnv1a(display.histogram.iter().flat_map(|bin| bin.to_le_bytes())),
        fnv1a(display.display_data.iter().copied()),
        display.display_data.len(),
        fnv1a(raw.iter().flat_map(|v| v.to_le_bytes())),
    )
}

async fn manual_capture(device_id: &str) {
    crate::api::imaging::camera_start_exposure_configured_opt(
        device_id.to_string(),
        2.0,
        Some(139),
        Some(21),
        1,
        1,
        None,
        skotiq_device::FrameType::Light,
    )
    .await
    .expect("manual capture");
}

async fn sequence_capture(device_id: &str) -> ImageData {
    create_unified_device_ops()
        .camera_start_exposure(
            skotiq_sequencer::ExposureRequest::new(device_id, 2.0)
                .gain(Some(139))
                .offset(Some(21)),
        )
        .await
        .expect("sequence capture")
}

fn assert_digests(cases: &[(&str, &str, &str)]) {
    let moved: Vec<String> = cases
        .iter()
        .filter(|(_, actual, expected)| actual != expected)
        .map(|(label, actual, expected)| {
            format!(
                "{label}: the stored frame moved.\n--- actual\n{actual}\n--- expected\n{expected}"
            )
        })
        .collect();
    assert!(moved.is_empty(), "{}", moved.join("\n\n"));
}

#[tokio::test]
async fn a_mono_frame_publishes_the_same_measurements_from_either_entry_point() {
    let frame = Arc::new(rig_crop());
    let device_id = "native:pin_mono";
    connect_fixed_camera(device_id, frame, None).await;

    manual_capture(device_id).await;
    let manual = stored_frame_digest(device_id).await;
    let returned = sequence_capture(device_id).await;
    let sequence = stored_frame_digest(device_id).await;
    disconnect_fixed_camera(device_id).await;

    assert_digests(&[
        ("manual mono", &manual, MONO),
        ("sequence mono", &sequence, MONO),
    ]);
    assert_eq!(
        (returned.sensor_type.as_deref(), returned.color_filter),
        (Some("Monochrome"), None)
    );
}

#[tokio::test]
async fn a_color_frame_publishes_the_same_measurements_from_either_entry_point() {
    let frame = Arc::new(rig_crop());
    let device_id = "native:pin_color";
    connect_fixed_camera(device_id, frame, Some(BayerPattern::Grbg)).await;

    manual_capture(device_id).await;
    let manual = stored_frame_digest(device_id).await;
    let returned = sequence_capture(device_id).await;
    let sequence = stored_frame_digest(device_id).await;
    disconnect_fixed_camera(device_id).await;

    assert_digests(&[
        ("manual color", &manual, COLOR),
        ("sequence color", &sequence, COLOR),
    ]);
    assert_eq!(
        (returned.sensor_type.as_deref(), returned.color_filter),
        (Some("Color"), Some(BayerPattern::Grbg))
    );
}

/// Wall time of one manual capture of a full-size frame, from the call to the
/// stored result (the driver answers instantly, so this is the analysis).
///
/// ```text
/// cargo test --release -p skotiq_bridge --lib capture_time_per_full_frame -- --ignored --nocapture
/// ```
#[tokio::test]
#[ignore = "timing probe; run by hand"]
async fn capture_time_per_full_frame() {
    let frame = Arc::new(full_sensor_frame());
    for (device_id, bayer) in [
        ("native:timing_mono", None),
        ("native:timing_color", Some(BayerPattern::Rggb)),
    ] {
        connect_fixed_camera(device_id, frame.clone(), bayer).await;
        let mut manual = Vec::new();
        let mut sequence = Vec::new();
        for _ in 0..5 {
            let started = std::time::Instant::now();
            manual_capture(device_id).await;
            manual.push(started.elapsed().as_secs_f64());
            let started = std::time::Instant::now();
            sequence_capture(device_id).await;
            sequence.push(started.elapsed().as_secs_f64());
        }
        disconnect_fixed_camera(device_id).await;
        manual.sort_by(f64::total_cmp);
        sequence.sort_by(f64::total_cmp);
        println!(
            "{device_id}: manual median {:.3} s (min {:.3}), sequence median {:.3} s (min {:.3})",
            manual[2], manual[0], sequence[2], sequence[0]
        );
    }
}

const MONO: &str = "1024x1024 color=false exposure=2.0
stats min=16.0 max=65504.0 mean=698.3109436035156 median=672.0 std_dev=657.9213351686734
stars=192 hfr=Some(2.310760259173266) fwhm=Some(4.621520518346532) eccentricity=Some(0.6601127561091212)
histogram=d5f0d1c69d0b6d04 display=d46f5a116b546afc display_len=4194304 raw=c88128ab9b80e33f";
const COLOR: &str = "1024x1024 color=true exposure=2.0
stats min=16.0 max=65504.0 mean=698.3109436035156 median=672.0 std_dev=657.9213351686734
stars=192 hfr=Some(2.310760259173266) fwhm=Some(4.621520518346532) eccentricity=Some(0.6601127561091212)
histogram=3513c089f664dcd4 display=0a6c414758185544 display_len=4194304 raw=c88128ab9b80e33f";
