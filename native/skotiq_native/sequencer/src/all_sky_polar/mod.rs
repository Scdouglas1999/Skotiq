//! All-Sky Polar Alignment (Sharpcap-style).
//!
//! Two solved frames separated in time, combined with the observer's
//! geographic location, are sufficient to recover the mount's polar-axis
//! misalignment `(Δaz, Δalt)`. The wizard:
//!
//! 1. Captures a baseline frame anywhere in the sky and plate-solves it.
//! 2. Loops on a cadence: capture a current frame, plate-solve, compute
//!    drift relative to the baseline, render arrows, repeat. The
//!    baseline is intentionally NOT updated each iteration so drift
//!    accumulates over the session for sub-arcsec sensitivity.
//! 3. Auto-completes when the total error stays below the configured
//!    threshold for `AUTO_COMPLETE_HOLD_SECS` consecutive iterations.
//!
//! ## Implementation
//!
//! The flow is expressed as a [`crate::wizard::Wizard`] for uniform
//! cancellation and progress handling. The two phases (baseline capture,
//! adjustment loop) become two wizard steps; the loop body lives inside
//! the second step. The drift math is in [`drift_math`].
//!
//! ## Errors
//!
//! All failure modes are propagated as [`PolarAlignError`]. The most
//! common is `SolverUnavailable` — the all-sky algorithm requires an
//! external plate solver (ASTAP) and **does not** silently fall back
//! to a stub.

mod drift_math;

pub use drift_math::{compute_polar_misalignment_from_drift, PolarMisalignment, SolvedFrame};

use crate::polar_align::{prepare_image_for_display, PolarAlignResult, PolarAlignmentImageData};
use crate::wizard::{
    NoopProgressReporter, NullCheckpointSink, Wizard, WizardExecutor, WizardProgressReporter,
    WizardRunStatus, WizardStepOutcome,
};
use crate::InstructionContext;
use chrono::Utc;
use skotiq_imaging::{BayerPattern, ImageData as ImagingImageData, PixelType};
use std::sync::atomic::Ordering;
use std::time::Duration;
use tokio::time::sleep;

/// Errors specific to all-sky polar alignment.
#[derive(Debug, Clone, PartialEq)]
pub enum PolarAlignError {
    SolverUnavailable,
    SolveFailed(String),
    LocationMissing,
    DeviceError(String),
    Cancelled,
    ImageError(String),
}

impl std::fmt::Display for PolarAlignError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PolarAlignError::SolverUnavailable => write!(
                f,
                "Plate solver required — install ASTAP and re-run all-sky polar alignment"
            ),
            PolarAlignError::SolveFailed(msg) => write!(f, "Plate solve failed: {}", msg),
            PolarAlignError::LocationMissing => write!(
                f,
                "Observer latitude/longitude is required for all-sky polar alignment"
            ),
            PolarAlignError::DeviceError(msg) => write!(f, "Device error: {}", msg),
            PolarAlignError::Cancelled => write!(f, "Cancelled"),
            PolarAlignError::ImageError(msg) => write!(f, "Image error: {}", msg),
        }
    }
}
impl std::error::Error for PolarAlignError {}

/// Configuration for an all-sky polar alignment run.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct AllSkyPolarAlignConfig {
    pub exposure_time: f64,
    pub solve_timeout: f64,
    pub gain: Option<i32>,
    pub offset: Option<i32>,
    pub binning: Option<i32>,
    pub is_north: bool,
    pub acceptance_threshold_arcsec: f64,
    pub iteration_cadence_secs: f64,
}

impl Default for AllSkyPolarAlignConfig {
    fn default() -> Self {
        Self {
            exposure_time: 5.0,
            solve_timeout: 30.0,
            gain: None,
            offset: None,
            binning: Some(2),
            is_north: true,
            acceptance_threshold_arcsec: 30.0,
            iteration_cadence_secs: 3.0,
        }
    }
}

/// How long the total error must remain below the acceptance threshold
/// before declaring the alignment complete.
const AUTO_COMPLETE_HOLD_SECS: u64 = 3;

/// Steps in the all-sky polar plan.
#[derive(Clone, serde::Serialize, serde::Deserialize)]
enum AllSkyStep {
    /// Capture and plate-solve the anchor frame.
    Baseline,
    /// Unbounded adjustment loop (cancellation or auto-acceptance).
    Adjustment,
}

struct AllSkyRun<'a, S, I, E>
where
    S: Fn(String, Option<f64>) + Send + Sync,
    I: Fn(PolarAlignmentImageData) + Send + Sync,
    E: Fn(&PolarAlignResult) + Send + Sync,
{
    config: &'a AllSkyPolarAlignConfig,
    camera_id: String,
    observer_lat: f64,
    observer_lon: f64,
    binning: i32,
    status_callback: &'a S,
    image_callback: &'a I,
    error_callback: &'a E,
    /// Solved baseline frame, set by the Baseline step.
    baseline: Option<SolvedFrame>,
    /// Terminal error to surface from `perform_all_sky_polar_alignment`.
    terminal_error: Option<PolarAlignError>,
}

#[async_trait::async_trait]
impl<'a, S, I, E> Wizard for AllSkyRun<'a, S, I, E>
where
    S: Fn(String, Option<f64>) + Send + Sync,
    I: Fn(PolarAlignmentImageData) + Send + Sync,
    E: Fn(&PolarAlignResult) + Send + Sync,
{
    type StepKey = AllSkyStep;
    type Outcome = Result<(), PolarAlignError>;

    fn name(&self) -> &'static str {
        "All-Sky Polar Alignment"
    }
    fn checkpoint_key(&self) -> &'static str {
        "all_sky_polar"
    }
    fn plan_steps(&self, _resume_idx: usize) -> Vec<AllSkyStep> {
        // All-sky polar has a fixed two-step plan; resume_idx is
        // informational (executor skips the first N steps).
        vec![AllSkyStep::Baseline, AllSkyStep::Adjustment]
    }
    fn describe_step(&self, step: &AllSkyStep, _idx: usize) -> String {
        match step {
            AllSkyStep::Baseline => "Capturing baseline".to_string(),
            AllSkyStep::Adjustment => "Refining alignment".to_string(),
        }
    }

    async fn execute_step(
        &mut self,
        ctx: &InstructionContext,
        step: AllSkyStep,
        _idx: usize,
        _progress: &dyn WizardProgressReporter,
    ) -> WizardStepOutcome<AllSkyStep> {
        match step {
            AllSkyStep::Baseline => self.do_baseline(ctx).await,
            AllSkyStep::Adjustment => self.do_adjustment(ctx).await,
        }
    }

    fn finalize(self, status: WizardRunStatus) -> Result<(), PolarAlignError> {
        if let Some(err) = self.terminal_error {
            return Err(err);
        }
        match status {
            WizardRunStatus::Completed => Ok(()),
            WizardRunStatus::Cancelled => Err(PolarAlignError::Cancelled),
            WizardRunStatus::Failed(msg) => Err(PolarAlignError::DeviceError(msg)),
        }
    }
}

impl<'a, S, I, E> AllSkyRun<'a, S, I, E>
where
    S: Fn(String, Option<f64>) + Send + Sync,
    I: Fn(PolarAlignmentImageData) + Send + Sync,
    E: Fn(&PolarAlignResult) + Send + Sync,
{
    async fn do_baseline(&mut self, ctx: &InstructionContext) -> WizardStepOutcome<AllSkyStep> {
        match self
            .capture_and_solve(ctx, "All-sky: capturing baseline frame...")
            .await
        {
            Ok(frame) => {
                (self.status_callback)(
                    format!(
                        "Baseline locked at RA={:.4}°, Dec={:.4}°. Tracking — adjust bolts.",
                        frame.ra_deg, frame.dec_deg
                    ),
                    None,
                );
                self.baseline = Some(frame);
                WizardStepOutcome::Completed
            }
            Err(e) => {
                self.terminal_error = Some(e);
                WizardStepOutcome::Failed("baseline capture failed".to_string())
            }
        }
    }

    async fn do_adjustment(&mut self, ctx: &InstructionContext) -> WizardStepOutcome<AllSkyStep> {
        let baseline = match self.baseline {
            Some(b) => b,
            None => {
                self.terminal_error = Some(PolarAlignError::DeviceError(
                    "Baseline frame missing on adjustment entry".to_string(),
                ));
                return WizardStepOutcome::Failed("missing baseline".to_string());
            }
        };
        let threshold_arcsec = self.config.acceptance_threshold_arcsec;
        let cadence = Duration::from_secs_f64(self.config.iteration_cadence_secs.max(0.5));
        let mut below_threshold_since: Option<std::time::Instant> = None;

        loop {
            if ctx.cancellation_token.load(Ordering::Relaxed) {
                self.terminal_error = Some(PolarAlignError::Cancelled);
                return WizardStepOutcome::Cancelled;
            }

            // Pace iterations — slice the cadence into 250 ms checks so
            // cancellation is responsive even with multi-second cadence.
            let mut waited = Duration::ZERO;
            while waited < cadence {
                if ctx.cancellation_token.load(Ordering::Relaxed) {
                    self.terminal_error = Some(PolarAlignError::Cancelled);
                    return WizardStepOutcome::Cancelled;
                }
                let step = Duration::from_millis(250).min(cadence - waited);
                sleep(step).await;
                waited += step;
            }

            let current = match self
                .capture_and_solve(ctx, "All-sky: re-solving for drift...")
                .await
            {
                Ok(frame) => frame,
                Err(e) => {
                    self.terminal_error = Some(e);
                    return WizardStepOutcome::Failed("capture/solve failed".to_string());
                }
            };

            let misalignment = compute_polar_misalignment_from_drift(
                &baseline,
                &current,
                self.observer_lat,
                self.observer_lon,
                self.config.is_north,
            );

            let total_error_arcsec = (misalignment.azimuth_error_arcsec.powi(2)
                + misalignment.altitude_error_arcsec.powi(2))
            .sqrt();

            let result = PolarAlignResult {
                azimuth_error: misalignment.azimuth_error_arcsec / 60.0,
                altitude_error: misalignment.altitude_error_arcsec / 60.0,
                total_error: total_error_arcsec / 60.0,
                current_ra: current.ra_deg,
                current_dec: current.dec_deg,
                target_ra: baseline.ra_deg,
                target_dec: baseline.dec_deg,
            };

            (self.error_callback)(&result);
            let _ = ctx.device_ops.polar_align_update(&result).await;

            tracing::info!(
                "All-sky polar align: total={:.1}\" (Δaz={:.1}\", Δalt={:.1}\")",
                total_error_arcsec,
                misalignment.azimuth_error_arcsec,
                misalignment.altitude_error_arcsec
            );

            (self.status_callback)(
                format!(
                    "Error {:.1}\" (Δaz={:.1}\", Δalt={:.1}\")",
                    total_error_arcsec,
                    misalignment.azimuth_error_arcsec,
                    misalignment.altitude_error_arcsec
                ),
                None,
            );

            if total_error_arcsec <= threshold_arcsec {
                match below_threshold_since {
                    None => {
                        below_threshold_since = Some(std::time::Instant::now());
                    }
                    Some(start) if start.elapsed().as_secs() >= AUTO_COMPLETE_HOLD_SECS => {
                        (self.status_callback)(
                            format!(
                                "All-sky polar alignment complete: {:.1}\" total error",
                                total_error_arcsec
                            ),
                            Some(1.0),
                        );
                        return WizardStepOutcome::Done;
                    }
                    _ => {}
                }
            } else {
                below_threshold_since = None;
            }
        }
    }

    /// Capture a single exposure, plate-solve it, and emit live previews.
    async fn capture_and_solve(
        &self,
        ctx: &InstructionContext,
        status_msg: &str,
    ) -> Result<SolvedFrame, PolarAlignError> {
        if ctx.cancellation_token.load(Ordering::Relaxed) {
            return Err(PolarAlignError::Cancelled);
        }

        (self.status_callback)(status_msg.to_string(), None);

        let image_data = ctx
            .device_ops
            .camera_start_exposure(
                &self.camera_id,
                self.config.exposure_time,
                self.config.gain,
                self.config.offset,
                self.binning,
                self.binning,
            )
            .await
            .map_err(|e| PolarAlignError::DeviceError(format!("Camera capture failed: {}", e)))?;

        if ctx.cancellation_token.load(Ordering::Relaxed) {
            return Err(PolarAlignError::Cancelled);
        }

        emit_adjustment_preview(&image_data, self.image_callback, None, None);

        (self.status_callback)("All-sky: plate-solving...".to_string(), None);

        let solve_future = ctx.device_ops.plate_solve(&image_data, None, None, None);
        let solve_result = match tokio::time::timeout(
            Duration::from_secs_f64(self.config.solve_timeout),
            solve_future,
        )
        .await
        {
            Ok(Ok(res)) if res.success => res,
            Ok(Ok(_)) => {
                return Err(PolarAlignError::SolveFailed(
                    "Solver returned unsuccessful result".to_string(),
                ));
            }
            Ok(Err(e)) => return Err(PolarAlignError::SolveFailed(e)),
            Err(_) => {
                return Err(PolarAlignError::SolveFailed(format!(
                    "Solver timed out after {:.1}s",
                    self.config.solve_timeout
                )));
            }
        };

        emit_adjustment_preview(
            &image_data,
            self.image_callback,
            Some(solve_result.ra_degrees),
            Some(solve_result.dec_degrees),
        );

        Ok(SolvedFrame {
            ra_deg: solve_result.ra_degrees,
            dec_deg: solve_result.dec_degrees,
            when: Utc::now(),
        })
    }
}

/// Execute the all-sky polar alignment routine.
pub async fn perform_all_sky_polar_alignment<S, I, E>(
    config: &AllSkyPolarAlignConfig,
    ctx: &InstructionContext,
    status_callback: S,
    image_callback: I,
    error_callback: E,
) -> Result<(), PolarAlignError>
where
    S: Fn(String, Option<f64>) + Send + Sync,
    I: Fn(PolarAlignmentImageData) + Send + Sync,
    E: Fn(&PolarAlignResult) + Send + Sync,
{
    // Pre-flight: require an external plate solver.
    if !skotiq_imaging::is_solver_available() {
        return Err(PolarAlignError::SolverUnavailable);
    }

    let camera_id = ctx
        .camera_id
        .clone()
        .ok_or_else(|| PolarAlignError::DeviceError("No camera connected".to_string()))?;

    let (observer_lat, observer_lon) = match (ctx.latitude, ctx.longitude) {
        (Some(lat), Some(lon)) => (lat, lon),
        _ => ctx
            .device_ops
            .get_observer_location()
            .ok_or(PolarAlignError::LocationMissing)?,
    };

    // Why: `config.binning` is `Option<i32>` — user-supplied
    // override. `None` means "use the all-sky polar default (2x2 binning)" —
    // the optimal trade-off between SNR and resolution for plate-solving the
    // polar refinement frame. Documented constructor default, not a silent
    // error fallback.
    let binning = config.binning.unwrap_or(2);

    let wizard = AllSkyRun {
        config,
        camera_id,
        observer_lat,
        observer_lon,
        binning,
        status_callback: &status_callback,
        image_callback: &image_callback,
        error_callback: &error_callback,
        baseline: None,
        terminal_error: None,
    };

    let progress = NoopProgressReporter;
    static SINK: NullCheckpointSink = NullCheckpointSink;
    let executor = WizardExecutor::new(&progress, &SINK);
    let (outcome, _status) = executor.run(wizard, ctx).await;
    outcome
}

/// Emit an adjustment preview frame. The all-sky UI renders these callbacks as
/// tracking-arrow updates, so they use point zero and the `adjusting` phase.
fn emit_adjustment_preview(
    image_data: &crate::device_ops::ImageData,
    image_callback: &impl Fn(PolarAlignmentImageData),
    solved_ra: Option<f64>,
    solved_dec: Option<f64>,
) {
    let is_color = image_data.sensor_type.as_deref() == Some("Color");
    let bayer_pattern = image_data.bayer_offset.map(|(x, y)| match (x % 2, y % 2) {
        (0, 0) => BayerPattern::RGGB,
        (1, 0) => BayerPattern::GRBG,
        (0, 1) => BayerPattern::GBRG,
        (1, 1) => BayerPattern::BGGR,
        _ => BayerPattern::RGGB,
    });

    let packed_data: Vec<u8> = image_data
        .data
        .iter()
        .flat_map(|&v| v.to_le_bytes())
        .collect();
    let imaging_image = ImagingImageData {
        width: image_data.width,
        height: image_data.height,
        channels: 1,
        pixel_type: PixelType::U16,
        data: packed_data,
    };

    if let Ok(jpeg) = prepare_image_for_display(&imaging_image, is_color, bayer_pattern) {
        image_callback(PolarAlignmentImageData {
            image_data: jpeg,
            width: image_data.width,
            height: image_data.height,
            solved_ra,
            solved_dec,
            point: 0,
            phase: "adjusting".to_string(),
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn solver_unavailable_error_message_is_actionable() {
        let err = PolarAlignError::SolverUnavailable;
        let msg = err.to_string();
        assert!(msg.contains("ASTAP"));
        assert!(msg.contains("Plate solver"));
    }

    #[test]
    fn solve_failed_error_includes_inner_message() {
        let err = PolarAlignError::SolveFailed("timeout".to_string());
        let msg = err.to_string();
        assert!(msg.contains("timeout"));
    }

    #[test]
    fn location_missing_error_is_actionable() {
        let err = PolarAlignError::LocationMissing;
        let msg = err.to_string();
        assert!(msg.contains("latitude"));
    }

    #[test]
    fn default_config_has_30_arcsec_threshold() {
        let cfg = AllSkyPolarAlignConfig::default();
        assert_eq!(cfg.acceptance_threshold_arcsec, 30.0);
    }

    /// Compile-time: ensure the public type re-exports are reachable
    /// (regression guard for module reorganization).
    #[test]
    fn public_types_are_reachable() {
        let _: Option<SolvedFrame> = None;
        let _: Option<PolarMisalignment> = None;
        let _: fn(&SolvedFrame, &SolvedFrame, f64, f64, bool) -> PolarMisalignment =
            compute_polar_misalignment_from_drift;
    }
}
