//! Three-Point Polar Alignment (TPPA).
//!
//! This module implements the high-level TPPA flow:
//! 1. Optionally slew to a near-pole starting position.
//! 2. Capture and plate-solve three frames separated by a rotation
//!    step around the mount's polar axis.
//! 3. Compute the mechanical centre of rotation from those three
//!    points, then enter an unbounded adjustment loop that displays
//!    a live (Δaz, Δalt) error vector until the user dials the
//!    misalignment below the configured threshold.
//!
//! ## Implementation
//!
//! The flow is expressed as a [`crate::wizard::Wizard`] so the three
//! measurement steps are checkpointable (a sequence killed during
//! point 2 resumes by measuring point 2 again). The adjustment loop
//! is unbounded by design and lives in a single non-resumable step.
//! Mathematics and image preview helpers live in submodules so this
//! file reads as a pure state machine.
//!
//! ## `unwrap_or` policy
//!
//! * `config.binning.unwrap_or(1)` — 1×1 binning is the
//!   star-detection-optimal default and matches the PA wizard UI's
//!   "Binning" dropdown default.

mod math;
mod preview;

pub use math::{
    calculate_alignment_error_arcmin, fit_rotation_axis, rotate_axis_by_star_motion,
    RotationAxisFit,
};
pub use preview::prepare_image_for_display;

use crate::wizard::{
    wait_for_slew_complete, NoopProgressReporter, NullCheckpointSink, Wizard, WizardExecutor,
    WizardProgressReporter, WizardRunStatus, WizardStepOutcome,
};
use crate::*;
use std::time::Duration;
use tokio::time::sleep;

/// Image data for polar alignment UI display.
#[derive(Debug, Clone)]
pub struct PolarAlignmentImageData {
    pub image_data: Vec<u8>,
    pub width: u32,
    pub height: u32,
    pub solved_ra: Option<f64>,
    pub solved_dec: Option<f64>,
    /// Current measurement point (1-3) or 0 for adjustment phase.
    pub point: i32,
    /// Phase: "measuring" or "adjusting".
    pub phase: String,
}

/// Configuration for polar alignment.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct PolarAlignConfig {
    pub step_size: f64,
    pub exposure_time: f64,
    pub solve_timeout: f64,
    pub manual_rotation: bool,
    pub rotate_east: bool,
    pub gain: Option<i32>,
    pub offset: Option<i32>,
    pub binning: Option<i32>,
    // These three were added after the original config shape shipped, so
    // sequence JSON authored before the serializer emitted them (or by an
    // older client) must still deserialize — without the defaults a single
    // Polar Alignment node hard-failed the WHOLE sequence load with
    // "missing field `start_from_current`". Defaults mirror `Default`.
    #[serde(default = "default_start_from_current")]
    pub start_from_current: bool,
    #[serde(default = "default_is_north")]
    pub is_north: bool,
    /// Auto-complete threshold in arcseconds (default 30").
    #[serde(default = "default_auto_complete_threshold")]
    pub auto_complete_threshold: f64,
}

fn default_start_from_current() -> bool {
    true
}

fn default_is_north() -> bool {
    true
}

fn default_auto_complete_threshold() -> f64 {
    30.0
}

impl Default for PolarAlignConfig {
    fn default() -> Self {
        Self {
            step_size: 15.0,
            exposure_time: 5.0,
            solve_timeout: 30.0,
            manual_rotation: false,
            rotate_east: true,
            gain: None,
            offset: None,
            binning: Some(2),
            start_from_current: true,
            is_north: true,
            auto_complete_threshold: 30.0,
        }
    }
}

/// Result of polar alignment calculation.
#[derive(Debug, Clone, serde::Serialize)]
pub struct PolarAlignResult {
    pub azimuth_error: f64,
    pub altitude_error: f64,
    pub total_error: f64,
    pub current_ra: f64,
    pub current_dec: f64,
    pub target_ra: f64,
    pub target_dec: f64,
}

/// Steps in the three-point polar-alignment plan.
#[derive(Clone, serde::Serialize, serde::Deserialize)]
enum PolarStep {
    /// Optional initial slew to a near-pole position. Skipped when
    /// `start_from_current` is true.
    SlewToStart,
    /// Capture, solve, and (for points 0..2) rotate the mount toward
    /// the next measurement position.
    MeasurePoint(u8),
    /// Unbounded adjustment-feedback loop.
    Adjustment,
}

/// Internal state for a polar-alignment run.
struct PolarAlignRun<'a, S, I>
where
    S: Fn(String, Option<f64>) + Send + Sync,
    I: Fn(PolarAlignmentImageData) + Send + Sync,
{
    config: &'a PolarAlignConfig,
    mount_id: String,
    camera_id: String,
    status_callback: &'a S,
    image_callback: &'a I,
    /// Solved (RA°, Dec°) coordinates of each measurement point.
    points: Vec<(f64, f64)>,
    /// Terminal `InstructionResult`. Populated by the adjustment step
    /// when auto-complete fires (and on cancellation paths).
    terminal_result: Option<InstructionResult>,
}

#[async_trait::async_trait]
impl<'a, S, I> Wizard for PolarAlignRun<'a, S, I>
where
    S: Fn(String, Option<f64>) + Send + Sync,
    I: Fn(PolarAlignmentImageData) + Send + Sync,
{
    type StepKey = PolarStep;
    type Outcome = InstructionResult;

    fn name(&self) -> &'static str {
        "Polar Alignment"
    }
    fn checkpoint_key(&self) -> &'static str {
        "polar_alignment"
    }

    fn plan_steps(&self, _resume_idx: usize) -> Vec<PolarStep> {
        // Polar alignment has a fixed plan; the executor handles resume
        // by skipping the first `_resume_idx` steps.
        let mut plan = Vec::new();
        if !self.config.start_from_current {
            plan.push(PolarStep::SlewToStart);
        }
        plan.push(PolarStep::MeasurePoint(0));
        plan.push(PolarStep::MeasurePoint(1));
        plan.push(PolarStep::MeasurePoint(2));
        plan.push(PolarStep::Adjustment);
        plan
    }

    fn describe_step(&self, step: &PolarStep, _idx: usize) -> String {
        match step {
            PolarStep::SlewToStart => "Slewing to alignment start".to_string(),
            PolarStep::MeasurePoint(i) => format!("Measuring point {}/3", i + 1),
            PolarStep::Adjustment => "Adjustment phase".to_string(),
        }
    }

    async fn execute_step(
        &mut self,
        ctx: &InstructionContext,
        step: PolarStep,
        _idx: usize,
        _progress: &dyn WizardProgressReporter,
    ) -> WizardStepOutcome<PolarStep> {
        match step {
            PolarStep::SlewToStart => {
                self.do_slew_to_start(ctx).await;
                WizardStepOutcome::Completed
            }
            PolarStep::MeasurePoint(i) => self.do_measure_point(ctx, i).await,
            PolarStep::Adjustment => self.do_adjustment_loop(ctx).await,
        }
    }

    fn finalize(self, status: WizardRunStatus) -> InstructionResult {
        if let Some(r) = self.terminal_result {
            return r;
        }
        match status {
            WizardRunStatus::Completed => InstructionResult::success(),
            WizardRunStatus::Cancelled => InstructionResult::cancelled("Operation cancelled"),
            WizardRunStatus::Failed(msg) => InstructionResult::failure(msg),
        }
    }
}

impl<'a, S, I> PolarAlignRun<'a, S, I>
where
    S: Fn(String, Option<f64>) + Send + Sync,
    I: Fn(PolarAlignmentImageData) + Send + Sync,
{
    async fn do_slew_to_start(&self, ctx: &InstructionContext) {
        (self.status_callback)(
            "Slewing to alignment start position...".to_string(),
            Some(0.0),
        );

        let (start_ra, start_dec) = if self.config.is_north {
            (2.0, 89.0) // Near Polaris
        } else {
            (21.0, -89.0) // Near southern celestial pole
        };

        if let Err(e) = ctx
            .device_ops
            .mount_slew_to_coordinates(&self.mount_id, start_ra, start_dec)
            .await
        {
            tracing::warn!("Failed to slew to start position: {}", e);
            // Continue anyway — the user can manually position if needed.
            return;
        }

        if let Err(e) =
            wait_for_slew_complete(ctx, &self.mount_id, 300, "Slew to alignment start position")
                .await
        {
            tracing::warn!("{}", e);
        }
    }

    async fn do_measure_point(
        &mut self,
        ctx: &InstructionContext,
        i: u8,
    ) -> WizardStepOutcome<PolarStep> {
        if let Some(result) = ctx.check_cancelled() {
            self.terminal_result = Some(result);
            return WizardStepOutcome::Cancelled;
        }

        (self.status_callback)(
            format!("Measuring point {}/3...", i + 1),
            // Why: u8 in 0..3; lossless to f64.
            Some(f64::from(i) / 3.0),
        );

        let image_data = match ctx
            .device_ops
            .camera_start_exposure(
                &self.camera_id,
                self.config.exposure_time,
                None,
                None,
                self.config.binning.unwrap_or(1),
                self.config.binning.unwrap_or(1),
            )
            .await
        {
            Ok(data) => data,
            Err(e) => {
                return WizardStepOutcome::Failed(format!("Failed to capture image: {}", e));
            }
        };

        preview::emit_preview(
            &image_data,
            self.image_callback,
            None,
            None,
            i32::from(i + 1),
            "measuring",
        );

        let solve_result = match ctx
            .device_ops
            .plate_solve(
                &image_data,
                None,
                None,
                // 4th argument is hint_scale (arcsec/pixel), NOT a timeout.
                // This step has no measured scale of its own; the device
                // layer derives it from the profile optics and the camera.
                None,
            )
            .await
        {
            Ok(res) if res.success => res,
            Ok(_) => return WizardStepOutcome::Failed("Plate solve failed".to_string()),
            Err(e) => return WizardStepOutcome::Failed(format!("Plate solve error: {}", e)),
        };

        preview::emit_preview(
            &image_data,
            self.image_callback,
            Some(solve_result.ra_degrees),
            Some(solve_result.dec_degrees),
            i32::from(i + 1),
            "measuring",
        );

        self.points
            .push((solve_result.ra_degrees, solve_result.dec_degrees));

        // Rotate the mount toward the next measurement position (unless
        // this was the third point).
        if i < 2 {
            (self.status_callback)(format!("Rotating mount for point {}...", i + 2), None);
            if self.config.manual_rotation {
                tracing::info!("Waiting for manual rotation...");
                sleep(Duration::from_secs(10)).await;
            } else {
                let current_ra = solve_result.ra_degrees;
                let current_dec = solve_result.dec_degrees;
                let move_amount = if self.config.rotate_east {
                    self.config.step_size
                } else {
                    -self.config.step_size
                };
                let target_ra = (current_ra + move_amount + 360.0) % 360.0;

                if let Err(e) = ctx
                    .device_ops
                    .mount_slew_to_coordinates(&self.mount_id, target_ra / 15.0, current_dec)
                    .await
                {
                    return WizardStepOutcome::Failed(format!("Failed to rotate mount: {}", e));
                }

                if let Err(e) = wait_for_slew_complete(
                    ctx,
                    &self.mount_id,
                    300,
                    "Mount rotation for polar alignment",
                )
                .await
                {
                    return WizardStepOutcome::Failed(e);
                }
            }
        }
        WizardStepOutcome::Completed
    }

    async fn do_adjustment_loop(
        &mut self,
        ctx: &InstructionContext,
    ) -> WizardStepOutcome<PolarStep> {
        let Some(fit) = math::fit_rotation_axis(&self.points, self.config.is_north) else {
            return WizardStepOutcome::Failed(
                "The three measurement points do not describe a rotation — the mount did not \
                 turn between them, or the same field was solved three times."
                    .to_string(),
            );
        };
        let (center_ra, center_dec) = (fit.ra_degrees, fit.dec_degrees);
        tracing::info!(
            "Calculated Center of Rotation: RA {:.4}°, Dec {:.4}° \
             (circle radius {:.2}°, arc {:.1}°, {:.2}°/arcmin of point error)",
            center_ra,
            center_dec,
            fit.radius_degrees,
            fit.arc_degrees,
            fit.axis_degrees_per_arcmin
        );

        (self.status_callback)("Entering adjustment mode".to_string(), Some(1.0));

        let threshold_arcsec = self.config.auto_complete_threshold;
        let threshold_arcmin = threshold_arcsec / 60.0;
        let mut below_threshold_start: Option<std::time::Instant> = None;
        const AUTO_COMPLETE_HOLD_SECS: u64 = 3;

        // the reference star's solved position on the FIRST adjustment
        // frame. As the operator turns the alt/az bolts, the live solved
        // position drifts from this; the rigid rotation between them is applied
        // to the measured axis so the displayed error actually tracks the
        // adjustment instead of being frozen at the initial measurement.
        let mut initial_solved: Option<(f64, f64)> = None;

        let (observer_latitude, observer_longitude) = match (ctx.latitude, ctx.longitude) {
            (Some(lat), Some(lon)) => (lat, lon),
            _ => match ctx.device_ops.get_observer_location() {
                Some(loc) => loc,
                None => {
                    return WizardStepOutcome::Failed(
                        "Polar alignment requires observer latitude/longitude to calculate azimuth and altitude error".to_string(),
                    );
                }
            },
        };

        loop {
            if let Some(result) = ctx.check_cancelled() {
                self.terminal_result = Some(result);
                return WizardStepOutcome::Cancelled;
            }

            let image_data = match ctx
                .device_ops
                .camera_start_exposure(
                    &self.camera_id,
                    self.config.exposure_time,
                    None,
                    None,
                    self.config.binning.unwrap_or(1),
                    self.config.binning.unwrap_or(1),
                )
                .await
            {
                Ok(data) => data,
                Err(e) => {
                    return WizardStepOutcome::Failed(format!("Failed to capture image: {}", e));
                }
            };

            preview::emit_preview(&image_data, self.image_callback, None, None, 0, "adjusting");

            let solve_result = match ctx
                .device_ops
                .plate_solve(
                    &image_data,
                    None,
                    None,
                    // 4th argument is hint_scale (arcsec/pixel), NOT a timeout.
                    // This step has no measured scale of its own; the device
                    // layer derives it from the profile optics and the camera.
                    None,
                )
                .await
            {
                Ok(res) if res.success => res,
                _ => continue, // Ignore solve failures and retry.
            };

            preview::emit_preview(
                &image_data,
                self.image_callback,
                Some(solve_result.ra_degrees),
                Some(solve_result.dec_degrees),
                0,
                "adjusting",
            );

            let pole_dec = if self.config.is_north { 90.0 } else { -90.0 };

            // Anchor the reference star on the first solved frame, then track
            // the mechanical axis as the mount is adjusted.
            let current_solved = (solve_result.ra_degrees, solve_result.dec_degrees);
            let star_initial = *initial_solved.get_or_insert(current_solved);
            let (live_axis_ra, live_axis_dec) = math::rotate_axis_by_star_motion(
                (center_ra, center_dec),
                star_initial,
                current_solved,
            );

            let (az_error_am, alt_error_am, total_error_am) =
                math::calculate_alignment_error_arcmin(
                    live_axis_ra,
                    live_axis_dec,
                    self.config.is_north,
                    observer_latitude,
                    observer_longitude,
                    chrono::Utc::now(),
                );

            let result = PolarAlignResult {
                azimuth_error: az_error_am,
                altitude_error: alt_error_am,
                total_error: total_error_am,
                current_ra: solve_result.ra_degrees,
                current_dec: solve_result.dec_degrees,
                target_ra: center_ra,
                target_dec: pole_dec,
            };

            if let Err(e) = ctx.device_ops.polar_align_update(&result).await {
                tracing::warn!("Failed to send polar align update: {}", e);
            }

            tracing::info!(
                "Polar Align Error: Alt {:.1}', Az {:.1}'",
                result.altitude_error,
                result.azimuth_error
            );

            if total_error_am < threshold_arcmin {
                match below_threshold_start {
                    None => {
                        below_threshold_start = Some(std::time::Instant::now());
                        tracing::info!("Error below threshold, starting hold timer");
                    }
                    Some(start) => {
                        if start.elapsed().as_secs() >= AUTO_COMPLETE_HOLD_SECS {
                            tracing::info!(
                                "Auto-complete: error held below threshold for {}s",
                                AUTO_COMPLETE_HOLD_SECS
                            );
                            let msg = format!(
                                "Polar alignment complete! Final error: {:.1}\" (below {:.0}\" threshold)",
                                total_error_am * 60.0,
                                threshold_arcsec
                            );
                            self.terminal_result =
                                Some(InstructionResult::success_with_message(msg));
                            return WizardStepOutcome::Done;
                        }
                    }
                }
            } else if below_threshold_start.is_some() {
                tracing::debug!("Error above threshold, resetting hold timer");
                below_threshold_start = None;
            }

            sleep(Duration::from_secs(1)).await;
        }
    }
}

/// Execute three-point polar alignment.
pub async fn perform_polar_alignment(
    config: &PolarAlignConfig,
    ctx: &InstructionContext,
    status_callback: impl Fn(String, Option<f64>) + Send + Sync,
    image_callback: impl Fn(PolarAlignmentImageData) + Send + Sync,
) -> InstructionResult {
    let mount_id = match ctx.mount_id() {
        Ok(id) => id.to_string(),
        Err(e) => return e,
    };
    let camera_id = match ctx.camera_id() {
        Ok(id) => id.to_string(),
        Err(e) => return e,
    };

    let wizard = PolarAlignRun {
        config,
        mount_id,
        camera_id,
        status_callback: &status_callback,
        image_callback: &image_callback,
        points: Vec::new(),
        terminal_result: None,
    };

    // The polar wizard surfaces status updates via `status_callback`, so the
    // shared wizard reporter is a no-op. `NullCheckpointSink` keeps
    // standalone (non-sequence) runs from accumulating wizard checkpoint
    // state on disk.
    let progress = NoopProgressReporter;
    static SINK: NullCheckpointSink = NullCheckpointSink;
    let executor = WizardExecutor::new(&progress, &SINK);
    let (result, _status) = executor.run(wizard, ctx).await;
    result
}

#[cfg(test)]
mod config_serde_tests {
    use super::PolarAlignConfig;

    /// Sequence JSON authored before the serializer emitted
    /// `start_from_current` / `is_north` / `auto_complete_threshold` (or by an
    /// older client) must still deserialize — without the serde defaults a
    /// single Polar Alignment node hard-failed the WHOLE sequence load.
    #[test]
    fn legacy_config_without_late_fields_deserializes_to_defaults() {
        let legacy = r#"{
            "step_size": 20.0,
            "exposure_time": 2.0,
            "solve_timeout": 60.0,
            "manual_rotation": false,
            "rotate_east": true,
            "gain": null,
            "offset": null,
            "binning": 2
        }"#;
        let cfg: PolarAlignConfig =
            serde_json::from_str(legacy).expect("legacy polar config must parse");
        assert!(cfg.start_from_current);
        assert!(cfg.is_north);
        assert!((cfg.auto_complete_threshold - 30.0).abs() < 1e-9);
    }
}
