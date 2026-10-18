//! Driving the two scans that measure a focuser's backlash.
//!
//! The arithmetic, the refusal conditions and the mechanical model they come
//! from all live in [`crate::focuser_calibration`]. This module is the part
//! that opens the shutter: it walks a range of positions twice, approaching
//! every point from below on the first pass and from above on the second,
//! measures HFR with the same code path autofocus uses, fits both passes with
//! the same curve fitters, and hands the two fits to the analysis.
//!
//! It takes the autofocus admission gate, because it drives the same camera
//! and focuser and must never overlap a sweep.

use super::*;

use crate::focuser_calibration::{
    derive_backlash_calibration, ApproachDirection, BacklashAnalysisThresholds, CalibrationRefusal,
    DirectionalScan, FocuserBacklashCalibration, MeasurementContext,
};

/// Sample spacing. Finer than an autofocus sweep on purpose: the pair of
/// fitted vertices can only be resolved to about half the spacing, and that
/// resolution is the floor on the whole measurement.
fn default_calibration_step_size() -> i32 {
    30
}

/// Points either side of the centre. 6 gives a 13-point scan spanning ±180
/// steps, which brackets focus comfortably on the owner's rig (HFR 3.0 at
/// focus, ~8 at ±180) without the scan taking all night.
fn default_calibration_steps_out() -> u32 {
    6
}

/// The run-up applied to every point. What it has to be large enough for is
/// the scan's REVERSAL BUDGET — `(clearance - step) * points`, the widest dead
/// band the scan can take up; see the model in [`crate::focuser_calibration`].
/// At the defaults here that is `(400 - 30) * 13 = 4810` steps, some forty
/// times the worst backlash measured on this rig (105 steps at position 6600,
/// 83 at 2500), which leaves room for a far coarser drive train. A budget that
/// turns out to be too small for the focuser in front of it is refused or
/// flagged, never quietly reported as a measurement.
fn default_calibration_clearance_steps() -> i32 {
    400
}

/// Short, because the calibration wants many frames and star positions rather
/// than depth.
fn default_calibration_exposure_duration() -> f64 {
    2.0
}

/// Two frames per point, median-combined — the method the owner measured by
/// hand on 2026-09-14.
fn default_calibration_exposures_per_point() -> u32 {
    2
}

/// Stricter than autofocus's default. Autofocus can afford a mediocre fit
/// because it verifies the landing with a real frame afterwards; a backlash
/// figure gets written down and then silently moves the drawtube on every
/// future run, so it has to be right the first time.
fn default_calibration_r_squared_threshold() -> f64 {
    0.90
}

/// A parabola is the honest model for a narrow scan either side of focus, and
/// it is closed-form, so the vertex is deterministic. The wide, deeply
/// defocused wings that make a V-curve fit the better choice for an autofocus
/// sweep are exactly what this scan does not have.
fn default_calibration_method() -> AutofocusMethod {
    AutofocusMethod::Quadratic
}

/// Two 13-point scans at two frames each, plus focuser motion — a few minutes.
/// Twenty is a ceiling, not a target.
fn default_calibration_max_duration_secs() -> f64 {
    1_200.0
}

/// What to measure, and how carefully.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BacklashCalibrationConfig {
    /// Centre of the scan. `None` means "wherever the focuser is", which is
    /// the operator's rough focus — the only place this measurement is worth
    /// taking.
    #[serde(default)]
    pub center_position: Option<i32>,
    #[serde(default = "default_calibration_step_size")]
    pub step_size: i32,
    #[serde(default = "default_calibration_steps_out")]
    pub steps_out: u32,
    /// The run-up `k` every point is approached with.
    #[serde(default = "default_calibration_clearance_steps")]
    pub clearance_steps: i32,
    #[serde(default = "default_calibration_exposure_duration")]
    pub exposure_duration: f64,
    #[serde(default = "default_calibration_exposures_per_point")]
    pub exposures_per_point: u32,
    #[serde(default)]
    pub binning: Binning,
    #[serde(default)]
    pub gain: Option<i32>,
    #[serde(default)]
    pub offset: Option<i32>,
    #[serde(default = "default_af_min_star_count")]
    pub min_star_count: u32,
    #[serde(default = "default_calibration_r_squared_threshold")]
    pub r_squared_threshold: f64,
    #[serde(default = "default_af_outer_crop_ratio")]
    pub outer_crop_ratio: f64,
    #[serde(default)]
    pub inner_crop_ratio: f64,
    #[serde(default = "default_af_use_brightest_n_stars")]
    pub use_brightest_n_stars: u32,
    #[serde(default = "default_af_focuser_settle_time_ms")]
    pub focuser_settle_time_ms: u64,
    #[serde(default = "default_calibration_method")]
    pub method: AutofocusMethod,
    #[serde(default = "default_af_outlier_rejection_sigma")]
    pub outlier_rejection_sigma: f64,
    #[serde(default = "default_calibration_max_duration_secs")]
    pub max_duration_secs: f64,
    /// Stamped into the record so a figure can be traced to the build that
    /// took it.
    #[serde(default)]
    pub app_version: String,
}

impl Default for BacklashCalibrationConfig {
    fn default() -> Self {
        Self {
            center_position: None,
            step_size: default_calibration_step_size(),
            steps_out: default_calibration_steps_out(),
            clearance_steps: default_calibration_clearance_steps(),
            exposure_duration: default_calibration_exposure_duration(),
            exposures_per_point: default_calibration_exposures_per_point(),
            binning: Binning::One,
            gain: None,
            offset: None,
            min_star_count: default_af_min_star_count(),
            r_squared_threshold: default_calibration_r_squared_threshold(),
            outer_crop_ratio: default_af_outer_crop_ratio(),
            inner_crop_ratio: 0.0,
            use_brightest_n_stars: default_af_use_brightest_n_stars(),
            focuser_settle_time_ms: default_af_focuser_settle_time_ms(),
            method: default_calibration_method(),
            outlier_rejection_sigma: default_af_outlier_rejection_sigma(),
            max_duration_secs: default_calibration_max_duration_secs(),
            app_version: String::new(),
        }
    }
}

/// How long the run will take and how far it will move, so the operator can
/// be told before they agree to it rather than after.
#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct BacklashCalibrationPlan {
    pub points_per_scan: usize,
    pub total_exposures: u32,
    pub scan_low_position: i32,
    pub scan_high_position: i32,
    /// Lowest and highest position the focuser will actually be commanded to,
    /// which includes the run-up either side of the scan.
    pub travel_low_position: i32,
    pub travel_high_position: i32,
    pub estimated_duration_secs: f64,
    /// How far the scan reverses the drive train in total, and so the widest
    /// backlash it could possibly expose: `clearance + (points - 1) * step`.
    pub reversal_budget_steps: i32,
    /// The same, taken only as far as the middle of the scan, where the points
    /// that set the vertex are. A result above this may be a floor rather than
    /// the value.
    pub reversal_budget_at_vertex_steps: i32,
}

/// Prefix on every error the routine returns for an operator-requested stop.
///
/// The executor's error channel is a `String`, so the bridge needs something
/// stable to key on in order to report a cancellation as a cancellation rather
/// than as a failed run — the wizard shows those differently, and it should.
pub const BACKLASH_CALIBRATION_CANCELLED: &str = "Backlash calibration cancelled";

/// Focuser move time the estimate assumes, per point, for the run-up plus the
/// approach. Deliberately rough — it is an estimate offered as one, and the
/// UI says so.
const ESTIMATED_FOCUSER_MOVE_SECS_PER_POINT: f64 = 6.0;
/// Download and star-detection time the estimate assumes per frame.
const ESTIMATED_FRAME_OVERHEAD_SECS: f64 = 1.5;

/// Both scans, in commanded focuser positions, ascending.
fn scan_positions(config: &BacklashCalibrationConfig, center: i32) -> Vec<i32> {
    let steps_out = i32::try_from(config.steps_out).unwrap_or(i32::MAX);
    let half_range = steps_out.saturating_mul(config.step_size);
    let start = center.saturating_sub(half_range);
    let total =
        usize::try_from(config.steps_out.saturating_mul(2).saturating_add(1)).unwrap_or(usize::MAX);
    (0..total)
        .map(|index| {
            let index = i32::try_from(index).unwrap_or(i32::MAX);
            start.saturating_add(index.saturating_mul(config.step_size))
        })
        .collect()
}

/// What the run will cost, before it starts.
pub fn plan_backlash_calibration(
    config: &BacklashCalibrationConfig,
    center_position: i32,
) -> BacklashCalibrationPlan {
    let positions = scan_positions(config, center_position);
    let low = positions.first().copied().unwrap_or(center_position);
    let high = positions.last().copied().unwrap_or(center_position);
    let points = positions.len();
    let exposures_per_scan = u32::try_from(points)
        .unwrap_or(u32::MAX)
        .saturating_mul(config.exposures_per_point);
    let total_exposures = exposures_per_scan.saturating_mul(2);

    let per_frame = config.exposure_duration + ESTIMATED_FRAME_OVERHEAD_SECS;
    let settle = config.focuser_settle_time_ms as f64 / 1000.0;
    let per_point = ESTIMATED_FOCUSER_MOVE_SECS_PER_POINT
        + settle
        + per_frame * f64::from(config.exposures_per_point);
    // Why: points is bounded by 2*steps_out+1, and steps_out is validated to
    // 50 or less, so this is at most 101.
    let estimated_duration_secs = per_point * points as f64 * 2.0;

    // How far the scan can reverse the drive train by the time it reaches a
    // given point. The first run-up contributes `clearance`; from then on the
    // run-up and the step to the next point net one `step_size` per point in
    // the reversing direction. Taken over the whole scan that is the widest
    // dead band the scan could have taken up, and taken to the middle — where
    // the points that set the vertex are — it is the widest one it could have
    // taken up in time to matter.
    let points_i32 = i32::try_from(points).unwrap_or(i32::MAX);
    let reversal_budget_steps = config.clearance_steps.saturating_add(
        points_i32
            .saturating_sub(1)
            .saturating_mul(config.step_size),
    );
    let reversal_budget_at_vertex_steps = config.clearance_steps.saturating_add(
        (points_i32 / 2)
            .saturating_sub(1)
            .max(0)
            .saturating_mul(config.step_size),
    );

    BacklashCalibrationPlan {
        points_per_scan: points,
        total_exposures,
        scan_low_position: low,
        scan_high_position: high,
        travel_low_position: low.saturating_sub(config.clearance_steps),
        travel_high_position: high.saturating_add(config.clearance_steps),
        estimated_duration_secs,
        reversal_budget_steps,
        reversal_budget_at_vertex_steps,
    }
}

/// The result of a calibration run that reached an answer, one way or the
/// other. A refusal is an answer; a hardware error is not, and comes back as
/// `Err` from [`execute_backlash_calibration`].
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "outcome", rename_all = "snake_case")]
pub enum BacklashCalibrationOutcome {
    /// A backlash worth compensating was measured.
    Measured {
        calibration: FocuserBacklashCalibration,
    },
    /// The scans agreed to within their own resolution. Nothing to
    /// compensate, and saying so is the honest result.
    NoMeasurableBacklash {
        calibration: FocuserBacklashCalibration,
    },
    /// The scans happened but do not support a figure. `message` says what
    /// went wrong and `remedy` what to do about it.
    Refused {
        refusal: CalibrationRefusal,
        message: String,
        remedy: String,
    },
}

impl BacklashCalibrationOutcome {
    fn refused(refusal: CalibrationRefusal) -> Self {
        Self::Refused {
            message: refusal.to_string(),
            remedy: refusal.remedy(),
            refusal,
        }
    }

    /// The figure to save, when there is one to save.
    pub fn calibration(&self) -> Option<&FocuserBacklashCalibration> {
        match self {
            Self::Measured { calibration } | Self::NoMeasurableBacklash { calibration } => {
                Some(calibration)
            }
            Self::Refused { .. } => None,
        }
    }
}

pub fn validate_backlash_calibration_config(
    config: &BacklashCalibrationConfig,
) -> Result<(), String> {
    if !config.exposure_duration.is_finite() || config.exposure_duration <= 0.0 {
        return Err("Calibration exposure duration must be finite and positive".to_string());
    }
    if !config.max_duration_secs.is_finite() || config.max_duration_secs <= 0.0 {
        return Err("Calibration maximum duration must be finite and positive".to_string());
    }
    if config.step_size <= 0 {
        return Err("Calibration step size must be positive".to_string());
    }
    if !(3..=50).contains(&config.steps_out) {
        return Err(
            "Calibration steps out must be between 3 and 50 — fewer than 3 either side of \
             centre cannot describe a focus curve"
                .to_string(),
        );
    }
    if config.clearance_steps <= 0 {
        return Err(
            "Calibration run-up must be positive: with no run-up both scans approach every \
             point the same way and there is no backlash to see"
                .to_string(),
        );
    }
    if config.clearance_steps <= config.step_size {
        return Err(format!(
            "Calibration run-up ({} steps) must exceed the step size ({} steps), or moving to \
             the next point already undoes the approach",
            config.clearance_steps, config.step_size
        ));
    }
    if !(1..=20).contains(&config.exposures_per_point) {
        return Err("Calibration exposures per point must be between 1 and 20".to_string());
    }
    if !config.r_squared_threshold.is_finite() || !(0.0..=1.0).contains(&config.r_squared_threshold)
    {
        return Err("Calibration R² threshold must be between 0 and 1".to_string());
    }
    if !config.outer_crop_ratio.is_finite()
        || !config.inner_crop_ratio.is_finite()
        || config.outer_crop_ratio <= 0.0
        || config.outer_crop_ratio > 1.0
        || config.inner_crop_ratio < 0.0
        || config.inner_crop_ratio >= config.outer_crop_ratio
    {
        return Err("Calibration crop ratios must satisfy 0 <= inner < outer <= 1".to_string());
    }
    if config.focuser_settle_time_ms > 10_000 {
        return Err("Calibration focuser settle time cannot exceed 10000 ms".to_string());
    }
    if config.gain.is_some_and(|gain| gain < 0) || config.offset.is_some_and(|offset| offset < 0) {
        return Err("Calibration gain and offset cannot be negative".to_string());
    }
    Ok(())
}

/// Measure this focuser's backlash, taking the shared camera/focuser gate
/// first so it can never overlap an autofocus sweep.
pub async fn execute_backlash_calibration(
    config: &BacklashCalibrationConfig,
    ctx: &InstructionContext,
    progress_callback: Option<&(dyn Fn(f64, String) + Send + Sync)>,
) -> Result<BacklashCalibrationOutcome, String> {
    let Some(guard) = try_admit_autofocus_run() else {
        return Err(
            "Autofocus is already running on this equipment host; backlash calibration drives \
             the same camera and focuser"
                .to_string(),
        );
    };
    execute_backlash_calibration_admitted(config, ctx, progress_callback, guard).await
}

/// [`execute_backlash_calibration`] for a caller that already holds the gate.
pub async fn execute_backlash_calibration_admitted(
    config: &BacklashCalibrationConfig,
    ctx: &InstructionContext,
    progress_callback: Option<&(dyn Fn(f64, String) + Send + Sync)>,
    _guard: AutofocusRunGuard,
) -> Result<BacklashCalibrationOutcome, String> {
    validate_backlash_calibration_config(config)?;

    let camera_id = ctx
        .camera_id
        .as_deref()
        .filter(|id| !id.is_empty())
        .ok_or_else(|| "Backlash calibration needs a connected camera".to_string())?
        .to_string();
    let focuser_id = ctx
        .focuser_id
        .as_deref()
        .filter(|id| !id.is_empty())
        .ok_or_else(|| "Backlash calibration needs a connected focuser".to_string())?
        .to_string();

    let origin_position = ctx
        .device_ops
        .focuser_get_position(&focuser_id)
        .await
        .map_err(|error| format!("Could not read the focuser position: {}", error))?;
    let center = config.center_position.unwrap_or(origin_position);

    let deadline = Duration::from_secs_f64(config.max_duration_secs);
    let run = run_both_scans(
        config,
        ctx,
        &camera_id,
        &focuser_id,
        center,
        progress_callback,
    );
    let outcome = match tokio::time::timeout(deadline, run).await {
        Ok(outcome) => outcome,
        Err(_) => Err(format!(
            "Backlash calibration timed out after {:.0}s",
            config.max_duration_secs
        )),
    };

    // Whatever happened, the focuser goes back where the operator left it.
    // A calibration is a diagnostic, not a focus run: it has no business
    // leaving the drawtube parked at the end of a scan.
    let restored = restore_autofocus_origin(&focuser_id, ctx, origin_position, None).await;

    match (outcome, restored) {
        (Ok(outcome), Ok(())) => Ok(outcome),
        (Ok(_), Err(error)) => Err(format!(
            "Backlash calibration finished but the focuser could not be returned to {}: {}",
            origin_position, error
        )),
        (Err(error), Ok(())) => Err(error),
        (Err(error), Err(restore_error)) => Err(format!(
            "{}; CRITICAL: the focuser could not be returned to {}: {}",
            error, origin_position, restore_error
        )),
    }
}

async fn run_both_scans(
    config: &BacklashCalibrationConfig,
    ctx: &InstructionContext,
    camera_id: &str,
    focuser_id: &str,
    center: i32,
    progress_callback: Option<&(dyn Fn(f64, String) + Send + Sync)>,
) -> Result<BacklashCalibrationOutcome, String> {
    let positions = scan_positions(config, center);
    let plan = plan_backlash_calibration(config, center);

    tracing::info!(
        "Starting focuser backlash calibration: {} points from {} to {}, {}-step run-up, \
         {} exposures in total",
        plan.points_per_scan,
        plan.scan_low_position,
        plan.scan_high_position,
        config.clearance_steps,
        plan.total_exposures
    );

    // From below first, ascending: that pass's optimum is true optical focus,
    // and it is the position the whole record is anchored to.
    let below = match scan_one_direction(
        config,
        ctx,
        camera_id,
        focuser_id,
        &positions,
        ApproachDirection::FromBelow,
        &plan,
        progress_callback,
    )
    .await?
    {
        Ok(scan) => scan,
        Err(refusal) => return Ok(BacklashCalibrationOutcome::refused(refusal)),
    };

    let above_positions: Vec<i32> = positions.iter().rev().copied().collect();
    let above = match scan_one_direction(
        config,
        ctx,
        camera_id,
        focuser_id,
        &above_positions,
        ApproachDirection::FromAbove,
        &plan,
        progress_callback,
    )
    .await?
    {
        Ok(scan) => scan,
        Err(refusal) => return Ok(BacklashCalibrationOutcome::refused(refusal)),
    };

    if let Some(cb) = progress_callback {
        cb(
            96.0,
            serde_json::json!({
                "type": "focuser_backlash_progress",
                "phase": "analysing",
            })
            .to_string(),
        );
    }

    // The driver's own temperature, read once after both scans, so the record
    // says how warm the tube was when the number was taken. Backlash is a
    // mechanical property and this is the closest thing to the metal.
    let temperature_celsius = ctx
        .device_ops
        .focuser_get_temperature(focuser_id)
        .await
        .ok()
        .flatten();

    let thresholds = BacklashAnalysisThresholds {
        min_star_count: config.min_star_count,
        r_squared_threshold: config.r_squared_threshold,
        clearance_steps: config.clearance_steps,
        reversal_budget_steps: plan.reversal_budget_steps,
        reversal_budget_at_vertex_steps: plan.reversal_budget_at_vertex_steps,
    };
    let context = MeasurementContext {
        focuser_device_id: focuser_id.to_string(),
        taken_at: chrono::Utc::now(),
        temperature_celsius,
        app_version: config.app_version.clone(),
    };

    let outcome = match derive_backlash_calibration(below, above, thresholds, context) {
        Ok(calibration) if calibration.measurable => {
            tracing::info!(
                "Focuser backlash measured: {} steps at position {} ({} confidence)",
                calibration.steps,
                calibration.measured_at_position,
                calibration.confidence
            );
            BacklashCalibrationOutcome::Measured { calibration }
        }
        Ok(calibration) => {
            tracing::info!(
                "No measurable focuser backlash: the two optima agreed to within {:.0} steps at \
                 position {}",
                calibration.resolution_limit_steps,
                calibration.measured_at_position
            );
            BacklashCalibrationOutcome::NoMeasurableBacklash { calibration }
        }
        Err(refusal) => {
            tracing::warn!(
                "Focuser backlash calibration refused ({}): {}",
                refusal.code(),
                refusal
            );
            BacklashCalibrationOutcome::refused(refusal)
        }
    };

    if let Some(cb) = progress_callback {
        // `to_string` fails here only if the outcome carries a non-finite
        // float — a NaN out of a degenerate curve fit, which JSON cannot
        // represent. That is rare but not impossible, and the old
        // `unwrap_or_default()` turned it into an empty detail string: the
        // wizard would take a 100 % tick carrying nothing and show the
        // operator silence at the end of a full calibration run. The run's
        // real answer still returns through `Ok(outcome)` below, so the frame
        // is not the only copy — but a frame that cannot be built has to be
        // recorded rather than swallowed.
        match serde_json::to_string(&serde_json::json!({
            "type": "focuser_backlash_result",
            "result": &outcome,
        })) {
            Ok(frame) => cb(100.0, frame),
            Err(error) => tracing::error!(
                "Focuser backlash result could not be serialised for the progress stream \
                 ({}); the outcome is still returned to the caller",
                error
            ),
        }
    }

    Ok(outcome)
}

/// Walk `positions` in the order given, approaching each one from `approach`,
/// and fit what comes back.
///
/// `Ok(Err(refusal))` is a scan that ran and then could not support a figure;
/// `Err(String)` is a scan that could not run.
#[allow(clippy::too_many_arguments)]
async fn scan_one_direction(
    config: &BacklashCalibrationConfig,
    ctx: &InstructionContext,
    camera_id: &str,
    focuser_id: &str,
    positions: &[i32],
    approach: ApproachDirection,
    plan: &BacklashCalibrationPlan,
    progress_callback: Option<&(dyn Fn(f64, String) + Send + Sync)>,
) -> Result<Result<DirectionalScan, CalibrationRefusal>, String> {
    let (bin_x, bin_y) = match config.binning {
        Binning::One => (1, 1),
        Binning::Two => (2, 2),
        Binning::Three => (3, 3),
        Binning::Four => (4, 4),
    };
    let star_floor = config.min_star_count.max(1);
    let total_points = positions.len();
    // From-below runs 5–50%, from-above 50–95%; the last 5% is the fit.
    let progress_base = match approach {
        ApproachDirection::FromBelow => 5.0,
        ApproachDirection::FromAbove => 50.0,
    };
    let progress_span = 45.0;

    let mut measured: Vec<crate::autofocus::FocusDataPoint> = Vec::with_capacity(total_points);
    let mut low_star_points = 0usize;

    for (index, &position) in positions.iter().enumerate() {
        if ctx.cancellation_token.load(Ordering::Relaxed) {
            return Err(BACKLASH_CALIBRATION_CANCELLED.to_string());
        }

        // The whole point of the run: every sample is reached from the same
        // side, so the fitted optimum is expressed in one approach frame.
        let run_up_from = match approach {
            ApproachDirection::FromBelow => position.saturating_sub(config.clearance_steps),
            ApproachDirection::FromAbove => position.saturating_add(config.clearance_steps),
        };

        for leg in [run_up_from, position] {
            ctx.device_ops
                .focuser_move_to(focuser_id, leg)
                .await
                .map_err(|error| format!("Focuser move to {} failed: {}", leg, error))?;
            wait_for_focuser_idle(focuser_id, ctx, Duration::from_secs(120)).await?;
        }
        settle_after_move(config, ctx).await?;

        let mut samples = Vec::with_capacity(config.exposures_per_point as usize);
        for _ in 0..config.exposures_per_point {
            if ctx.cancellation_token.load(Ordering::Relaxed) {
                return Err(BACKLASH_CALIBRATION_CANCELLED.to_string());
            }
            let mut abort_guard =
                CameraExposureAbortGuard::new(ctx.device_ops.clone(), camera_id.to_string());
            let exposure = ctx
                .device_ops
                .camera_start_exposure(
                    camera_id,
                    config.exposure_duration,
                    config.gain,
                    config.offset,
                    bin_x,
                    bin_y,
                )
                .await;
            abort_guard.disarm();
            let image = exposure.map_err(|error| {
                format!("Calibration exposure at {} failed: {}", position, error)
            })?;
            samples.push(calculate_hfr_with_crops(
                &image,
                config.outer_crop_ratio,
                config.inner_crop_ratio,
                config.use_brightest_n_stars,
            ));
        }
        samples.sort_by(|a, b| a.hfr.total_cmp(&b.hfr));
        let sample = samples.swap_remove(samples.len() / 2);

        tracing::info!(
            "Backlash calibration {} point {}/{} at {}: HFR {:.2} from {} stars",
            approach,
            index + 1,
            total_points,
            position,
            sample.hfr,
            sample.star_count
        );

        if sample.star_count < star_floor {
            low_star_points += 1;
            // Same rule autofocus uses: more than half the frames failing
            // star detection means the sky, not the focuser, and finishing
            // the scan would only waste the operator's night.
            if low_star_points > total_points / 2 {
                return Ok(Err(CalibrationRefusal::ScanAbandonedForStars {
                    direction: approach,
                    low_points: low_star_points,
                    total_points,
                    star_floor,
                }));
            }
        }

        measured.push(crate::autofocus::FocusDataPoint {
            position,
            hfr: sample.hfr,
            fwhm: None,
            star_count: sample.star_count,
        });

        if let Some(cb) = progress_callback {
            // Why: index and total_points are bounded by 2*steps_out+1 <= 101.
            let fraction = (index + 1) as f64 / total_points as f64;
            let percent = progress_base + fraction * progress_span;
            cb(
                percent,
                serde_json::json!({
                    "type": "focuser_backlash_progress",
                    "phase": approach,
                    "point": index + 1,
                    "total_points": total_points,
                    "position": position,
                    "hfr": sample.hfr,
                    "star_count": sample.star_count,
                    "scan_range": {
                        "min": plan.scan_low_position,
                        "max": plan.scan_high_position,
                    },
                    "points": measured.iter().map(|point| serde_json::json!({
                        "position": point.position,
                        "hfr": point.hfr,
                    })).collect::<Vec<_>>(),
                })
                .to_string(),
            );
        }
    }

    Ok(fit_one_direction(config, approach, measured))
}

/// Fit one direction's samples with the engine autofocus uses, so the vertex,
/// the one-sided outlier rejection and the near-focus refit are all the same
/// code that finds best focus on a sweep.
fn fit_one_direction(
    config: &BacklashCalibrationConfig,
    approach: ApproachDirection,
    measured: Vec<crate::autofocus::FocusDataPoint>,
) -> Result<DirectionalScan, CalibrationRefusal> {
    let engine = crate::autofocus::VCurveAutofocus::new(crate::autofocus::AutofocusConfig {
        method: config.method.into(),
        step_size: config.step_size,
        steps_out: config.steps_out,
        exposure_duration: config.exposure_duration,
        backlash_compensation: 0,
        backlash_out_compensation: 0,
        use_temperature_prediction: false,
        max_star_count_change: None,
        outlier_rejection_sigma: config.outlier_rejection_sigma,
        max_duration_secs: config.max_duration_secs,
    });

    // `find_best_focus` is deliberately fail-soft — on a failed fit it falls
    // back to the lowest sampled point and reports R² 0.0, because on a real
    // sweep any focus is better than none. Here that fallback is not a
    // result: 0.0 is below every usable threshold, so the analysis refuses it
    // with the direction that failed. Nothing is clamped or guessed.
    let fitted = match engine.find_best_focus(measured) {
        Ok(fitted) => fitted,
        Err(error) => {
            tracing::warn!(
                "Backlash calibration {} scan could not be fitted: {}",
                approach,
                error
            );
            return Err(CalibrationRefusal::PoorFit {
                direction: approach,
                r_squared: 0.0,
                required: config.r_squared_threshold,
            });
        }
    };

    let scan = DirectionalScan {
        approach,
        points: fitted.data_points,
        optimum_position: fitted.best_position,
        r_squared: fitted.curve_fit_quality,
        method: config.method.into(),
    };

    // The analysis checks both of these again — it is the authority, and it is
    // what the unit tests hold to account. Checking here as well is worth it
    // for the operator: a first scan that cannot support a vertex means the
    // second scan is three more minutes of sky that cannot change the answer.
    if scan.r_squared < config.r_squared_threshold {
        return Err(CalibrationRefusal::PoorFit {
            direction: approach,
            r_squared: scan.r_squared,
            required: config.r_squared_threshold,
        });
    }
    if let Some((lo, hi)) = scan.span() {
        if !(lo..=hi).contains(&scan.optimum_position) {
            return Err(CalibrationRefusal::VertexOutsideScan {
                direction: approach,
                vertex: scan.optimum_position,
                span: (lo, hi),
            });
        }
    }

    Ok(scan)
}

async fn settle_after_move(
    config: &BacklashCalibrationConfig,
    ctx: &InstructionContext,
) -> Result<(), String> {
    let mut remaining = config.focuser_settle_time_ms;
    while remaining > 0 {
        if ctx.cancellation_token.load(Ordering::Relaxed) {
            return Err(BACKLASH_CALIBRATION_CANCELLED.to_string());
        }
        let chunk = remaining.min(100);
        sleep(Duration::from_millis(chunk)).await;
        remaining -= chunk;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_default_scan_brackets_focus_and_resolves_the_owners_backlash() {
        let config = BacklashCalibrationConfig::default();
        let positions = scan_positions(&config, 6620);

        assert_eq!(positions.len(), 13);
        assert_eq!(positions[0], 6440);
        assert_eq!(positions[12], 6800);
        // Half the 30-step spacing is 15, so the rig's 105 steps come out at
        // 7x the resolution limit.
        assert!(
            config.step_size / 2 < 105,
            "a scan this coarse could not resolve the owner's 105 steps"
        );
        // And the from-above optimum, 105 steps low, still lands inside it.
        assert!(positions[0] <= 6620 - 105);
    }

    /// What has to be big enough is the reversal the whole scan accumulates,
    /// not the single run-up — and it has to clear the backlash with room to
    /// spare, or the result is only reported at low confidence.
    #[test]
    fn the_default_scan_reverses_far_enough_to_measure_the_rigs_backlash_confidently() {
        let config = BacklashCalibrationConfig::default();
        let budget = plan_backlash_calibration(&config, 6620).reversal_budget_at_vertex_steps;

        // 105 steps at position 6600 (2026-09-14) and 83 at 2500 (2026-09-08).
        for backlash in [83, 105] {
            assert!(
                budget > backlash,
                "a {}-step reversal budget does not confidently clear {} steps of backlash",
                budget,
                backlash
            );
        }
    }

    #[test]
    fn the_plan_states_the_travel_including_the_run_up() {
        let config = BacklashCalibrationConfig::default();
        let plan = plan_backlash_calibration(&config, 6620);

        assert_eq!(plan.points_per_scan, 13);
        assert_eq!(plan.total_exposures, 52);
        assert_eq!(plan.scan_low_position, 6440);
        assert_eq!(plan.scan_high_position, 6800);
        assert_eq!(plan.travel_low_position, 6040);
        assert_eq!(plan.travel_high_position, 7200);
        // 400 + 12 * 30, and 400 + 5 * 30 by the middle of the scan.
        assert_eq!(plan.reversal_budget_steps, 760);
        assert_eq!(plan.reversal_budget_at_vertex_steps, 550);
        assert!(plan.estimated_duration_secs > 0.0);
    }

    #[test]
    fn a_run_up_no_larger_than_the_step_is_rejected() {
        let config = BacklashCalibrationConfig {
            clearance_steps: 30,
            step_size: 30,
            ..BacklashCalibrationConfig::default()
        };
        let error = validate_backlash_calibration_config(&config)
            .expect_err("a run-up equal to the step size is undone by the next point");
        assert!(error.contains("must exceed the step size"), "{error}");
    }

    #[test]
    fn a_zero_run_up_is_rejected_because_it_measures_nothing() {
        let config = BacklashCalibrationConfig {
            clearance_steps: 0,
            ..BacklashCalibrationConfig::default()
        };
        assert!(validate_backlash_calibration_config(&config).is_err());
    }

    #[test]
    fn a_two_point_scan_is_rejected_before_any_hardware_moves() {
        let config = BacklashCalibrationConfig {
            steps_out: 2,
            ..BacklashCalibrationConfig::default()
        };
        assert!(validate_backlash_calibration_config(&config).is_err());
    }

    #[test]
    fn the_default_config_validates() {
        assert!(
            validate_backlash_calibration_config(&BacklashCalibrationConfig::default()).is_ok()
        );
    }

    /// The exact JSON Dart's `focuserBacklashCalibrationConfigJson` emits for
    /// a typical tuned config — every settings field under the snake_case key
    /// this struct expects, plus the run-scoped `center_position` and
    /// `app_version`. If a key ever drifts from this map serde silently
    /// substitutes a default the operator never chose; this test is the
    /// contract that makes the drift loud.
    #[test]
    fn the_dart_config_deserializes_every_field_and_validates() {
        let json = r#"{
            "step_size": 45,
            "steps_out": 6,
            "clearance_steps": 200,
            "exposure_duration": 4.0,
            "exposures_per_point": 2,
            "binning": "Two",
            "gain": 100,
            "offset": 50,
            "min_star_count": 12,
            "r_squared_threshold": 0.85,
            "outer_crop_ratio": 0.9,
            "inner_crop_ratio": 0.1,
            "use_brightest_n_stars": 15,
            "focuser_settle_time_ms": 750,
            "method": "Quadratic",
            "outlier_rejection_sigma": 2.5,
            "max_duration_secs": 900.0,
            "center_position": 6600,
            "app_version": "7.0.0+27"
        }"#;

        let config: BacklashCalibrationConfig = serde_json::from_str(json)
            .expect("the Dart calibration payload must deserialize");

        assert_eq!(config.center_position, Some(6600));
        assert_eq!(config.step_size, 45);
        assert_eq!(config.steps_out, 6);
        assert_eq!(config.clearance_steps, 200);
        assert_eq!(config.exposure_duration, 4.0);
        assert_eq!(config.exposures_per_point, 2);
        assert_eq!(config.binning, Binning::Two);
        assert_eq!(config.gain, Some(100));
        assert_eq!(config.offset, Some(50));
        assert_eq!(config.min_star_count, 12);
        assert_eq!(config.r_squared_threshold, 0.85);
        assert_eq!(config.outer_crop_ratio, 0.9);
        assert_eq!(config.inner_crop_ratio, 0.1);
        assert_eq!(config.use_brightest_n_stars, 15);
        assert_eq!(config.focuser_settle_time_ms, 750);
        assert_eq!(config.method, AutofocusMethod::Quadratic);
        assert_eq!(config.outlier_rejection_sigma, 2.5);
        assert_eq!(config.max_duration_secs, 900.0);
        assert_eq!(config.app_version, "7.0.0+27");

        validate_backlash_calibration_config(&config)
            .expect("a valid Dart config must pass the same validator the run uses");
    }

    /// Dart sends null for both the unset camera fields and "wherever the
    /// focuser is" — both land in `Option` fields and must round-trip as such.
    #[test]
    fn the_dart_config_carries_nulls_for_unset_fields() {
        let json = r#"{
            "step_size": 30,
            "steps_out": 6,
            "clearance_steps": 90,
            "exposure_duration": 2.0,
            "exposures_per_point": 1,
            "binning": "One",
            "gain": null,
            "offset": null,
            "min_star_count": 10,
            "r_squared_threshold": 0.7,
            "outer_crop_ratio": 1.0,
            "inner_crop_ratio": 0.0,
            "use_brightest_n_stars": 10,
            "focuser_settle_time_ms": 500,
            "method": "Quadratic",
            "outlier_rejection_sigma": 3.0,
            "max_duration_secs": 1200.0,
            "center_position": null,
            "app_version": "7.0.0+27"
        }"#;

        let config: BacklashCalibrationConfig = serde_json::from_str(json)
            .expect("the Dart calibration payload must deserialize");

        assert_eq!(config.center_position, None);
        assert_eq!(config.gain, None);
        assert_eq!(config.offset, None);
        validate_backlash_calibration_config(&config)
            .expect("camera defaults left unset are a valid config");
    }

    /// The dialog gates the run with a Dart copy of the validator; this is the
    /// same JSON shape failing where the shared rules say it must.
    #[test]
    fn a_dart_config_outside_the_rules_still_fails() {
        let json = r#"{
            "step_size": 200,
            "steps_out": 6,
            "clearance_steps": 100,
            "exposure_duration": 2.0,
            "exposures_per_point": 1,
            "binning": "One",
            "gain": null,
            "offset": null,
            "min_star_count": 10,
            "r_squared_threshold": 0.9,
            "outer_crop_ratio": 1.0,
            "inner_crop_ratio": 0.0,
            "use_brightest_n_stars": 10,
            "focuser_settle_time_ms": 500,
            "method": "Quadratic",
            "outlier_rejection_sigma": 3.0,
            "max_duration_secs": 1200.0,
            "center_position": null,
            "app_version": "7.0.0+27"
        }"#;

        let config: BacklashCalibrationConfig = serde_json::from_str(json)
            .expect("the Dart calibration payload must deserialize");
        let error = validate_backlash_calibration_config(&config)
            .expect_err("a run-up smaller than the step size must be refused");
        assert!(error.contains("must exceed the step size"), "{error}");
    }

    /// The owner's own from-below numbers, fitted by the engine autofocus
    /// uses, must land on 6620 — the position he measured HFR 2.94 at.
    #[test]
    fn the_rigs_from_below_samples_fit_to_the_position_he_measured() {
        let config = BacklashCalibrationConfig::default();
        let points = [
            (6320, 14.52),
            (6420, 11.36),
            (6520, 5.66),
            (6620, 2.99),
            (6720, 6.00),
            (6820, 12.86),
        ]
        .into_iter()
        .map(|(position, hfr)| crate::autofocus::FocusDataPoint {
            position,
            hfr,
            fwhm: None,
            star_count: 40,
        })
        .collect();

        let scan = fit_one_direction(&config, ApproachDirection::FromBelow, points)
            .expect("the rig's own sweep must fit");

        assert!(
            (scan.optimum_position - 6620).abs() <= config.step_size,
            "fitted {} is more than one step from the 6620 he measured",
            scan.optimum_position
        );
        assert!(
            scan.r_squared >= config.r_squared_threshold,
            "the rig's sweep fitted only R²={:.3}",
            scan.r_squared
        );
    }

    /// The from-above leg, which is where his 6515 came from.
    #[test]
    fn the_rigs_from_above_samples_fit_to_the_position_he_measured() {
        let config = BacklashCalibrationConfig::default();
        let points = [
            (6470, 3.32),
            (6520, 2.87),
            (6545, 3.17),
            (6570, 3.76),
            (6595, 4.63),
        ]
        .into_iter()
        .map(|(position, hfr)| crate::autofocus::FocusDataPoint {
            position,
            hfr,
            fwhm: None,
            star_count: 40,
        })
        .collect();

        let scan = fit_one_direction(&config, ApproachDirection::FromAbove, points)
            .expect("the rig's own from-above scan must fit");

        assert!(
            (scan.optimum_position - 6515).abs() <= 25,
            "fitted {} is not the 6515 he measured",
            scan.optimum_position
        );
    }

    /// A flat, star-poor scan must not come back as a confident vertex.
    #[test]
    fn a_flat_scan_is_refused_rather_than_fitted() {
        let config = BacklashCalibrationConfig::default();
        let points = (0..13)
            .map(|index| crate::autofocus::FocusDataPoint {
                position: 6440 + index * 30,
                hfr: 6.0,
                fwhm: None,
                star_count: 40,
            })
            .collect();

        let refusal = fit_one_direction(&config, ApproachDirection::FromBelow, points)
            .expect_err("a flat line has no vertex");
        // R² is 0.0 on a flat line (there is no variance to explain), so the
        // fit is refused before the second scan is ever started.
        assert_eq!(refusal.code(), "poor_fit");
    }

    /// A degenerate parabola through flat samples also puts its vertex
    /// nowhere near the scan; that is caught even if the R² gate were
    /// loosened.
    #[test]
    fn a_vertex_nowhere_near_the_scan_is_refused_even_with_a_permissive_threshold() {
        let config = BacklashCalibrationConfig {
            r_squared_threshold: 0.0,
            ..BacklashCalibrationConfig::default()
        };
        let points = (0..13)
            .map(|index| crate::autofocus::FocusDataPoint {
                position: 6440 + index * 30,
                hfr: 6.0,
                fwhm: None,
                star_count: 40,
            })
            .collect();

        let refusal = fit_one_direction(&config, ApproachDirection::FromBelow, points)
            .expect_err("a vertex outside the scan is an extrapolation");
        assert_eq!(refusal.code(), "vertex_outside_scan");
    }

    #[test]
    fn the_outcome_wire_shape_tags_a_refusal_with_its_remedy() {
        let outcome =
            BacklashCalibrationOutcome::refused(CalibrationRefusal::ExceedsReversalBudget {
                vertex_difference: 900,
                reversal_budget_steps: 130,
                clearance_steps: 40,
            });
        let json = serde_json::to_value(&outcome).expect("the outcome must serialise");

        assert_eq!(json["outcome"], "refused");
        assert_eq!(json["refusal"]["code"], "exceeds_reversal_budget");
        assert!(json["remedy"]
            .as_str()
            .expect("a remedy string")
            .contains("40"));
        assert!(outcome.calibration().is_none());
    }
}
