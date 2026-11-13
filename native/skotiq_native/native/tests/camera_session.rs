//! Full driver sessions against the software-only fake vendor SDKs, recorded as text.
//!
//! Each `#[ignore]` test drives every device one fake SDK exposes through a whole
//! session (discover, connect, settings, cooler, status, exposures with download,
//! abort, disconnect) and writes every answer to `$CAMERA_SESSION_OUT`: for a
//! downloaded frame the dimensions, bit depth, Bayer pattern, a hash of the pixels
//! and the whole metadata (timestamp zeroed). Nothing is asserted: the record is
//! compared before and after a driver change, together with the SDK call trace
//! the instrumented fakes write. `tests/fake_sdk_linux/run_sessions.sh` builds
//! the fakes, runs one vendor per process and explains the comparison.

#![cfg(unix)]

use skotiq_device::{CameraDriver, DriverError, FilterWheelDriver, FocuserDriver};
use skotiq_device::{CameraStatus, ExposureParams, FrameType, ImageData, SubFrame};
use skotiq_native::vendor::{atik, fli, moravian, player_one, qhy, svbony, touptek, zwo};
use std::fmt::Debug;
use std::fmt::Write as _;
use std::time::Duration;

struct Record(String);

impl Record {
    fn line(&mut self, label: &str, value: impl AsRef<str>) {
        writeln!(self.0, "{} = {}", label, value.as_ref()).unwrap();
    }

    fn result<T: Debug>(&mut self, label: &str, result: Result<T, DriverError>) {
        let text = match result {
            Ok(value) => format!("Ok({:?})", value),
            Err(error) => format!("Err({:?})", error),
        };
        self.line(label, text);
    }

    fn finish(self, name: &str) {
        match std::env::var_os("CAMERA_SESSION_OUT") {
            Some(dir) => {
                let path = std::path::Path::new(&dir).join(format!("{}.session", name));
                std::fs::write(path, self.0).expect("write session record");
            }
            None => print!("{}", self.0),
        }
    }
}

/// `exposure_remaining` depends on the wall clock; keep only whether it is reported.
fn status_text(status: Result<CameraStatus, DriverError>) -> String {
    match status {
        Ok(mut status) => {
            let remaining = status.exposure_remaining.take().is_some();
            format!("Ok({:?}) exposure_remaining_reported={}", status, remaining)
        }
        Err(error) => format!("Err({:?})", error),
    }
}

fn frame_text(frame: Result<ImageData, DriverError>) -> String {
    match frame {
        Ok(mut image) => {
            let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
            for pixel in &image.data {
                for byte in pixel.to_le_bytes() {
                    hash ^= u64::from(byte);
                    hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
                }
            }
            image.metadata.timestamp = chrono::DateTime::<chrono::Utc>::UNIX_EPOCH;
            let expected_pixels = image.width as usize * image.height as usize;
            let count_note = if image.data.len() == expected_pixels {
                ""
            } else {
                "PIXEL COUNT IS NOT WIDTH x HEIGHT "
            };
            format!(
                "Ok {}{}x{} pixels={} fnv1a={:016x} bits_per_pixel={} bayer={:?} metadata={:?}",
                count_note,
                image.width,
                image.height,
                image.data.len(),
                hash,
                image.bits_per_pixel,
                image.bayer_pattern,
                image.metadata
            )
        }
        Err(error) => format!("Err({:?})", error),
    }
}

fn exposure(
    duration_secs: f64,
    bin: i32,
    subframe: Option<SubFrame>,
    frame_type: FrameType,
) -> ExposureParams {
    ExposureParams {
        duration_secs,
        gain: Some(55),
        offset: Some(9),
        bin_x: bin,
        bin_y: bin,
        subframe,
        readout_mode: None,
        frame_type,
    }
}

async fn wait_for_frame<C: CameraDriver>(camera: &C) -> Result<bool, DriverError> {
    let mut last = Ok(false);
    for _ in 0..100 {
        last = camera.is_exposure_complete().await;
        if !matches!(last, Ok(false)) {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    last
}

async fn camera_session<C: CameraDriver>(record: &mut Record, label: &str, camera: &mut C) {
    let l = |step: &str| format!("{}.{}", label, step);
    record.line(&l("name before connect"), camera.name());
    record.result(&l("connect"), camera.connect().await);
    record.line(&l("is_connected"), camera.is_connected().to_string());
    record.line(&l("name"), camera.name());
    record.line(&l("vendor"), format!("{:?}", camera.vendor()));
    record.line(&l("serial_number"), format!("{:?}", camera.serial_number()));
    record.line(&l("capabilities"), format!("{:?}", camera.capabilities()));
    record.line(
        &l("get_sensor_info"),
        format!("{:?}", camera.get_sensor_info()),
    );
    record.result(&l("get_gain_range"), camera.get_gain_range().await);
    record.result(&l("get_offset_range"), camera.get_offset_range().await);
    record.result(&l("get_exposure_range"), camera.get_exposure_range().await);
    record.result(
        &l("get_cooler_temp_range"),
        camera.get_cooler_temp_range().await,
    );
    record.result(
        &l("get_recommended_settings"),
        camera.get_recommended_settings().await,
    );
    record.result(&l("get_readout_modes"), camera.get_readout_modes().await);
    record.result(
        &l("get_vendor_features"),
        camera.get_vendor_features().await,
    );
    record.line(
        &l("get_status initial"),
        status_text(camera.get_status().await),
    );

    record.result(&l("set_gain(42)"), camera.set_gain(42).await);
    record.result(&l("get_gain"), camera.get_gain().await);
    record.result(&l("set_offset(8)"), camera.set_offset(8).await);
    record.result(&l("get_offset"), camera.get_offset().await);
    record.result(&l("set_binning(2,2)"), camera.set_binning(2, 2).await);
    record.result(&l("get_binning"), camera.get_binning().await);
    record.result(
        &l("set_subframe(8,4,16,8)"),
        camera
            .set_subframe(Some(SubFrame {
                start_x: 8,
                start_y: 4,
                width: 16,
                height: 8,
            }))
            .await,
    );
    record.result(&l("set_subframe(None)"), camera.set_subframe(None).await);
    record.result(
        &l("set_cooler(on,-12.5)"),
        camera.set_cooler(true, Some(-12.5)).await,
    );
    record.line(
        &l("get_status cooling"),
        status_text(camera.get_status().await),
    );
    record.result(&l("get_temperature"), camera.get_temperature().await);
    record.result(&l("get_cooler_power"), camera.get_cooler_power().await);

    record.result(
        &l("start_exposure light bin2"),
        camera
            .start_exposure(exposure(0.01, 2, None, FrameType::Light))
            .await,
    );
    record.result(&l("exposure complete"), wait_for_frame(camera).await);
    record.line(
        &l("download light bin2"),
        frame_text(camera.download_image().await),
    );
    record.line(
        &l("get_status after download"),
        status_text(camera.get_status().await),
    );

    record.result(
        &l("start_exposure dark bin1 subframe"),
        camera
            .start_exposure(exposure(
                0.01,
                1,
                Some(SubFrame {
                    start_x: 8,
                    start_y: 4,
                    width: 16,
                    height: 8,
                }),
                FrameType::Dark,
            ))
            .await,
    );
    record.result(&l("exposure complete"), wait_for_frame(camera).await);
    record.line(
        &l("download dark subframe"),
        frame_text(camera.download_image().await),
    );

    record.result(
        &l("start_exposure invalid bin"),
        camera
            .start_exposure(exposure(0.01, 99, None, FrameType::Light))
            .await,
    );
    record.result(
        &l("start_exposure long"),
        camera
            .start_exposure(exposure(10.0, 1, None, FrameType::Light))
            .await,
    );
    record.line(
        &l("get_status exposing"),
        status_text(camera.get_status().await),
    );
    record.result(&l("abort_exposure"), camera.abort_exposure().await);
    record.line(
        &l("get_status aborted"),
        status_text(camera.get_status().await),
    );

    record.result(&l("set_cooler(off)"), camera.set_cooler(false, None).await);
    record.line(
        &l("get_status cooler off"),
        status_text(camera.get_status().await),
    );
    record.result(&l("disconnect"), camera.disconnect().await);
    record.line(&l("is_connected"), camera.is_connected().to_string());
    record.line(
        &l("get_status disconnected"),
        status_text(camera.get_status().await),
    );
}

async fn focuser_session<F: FocuserDriver>(record: &mut Record, label: &str, focuser: &mut F) {
    let l = |step: &str| format!("{}.{}", label, step);
    record.result(&l("connect"), focuser.connect().await);
    record.line(&l("name"), focuser.name());
    record.line(
        &l("serial_number"),
        format!("{:?}", focuser.serial_number()),
    );
    record.line(
        &l("get_max_position"),
        focuser.get_max_position().await.to_string(),
    );
    record.line(&l("get_step_size"), focuser.get_step_size().await.to_string());
    record.result(&l("get_position"), focuser.get_position().await);
    record.result(&l("move_to(1234)"), focuser.move_to(1234).await);
    record.result(&l("is_moving"), focuser.is_moving().await);
    record.result(&l("get_position"), focuser.get_position().await);
    record.result(&l("move_relative(-34)"), focuser.move_relative(-34).await);
    record.result(&l("move_to(-5)"), focuser.move_to(-5).await);
    record.result(&l("get_temperature"), focuser.get_temperature().await);
    record.result(&l("halt"), focuser.halt().await);
    record.result(&l("disconnect"), focuser.disconnect().await);
    record.result(
        &l("get_position disconnected"),
        focuser.get_position().await,
    );
}

async fn wheel_session<W: FilterWheelDriver>(record: &mut Record, label: &str, wheel: &mut W) {
    let l = |step: &str| format!("{}.{}", label, step);
    record.result(&l("connect"), wheel.connect().await);
    record.line(&l("name"), wheel.name());
    record.line(&l("serial_number"), format!("{:?}", wheel.serial_number()));
    record.line(&l("get_filter_count"), wheel.get_filter_count().await.to_string());
    record.result(&l("get_filter_names"), wheel.get_filter_names().await);
    record.result(&l("get_position"), wheel.get_position().await);
    record.result(&l("move_to_position(2)"), wheel.move_to_position(2).await);
    record.result(&l("is_moving"), wheel.is_moving().await);
    record.result(&l("get_position"), wheel.get_position().await);
    record.result(&l("move_to_position(99)"), wheel.move_to_position(99).await);
    record.result(
        &l("set_filter_name(1)"),
        wheel.set_filter_name(1, "Ha".to_string()).await,
    );
    record.result(&l("get_filter_names"), wheel.get_filter_names().await);
    record.result(&l("disconnect"), wheel.disconnect().await);
    record.result(&l("get_position disconnected"), wheel.get_position().await);
}

#[tokio::test]
#[ignore = "needs the fake SDKs on LD_LIBRARY_PATH: tests/fake_sdk_linux/run_sessions.sh"]
async fn session_zwo() {
    let mut record = Record(String::new());
    let cameras = zwo::discover_devices().await;
    record.line(
        "zwo.discover_devices",
        format!("{:?}", cameras.as_ref().map(|c| c.len())),
    );
    let ids: Vec<i32> = cameras
        .map(|c| c.iter().map(|c| c.camera_id).collect())
        .unwrap_or_default();
    for id in if ids.is_empty() { vec![0] } else { ids } {
        let mut camera = zwo::ZwoCamera::new(id);
        camera_session(&mut record, &format!("zwo.camera{}", id), &mut camera).await;
    }
    let focusers = zwo::discover_focusers().await;
    record.line(
        "zwo.discover_focusers",
        format!("{:?}", focusers.as_ref().map(|f| f.len())),
    );
    let mut focuser = zwo::ZwoFocuser::new(
        focusers
            .ok()
            .and_then(|f| f.first().map(|f| f.focuser_id))
            .unwrap_or(0),
    );
    focuser_session(&mut record, "zwo.eaf", &mut focuser).await;
    // Connect before any wheel discovery: a saved profile reaches the wheel this way.
    let mut wheel = zwo::ZwoFilterWheel::new(0);
    wheel_session(&mut record, "zwo.efw", &mut wheel).await;
    let wheels = zwo::discover_filter_wheels().await;
    record.line(
        "zwo.discover_filter_wheels",
        format!("{:?}", wheels.as_ref().map(|w| w.len())),
    );
    record.finish("zwo");
}

#[tokio::test]
#[ignore = "needs the fake SDKs on LD_LIBRARY_PATH: tests/fake_sdk_linux/run_sessions.sh"]
async fn session_atik() {
    let mut record = Record(String::new());
    let cameras = atik::discover_devices().await;
    record.line(
        "atik.discover_devices",
        format!("{:?}", cameras.as_ref().map(|c| c.len())),
    );
    let ids: Vec<i32> = cameras
        .map(|c| c.iter().map(|c| c.device_index).collect())
        .unwrap_or_default();
    for id in if ids.is_empty() { vec![0] } else { ids } {
        let mut camera = atik::AtikCamera::new(id);
        camera_session(&mut record, &format!("atik.camera{}", id), &mut camera).await;
    }
    let wheels = atik::discover_filter_wheels().await;
    record.line(
        "atik.discover_filter_wheels",
        format!("{:?}", wheels.as_ref().map(|w| w.len())),
    );
    let mut wheel = atik::AtikFilterWheel::new(
        wheels
            .ok()
            .and_then(|w| w.first().map(|w| w.device_index))
            .unwrap_or(0),
    );
    wheel_session(&mut record, "atik.efw", &mut wheel).await;
    record.finish("atik");
}

#[tokio::test]
#[ignore = "needs the fake SDKs on LD_LIBRARY_PATH: tests/fake_sdk_linux/run_sessions.sh"]
async fn session_svbony() {
    let mut record = Record(String::new());
    let cameras = svbony::discover_devices().await;
    record.line(
        "svbony.discover_devices",
        format!("{:?}", cameras.as_ref().map(|c| c.len())),
    );
    let ids: Vec<i32> = cameras
        .map(|c| c.iter().map(|c| c.camera_id).collect())
        .unwrap_or_default();
    for id in if ids.is_empty() { vec![0] } else { ids } {
        let mut camera = svbony::SvbonyCamera::new(id);
        camera_session(&mut record, &format!("svbony.camera{}", id), &mut camera).await;
    }
    record.finish("svbony");
}

#[tokio::test]
#[ignore = "needs the fake SDKs on LD_LIBRARY_PATH: tests/fake_sdk_linux/run_sessions.sh"]
async fn session_player_one() {
    let mut record = Record(String::new());
    let cameras = player_one::discover_devices().await;
    record.line(
        "player_one.discover_devices",
        format!("{:?}", cameras.as_ref().map(|c| c.len())),
    );
    let ids: Vec<i32> = cameras
        .map(|c| c.iter().map(|c| c.camera_id).collect())
        .unwrap_or_default();
    for id in if ids.is_empty() { vec![0] } else { ids } {
        let mut camera = player_one::PlayerOneCamera::new(id);
        camera_session(
            &mut record,
            &format!("player_one.camera{}", id),
            &mut camera,
        )
        .await;
    }
    let wheels = player_one::discover_filter_wheels().await;
    record.line(
        "player_one.discover_filter_wheels",
        format!("{:?}", wheels.as_ref().map(|w| w.len())),
    );
    let mut wheel = player_one::PlayerOneFilterWheel::new(
        wheels
            .ok()
            .and_then(|w| w.first().map(|w| w.handle))
            .unwrap_or(0),
    );
    wheel_session(&mut record, "player_one.pw", &mut wheel).await;
    record.finish("player_one");
}

#[tokio::test]
#[ignore = "needs the fake SDKs on LD_LIBRARY_PATH: tests/fake_sdk_linux/run_sessions.sh"]
async fn session_qhy() {
    let mut record = Record(String::new());
    let cameras = qhy::discover_devices().await;
    record.line(
        "qhy.discover_devices",
        format!("{:?}", cameras.as_ref().map(|c| c.len())),
    );
    let ids: Vec<String> = cameras
        .map(|c| c.iter().map(|c| c.camera_id.clone()).collect())
        .unwrap_or_default();
    for (index, id) in ids.iter().enumerate() {
        let mut camera = qhy::QhyCamera::new(id.clone());
        camera_session(&mut record, &format!("qhy.camera{}", index), &mut camera).await;
    }
    let wheels = qhy::discover_filter_wheels().await;
    record.line(
        "qhy.discover_filter_wheels",
        format!("{:?}", wheels.as_ref().map(|w| w.len())),
    );
    if let Some(id) = wheels
        .ok()
        .and_then(|w| w.first().map(|w| w.camera_id.clone()))
    {
        let mut wheel = qhy::QhyFilterWheel::new(id);
        wheel_session(&mut record, "qhy.cfw", &mut wheel).await;
    }
    record.finish("qhy");
}

#[tokio::test]
#[ignore = "needs the fake SDKs on LD_LIBRARY_PATH: tests/fake_sdk_linux/run_sessions.sh"]
async fn session_touptek() {
    let mut record = Record(String::new());
    let cameras = touptek::discover_devices_for_brand("OGMA").await;
    record.line(
        "touptek.discover_devices",
        format!("{:?}", cameras.as_ref().map(|c| c.len())),
    );
    let count = cameras.map(|c| c.len()).unwrap_or(0).max(1);
    for index in 0..count {
        let mut camera = touptek::TouptekCamera::new(index, "OGMA");
        camera_session(
            &mut record,
            &format!("touptek.camera{}", index),
            &mut camera,
        )
        .await;
    }
    record.finish("touptek");
}

#[tokio::test]
#[ignore = "needs the fake SDKs on LD_LIBRARY_PATH: tests/fake_sdk_linux/run_sessions.sh"]
async fn session_fli() {
    let mut record = Record(String::new());
    let cameras = fli::discover_cameras().await;
    record.line(
        "fli.discover_cameras",
        format!("{:?}", cameras.as_ref().map(|c| c.len())),
    );
    for (index, info) in cameras.unwrap_or_default().iter().enumerate() {
        let mut camera = fli::FliCamera::new(info.device_path.clone());
        camera_session(&mut record, &format!("fli.camera{}", index), &mut camera).await;
    }
    let focusers = fli::discover_focusers().await;
    record.line(
        "fli.discover_focusers",
        format!("{:?}", focusers.as_ref().map(|f| f.len())),
    );
    if let Some(info) = focusers.unwrap_or_default().first() {
        let mut focuser = fli::FliFocuser::new(info.device_path.clone());
        focuser_session(&mut record, "fli.focuser", &mut focuser).await;
    }
    let wheels = fli::discover_filter_wheels().await;
    record.line(
        "fli.discover_filter_wheels",
        format!("{:?}", wheels.as_ref().map(|w| w.len())),
    );
    if let Some(info) = wheels.unwrap_or_default().first() {
        let mut wheel = fli::FliFilterWheel::new(info.device_path.clone());
        wheel_session(&mut record, "fli.wheel", &mut wheel).await;
    }
    record.finish("fli");
}

#[tokio::test]
#[ignore = "needs the fake SDKs on LD_LIBRARY_PATH: tests/fake_sdk_linux/run_sessions.sh"]
async fn session_moravian() {
    let mut record = Record(String::new());
    let cameras = moravian::discover_devices().await;
    record.line(
        "moravian.discover_devices",
        format!("{:?}", cameras.as_ref().map(|c| c.len())),
    );
    let addresses: Vec<_> = cameras
        .map(|c| c.iter().map(|c| c.address()).collect())
        .unwrap_or_default();
    for address in if addresses.is_empty() {
        vec!["0".to_string()]
    } else {
        addresses
    } {
        let mut camera = moravian::MoravianCamera::from_address(&address).expect("an address");
        camera_session(
            &mut record,
            &format!("moravian.camera{}", address),
            &mut camera,
        )
        .await;
    }
    record.finish("moravian");
}
