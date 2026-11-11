//! What every vendor driver answers while it is not connected.
//!
//! Each trait method is called on a freshly constructed driver (one driver per
//! call, so no call sees state left by another) and the answer is compared with
//! `tests/fixtures/disconnected_contract.txt`. The fixture pins, per method,
//! whether a disconnected device answers `NotConnected`, answers from cached
//! state, or validates its parameters first.
//!
//! The fixture was recorded with no vendor SDK installed. Methods that reach
//! for the SDK without checking the connection answer `SdkNotInstalled` there;
//! on a machine that has the SDK they would call into it, so a vendor whose
//! library loads is skipped.
//!
//! Regenerate with `UPDATE_DISCONNECTED_CONTRACT=1 cargo test --test disconnected_contract`.
//! Fujifilm is a Windows-only module with no fixture and is not covered here.

use skotiq_native::traits::{NativeCamera, NativeError, NativeFilterWheel, NativeFocuser};
use skotiq_native::vendor::{atik, fli, gphoto2, moravian, player_one, qhy, svbony, touptek, zwo};
use skotiq_native::{ExposureParams, FrameType, ReadoutMode, SubFrame};
use std::fmt::Debug;
use std::fmt::Write as _;

fn show<T: Debug>(result: Result<T, NativeError>) -> String {
    match result {
        Ok(value) => format!("Ok({:?})", value),
        Err(NativeError::SdkNotInstalled(_)) => "Err(SdkNotInstalled)".to_string(),
        Err(error) => format!("Err({:?})", error),
    }
}

/// `custom_data` is a hash map; print it in key order so the record is stable.
struct SortedFeatures(skotiq_native::VendorFeatures);

impl Debug for SortedFeatures {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let custom: std::collections::BTreeMap<_, _> = self.0.custom_data.iter().collect();
        let mut rest = self.0.clone();
        rest.custom_data.clear();
        write!(f, "{:?} custom_data={:?}", rest, custom)
    }
}

fn exposure(bin: i32, duration_secs: f64) -> ExposureParams {
    ExposureParams {
        duration_secs,
        gain: Some(100),
        offset: Some(10),
        bin_x: bin,
        bin_y: bin,
        subframe: None,
        readout_mode: None,
        frame_type: FrameType::Light,
    }
}

fn readout_mode() -> ReadoutMode {
    ReadoutMode {
        name: "Mode".to_string(),
        description: String::new(),
        index: 0,
        gain_min: None,
        gain_max: None,
        offset_min: None,
        offset_max: None,
    }
}

macro_rules! row {
    ($out:ident, $label:expr, $value:expr) => {
        writeln!($out, "  {} = {}", $label, $value).unwrap()
    };
}

async fn camera_rows<C: NativeCamera>(out: &mut String, make: impl Fn() -> C) {
    row!(out, "vendor", format!("{:?}", make().vendor()));
    row!(out, "is_connected", make().is_connected());
    row!(
        out,
        "serial_number",
        format!("{:?}", make().serial_number())
    );
    row!(out, "disconnect", show(make().disconnect().await));
    row!(out, "capabilities", format!("{:?}", make().capabilities()));
    row!(
        out,
        "get_sensor_info",
        format!("{:?}", make().get_sensor_info())
    );
    row!(out, "get_status", show(make().get_status().await));
    row!(
        out,
        "start_exposure",
        show(make().start_exposure(exposure(1, 1.0)).await)
    );
    row!(
        out,
        "start_exposure(bin 0)",
        show(make().start_exposure(exposure(0, 1.0)).await)
    );
    row!(
        out,
        "start_exposure(bin 99)",
        show(make().start_exposure(exposure(99, 1.0)).await)
    );
    row!(
        out,
        "start_exposure(-1 s)",
        show(make().start_exposure(exposure(1, -1.0)).await)
    );
    row!(out, "abort_exposure", show(make().abort_exposure().await));
    row!(
        out,
        "is_exposure_complete",
        show(make().is_exposure_complete().await)
    );
    row!(
        out,
        "download_image",
        show(
            make()
                .download_image()
                .await
                .map(|image| (image.width, image.height))
        )
    );
    row!(
        out,
        "set_cooler(on, -10)",
        show(make().set_cooler(true, Some(-10.0)).await)
    );
    row!(
        out,
        "set_cooler(on, 1e9)",
        show(make().set_cooler(true, Some(1e9)).await)
    );
    row!(
        out,
        "set_cooler(off)",
        show(make().set_cooler(false, None).await)
    );
    row!(out, "get_temperature", show(make().get_temperature().await));
    row!(
        out,
        "get_cooler_power",
        show(make().get_cooler_power().await)
    );
    row!(out, "set_gain(100)", show(make().set_gain(100).await));
    row!(out, "set_gain(-1)", show(make().set_gain(-1).await));
    row!(out, "get_gain", show(make().get_gain().await));
    row!(out, "set_offset(10)", show(make().set_offset(10).await));
    row!(out, "set_offset(-1)", show(make().set_offset(-1).await));
    row!(out, "get_offset", show(make().get_offset().await));
    row!(
        out,
        "set_binning(2,2)",
        show(make().set_binning(2, 2).await)
    );
    row!(
        out,
        "set_binning(0,0)",
        show(make().set_binning(0, 0).await)
    );
    row!(
        out,
        "set_binning(1,2)",
        show(make().set_binning(1, 2).await)
    );
    row!(
        out,
        "set_binning(99,99)",
        show(make().set_binning(99, 99).await)
    );
    row!(out, "get_binning", show(make().get_binning().await));
    row!(
        out,
        "set_subframe(None)",
        show(make().set_subframe(None).await)
    );
    row!(
        out,
        "set_subframe(8,8,64,64)",
        show(
            make()
                .set_subframe(Some(SubFrame {
                    start_x: 8,
                    start_y: 8,
                    width: 64,
                    height: 64
                }))
                .await
        )
    );
    row!(
        out,
        "set_subframe(0x0)",
        show(
            make()
                .set_subframe(Some(SubFrame {
                    start_x: 0,
                    start_y: 0,
                    width: 0,
                    height: 0
                }))
                .await
        )
    );
    row!(
        out,
        "get_readout_modes",
        show(make().get_readout_modes().await)
    );
    row!(
        out,
        "set_readout_mode",
        show(make().set_readout_mode(&readout_mode()).await)
    );
    row!(
        out,
        "get_vendor_features",
        show(make().get_vendor_features().await.map(SortedFeatures))
    );
    row!(out, "get_gain_range", show(make().get_gain_range().await));
    row!(
        out,
        "get_offset_range",
        show(make().get_offset_range().await)
    );
    row!(
        out,
        "get_recommended_settings",
        show(make().get_recommended_settings().await)
    );
    row!(
        out,
        "get_cooler_temp_range",
        show(make().get_cooler_temp_range().await)
    );
    row!(
        out,
        "get_exposure_range",
        show(make().get_exposure_range().await)
    );
    row!(
        out,
        "capture_preview",
        show(make().capture_preview().await.map(|bytes| bytes.len()))
    );
}

async fn focuser_rows<F: NativeFocuser>(out: &mut String, make: impl Fn() -> F) {
    row!(out, "vendor", format!("{:?}", make().vendor()));
    row!(out, "is_connected", make().is_connected());
    row!(
        out,
        "serial_number",
        format!("{:?}", make().serial_number())
    );
    row!(out, "disconnect", show(make().disconnect().await));
    row!(out, "move_to(100)", show(make().move_to(100).await));
    row!(out, "move_to(-1)", show(make().move_to(-1).await));
    row!(
        out,
        "move_relative(10)",
        show(make().move_relative(10).await)
    );
    row!(out, "get_position", show(make().get_position().await));
    row!(out, "is_moving", show(make().is_moving().await));
    row!(out, "halt", show(make().halt().await));
    row!(out, "get_temperature", show(make().get_temperature().await));
    row!(out, "get_max_position", make().get_max_position());
    row!(out, "get_step_size", make().get_step_size());
}

async fn wheel_rows<W: NativeFilterWheel>(out: &mut String, make: impl Fn() -> W) {
    row!(out, "vendor", format!("{:?}", make().vendor()));
    row!(out, "is_connected", make().is_connected());
    row!(
        out,
        "serial_number",
        format!("{:?}", make().serial_number())
    );
    row!(out, "disconnect", show(make().disconnect().await));
    row!(
        out,
        "move_to_position(1)",
        show(make().move_to_position(1).await)
    );
    row!(
        out,
        "move_to_position(-1)",
        show(make().move_to_position(-1).await)
    );
    row!(
        out,
        "move_to_position(99)",
        show(make().move_to_position(99).await)
    );
    row!(out, "get_position", show(make().get_position().await));
    row!(out, "is_moving", show(make().is_moving().await));
    row!(out, "get_filter_count", make().get_filter_count());
    row!(
        out,
        "get_filter_names",
        show(make().get_filter_names().await)
    );
    row!(
        out,
        "set_filter_name(0)",
        show(make().set_filter_name(0, "L".to_string()).await)
    );
    row!(
        out,
        "set_filter_name(99)",
        show(make().set_filter_name(99, "L".to_string()).await)
    );
}

async fn record() -> String {
    let mut out = String::new();
    macro_rules! section {
        ($title:expr, $sdk_present:expr, $rows:ident, $make:expr) => {
            if $sdk_present {
                eprintln!("{}: SDK installed on this machine, skipped", $title);
            } else {
                writeln!(out, "[{}]", $title).unwrap();
                $rows(&mut out, $make).await;
            }
        };
    }
    section!("zwo camera", zwo::is_sdk_available(), camera_rows, || {
        zwo::ZwoCamera::new(0)
    });
    section!(
        "zwo focuser",
        zwo::is_eaf_sdk_available(),
        focuser_rows,
        || zwo::ZwoFocuser::new(0)
    );
    section!(
        "zwo filter wheel",
        zwo::is_efw_sdk_available(),
        wheel_rows,
        || { zwo::ZwoFilterWheel::new(0) }
    );
    section!("qhy camera", qhy::is_sdk_available(), camera_rows, || {
        qhy::QhyCamera::new("QHY268M-0123456789".to_string())
    });
    section!(
        "qhy filter wheel",
        qhy::is_sdk_available(),
        wheel_rows,
        || { qhy::QhyFilterWheel::new("QHY268M-0123456789".to_string()) }
    );
    section!(
        "player one camera",
        player_one::is_sdk_available(),
        camera_rows,
        || { player_one::PlayerOneCamera::new(0) }
    );
    section!(
        "player one filter wheel",
        player_one::is_pw_sdk_available(),
        wheel_rows,
        || { player_one::PlayerOneFilterWheel::new(0) }
    );
    section!(
        "svbony camera",
        svbony::is_sdk_available(),
        camera_rows,
        || { svbony::SvbonyCamera::new(0) }
    );
    section!("atik camera", atik::is_sdk_available(), camera_rows, || {
        atik::AtikCamera::new(0)
    });
    section!(
        "atik filter wheel",
        atik::is_sdk_available(),
        wheel_rows,
        || { atik::AtikFilterWheel::new(0) }
    );
    section!("fli camera", fli::is_sdk_available(), camera_rows, || {
        fli::FliCamera::new("/dev/fliusb0".to_string())
    });
    section!("fli focuser", fli::is_sdk_available(), focuser_rows, || {
        fli::FliFocuser::new("/dev/fliusb1".to_string())
    });
    section!(
        "fli filter wheel",
        fli::is_sdk_available(),
        wheel_rows,
        || { fli::FliFilterWheel::new("/dev/fliusb2".to_string()) }
    );
    section!(
        "touptek camera",
        touptek::is_sdk_available(),
        camera_rows,
        || { touptek::TouptekCamera::new(0, "ogma") }
    );
    section!(
        "moravian camera",
        moravian::is_sdk_available(),
        camera_rows,
        || { moravian::MoravianCamera::new(0) }
    );
    section!(
        "gphoto2 camera",
        gphoto2::is_sdk_available(),
        camera_rows,
        || { gphoto2::GPhoto2Camera::new(0, "Canon EOS 6D", "usb:001,004") }
    );
    out
}

#[tokio::test]
async fn disconnected_drivers_answer_as_recorded() {
    let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/disconnected_contract.txt");
    let actual = record().await;
    if std::env::var_os("UPDATE_DISCONNECTED_CONTRACT").is_some() {
        std::fs::write(&fixture, &actual).expect("write fixture");
        return;
    }
    let expected = std::fs::read_to_string(&fixture).expect("read fixture");
    // A skipped vendor has no section in `actual`; compare only the sections present.
    let mut expected_kept = String::new();
    let mut keep = true;
    for line in expected.lines() {
        if line.starts_with('[') {
            keep = actual.contains(&format!("{}\n", line));
        }
        if keep {
            expected_kept.push_str(line);
            expected_kept.push('\n');
        }
    }
    if actual != expected_kept {
        for (a, e) in actual.lines().zip(expected_kept.lines()) {
            if a != e {
                eprintln!("recorded: {}\nnow:      {}\n", e, a);
            }
        }
        panic!("a disconnected driver answers differently from the recorded contract");
    }
}
