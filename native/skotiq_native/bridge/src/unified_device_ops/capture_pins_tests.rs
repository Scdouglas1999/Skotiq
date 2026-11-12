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
            saturation_adu: None,
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
    mgr.hold_vendor_camera(
        device_id,
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
    mgr.handles.remove(device_id);
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

#[tokio::test]
async fn a_stored_frame_is_measured_for_grading_as_a_fresh_detection_measures_it() {
    let device_id = "native:pin_grading";
    connect_fixed_camera(device_id, Arc::new(rig_crop()), None).await;
    let mut image = sequence_capture(device_id).await;
    let ops = create_unified_device_ops();
    let fresh = |image: &ImageData| {
        super::frame_store::measure_light_frame(
            &skotiq_imaging::ImageData::from_u16(image.width, image.height, 1, &image.data),
            None,
        )
    };

    assert!(
        crate::last_frame::detected_stars(image.width, image.height, &image.data)
            .await
            .is_some(),
        "the store keeps the detection of the frame it holds"
    );
    let measured = ops.measure_light_frame(&image).await.expect("measurement");
    assert_eq!(measured, fresh(&image));
    assert!(measured.star_count.is_some_and(|n| n > 100), "{measured:?}");

    // A frame changed after it was stored (a defect map corrected a pixel)
    // is detected again, not answered with the stored stars.
    image.data[0] = image.data[0].wrapping_add(1);
    assert!(
        crate::last_frame::detected_stars(image.width, image.height, &image.data)
            .await
            .is_none()
    );
    assert_eq!(
        ops.measure_light_frame(&image).await.expect("measurement"),
        fresh(&image)
    );
    disconnect_fixed_camera(device_id).await;
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

/// The owner's ASI1600 frame tiled to `width` x `height`.
fn rig_frame_of_size(width: u32, height: u32) -> (u32, u32, Vec<u16>) {
    let path = std::env::var("SKOTIQ_TIMING_FRAME")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| {
            std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../test-fixtures/rig-2026-09-14/focused_L_0005.fits")
        });
    let (image, _) = skotiq_imaging::read_frame(&path).expect("read the rig frame");
    let (cw, ch) = (image.width, image.height);
    let crop = image.as_u16().expect("a 16-bit frame");
    let mut data = Vec::with_capacity((width * height) as usize);
    for y in 0..height {
        let row = (y % ch) as usize * cw as usize;
        for x in 0..width {
            data.push(crop[row + (x % cw) as usize]);
        }
    }
    (width, height, data)
}

fn median_ms(mut samples: Vec<f64>) -> f64 {
    samples.sort_by(f64::total_cmp);
    samples[samples.len() / 2] * 1e3
}

/// Wall time of each stage a sequence light frame goes through on the host,
/// from the driver's download to the saved file and its thumbnail, at the
/// sizes of a 26 MP and a 61 MP sensor.
///
/// ```text
/// SKOTIQ_TIMING_FRAME=<a real 16-bit frame> \
/// cargo test --release -p skotiq_bridge --lib frame_path_stage_times -- --ignored --nocapture
/// ```
#[tokio::test(flavor = "multi_thread")]
#[ignore = "timing probe; run by hand"]
async fn frame_path_stage_times() {
    let runs = 5;
    let dir = std::env::temp_dir().join(format!("sk-frame-path-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    for (label, width, height) in [("26MP", 6248u32, 4176u32), ("61MP", 9576, 6388)] {
        let frame = Arc::new(rig_frame_of_size(width, height));
        let device_id = format!("native:timing_{label}");
        connect_fixed_camera(&device_id, frame.clone(), None).await;
        let ops = create_unified_device_ops();
        let mut stages: Vec<(&str, Vec<f64>)> = Vec::new();
        let mut record =
            |name: &'static str, secs: f64| match stages.iter_mut().find(|(n, _)| *n == name) {
                Some((_, v)) => v.push(secs),
                None => stages.push((name, vec![secs])),
            };
        for run in 0..runs {
            let t = std::time::Instant::now();
            let image = sequence_capture(&device_id).await;
            record(
                "capture (download+validate+store)",
                t.elapsed().as_secs_f64(),
            );

            let t = std::time::Instant::now();
            let bytes = skotiq_imaging::ImageData::from_u16(width, height, 1, &image.data);
            record("  of which: u16 -> byte copy", t.elapsed().as_secs_f64());
            let t = std::time::Instant::now();
            let _ = skotiq_imaging::validate_image_comprehensive(
                &bytes,
                skotiq_imaging::ImageValidationOptions {
                    expected_width: Some(width),
                    expected_height: Some(height),
                    ..Default::default()
                },
            );
            record("  of which: validation", t.elapsed().as_secs_f64());
            let raw = crate::last_frame::raw(&device_id).await.expect("stored");
            let t = std::time::Instant::now();
            let _ = crate::last_frame::measure(&raw, 2.0);
            record("  of which: display+stats+stars", t.elapsed().as_secs_f64());

            let t = std::time::Instant::now();
            let _ = ops.measure_light_frame(&image).await.expect("measurement");
            record("grading measurement", t.elapsed().as_secs_f64());
            let t = std::time::Instant::now();
            let _ = super::frame_store::measure_light_frame(&bytes, None);
            record("  the same, stars not stored", t.elapsed().as_secs_f64());

            for (format, ext) in [
                (skotiq_sequencer::ArchiveFormat::Fits, "fits"),
                (skotiq_sequencer::ArchiveFormat::Xisf, "xisf"),
            ] {
                skotiq_sequencer::executor_handle()
                    .update_run_config(|config| {
                        config.frame_format = skotiq_sequencer::FrameFormat {
                            format,
                            xisf_compression: skotiq_imaging::XisfCompression::from_name("zstd+sh")
                                .unwrap(),
                            xisf_checksums: true,
                        }
                    })
                    .await
                    .expect("the frame format applies");
                let path = dir.join(format!("{label}_{run}.{ext}"));
                let t = std::time::Instant::now();
                ops.save_fits(
                    &image,
                    path.to_str().unwrap(),
                    &skotiq_sequencer::scheduling::FrameContext::default(),
                )
                .await
                .expect("save");
                record(
                    if ext == "fits" {
                        "save FITS"
                    } else {
                        "save XISF zstd+sh"
                    },
                    t.elapsed().as_secs_f64(),
                );
                let t = std::time::Instant::now();
                crate::api::imaging::api_generate_fits_thumbnail(
                    path.to_string_lossy().into_owned(),
                    512,
                )
                .await
                .expect("thumbnail");
                record(
                    if ext == "fits" {
                        "thumbnail from FITS"
                    } else {
                        "thumbnail from XISF"
                    },
                    t.elapsed().as_secs_f64(),
                );
                let t = std::time::Instant::now();
                let _ = skotiq_imaging::read_frame(&path).expect("read back");
                record(
                    if ext == "fits" {
                        "read FITS"
                    } else {
                        "read XISF"
                    },
                    t.elapsed().as_secs_f64(),
                );
            }
            skotiq_sequencer::executor_handle()
                .update_run_config(|config| {
                    config.frame_format = skotiq_sequencer::FrameFormat::default()
                })
                .await
                .expect("the frame format applies");

            let t = std::time::Instant::now();
            let last = crate::api::api_get_last_image(device_id.clone())
                .await
                .expect("last image");
            record("last image for the screen", t.elapsed().as_secs_f64());

            // What a linked client's 2560 px preview would cost encoded here
            // (nearest-neighbor resize and JPEG quality 85, as the host's
            // Dart encoder does it).
            let t = std::time::Instant::now();
            let (w, h) = (
                2560u32,
                (f64::from(height) * 2560.0 / f64::from(width)).round() as u32,
            );
            let mut rgb = Vec::with_capacity((w * h * 3) as usize);
            for y in 0..h {
                let row = (y * height / h) as usize * width as usize;
                for x in 0..w {
                    let at = (row + (x * width / w) as usize) * 4;
                    rgb.extend_from_slice(&last.display_data[at..at + 3]);
                }
            }
            let mut jpeg = Vec::new();
            image::codecs::jpeg::JpegEncoder::new_with_quality(&mut jpeg, 85)
                .encode(&rgb, w, h, image::ColorType::Rgb8)
                .expect("jpeg");
            record("preview JPEG 2560 px, native", t.elapsed().as_secs_f64());
        }
        disconnect_fixed_camera(&device_id).await;
        println!("== {label} {width}x{height} mono, median of {runs} (ms)");
        for (name, samples) in stages {
            println!("{name:>36}: {:8.1}", median_ms(samples));
        }
    }
    let _ = std::fs::remove_dir_all(&dir);
}
