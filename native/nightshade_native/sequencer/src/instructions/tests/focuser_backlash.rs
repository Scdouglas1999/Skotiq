//! Backlash calibration end to end, against a simulated gear train.
//!
//! The unit tests in `crate::focuser_calibration` hold the arithmetic and its
//! refusals to account on fixed point sets. These drive the whole routine —
//! focuser moves, exposures, real star detection, real HFR measurement, the
//! real curve fitters — against a focuser with a dead band of known width, and
//! check that what comes out is that width.
//!
//! The simulated focuser implements the model documented in
//! `crate::focuser_calibration`: optical position `a = c + d` with
//! `d` in `[0, b]`, driven to 0 by upward motion and to `b` by downward
//! motion. Testing against the model would be circular were the model not
//! also what the owner's hardware did on 2026-09-14 — 6620 from below, 6515
//! from above, 105 apart — which is the fact these tests encode.

use super::*;

use std::sync::Arc;
use tokio::sync::Mutex as AsyncMutex;

/// Backlash the simulated focuser has, in steps: the figure the owner
/// measured on his ZWO EAF near position 6600 on 2026-09-14.
const SIMULATED_BACKLASH: i32 = 105;

/// Where the simulated optics are actually in focus, in optical steps.
const TRUE_OPTICAL_FOCUS: i32 = 6620;

/// Rough focus the operator starts the calibration from. Deliberately not
/// true focus — nobody starts there, and the scan has to bracket focus from
/// wherever they actually are.
const STARTING_POSITION: i32 = 6600;

/// Star PSF sigma at perfect focus, in pixels. Gives a measured HFR near 2,
/// comfortably above the detector's `min_hfr` of 1.0.
const FOCUSED_SIGMA_PX: f64 = 1.7;

/// How fast the PSF grows with defocus, in sigma-pixels per step squared.
/// Quadratic in defocus so the HFR curve the routine fits is a parabola,
/// which is the model it uses; 180 steps out gives sigma ~6.8 (HFR ~8),
/// matching the depth of the owner's own sweep.
const SIGMA_PER_STEP_SQUARED: f64 = 1.574e-4;

/// Frame geometry. Small and sparse so 60-odd exposures of real star
/// detection stay fast, and so no two PSFs can merge into one blob at the
/// widest defocus the scan reaches.
const FRAME_SIZE_PX: u32 = 320;
const STAR_POSITIONS_PX: &[(f64, f64)] =
    &[(85.0, 85.0), (235.0, 85.0), (85.0, 235.0), (235.0, 235.0)];
const BACKGROUND_ADU: f64 = 1000.0;
const STAR_PEAK_ADU: f64 = 30000.0;
/// Background noise. Needed, and not decoration: star detection thresholds
/// at `background + 5 * noise`, so a perfectly flat frame gives a threshold
/// sitting on the background and every PSF wing joins its neighbours into one
/// enormous blob.
const NOISE_SIGMA_ADU: f64 = 25.0;

/// A focuser whose drive train has a dead band, wrapped around the standard
/// test double for everything else.
struct BacklashFocuserOps {
    inner: NullDeviceOps,
    state: Arc<AsyncMutex<GearState>>,
    backlash: i32,
}

struct GearState {
    /// Commanded position.
    commanded: i32,
    /// How much of the dead band is taken up: 0 after upward motion, the full
    /// backlash after downward motion.
    takeup: i32,
    /// Every position the focuser was commanded to, in order, so a test can
    /// check HOW it was approached and not merely where it ended up.
    commands: Vec<i32>,
    /// `(commanded, takeup)` at every exposure, in order.
    exposures: Vec<(i32, i32)>,
    /// Exposures after this many come back starless, as under cloud.
    clouded_after: Option<usize>,
}

impl BacklashFocuserOps {
    fn new(backlash: i32, starting_position: i32) -> Self {
        Self {
            inner: NullDeviceOps,
            state: Arc::new(AsyncMutex::new(GearState {
                commanded: starting_position,
                // Start mid-band: the operator's last move could have been
                // either way, and the routine must not depend on it.
                takeup: backlash / 2,
                commands: Vec::new(),
                exposures: Vec::new(),
                clouded_after: None,
            })),
            backlash,
        }
    }

    fn state(&self) -> Arc<AsyncMutex<GearState>> {
        Arc::clone(&self.state)
    }
}

#[async_trait]
impl DeviceOps for BacklashFocuserOps {
    async fn focuser_move_to(&self, _focuser_id: &str, position: i32) -> DeviceResult<()> {
        let mut state = self.state.lock().await;
        let delta = position - state.commanded;
        // Upward motion pays down the dead band; downward motion fills it. A
        // move shorter than the remaining slack only moves the motor.
        state.takeup = (state.takeup - delta).clamp(0, self.backlash);
        state.commanded = position;
        state.commands.push(position);
        Ok(())
    }

    async fn focuser_get_position(&self, _focuser_id: &str) -> DeviceResult<i32> {
        Ok(self.state.lock().await.commanded)
    }

    async fn focuser_is_moving(&self, _focuser_id: &str) -> DeviceResult<bool> {
        Ok(false)
    }

    async fn focuser_get_temperature(&self, _focuser_id: &str) -> DeviceResult<Option<f64>> {
        Ok(Some(11.5))
    }

    async fn focuser_halt(&self, _focuser_id: &str) -> DeviceResult<()> {
        Ok(())
    }

    async fn camera_start_exposure(
        &self,
        _camera_id: &str,
        duration_secs: f64,
        gain: Option<i32>,
        offset: Option<i32>,
        _bin_x: i32,
        _bin_y: i32,
    ) -> DeviceResult<ImageData> {
        let (optical_position, clouded) = {
            let mut state = self.state.lock().await;
            let sample = (state.commanded, state.takeup);
            state.exposures.push(sample);
            let clouded = state
                .clouded_after
                .is_some_and(|after| state.exposures.len() > after);
            (state.commanded + state.takeup, clouded)
        };
        Ok(render_star_field(
            optical_position,
            !clouded,
            duration_secs,
            gain,
            offset,
        ))
    }

    // Everything the calibration does not touch falls through to the standard
    // test double. `DeviceOps` has no blanket default for these, so the
    // delegation is spelled out the same way the in-crate scripted doubles do.
    async fn mount_slew_to_coordinates(
        &self,
        mount_id: &str,
        ra_hours: f64,
        dec_degrees: f64,
    ) -> DeviceResult<()> {
        self.inner
            .mount_slew_to_coordinates(mount_id, ra_hours, dec_degrees)
            .await
    }
    async fn mount_abort_slew(&self, mount_id: &str) -> DeviceResult<()> {
        self.inner.mount_abort_slew(mount_id).await
    }
    async fn mount_get_coordinates(&self, mount_id: &str) -> DeviceResult<(f64, f64)> {
        self.inner.mount_get_coordinates(mount_id).await
    }
    async fn mount_sync(
        &self,
        mount_id: &str,
        ra_hours: f64,
        dec_degrees: f64,
    ) -> DeviceResult<()> {
        self.inner.mount_sync(mount_id, ra_hours, dec_degrees).await
    }
    async fn mount_park(&self, mount_id: &str) -> DeviceResult<()> {
        self.inner.mount_park(mount_id).await
    }
    async fn mount_unpark(&self, mount_id: &str) -> DeviceResult<()> {
        self.inner.mount_unpark(mount_id).await
    }
    async fn mount_is_slewing(&self, mount_id: &str) -> DeviceResult<bool> {
        self.inner.mount_is_slewing(mount_id).await
    }
    async fn mount_is_parked(&self, mount_id: &str) -> DeviceResult<bool> {
        self.inner.mount_is_parked(mount_id).await
    }
    async fn mount_can_flip(&self, mount_id: &str) -> DeviceResult<bool> {
        self.inner.mount_can_flip(mount_id).await
    }
    async fn mount_side_of_pier(&self, mount_id: &str) -> DeviceResult<crate::meridian::PierSide> {
        self.inner.mount_side_of_pier(mount_id).await
    }
    async fn mount_is_tracking(&self, mount_id: &str) -> DeviceResult<bool> {
        self.inner.mount_is_tracking(mount_id).await
    }
    async fn mount_set_tracking(&self, mount_id: &str, enabled: bool) -> DeviceResult<()> {
        self.inner.mount_set_tracking(mount_id, enabled).await
    }
    async fn camera_abort_exposure(&self, camera_id: &str) -> DeviceResult<()> {
        self.inner.camera_abort_exposure(camera_id).await
    }
    async fn camera_get_temperature(&self, camera_id: &str) -> DeviceResult<f64> {
        self.inner.camera_get_temperature(camera_id).await
    }
    async fn camera_set_cooler(
        &self,
        camera_id: &str,
        enabled: bool,
        target_temp: f64,
    ) -> DeviceResult<()> {
        self.inner
            .camera_set_cooler(camera_id, enabled, target_temp)
            .await
    }
    async fn camera_get_cooler_power(&self, camera_id: &str) -> DeviceResult<f64> {
        self.inner.camera_get_cooler_power(camera_id).await
    }
    async fn filterwheel_set_position(&self, fw_id: &str, position: i32) -> DeviceResult<()> {
        self.inner.filterwheel_set_position(fw_id, position).await
    }
    async fn filterwheel_get_position(&self, fw_id: &str) -> DeviceResult<i32> {
        self.inner.filterwheel_get_position(fw_id).await
    }
    async fn filterwheel_get_names(&self, fw_id: &str) -> DeviceResult<Vec<String>> {
        self.inner.filterwheel_get_names(fw_id).await
    }
    async fn filterwheel_set_filter_by_name(&self, fw_id: &str, name: &str) -> DeviceResult<i32> {
        self.inner.filterwheel_set_filter_by_name(fw_id, name).await
    }
    async fn rotator_move_to(&self, rotator_id: &str, angle: f64) -> DeviceResult<()> {
        self.inner.rotator_move_to(rotator_id, angle).await
    }
    async fn rotator_move_relative(&self, rotator_id: &str, delta: f64) -> DeviceResult<()> {
        self.inner.rotator_move_relative(rotator_id, delta).await
    }
    async fn rotator_get_angle(&self, rotator_id: &str) -> DeviceResult<f64> {
        self.inner.rotator_get_angle(rotator_id).await
    }
    async fn rotator_halt(&self, rotator_id: &str) -> DeviceResult<()> {
        self.inner.rotator_halt(rotator_id).await
    }
    async fn guider_dither(
        &self,
        pixels: f64,
        settle_pixels: f64,
        settle_time: f64,
        settle_timeout: f64,
        ra_only: bool,
    ) -> DeviceResult<()> {
        self.inner
            .guider_dither(pixels, settle_pixels, settle_time, settle_timeout, ra_only)
            .await
    }
    async fn guider_get_status(&self) -> DeviceResult<GuidingStatus> {
        self.inner.guider_get_status().await
    }
    async fn guider_start(
        &self,
        settle_pixels: f64,
        settle_time: f64,
        settle_timeout: f64,
    ) -> DeviceResult<()> {
        self.inner
            .guider_start(settle_pixels, settle_time, settle_timeout)
            .await
    }
    async fn guider_stop(&self) -> DeviceResult<()> {
        self.inner.guider_stop().await
    }
    async fn plate_solve(
        &self,
        image_data: &ImageData,
        hint_ra: Option<f64>,
        hint_dec: Option<f64>,
        hint_scale: Option<f64>,
    ) -> DeviceResult<PlateSolveResult> {
        self.inner
            .plate_solve(image_data, hint_ra, hint_dec, hint_scale)
            .await
    }
    async fn save_fits(
        &self,
        image_data: &ImageData,
        file_path: &str,
        frame_ctx: &crate::scheduling::FrameContext,
    ) -> DeviceResult<()> {
        self.inner.save_fits(image_data, file_path, frame_ctx).await
    }
    async fn send_notification(
        &self,
        level: &str,
        title: &str,
        message: &str,
        explicit_transports: Option<&[String]>,
    ) -> DeviceResult<()> {
        self.inner
            .send_notification(level, title, message, explicit_transports)
            .await
    }
    fn calculate_altitude(&self, ra_hours: f64, dec_degrees: f64, lat: f64, lon: f64) -> f64 {
        self.inner
            .calculate_altitude(ra_hours, dec_degrees, lat, lon)
    }
    fn get_observer_location(&self) -> Option<(f64, f64)> {
        self.inner.get_observer_location()
    }
    async fn polar_align_update(
        &self,
        result: &crate::polar_align::PolarAlignResult,
    ) -> DeviceResult<()> {
        self.inner.polar_align_update(result).await
    }
    async fn dome_open(&self, dome_id: &str) -> DeviceResult<()> {
        self.inner.dome_open(dome_id).await
    }
    async fn dome_close(&self, dome_id: &str) -> DeviceResult<()> {
        self.inner.dome_close(dome_id).await
    }
    async fn dome_park(&self, dome_id: &str) -> DeviceResult<()> {
        self.inner.dome_park(dome_id).await
    }
    async fn dome_get_shutter_status(&self, dome_id: &str) -> DeviceResult<String> {
        self.inner.dome_get_shutter_status(dome_id).await
    }
    async fn safety_is_safe(&self, safety_id: Option<&str>) -> DeviceResult<bool> {
        self.inner.safety_is_safe(safety_id).await
    }
    async fn calculate_image_hfr(&self, image_data: &ImageData) -> DeviceResult<Option<f64>> {
        self.inner.calculate_image_hfr(image_data).await
    }
    async fn detect_stars_in_image(
        &self,
        image_data: &ImageData,
    ) -> DeviceResult<Vec<(f64, f64, f64)>> {
        self.inner.detect_stars_in_image(image_data).await
    }
    async fn cover_calibrator_open_cover(&self, device_id: &str) -> DeviceResult<()> {
        self.inner.cover_calibrator_open_cover(device_id).await
    }
    async fn cover_calibrator_close_cover(&self, device_id: &str) -> DeviceResult<()> {
        self.inner.cover_calibrator_close_cover(device_id).await
    }
    async fn cover_calibrator_halt_cover(&self, device_id: &str) -> DeviceResult<()> {
        self.inner.cover_calibrator_halt_cover(device_id).await
    }
    async fn cover_calibrator_calibrator_on(
        &self,
        device_id: &str,
        brightness: i32,
    ) -> DeviceResult<()> {
        self.inner
            .cover_calibrator_calibrator_on(device_id, brightness)
            .await
    }
    async fn cover_calibrator_calibrator_off(&self, device_id: &str) -> DeviceResult<()> {
        self.inner.cover_calibrator_calibrator_off(device_id).await
    }
    async fn cover_calibrator_get_cover_state(&self, device_id: &str) -> DeviceResult<i32> {
        self.inner.cover_calibrator_get_cover_state(device_id).await
    }
    async fn cover_calibrator_get_calibrator_state(&self, device_id: &str) -> DeviceResult<i32> {
        self.inner
            .cover_calibrator_get_calibrator_state(device_id)
            .await
    }
    async fn cover_calibrator_get_brightness(&self, device_id: &str) -> DeviceResult<i32> {
        self.inner.cover_calibrator_get_brightness(device_id).await
    }
    async fn cover_calibrator_get_max_brightness(&self, device_id: &str) -> DeviceResult<i32> {
        self.inner
            .cover_calibrator_get_max_brightness(device_id)
            .await
    }
}

/// A frame as the simulated optics would see it from `optical_position`.
fn render_star_field(
    optical_position: i32,
    stars: bool,
    duration_secs: f64,
    gain: Option<i32>,
    offset: Option<i32>,
) -> ImageData {
    let defocus = f64::from(optical_position - TRUE_OPTICAL_FOCUS);
    let sigma = FOCUSED_SIGMA_PX + SIGMA_PER_STEP_SQUARED * defocus * defocus;
    let two_sigma_squared = 2.0 * sigma * sigma;
    // Peak flux is conserved as the PSF spreads, which is what makes a
    // defocused star fade as well as swell.
    let peak = STAR_PEAK_ADU * (FOCUSED_SIGMA_PX * FOCUSED_SIGMA_PX) / (sigma * sigma);

    let size = FRAME_SIZE_PX as usize;
    let mut data = vec![0u16; size * size];
    // A fixed linear congruential sequence: deterministic, so a failure is
    // reproducible, while still giving the background a real standard
    // deviation for the detector to threshold against.
    let mut seed: u32 = 0x5EED_1234;
    for y in 0..size {
        for x in 0..size {
            seed = seed.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            let uniform = f64::from(seed >> 8) / f64::from(1u32 << 24) - 0.5;
            let mut value = BACKGROUND_ADU + uniform * NOISE_SIGMA_ADU * 3.464;
            for &(cx, cy) in STAR_POSITIONS_PX.iter().filter(|_| stars) {
                let dx = x as f64 - cx;
                let dy = y as f64 - cy;
                value += peak * (-(dx * dx + dy * dy) / two_sigma_squared).exp();
            }
            data[y * size + x] = value.clamp(0.0, 65535.0) as u16;
        }
    }

    ImageData {
        width: FRAME_SIZE_PX,
        height: FRAME_SIZE_PX,
        data,
        bits_per_pixel: 16,
        exposure_secs: duration_secs,
        gain,
        offset,
        temperature: Some(-10.0),
        filter: None,
        timestamp: 0,
        sensor_type: Some("Monochrome".to_string()),
        bayer_offset: None,
    }
}

/// A calibration config sized for the simulated frame: four stars, so the
/// star floor is four, and a crop that keeps all of them.
fn test_config(clearance_steps: i32) -> BacklashCalibrationConfig {
    BacklashCalibrationConfig {
        clearance_steps,
        exposures_per_point: 1,
        exposure_duration: 0.01,
        min_star_count: 4,
        outer_crop_ratio: 0.95,
        focuser_settle_time_ms: 0,
        app_version: "7.0.0+28-test".to_string(),
        ..BacklashCalibrationConfig::default()
    }
}

/// The calibration's context, from the crate's own test-execution context so
/// this does not re-spell 90 fields that have nothing to do with backlash.
async fn calibration_context(ops: Arc<BacklashFocuserOps>) -> InstructionContext {
    let mut execution =
        crate::node::context::ExecutionContext::new_for_test("backlash-calibration".to_string());
    execution.device_ops = ops;
    execution.camera_id = Some("sim-camera".to_string());
    execution.focuser_id = Some("sim-focuser".to_string());
    execution
        .to_instruction_context("backlash-calibration")
        .await
}

/// Run a calibration, waiting for the shared camera/focuser gate rather than
/// failing if something else holds it.
///
/// These tests run concurrently with the autofocus tests, which take the same
/// process-wide gate. Waiting on it through the production waiter serialises
/// them without a test-only mutex — and a test-only mutex would have to be
/// held across every await in the run, which is exactly what it must not do.
async fn run_calibration(
    config: &BacklashCalibrationConfig,
    ctx: &InstructionContext,
) -> Result<BacklashCalibrationOutcome, String> {
    let guard = admit_autofocus_run_waiting(Duration::from_secs(600))
        .await
        .expect("the autofocus gate must free up within the test deadline");
    execute_backlash_calibration_admitted(config, ctx, None, guard).await
}

/// The progress payload Dart parses, pinned by capturing it from a real run.
///
/// `FocuserBacklashProgressData.tryParse` keys on `type` and reads these exact
/// field names; a rename here is invisible to the Rust compiler and silently
/// leaves the wizard's chart empty.
#[tokio::test(flavor = "multi_thread")]
async fn the_progress_payload_carries_the_fields_the_wizard_parses() {
    let ops = Arc::new(BacklashFocuserOps::new(
        SIMULATED_BACKLASH,
        STARTING_POSITION,
    ));
    let ctx = calibration_context(ops).await;
    let frames = Arc::new(std::sync::Mutex::new(Vec::<String>::new()));
    let collector = {
        let frames = Arc::clone(&frames);
        move |_: f64, detail: String| {
            frames
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .push(detail);
        }
    };

    let guard = admit_autofocus_run_waiting(Duration::from_secs(600))
        .await
        .expect("the autofocus gate must free up within the test deadline");
    execute_backlash_calibration_admitted(&test_config(400), &ctx, Some(&collector), guard)
        .await
        .expect("the calibration must run to a conclusion");

    let frames = frames.lock().unwrap_or_else(|e| e.into_inner()).clone();
    let parsed: Vec<serde_json::Value> = frames
        .iter()
        .map(|frame| serde_json::from_str(frame).expect("every frame must be JSON"))
        .collect();

    let sample = parsed
        .iter()
        .find(|frame| {
            frame["type"] == "focuser_backlash_progress" && frame["phase"] == "from_below"
        })
        .expect("a from-below sample frame");
    for field in [
        "point",
        "total_points",
        "position",
        "hfr",
        "star_count",
        "scan_range",
        "points",
    ] {
        assert!(
            !sample[field].is_null(),
            "the progress frame is missing {field}: {sample}"
        );
    }
    assert!(!sample["scan_range"]["min"].is_null());
    assert!(!sample["scan_range"]["max"].is_null());
    assert!(!sample["points"][0]["position"].is_null());
    assert!(!sample["points"][0]["hfr"].is_null());

    assert!(
        parsed
            .iter()
            .any(|frame| frame["phase"] == "from_above"
                && frame["type"] == "focuser_backlash_progress"),
        "the second scan must report progress under its own phase"
    );
    assert!(
        parsed.iter().any(|frame| frame["phase"] == "analysing"),
        "the fit needs its own phase — it is the pause after the last exposure"
    );

    let result = parsed
        .iter()
        .find(|frame| frame["type"] == "focuser_backlash_result")
        .expect("a terminal result frame");
    assert_eq!(result["result"]["outcome"], "measured");
    assert!(!result["result"]["calibration"]["steps"].is_null());
}

/// The result payload's field names, pinned by capturing a real run.
///
/// Dart parses these as REQUIRED — `FocuserBacklashResult.tryParse` returns
/// null rather than a partial model if one is missing — so a rename here would
/// not fail any Rust test and would silently leave the wizard unable to read
/// its own result. This is the test that makes it fail here instead.
#[tokio::test(flavor = "multi_thread")]
async fn the_result_payload_carries_every_field_dart_requires() {
    let ops = Arc::new(BacklashFocuserOps::new(
        SIMULATED_BACKLASH,
        STARTING_POSITION,
    ));
    let ctx = calibration_context(ops).await;

    let outcome = run_calibration(&test_config(400), &ctx)
        .await
        .expect("the calibration must run to a conclusion");
    let json = serde_json::to_value(&outcome).expect("the outcome must serialise");

    assert_eq!(json["outcome"], "measured");
    let calibration = &json["calibration"];
    for field in [
        "steps",
        "vertex_difference",
        "measurable",
        "resolution_limit_steps",
        "below",
        "above",
        "measured_at_position",
        "clearance_steps",
        "reversal_budget_steps",
        "reversal_budget_at_vertex_steps",
        "confidence",
        "confidence_reason",
        "context",
    ] {
        assert!(
            !calibration[field].is_null(),
            "the calibration payload is missing {field}"
        );
    }
    for scan in ["below", "above"] {
        for field in [
            "approach",
            "points",
            "optimum_position",
            "r_squared",
            "method",
        ] {
            assert!(
                !calibration[scan][field].is_null(),
                "the {scan} scan is missing {field}"
            );
        }
        assert!(!calibration[scan]["points"][0]["position"].is_null());
        assert!(!calibration[scan]["points"][0]["hfr"].is_null());
        assert!(!calibration[scan]["points"][0]["star_count"].is_null());
    }
    for field in [
        "focuser_device_id",
        "taken_at",
        "temperature_celsius",
        "app_version",
    ] {
        assert!(
            !calibration["context"][field].is_null(),
            "the measurement context is missing {field}"
        );
    }
    // `confidence` is a lower-case discriminant the UI maps to a band.
    assert!(
        ["high", "moderate", "low"].contains(&calibration["confidence"].as_str().unwrap_or("")),
        "unexpected confidence discriminant {}",
        calibration["confidence"]
    );
    assert_eq!(calibration["below"]["approach"], "from_below");
    assert_eq!(calibration["above"]["approach"], "from_above");
}

/// The plan payload, same reasoning: Dart parses every field as required so it
/// can state the run's cost before the operator agrees to it.
#[test]
fn the_plan_payload_carries_every_field_dart_requires() {
    let plan = plan_backlash_calibration(&test_config(400), 6620);
    let json = serde_json::to_value(plan).expect("the plan must serialise");

    for field in [
        "points_per_scan",
        "total_exposures",
        "scan_low_position",
        "scan_high_position",
        "travel_low_position",
        "travel_high_position",
        "estimated_duration_secs",
        "reversal_budget_steps",
        "reversal_budget_at_vertex_steps",
    ] {
        assert!(
            !json[field].is_null(),
            "the plan payload is missing {field}"
        );
    }
}

/// Dart matches this phrase to decide when to offer the calibration again: two
/// landing-verification failures in a row on one focuser is the signature of an
/// uncalibrated or changed drive train. Rewording the sentence without the
/// constant would silently retire that offer.
#[test]
fn the_landing_verification_failure_phrase_is_the_one_dart_matches() {
    assert_eq!(
        crate::instructions::LANDING_VERIFICATION_FAILURE_PHRASE,
        "but the frame taken there measures HFR",
        "Dart's autofocusLandingVerificationFailureMarker matches this exact phrase \
         (packages/nightshade_core/lib/src/providers/focuser_backlash_provider.dart); \
         change both or neither"
    );
}

/// The gate itself: a calibration must refuse to start while an autofocus
/// holds the camera and focuser, rather than driving them underneath it.
#[tokio::test(flavor = "multi_thread")]
async fn a_calibration_refuses_to_start_while_autofocus_holds_the_equipment() {
    let inflight = admit_autofocus_run_waiting(Duration::from_secs(600))
        .await
        .expect("the gate must free up within the test deadline");
    let ops = Arc::new(BacklashFocuserOps::new(
        SIMULATED_BACKLASH,
        STARTING_POSITION,
    ));
    let ctx = calibration_context(ops).await;

    let error = execute_backlash_calibration(&test_config(400), &ctx, None)
        .await
        .expect_err("the calibration must not run while the gate is held");
    assert!(
        error.contains("already running"),
        "the error should say the equipment is busy: {error}"
    );
    drop(inflight);
}

/// The headline: a focuser with 105 steps of backlash measures 105 steps of
/// backlash, through the whole real pipeline.
#[tokio::test(flavor = "multi_thread")]
async fn a_simulated_focuser_with_105_steps_of_backlash_measures_105_steps() {
    let ops = Arc::new(BacklashFocuserOps::new(
        SIMULATED_BACKLASH,
        STARTING_POSITION,
    ));
    let gear = ops.state();
    let ctx = calibration_context(ops).await;

    let outcome = run_calibration(&test_config(400), &ctx)
        .await
        .expect("the calibration must run to a conclusion");

    let calibration = match &outcome {
        BacklashCalibrationOutcome::Measured { calibration } => calibration,
        other => panic!("expected a measurement, got {:?}", other),
    };

    // One scan step of tolerance: the vertices are located from samples 30
    // steps apart, so demanding better than that would be demanding better
    // than the measurement's own resolution.
    let error = f64::from((calibration.steps - SIMULATED_BACKLASH).abs());
    assert!(
        error <= calibration.resolution_limit_steps,
        "measured {} steps against a simulated {} ({:.0} off, resolution {:.0})",
        calibration.steps,
        SIMULATED_BACKLASH,
        error,
        calibration.resolution_limit_steps
    );
    assert!(calibration.measurable);
    assert!(
        (calibration.below.optimum_position - TRUE_OPTICAL_FOCUS).abs() <= 30,
        "the from-below optimum {} should be true optical focus {}",
        calibration.below.optimum_position,
        TRUE_OPTICAL_FOCUS
    );
    assert_eq!(calibration.context.temperature_celsius, Some(11.5));
    assert_eq!(calibration.context.app_version, "7.0.0+28-test");
    assert_eq!(calibration.context.focuser_device_id, "sim-focuser");

    // And the focuser is back where the operator left it, not parked at the
    // end of a scan.
    let gear = gear.lock().await;
    assert_eq!(gear.commanded, STARTING_POSITION);
}

/// Every point of the from-below pass must be reached by a move UP, and every
/// point of the from-above pass by a move DOWN. That is the entire mechanism;
/// if the approach is wrong the two fits are measuring the same thing.
#[tokio::test(flavor = "multi_thread")]
async fn every_sample_is_approached_from_the_side_its_scan_claims() {
    let ops = Arc::new(BacklashFocuserOps::new(
        SIMULATED_BACKLASH,
        STARTING_POSITION,
    ));
    let gear = ops.state();
    let ctx = calibration_context(ops).await;
    let config = test_config(400);

    run_calibration(&config, &ctx)
        .await
        .expect("the calibration must run to a conclusion");

    let commands = gear.lock().await.commands.clone();
    // Commands arrive in pairs — run-up, then the sample position — for each
    // point of each scan, followed by the halt-and-return.
    let points = usize::try_from(config.steps_out * 2 + 1).expect("bounded by 101");
    let below: Vec<_> = commands[..points * 2].chunks(2).collect();
    let above: Vec<_> = commands[points * 2..points * 4].chunks(2).collect();

    for pair in &below {
        assert!(
            pair[1] > pair[0],
            "a from-below sample at {} was approached from {}, which is not below it",
            pair[1],
            pair[0]
        );
        assert_eq!(
            pair[1] - pair[0],
            config.clearance_steps,
            "the run-up should be exactly the configured clearance"
        );
    }
    for pair in &above {
        assert!(
            pair[1] < pair[0],
            "a from-above sample at {} was approached from {}, which is not above it",
            pair[1],
            pair[0]
        );
    }
}

/// The correction the simulation forced, and the reason this test exists.
///
/// Reasoning about a single isolated approach says the run-up must exceed the
/// backlash, and an earlier version of this module refused anything else. It
/// is wrong: the scan is monotone, so each run-up reverses `k - step` and the
/// scan accumulates `clearance + (n - 1) * step` of reversal as it goes. A
/// 40-step run-up over 13 points at a 30-step spacing therefore still takes up
/// 105 steps of dead band, and measures it — so refusing here would have
/// thrown away a perfectly good measurement of the owner's focuser.
#[tokio::test(flavor = "multi_thread")]
async fn a_run_up_smaller_than_the_backlash_still_measures_it_because_the_scan_accumulates() {
    let ops = Arc::new(BacklashFocuserOps::new(
        SIMULATED_BACKLASH,
        STARTING_POSITION,
    ));
    let ctx = calibration_context(ops).await;

    let outcome = run_calibration(&test_config(40), &ctx)
        .await
        .expect("the calibration must run to a conclusion");

    let calibration = match &outcome {
        BacklashCalibrationOutcome::Measured { calibration } => calibration,
        other => panic!(
            "a 40-step run-up over 13 points still reverses 400 steps; expected a \
             measurement, got {:?}",
            other
        ),
    };
    let error = f64::from((calibration.steps - SIMULATED_BACKLASH).abs());
    assert!(
        error <= calibration.resolution_limit_steps,
        "measured {} steps against a simulated {}",
        calibration.steps,
        SIMULATED_BACKLASH
    );
    assert_eq!(calibration.reversal_budget_at_vertex_steps, 190);
}

/// The case a small run-up genuinely cannot handle: a dead band wider than the
/// scan ever reverses. The from-above pass is still filling the gear while it
/// samples, which shifts each point's optical position along with the scan and
/// flattens the very curve the fit needs — so this comes back as a refusal,
/// not as an under-reported figure presented as fact.
#[tokio::test(flavor = "multi_thread")]
async fn a_dead_band_wider_than_the_scan_can_take_up_is_refused_not_under_reported() {
    let ops = Arc::new(BacklashFocuserOps::new(1200, STARTING_POSITION));
    let ctx = calibration_context(ops).await;

    let outcome = run_calibration(&test_config(40), &ctx)
        .await
        .expect("the calibration must run to a conclusion");

    match &outcome {
        BacklashCalibrationOutcome::Refused { refusal, .. } => {
            // Any of these guards is an honest catch, and which one fires
            // depends on how far the unconverged pass has pushed the optics.
            // At 1200 steps out the stars are too bloated to detect at all,
            // which is the first gate the scan hits; a narrower dead band
            // trips the fit-quality or bracketing gates instead. What matters
            // is that none of them is a number.
            assert!(
                matches!(
                    refusal.code(),
                    "scan_abandoned_for_stars"
                        | "too_few_stars_at_focus"
                        | "too_few_measurable_points"
                        | "poor_fit"
                        | "vertex_outside_scan"
                        | "exceeds_reversal_budget"
                ),
                "unexpected refusal {}",
                refusal.code()
            );
        }
        BacklashCalibrationOutcome::Measured { calibration } => panic!(
            "a 1200-step dead band measured as {} steps at {} confidence — an \
             under-report presented as fact",
            calibration.steps, calibration.confidence
        ),
        other => panic!("expected a refusal, got {:?}", other),
    }
}

/// A focuser with no backlash reports none, rather than manufacturing a
/// figure out of fit noise.
#[tokio::test(flavor = "multi_thread")]
async fn a_focuser_with_no_backlash_reports_no_measurable_backlash() {
    let ops = Arc::new(BacklashFocuserOps::new(0, STARTING_POSITION));
    let ctx = calibration_context(ops).await;

    let outcome = run_calibration(&test_config(400), &ctx)
        .await
        .expect("the calibration must run to a conclusion");

    match &outcome {
        BacklashCalibrationOutcome::NoMeasurableBacklash { calibration } => {
            assert_eq!(calibration.steps, 0);
            assert!(!calibration.measurable);
            assert!(calibration.provenance().contains("no backlash larger than"));
        }
        other => panic!("expected no measurable backlash, got {:?}", other),
    }
}

/// An autofocus sized for the simulated optics: a sweep of +/-180 steps, where
/// the PSF is still well measured, and nothing that waits on real time.
fn autofocus_test_config() -> AutofocusConfig {
    AutofocusConfig {
        step_size: 60,
        steps_out: 3,
        exposure_duration: 0.01,
        min_star_count: 4,
        outer_crop_ratio: 0.95,
        focuser_settle_time_ms: 0,
        ..AutofocusConfig::default()
    }
}

/// A failed autofocus promises to put the focuser back where it found it, and
/// a trigger-fired one keeps imaging on that promise. With backlash, "where it
/// found it" is the optical position, not the commanded number: an origin
/// last reached moving up (as every successful autofocus now lands) and then
/// returned to moving down sits a full dead band away.
#[tokio::test(flavor = "multi_thread")]
async fn a_failed_autofocus_puts_the_optics_back_where_it_found_them() {
    let ops = Arc::new(BacklashFocuserOps::new(
        SIMULATED_BACKLASH,
        STARTING_POSITION,
    ));
    let state = ops.state();
    // Arrived at the origin moving up, as the last successful run landed.
    state.lock().await.takeup = 0;
    let ctx = calibration_context(ops.clone()).await;

    let config = AutofocusConfig {
        // No real curve reaches R² = 1, so the run fails after the sweep,
        // with the focuser at the top of it.
        r_squared_threshold: 1.0,
        ..autofocus_test_config()
    };
    let result = execute_autofocus_once(
        &config,
        &ctx,
        None,
        &crate::node::context::PauseGate::default(),
    )
    .await;

    assert_eq!(result.status, NodeStatus::Failure, "{:?}", result.message);
    assert_eq!(
        result
            .data
            .as_ref()
            .and_then(|data| data.get("autofocus_origin_restored"))
            .and_then(|value| value.as_bool()),
        Some(true)
    );
    let state = state.lock().await;
    assert_eq!(state.commanded, STARTING_POSITION);
    assert_eq!(
        state.commanded + state.takeup,
        STARTING_POSITION,
        "the focuser reports its origin but the optics are {} steps away from it",
        state.takeup
    );
}

/// The landing is from below because every sweep point is measured moving up;
/// that is only true if the first points are, too. A dead band wider than one
/// sweep step swallows the first upward moves whole unless the approach to the
/// sweep start already took it up.
#[tokio::test(flavor = "multi_thread")]
async fn every_autofocus_sample_is_taken_with_the_dead_band_taken_up() {
    let ops = Arc::new(BacklashFocuserOps::new(
        SIMULATED_BACKLASH,
        STARTING_POSITION,
    ));
    let state = ops.state();
    let ctx = calibration_context(ops.clone()).await;

    let config = AutofocusConfig {
        measured_backlash_in: Some(SIMULATED_BACKLASH),
        ..autofocus_test_config()
    };
    let result = execute_autofocus_once(
        &config,
        &ctx,
        None,
        &crate::node::context::PauseGate::default(),
    )
    .await;
    assert_eq!(result.status, NodeStatus::Success, "{:?}", result.message);

    let state = state.lock().await;
    let sweep: Vec<(i32, i32)> = state
        .exposures
        .iter()
        .take((2 * config.steps_out + 1) as usize)
        .copied()
        .collect();
    assert!(
        sweep.iter().all(|(_, takeup)| *takeup == 0),
        "sweep samples (commanded, dead band still to take up): {:?}",
        sweep
    );
}

/// Cloud over the verification frame is not a focuser that missed its mark.
/// A starless frame measures nothing, so it cannot say the landing was wrong,
/// and the landing-failure sentence is what re-opens the backlash
/// recalibration offer in the app.
#[tokio::test(flavor = "multi_thread")]
async fn a_starless_verification_frame_is_not_reported_as_a_bad_landing() {
    let ops = Arc::new(BacklashFocuserOps::new(
        SIMULATED_BACKLASH,
        STARTING_POSITION,
    ));
    let state = ops.state();
    let config = autofocus_test_config();
    // The sweep's frames see stars; the one after them, the verification
    // frame, does not.
    state.lock().await.clouded_after = Some((2 * config.steps_out + 1) as usize);
    let ctx = calibration_context(ops.clone()).await;

    let result = execute_autofocus_once(
        &config,
        &ctx,
        None,
        &crate::node::context::PauseGate::default(),
    )
    .await;

    let message = result.message.clone().unwrap_or_default();
    assert!(
        !message.contains(crate::instructions::LANDING_VERIFICATION_FAILURE_PHRASE),
        "a clouded verification frame was reported as a landing failure: {} ({:?})",
        message,
        result.status
    );
}

/// `failure_hfr_tolerance_ratio` at zero means "every autofocus failure is
/// unrecoverable". It says nothing about how close a landing must be, and must
/// not turn the landing check into "no worse than the best sample", which a
/// correctly landed frame fails on noise alone.
#[tokio::test(flavor = "multi_thread")]
async fn a_zero_failure_tolerance_does_not_fail_a_correct_landing() {
    let ops = Arc::new(BacklashFocuserOps::new(
        SIMULATED_BACKLASH,
        STARTING_POSITION,
    ));
    let ctx = calibration_context(ops.clone()).await;

    let config = AutofocusConfig {
        measured_backlash_in: Some(SIMULATED_BACKLASH),
        failure_hfr_tolerance_ratio: 0.0,
        ..autofocus_test_config()
    };
    let result = execute_autofocus_once(
        &config,
        &ctx,
        None,
        &crate::node::context::PauseGate::default(),
    )
    .await;
    assert_eq!(result.status, NodeStatus::Success, "{:?}", result.message);
}
