//! Camera operations dispatcher.
//!
//! Methods in this module are an additional impl block on `DeviceManager`
//! using Rust's split-impl-block feature.
//!
//! # `as`-cast policy
//!
//! Numeric casts in this file cluster into:
//! - **INDI wire f64 ↔ device numeric** (lines 118, 121, 125, 127, 937,
//!   1002, 1078, 1081): INDI represents every numeric property as `f64`
//!   over XML; i32/u32/u16 → f64 is exact widening. The reverse direction
//!   `v as i32 / u32` (lines 754, 764, 791, 801, 829, 844, 845) is bounded
//!   by INDI driver-advertised min/max ranges (gain/offset/bin are all
//!   small integers; max_adu fits u32 for any current sensor). Saturation
//!   on out-of-range surfaces as the displayed-zero baseline from the
//!   companion `unwrap_or(0)` policy below.
//! - **Sensor dimensions i32 → u32** (lines 374, 381, 675, 676): ASCOM
//!   CameraXSize/YSize are int (i32) ≥ 1 by spec; the upstream Option
//!   filter strips the None case. Negative would round to giant u32 and
//!   immediately fail buffer-sizing.
//! - **max_adu i32 → u32** (line 679): MaxADU is i32 by ASCOM spec but
//!   physically u32-sized (≤ 4_294_967_295 for 32-bit sensors); positive
//!   i32 narrows-and-widens cleanly to u32.
//! - **Readout mode index i32 → usize** (lines 1180, 1181): preceded by
//!   `mode_index >= 0` check; non-negative i32 → usize is widening on every
//!   supported target.
//!
//! Sites with a local `Why:` comment override the module-level reasoning.
//!
//! # `unwrap_or` policy
//!
//! All `unwrap_or` sites in this module are dimension/state composition
//! steps that flatten `Option<T>` values from optional ASCOM probes into
//! a flat `CameraInfo`/`CameraStatus`. Defaults:
//!
//! * sensor dimensions (`sensor_width`, `sensor_height`) → 0 when the
//!   ASCOM driver did not provide a value; the UI distinguishes "no
//!   sensor info" from "1×1 sensor" by checking the `can_*` booleans.
//! * `pixel_size_x/y` → 0.0 → "unknown" in UI scale bars.
//! * `max_adu` → `65535` — the 16-bit max representable in standard ASCOM
//!   camera readouts; safe default for histogram scaling.
//! * boolean caps (`can_cool`, `cooler_on`) → `false` — feature-not-declared.
//! * `gain`/`offset` → 0 — bottom of the legal ASCOM gain table; user
//!   adjusts via the gain UI before exposing.
//!
//! `set_cooler` has **no** default target. A "turn the cooler off" command
//! carries no setpoint, and substituting one (`target_temp.unwrap_or(-10.0)`)
//! pushes a `SetCCDTemperature` write at the driver on the way past — which
//! throws on a camera reporting `CanSetCCDTemperature = False`, and does so
//! before the `CoolerOn` write, so the cooler cannot be switched off at all.
//! The `Option` is carried all the way down to each driver, and
//! [`DeviceManager::cooler_setpoint_to_command`] drops it when the cooler is
//! being switched off.
//!
//! Connection-level errors are not silenced here; this layer composes
//! values *after* `with_camera!` has already established the device path.

use crate::device::*;
use crate::device_manager::DeviceManager;
use crate::dispatch::DeviceOpError;
use skotiq_native::camera::{ExposureParams, ImageData, SubFrame};
#[cfg(windows)]
use skotiq_native::traits::NativeCamera;
use std::sync::Arc;
use tracing::warn;

/// Sentinel meaning "this camera setting could not be read".
///
/// `ImageMetadata.gain`/`offset` are plain `i32` (unlike `temperature`, which is
/// already `Option`) and are constructed by every vendor driver, so widening
/// them to `Option` would be a large refactor of code that is not at fault.
/// Real gain/offset values are never negative, so a negative marker is
/// unambiguous, and [`camera_setting_or_unknown`] converts it back to `None` at
/// the one boundary that feeds FITS metadata.
pub(crate) const UNKNOWN_CAMERA_SETTING: i32 = -1;

/// `None` when a camera setting was recorded as unreadable, else `Some(value)`.
///
/// Keeps a failed device read from outranking the operator's configured value in
/// `image_data.gain.or(config.gain)`.
pub(crate) fn camera_setting_or_unknown(value: i32) -> Option<i32> {
    if value <= UNKNOWN_CAMERA_SETTING {
        None
    } else {
        Some(value)
    }
}

/// Parse the integer value out of a fixed-format 80-byte FITS header card.
///
/// FITS mandates `KEYWORD = value / comment` with the value right-justified in
/// bytes 10..30, so splitting on `=` and taking everything before any `/` is
/// sufficient — no full FITS parser needed for NAXIS1/NAXIS2. Returns `None`
/// for a malformed card so the caller can fall back rather than trust a guess.
fn parse_fits_card_u32(card: &[u8]) -> Option<u32> {
    let text = std::str::from_utf8(card).ok()?;
    let after_eq = text.split_once('=')?.1;
    let value = after_eq.split('/').next()?.trim();
    value.parse::<u32>().ok()
}

// The simulated sky and the plate scale it hangs off now live in
// `crate::sim_capture`, next to the renderer, so the Imaging screen's manual
// capture and this sequencer download cannot drift apart. Imported here only
// for the tests below, which pin their behaviour.
#[cfg(test)]
use crate::sim_capture::{
    sim_plate_scale_arcsec_per_px, sim_sky_view, SIM_DEFAULT_FOCAL_LENGTH_MM,
};

pub(crate) mod download;
pub(crate) mod exposure;
pub(crate) mod settings;
pub(crate) mod status;
#[cfg(test)]
mod fits_card_tests {
    use super::parse_fits_card_u32;

    /// These two cards are the verbatim 80-byte headers from a BLOB captured off
    /// a live `indi_simulator_ccd` at 2x2 binning, where CCD_INFO advertised the
    /// unbinned 1280x1024 while the frame was really 640x512. Reading NAXIS is
    /// what keeps those two facts from being confused.
    #[test]
    fn parses_naxis_cards_from_a_real_indi_blob() {
        let naxis1 =
            b"NAXIS1  =                  640 / length of data axis 1                          ";
        let naxis2 =
            b"NAXIS2  =                  512 / length of data axis 2                          ";
        assert_eq!(parse_fits_card_u32(naxis1), Some(640));
        assert_eq!(parse_fits_card_u32(naxis2), Some(512));
    }

    #[test]
    fn rejects_cards_it_cannot_trust() {
        // No '=', a non-numeric value, and a float value all fall back to None
        // so the caller keeps its own dimensions instead of using a bad parse.
        assert_eq!(parse_fits_card_u32(b"COMMENT no equals sign here"), None);
        assert_eq!(
            parse_fits_card_u32(b"NAXIS1  =                    T / bad"),
            None
        );
        assert_eq!(
            parse_fits_card_u32(b"NAXIS1  =                 6.40 / float"),
            None
        );
        assert_eq!(
            parse_fits_card_u32(b"NAXIS1  =                   -1 / negative"),
            None
        );
    }

    #[test]
    fn parses_a_card_with_no_comment() {
        assert_eq!(
            parse_fits_card_u32(b"NAXIS1  =                 4144"),
            Some(4144)
        );
    }

    /// A gain of 0 is a LEGITIMATE setting (unity gain on many cameras), so the
    /// unknown marker must be distinguishable from it — that conflation is what
    /// let a failed read outrank the operator's configured gain.
    #[test]
    fn unknown_camera_setting_is_distinct_from_a_real_zero() {
        use super::{camera_setting_or_unknown, UNKNOWN_CAMERA_SETTING};

        assert_eq!(camera_setting_or_unknown(UNKNOWN_CAMERA_SETTING), None);
        assert_eq!(camera_setting_or_unknown(0), Some(0));
        assert_eq!(camera_setting_or_unknown(139), Some(139));
        // `.or(config)` only falls through on None, which is the whole point.
        assert_eq!(
            camera_setting_or_unknown(UNKNOWN_CAMERA_SETTING).or(Some(120)),
            Some(120)
        );
        assert_eq!(camera_setting_or_unknown(0).or(Some(120)), Some(0));
    }
}

#[cfg(test)]
mod sim_camera_tests {
    use crate::api::devices::simulation::{
        clear_sim_exposure, get_sim_camera, sim_singleton_test_lock,
    };
    use crate::api::get_device_manager;
    use crate::device::{CameraState, DeviceInfo, DeviceType, DriverType};
    use skotiq_native::camera::FrameType;

    /// `expect_err` on a `Result<ImageData, _>` would dump a whole 1920x1080
    /// frame into the failure output, which buries the assertion.
    async fn download_error(device_id: &str, why: &str) -> String {
        match get_device_manager().camera_download_image(device_id).await {
            Ok(image) => panic!(
                "{why}, yet a complete {}x{} frame was returned \
                 (metadata claims a {}s exposure)",
                image.width, image.height, image.metadata.exposure_time
            ),
            Err(e) => e.to_string(),
        }
    }

    async fn attach_sim_camera(device_id: &str) {
        let info = DeviceInfo {
            id: device_id.to_string(),
            name: "Simulated Camera".to_string(),
            device_type: DeviceType::Camera,
            driver_type: DriverType::Simulator,
            description: "Simulated camera".to_string(),
            driver_version: "1.0".to_string(),
            serial_number: None,
            unique_id: None,
            display_name: "Simulated Camera".to_string(),
        };
        get_device_manager().register_device(info, false).await;
        get_sim_camera().write().await.status.connected = true;
        clear_sim_exposure().await;
    }

    /// `camera_get_status` and `camera_is_exposure_complete` are polled by the
    /// same UI and must never contradict each other. The status arm reported
    /// `Idle` throughout a running exposure while the completion arm said "not
    /// yet", so the dashboard showed an idle camera mid-frame and no progress
    /// UI could be exercised without hardware.
    #[tokio::test]
    async fn status_walks_the_exposure_state_machine() {
        let _serialized = sim_singleton_test_lock().lock().await;
        let device_id = "sim_camera_state_machine";
        attach_sim_camera(device_id).await;
        let mgr = get_device_manager();

        assert_eq!(
            mgr.camera_get_status(device_id).await.unwrap().state,
            CameraState::Idle,
            "a camera with no exposure in flight is idle"
        );

        mgr.camera_start_exposure(device_id, 0.4, None, None, 1, 1, FrameType::Light)
            .await
            .expect("simulated exposure should start");

        let mid = mgr.camera_get_status(device_id).await.unwrap();
        assert!(
            !mgr.camera_is_exposure_complete(device_id).await.unwrap(),
            "0.4s exposure cannot be complete immediately"
        );
        assert_eq!(
            mid.state,
            CameraState::Exposing,
            "status said {:?} while the exposure was still integrating",
            mid.state
        );

        tokio::time::sleep(std::time::Duration::from_millis(500)).await;
        assert!(mgr.camera_is_exposure_complete(device_id).await.unwrap());
        assert_eq!(
            mgr.camera_get_status(device_id).await.unwrap().state,
            CameraState::Reading,
            "an integrated but undownloaded frame is waiting to be read out"
        );

        mgr.camera_download_image(device_id)
            .await
            .expect("a completed exposure should download");
        assert_eq!(
            mgr.camera_get_status(device_id).await.unwrap().state,
            CameraState::Idle,
            "the camera returns to idle once the frame has been read out"
        );
    }

    /// Downloading mid-exposure returned a complete frame stamped with the full
    /// requested `EXPTIME`. A caller that skipped (or raced) the completion poll
    /// therefore wrote a FITS file whose header was a lie about how long the
    /// sensor had integrated.
    #[tokio::test]
    async fn download_before_completion_is_refused() {
        let _serialized = sim_singleton_test_lock().lock().await;
        let device_id = "sim_camera_early_download";
        attach_sim_camera(device_id).await;
        let mgr = get_device_manager();

        mgr.camera_start_exposure(device_id, 3.0, None, None, 1, 1, FrameType::Light)
            .await
            .unwrap();
        assert!(!mgr.camera_is_exposure_complete(device_id).await.unwrap());

        let err = download_error(device_id, "the exposure was still integrating").await;
        assert!(
            err.contains("still integrating"),
            "expected a not-ready error, got: {err}"
        );

        mgr.camera_abort_exposure(device_id).await.unwrap();
    }

    /// An aborted exposure has no frame to hand back. Returning one made abort
    /// indistinguishable from success, so a cancelled sequence still produced
    /// a saved light frame.
    #[tokio::test]
    async fn download_after_abort_is_refused() {
        let _serialized = sim_singleton_test_lock().lock().await;
        let device_id = "sim_camera_aborted_download";
        attach_sim_camera(device_id).await;
        let mgr = get_device_manager();

        mgr.camera_start_exposure(device_id, 5.0, None, None, 1, 1, FrameType::Light)
            .await
            .unwrap();
        mgr.camera_abort_exposure(device_id).await.unwrap();

        assert_eq!(
            mgr.camera_get_status(device_id).await.unwrap().state,
            CameraState::Idle,
            "an aborted camera is idle, not still exposing"
        );
        let err = download_error(device_id, "the exposure was aborted").await;
        assert!(
            err.contains("aborted"),
            "expected an abort error, got: {err}"
        );
    }

    /// Aborting must still release a caller that is waiting on completion —
    /// the refusal above applies to the download, not to the poll loop.
    #[tokio::test]
    async fn abort_releases_a_waiting_poller() {
        let _serialized = sim_singleton_test_lock().lock().await;
        let device_id = "sim_camera_abort_releases";
        attach_sim_camera(device_id).await;
        let mgr = get_device_manager();

        mgr.camera_start_exposure(device_id, 30.0, None, None, 1, 1, FrameType::Light)
            .await
            .unwrap();
        assert!(!mgr.camera_is_exposure_complete(device_id).await.unwrap());
        mgr.camera_abort_exposure(device_id).await.unwrap();
        assert!(
            mgr.camera_is_exposure_complete(device_id).await.unwrap(),
            "abort must not strand a poll loop waiting out the original duration"
        );
    }

    /// Downloading without having started anything is a caller bug, not an
    /// invitation to synthesize a frame out of the last request's parameters.
    #[tokio::test]
    async fn download_without_an_exposure_is_refused() {
        let _serialized = sim_singleton_test_lock().lock().await;
        let device_id = "sim_camera_no_exposure";
        attach_sim_camera(device_id).await;

        let err = download_error(device_id, "no exposure had been started").await;
        assert!(
            err.contains("No exposure"),
            "expected a no-exposure error, got: {err}"
        );
    }
}

/// The seam between the simulated mount's pointing and the frame the simulated
/// camera hands back.
#[cfg(test)]
mod sim_sky_wiring_tests {
    use super::*;
    use crate::api::devices::simulation::{
        clear_sim_exposure, get_sim_camera, get_sim_mount, sim_singleton_test_lock,
    };
    use crate::api::get_device_manager;
    use crate::device::{DeviceInfo, DeviceType, DriverType};
    use skotiq_native::camera::FrameType;

    /// The declared simulated rig: 3.76 um pixels behind the default 1000 mm
    /// profile. If this number moves, every rendered field is at a scale the
    /// solver's own hint contradicts.
    #[test]
    fn plate_scale_matches_the_declared_simulated_rig() {
        let scale = sim_plate_scale_arcsec_per_px(3.76, 1000.0);
        assert!((scale - 0.7756).abs() < 0.001, "{scale}");
        // Halving the focal length doubles the scale, and the wide end matches
        // the reference probe's 5.74"/px at 135 mm.
        assert!((sim_plate_scale_arcsec_per_px(3.76, 500.0) - 2.0 * scale).abs() < 1e-9);
        assert!((sim_plate_scale_arcsec_per_px(3.76, 135.0) - 5.744).abs() < 0.001);
    }

    /// A rig with no mount keeps the pseudo-random field.
    ///
    /// This is the guard on the whole change: the sim's own suite measures star
    /// counts, HFR and the autofocus V-curve against that field, so a camera-only
    /// rig — which has no pointing to render — must never be switched onto a
    /// catalogue sky.
    #[tokio::test]
    async fn a_rig_with_no_mount_gets_no_sky_view() {
        let _serialized = sim_singleton_test_lock().lock().await;
        get_sim_mount().write().await.status.connected = false;
        assert!(
            sim_sky_view(3.76, crate::sim_frame::SIM_W, crate::sim_frame::SIM_H)
                .await
                .is_none(),
            "a disconnected mount must not produce a pointing"
        );
    }

    /// A nonsense pixel size is not a pointing either.
    #[tokio::test]
    async fn an_unreadable_pixel_size_gets_no_sky_view() {
        let _serialized = sim_singleton_test_lock().lock().await;
        get_sim_mount().write().await.status.connected = true;
        for bad in [0.0, -3.76, f64::NAN] {
            assert!(
                sim_sky_view(bad, crate::sim_frame::SIM_W, crate::sim_frame::SIM_H)
                    .await
                    .is_none(),
                "pixel size {bad} must not produce a plate scale"
            );
        }
        get_sim_mount().write().await.status.connected = false;
    }

    /// The capture-path wiring, on CI.
    ///
    /// `a_downloaded_simulator_frame_solves_at_the_mounts_pointing` below is the
    /// stronger proof, but it is `#[ignore]`d because it needs `astap_cli` and a
    /// real star database — which left the single line that attaches the sky view
    /// to the frame request unguarded on every machine that does not have them.
    /// Replacing that line with `sky: None` kept all 498 default tests green.
    ///
    /// This test needs neither binary nor database: it synthesises its own area
    /// file and drives the real parser, index, cap lookup, TAN projection and
    /// renderer through `camera_download_image`. Sever the wiring and it fails.
    #[tokio::test]
    async fn a_downloaded_frame_carries_the_catalogue_field() {
        let _serialized = sim_singleton_test_lock().lock().await;

        // A grid of catalogue stars centred on the pointing, spaced ~90 px at the
        // simulated rig's 0.776"/px so the detector resolves them individually.
        let ra_hours = 5.59_f64;
        let dec_deg = -5.39_f64;
        let ra_deg = ra_hours * 15.0;
        let step_deg =
            90.0 * sim_plate_scale_arcsec_per_px(3.76, SIM_DEFAULT_FOCAL_LENGTH_MM) / 3600.0;
        let mut stars = Vec::new();
        for row in -4i32..=4 {
            for col in -8i32..=8 {
                stars.push((
                    ra_deg + f64::from(col) * step_deg / dec_deg.to_radians().cos(),
                    dec_deg + f64::from(row) * step_deg,
                    9.0 + f64::from((row + col).rem_euclid(5)),
                ));
            }
        }
        let catalog = tempfile::TempDir::new().unwrap();
        crate::sim_sky::astap_integration::write_synthetic_area(
            &catalog.path().join("d05_0001.1476"),
            &stars,
        );

        // Exactly what the Plate Solving settings screen writes. The store is
        // shared and process-lifetime on purpose — see
        // `sim_capture::shared_platesolver_store`.
        crate::sim_capture::shared_platesolver_store();
        let previous = crate::state::get_platesolver_preference().unwrap_or_default();
        crate::state::save_platesolver_preference(&crate::storage::PlateSolverPreference {
            catalog_path: catalog.path().to_string_lossy().to_string(),
            ..previous.clone()
        })
        .expect("save plate-solver preference");

        {
            // The simulated mount keeps coordinates of date; point it at the
            // J2000 field the way a slew would.
            let (mount_ra, mount_dec) = crate::device_manager::epoch::j2000_to_mount_frame(
                DriverType::Simulator,
                ra_hours,
                dec_deg,
            );
            let mut mount = get_sim_mount().write().await;
            mount.status.connected = true;
            mount.status.right_ascension = mount_ra;
            mount.status.declination = mount_dec;
        }
        // So the field sits where the projection puts it rather than where an
        // earlier test's accumulated drift left it.
        crate::api::devices::simulation::reset_sim_guide_offset().await;

        let device_id = "sim_camera_sky_wiring";
        let info = DeviceInfo {
            id: device_id.to_string(),
            name: "Simulated Camera".to_string(),
            device_type: DeviceType::Camera,
            driver_type: DriverType::Simulator,
            description: "Simulated camera".to_string(),
            driver_version: "1.0".to_string(),
            serial_number: None,
            unique_id: None,
            display_name: "Simulated Camera".to_string(),
        };
        let mgr = get_device_manager();
        mgr.register_device(info, false).await;
        get_sim_camera().write().await.status.connected = true;
        clear_sim_exposure().await;

        mgr.camera_start_exposure(device_id, 1.0, None, None, 1, 1, FrameType::Light)
            .await
            .expect("start exposure");
        while !mgr.camera_is_exposure_complete(device_id).await.unwrap() {
            tokio::time::sleep(std::time::Duration::from_millis(25)).await;
        }
        let image = mgr
            .camera_download_image(device_id)
            .await
            .expect("download frame");

        // Put the singletons back before asserting, so a failure here does not
        // leave a catalogue sky armed for every other simulator test.
        get_sim_mount().write().await.status.connected = false;
        get_sim_camera().write().await.status.connected = false;
        let _ = crate::state::save_platesolver_preference(&previous);

        let data =
            skotiq_imaging::ImageData::from_u16(image.width, image.height, 1, &image.data);
        let found = skotiq_imaging::detect_stars_with_stats(
            &data,
            &skotiq_imaging::StarDetectionConfig::default(),
        );
        assert!(
            found.stars.len() > 60,
            "the downloaded frame carried {} stars; the catalogue grid holds {} and \
             the pseudo-random fallback exactly 45, so the sky view never reached \
             the frame request",
            found.stars.len(),
            stars.len()
        );

        // Placed by the projection, not merely present: the grid's centre star
        // sits at the tangent point, which lands on the sensor's centre pixel at
        // any plate scale.
        let centre_x = f64::from(image.width) / 2.0;
        let centre_y = f64::from(image.height) / 2.0;
        let nearest = found
            .stars
            .iter()
            .map(|star| (star.x - centre_x).hypot(star.y - centre_y))
            .fold(f64::MAX, f64::min);
        assert!(
            nearest < 12.0,
            "nearest star to the frame centre is {nearest:.1} px away; the rendered \
             field is not the one the mount is pointing at"
        );
    }

    /// The whole point, end to end: a frame DOWNLOADED FROM THE SIMULATED CAMERA
    /// solves against the real ASTAP binary at the pointing the mount reports.
    ///
    /// Ignored by default because it needs `astap_cli` and a star database. Run
    /// it the same way as the renderer-level test:
    ///
    /// ```text
    /// SKOTIQ_SIM_SKY_ASTAP_DIR=~/.local/share/skotiq-audit/astap/bin \
    ///   cargo test -p skotiq_bridge --lib sim_sky_wiring -- --ignored --nocapture
    /// ```
    #[tokio::test]
    #[ignore = "needs astap_cli and a star database; see the doc comment to run it"]
    async fn a_downloaded_simulator_frame_solves_at_the_mounts_pointing() {
        use crate::sim_sky::astap_integration::{astap_dir, read_crval, write_fits, PIXEL_UM};

        let _serialized = sim_singleton_test_lock().lock().await;
        let dir = astap_dir();
        let binary = dir.join("astap_cli");
        assert!(
            binary.exists(),
            "no astap_cli in {dir:?}; set SKOTIQ_SIM_SKY_ASTAP_DIR"
        );

        // Point the app's plate-solver preference at the same database, which is
        // exactly what the settings screen writes.
        let store = tempfile::TempDir::new().unwrap();
        let _ = crate::state::init_platesolver_storage(store.path().to_path_buf());
        let previous = crate::state::get_platesolver_preference().unwrap_or_default();
        crate::state::save_platesolver_preference(&crate::storage::PlateSolverPreference {
            astap_path: binary.to_string_lossy().to_string(),
            catalog_path: dir.to_string_lossy().to_string(),
            ..previous.clone()
        })
        .expect("save plate-solver preference");

        // M42, and a mount that says so.
        let ra_hours = 5.59_f64;
        let dec_deg = -5.39_f64;
        {
            // The simulated mount keeps coordinates of date; point it at the
            // J2000 field the way a slew would.
            let (mount_ra, mount_dec) = crate::device_manager::epoch::j2000_to_mount_frame(
                DriverType::Simulator,
                ra_hours,
                dec_deg,
            );
            let mut mount = get_sim_mount().write().await;
            mount.status.connected = true;
            mount.status.right_ascension = mount_ra;
            mount.status.declination = mount_dec;
        }

        let device_id = "sim_camera_sky_solve";
        let info = DeviceInfo {
            id: device_id.to_string(),
            name: "Simulated Camera".to_string(),
            device_type: DeviceType::Camera,
            driver_type: DriverType::Simulator,
            description: "Simulated camera".to_string(),
            driver_version: "1.0".to_string(),
            serial_number: None,
            unique_id: None,
            display_name: "Simulated Camera".to_string(),
        };
        let mgr = get_device_manager();
        mgr.register_device(info, false).await;
        get_sim_camera().write().await.status.connected = true;
        clear_sim_exposure().await;

        mgr.camera_start_exposure(device_id, 0.3, None, None, 1, 1, FrameType::Light)
            .await
            .expect("start exposure");
        while !mgr.camera_is_exposure_complete(device_id).await.unwrap() {
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        }
        let image = mgr
            .camera_download_image(device_id)
            .await
            .expect("download frame");

        // Put the singletons back before asserting, so a failure here does not
        // leave a catalogue sky armed for every other simulator test.
        get_sim_mount().write().await.status.connected = false;
        get_sim_camera().write().await.status.connected = false;
        let _ = crate::state::save_platesolver_preference(&previous);

        let scratch = tempfile::TempDir::new().unwrap();
        let path = scratch.path().join("downloaded.fits");
        write_fits(&path, &image.data, ra_hours, dec_deg, 1000.0);
        let base = path.with_extension("");
        let scale = sim_plate_scale_arcsec_per_px(PIXEL_UM, 1000.0);
        let fov_h_deg = scale * f64::from(image.height) / 3600.0;
        let output = std::process::Command::new(&binary)
            .args([
                "-f".into(),
                path.to_string_lossy().to_string(),
                "-r".into(),
                "10".into(),
                "-fov".into(),
                format!("{fov_h_deg:.4}"),
                "-ra".into(),
                format!("{ra_hours:.5}"),
                "-spd".into(),
                format!("{:.5}", dec_deg + 90.0),
                "-d".into(),
                dir.to_string_lossy().to_string(),
                "-o".into(),
                base.to_string_lossy().to_string(),
                "-wcs".into(),
            ])
            .output()
            .expect("run astap_cli");

        let (solved_ra, solved_dec) = read_crval(&base).unwrap_or_else(|| {
            panic!(
                "the downloaded simulator frame did not solve:\n{}",
                String::from_utf8_lossy(&output.stdout).trim()
            )
        });
        let error_arcsec = ((solved_ra - ra_hours * 15.0) * dec_deg.to_radians().cos())
            .hypot(solved_dec - dec_deg)
            * 3600.0;
        println!("downloaded frame solved, centre error {error_arcsec:.1}\"");
        assert!(
            error_arcsec < scale,
            "solved centre {error_arcsec:.1}\" from the mount's pointing, over one \
             {scale:.2}\" pixel"
        );
    }
}
