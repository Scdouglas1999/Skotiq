//! Flat Wizard - Automated Flat Field Calibration
//!
//! Automatically determines optimal exposure time to hit target ADU
//! value using a binary-search algorithm. Supports flat panels and sky
//! flats.
//!
//! For flat panel mode the high-level flow is:
//! 1. Change filter (optional).
//! 2. Slew to zenith / sky-flat alt-az.
//! 3. Open cover (dust cap) and turn on flat panel at the requested
//!    brightness.
//! 4. Binary-search the exposure time, optionally adjusting brightness
//!    if the search hits the configured exposure bounds.
//! 5. Capture the requested flat frames at the converged exposure.
//! 6. Turn off the panel and close the cover.
//!
//! ## Implementation
//!
//! The wizard is implemented on top of [`crate::wizard::Wizard`] so the
//! binary-search iterations are step-checkpointable: a sequence killed
//! mid-search resumes on the next iteration. The cover/calibrator
//! device dance lives in [`panel`].
//!
//! Final frames use the sequencer's normal exposure pipeline so their
//! FITS files and metadata match ordinary calibration captures.

mod panel;

use crate::instructions::{
    execute_exposure_with_renderer, resolve_frame_filter, BurstControl, InstructionContext,
    InstructionResult,
};
use crate::node::instructions::expose::build_save_path_renderer;
use crate::wizard::{
    BorrowedProgressReporter, Wizard, WizardExecutor, WizardProgressReporter, WizardRunStatus,
    WizardStepOutcome,
};
use crate::NodeStatus;
use crate::{ExposureConfig, FlatWizardConfig, PanelLocation};
use async_trait::async_trait;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

/// Maximum number of binary-search iterations before declaring
/// non-convergence.
const MAX_BINARY_SEARCH_ITERATIONS: u32 = 10;

/// Steps in the flat-wizard plan. The plan begins as `[Filter, Position,
/// Panel, Iter(1)]` and dynamically appends `Iter(n+1)` until
/// convergence or the iteration cap is hit.
#[derive(Clone, serde::Serialize, serde::Deserialize)]
enum FlatStep {
    Filter,
    Position,
    Panel,
    Iter(u32),
}

/// Internal state for the flat-wizard run.
///
/// `panel_cleanup_required` is shared with the outer wrapper via an
/// `Arc<AtomicBool>` so that wrapper can run the panel teardown step
/// after any panel resource is acquired, regardless of how the wizard
/// exited (success, failure, cancel).
struct FlatWizardRun<'a> {
    config: &'a FlatWizardConfig,
    /// Current brightness; mutated when auto-adjust kicks in.
    current_brightness: i32,
    /// Lower bound of the binary-search exposure window.
    min_exp: f64,
    /// Upper bound of the binary-search exposure window.
    max_exp: f64,
    /// Last measured ADU (for the non-convergence error message).
    last_adu: Option<u16>,
    /// On success: the converged (exposure, adu, brightness) triple.
    converged: Option<(f64, u16, i32)>,
    panel_cleanup_required: Arc<AtomicBool>,
}

#[async_trait]
impl<'a> Wizard for FlatWizardRun<'a> {
    type StepKey = FlatStep;
    type Outcome = InstructionResult;

    fn name(&self) -> &'static str {
        "Flat Wizard"
    }

    fn checkpoint_key(&self) -> &'static str {
        "flat_wizard"
    }

    fn plan_steps(&self, resume_idx: usize) -> Vec<FlatStep> {
        // Seed plan: structural setup (3 steps) + first binary-search
        // iteration. The binary-search loop appends `Iter(n+1)`
        // dynamically until convergence.
        //
        // On resume (resume_idx > 4), expand the plan eagerly so the
        // executor's `while idx < plan.len()` loop body re-enters at
        // the correct iteration. Iterations are 1-indexed (`Iter(1)`,
        // `Iter(2)`, ...), so plan index 4 is `Iter(2)`, plan index 5
        // is `Iter(3)`, etc.
        let mut plan = vec![
            FlatStep::Filter,
            FlatStep::Position,
            FlatStep::Panel,
            FlatStep::Iter(1),
        ];
        // Extend up to and past resume_idx so the executor enters its
        // loop body at the resume position. We extend up to MAX
        // iterations (the natural cap) — `do_binary_search_iteration`
        // returns `Done` on convergence and trims the rest.
        let mut next_iter = 2_u32;
        while plan.len() <= resume_idx && next_iter <= MAX_BINARY_SEARCH_ITERATIONS {
            plan.push(FlatStep::Iter(next_iter));
            next_iter += 1;
        }
        plan
    }

    fn describe_step(&self, step: &FlatStep, _idx: usize) -> String {
        match step {
            FlatStep::Filter => "Changing filter".to_string(),
            FlatStep::Position => "Positioning for flats".to_string(),
            FlatStep::Panel => "Setting up flat panel".to_string(),
            FlatStep::Iter(n) => format!(
                "Binary search iteration {}/{}",
                n, MAX_BINARY_SEARCH_ITERATIONS
            ),
        }
    }

    async fn execute_step(
        &mut self,
        ctx: &InstructionContext,
        step: FlatStep,
        _idx: usize,
        progress: &dyn WizardProgressReporter,
    ) -> WizardStepOutcome<FlatStep> {
        match step {
            FlatStep::Filter => match self.do_filter_change(ctx).await {
                Ok(()) => WizardStepOutcome::Completed,
                Err(e) => WizardStepOutcome::Failed(e),
            },
            FlatStep::Position => match panel::position_for_flats(self.config, ctx, progress).await
            {
                Ok(()) => WizardStepOutcome::Completed,
                Err(e) => WizardStepOutcome::Failed(e),
            },
            FlatStep::Panel => {
                if !matches!(self.config.panel_location, PanelLocation::FlatPanel) {
                    return WizardStepOutcome::Completed;
                }
                progress.report(0.2, "Setting up flat panel".to_string());
                match panel::setup_flat_panel(
                    ctx,
                    self.current_brightness,
                    progress,
                    self.panel_cleanup_required.as_ref(),
                )
                .await
                {
                    Ok(()) => WizardStepOutcome::Completed,
                    Err(e) => WizardStepOutcome::Failed(e),
                }
            }
            FlatStep::Iter(n) => self.do_binary_search_iteration(ctx, n, progress).await,
        }
    }

    fn finalize(self, status: WizardRunStatus) -> InstructionResult {
        match (status, self.converged) {
            (
                WizardRunStatus::Completed,
                Some((optimal_exposure, actual_adu, final_brightness)),
            ) => {
                tracing::info!(
                    "Flat wizard complete: optimal exposure = {:.3}s, ADU = {}, brightness = {}",
                    optimal_exposure,
                    actual_adu,
                    final_brightness
                );
                InstructionResult {
                    status: NodeStatus::Success,
                    message: Some(format!(
                        "Captured {} flat frames at {:.3}s (ADU: {}, brightness: {})",
                        self.config.flat_count, optimal_exposure, actual_adu, final_brightness
                    )),
                    data: Some(serde_json::json!({
                        "optimal_exposure_secs": optimal_exposure,
                        "actual_adu": actual_adu,
                        "target_adu": self.config.target_adu,
                        "flat_count": self.config.flat_count,
                        "filter": self.config.filter,
                        "brightness": final_brightness,
                        "panel_location": format!("{:?}", self.config.panel_location),
                    })),
                    hfr_values: Vec::new(),
                }
            }
            (WizardRunStatus::Cancelled, _) => InstructionResult::failure("Operation cancelled"),
            (WizardRunStatus::Failed(msg), _) => InstructionResult::failure(msg),
            (WizardRunStatus::Completed, None) => {
                // Plan exhausted without convergence — emit the canonical
                // error message.
                let tolerance = (f64::from(self.config.target_adu) * self.config.tolerance_percent
                    / 100.0) as u16;
                let message = format!(
                    "Flat wizard did not converge after {} iterations (range {:.3}s-{:.3}s, last ADU={:?}, target={}±{}). \
Try adjusting panel brightness or exposure bounds.",
                    MAX_BINARY_SEARCH_ITERATIONS,
                    self.min_exp,
                    self.max_exp,
                    self.last_adu,
                    self.config.target_adu,
                    tolerance
                );
                tracing::warn!("{}", message);
                InstructionResult::failure(message)
            }
        }
    }
}

impl<'a> FlatWizardRun<'a> {
    async fn do_filter_change(&self, ctx: &InstructionContext) -> Result<(), String> {
        if self.config.filter.is_none() && self.config.filter_index.is_none() {
            return Ok(());
        }
        let fw_id = match &ctx.filterwheel_id {
            Some(id) => id,
            None => return Ok(()),
        };
        if let Some(index) = self.config.filter_index {
            tracing::info!(
                "Changing to filter position: {} (name: {:?})",
                index,
                self.config.filter
            );
            ctx.device_ops
                .filterwheel_set_position(fw_id, index)
                .await
                .map_err(|e| format!("Failed to change filter: {}", e))
        } else if let Some(filter_name) = &self.config.filter {
            tracing::info!("Changing to filter by name: {}", filter_name);
            ctx.device_ops
                .filterwheel_set_filter_by_name(fw_id, filter_name)
                .await
                .map(|_| ())
                .map_err(|e| format!("Failed to change filter: {}", e))
        } else {
            Ok(())
        }
    }

    async fn do_binary_search_iteration(
        &mut self,
        ctx: &InstructionContext,
        iteration: u32,
        progress: &dyn WizardProgressReporter,
    ) -> WizardStepOutcome<FlatStep> {
        let camera_id = match ctx.camera_id.as_deref() {
            Some(id) => id,
            None => return WizardStepOutcome::Failed("No camera connected".to_string()),
        };

        if ctx.cancellation_token.load(Ordering::Relaxed) {
            return WizardStepOutcome::Cancelled;
        }

        let target_adu = self.config.target_adu;
        // Why: target_adu is u16 (0..=65535) -> f64 lossless. Tolerance is at
        // most target_adu * 100 / 100 = target_adu, so the f64 -> u16 cast is
        // in range for any non-negative tolerance_percent <= 100. `as u16`
        // saturates on overflow, matching the "max tolerance == target"
        // intent for misconfig.
        let tolerance = (f64::from(target_adu) * self.config.tolerance_percent / 100.0) as u16;
        let is_flat_panel = matches!(self.config.panel_location, PanelLocation::FlatPanel);

        let test_exposure = (self.min_exp + self.max_exp) / 2.0;

        // Iterations span 30%..85% of overall progress.
        // Why: iteration is u32 in 1..=10; both lossless to f64.
        let fraction =
            0.30 + (f64::from(iteration) / f64::from(MAX_BINARY_SEARCH_ITERATIONS)) * 0.55;
        progress.report(
            fraction,
            format!(
                "Capturing flat frame {}/{}",
                iteration, MAX_BINARY_SEARCH_ITERATIONS
            ),
        );

        tracing::info!(
            "Iteration {}/{}: testing {:.3}s exposure at brightness {}, binning {}",
            iteration,
            MAX_BINARY_SEARCH_ITERATIONS,
            test_exposure,
            self.current_brightness,
            ctx.current_binning.as_str()
        );

        let (bin_x, bin_y) = binning_dimensions(ctx.current_binning);
        let image_data = match ctx
            .device_ops
            .camera_start_exposure(camera_id, test_exposure, None, None, bin_x, bin_y)
            .await
        {
            Ok(data) => data,
            Err(e) => return WizardStepOutcome::Failed(format!("Test exposure failed: {}", e)),
        };

        let median_adu = calculate_median_adu(&image_data);
        self.last_adu = Some(median_adu);

        tracing::info!("Test exposure: {:.3}s -> {} ADU", test_exposure, median_adu);

        if median_adu.abs_diff(target_adu) <= tolerance {
            tracing::info!(
                "Found optimal exposure: {:.3}s (ADU={}, target={}±{}, brightness={})",
                test_exposure,
                median_adu,
                target_adu,
                tolerance,
                self.current_brightness
            );
            let capture_result = capture_converged_flats(
                self.config,
                ctx,
                test_exposure,
                |frame, total, _recorded_secs| {
                    let capture_fraction = if total == 0 {
                        1.0
                    } else {
                        f64::from(frame) / f64::from(total)
                    };
                    progress.report(
                        0.85 + capture_fraction * 0.05,
                        format!(
                            "Capturing final flat frame {}/{} at {:.3}s",
                            frame, total, test_exposure
                        ),
                    );
                },
            )
            .await;

            match capture_result.status {
                NodeStatus::Success => {
                    self.converged = Some((test_exposure, median_adu, self.current_brightness));
                    return WizardStepOutcome::Done;
                }
                NodeStatus::Cancelled => return WizardStepOutcome::Cancelled,
                _ => {
                    return WizardStepOutcome::Failed(
                        capture_result
                            .message
                            .unwrap_or_else(|| "Final flat capture failed".to_string()),
                    );
                }
            }
        }

        // Adjust search range / brightness.
        if median_adu < target_adu {
            // Too dark, need longer exposure or brighter panel.
            self.min_exp = test_exposure;
            if test_exposure >= self.config.max_exposure * 0.9
                && is_flat_panel
                && self.config.auto_adjust_brightness
                && self.current_brightness < self.config.max_brightness
            {
                let new_brightness = (self.current_brightness + 20).min(self.config.max_brightness);
                tracing::info!(
                    "Max exposure reached with low ADU, increasing brightness from {} to {}",
                    self.current_brightness,
                    new_brightness
                );
                self.current_brightness = new_brightness;
                if let Err(e) = panel::set_panel_brightness(ctx, new_brightness).await {
                    tracing::warn!("Failed to adjust brightness: {}", e);
                } else {
                    self.min_exp = self.config.min_exposure;
                    self.max_exp = self.config.max_exposure;
                }
            }
        } else {
            // Too bright, need shorter exposure or dimmer panel.
            self.max_exp = test_exposure;
            if test_exposure <= self.config.min_exposure * 1.1
                && is_flat_panel
                && self.config.auto_adjust_brightness
                && self.current_brightness > self.config.min_brightness
            {
                let new_brightness = (self.current_brightness - 20).max(self.config.min_brightness);
                tracing::info!(
                    "Min exposure reached with high ADU, decreasing brightness from {} to {}",
                    self.current_brightness,
                    new_brightness
                );
                self.current_brightness = new_brightness;
                if let Err(e) = panel::set_panel_brightness(ctx, new_brightness).await {
                    tracing::warn!("Failed to adjust brightness: {}", e);
                } else {
                    self.min_exp = self.config.min_exposure;
                    self.max_exp = self.config.max_exposure;
                }
            }
        }

        if (self.max_exp - self.min_exp) < 0.001 {
            let message = format!(
                "Flat wizard did not converge: exposure search range collapsed to {:.4}s at {:.3}s (ADU={}, target={}±{}). \
Try adjusting panel brightness or widening exposure limits.",
                self.max_exp - self.min_exp,
                test_exposure,
                median_adu,
                target_adu,
                tolerance
            );
            tracing::warn!("{}", message);
            return WizardStepOutcome::Failed(message);
        }

        if iteration < MAX_BINARY_SEARCH_ITERATIONS {
            WizardStepOutcome::ContinueWithNext(FlatStep::Iter(iteration + 1))
        } else {
            // Plan exhausts; finalize emits the non-convergence error.
            WizardStepOutcome::Completed
        }
    }
}

fn binning_dimensions(binning: crate::Binning) -> (i32, i32) {
    let dimension = match binning {
        crate::Binning::One => 1,
        crate::Binning::Two => 2,
        crate::Binning::Three => 3,
        crate::Binning::Four => 4,
    };
    (dimension, dimension)
}

fn final_flat_exposure_config(
    config: &FlatWizardConfig,
    binning: crate::Binning,
    exposure_secs: f64,
) -> ExposureConfig {
    ExposureConfig {
        duration_secs: exposure_secs,
        count: config.flat_count,
        filter: config.filter.clone(),
        filter_index: config.filter_index,
        binning,
        dither_every: None,
        frame_type: "Flat".to_string(),
        ..ExposureConfig::default()
    }
}

/// Capture the requested flats at the converged exposure.
///
/// Flats go through the same save-path renderer as every other frame in the
/// session, so the user's configured naming template applies to them:
/// [`execute_exposure`]'s renderer-less branch falls back to the pre-template
/// `<target>_<filter>_<NNNN>.fits` layout and files a flat run with no target
/// — the normal shape, since flats are not shot at anything — under the
/// synthetic label `untargeted` instead of `Flat`.
///
/// The filter identity comes from [`resolve_frame_filter`], the same answer the
/// FITS FILTER card and the `captured_images` row are built from, so the
/// filename cannot disagree with the header.
pub(crate) async fn capture_converged_flats(
    config: &FlatWizardConfig,
    ctx: &InstructionContext,
    exposure_secs: f64,
    progress_callback: impl Fn(u32, u32, f64),
) -> InstructionResult {
    let capture_config = final_flat_exposure_config(config, ctx.current_binning, exposure_secs);

    let (filter_name, filter_index) = resolve_frame_filter(&capture_config, ctx).await;
    let mut template_ctx = ctx.to_template_context();
    template_ctx.current_filter = filter_name;
    template_ctx.current_filter_index = filter_index;

    let renderer = match build_save_path_renderer(&template_ctx, &capture_config, exposure_secs) {
        Ok(renderer) => renderer,
        Err(message) => {
            tracing::error!("{}", message);
            if let Some(event_tx) = &ctx.event_tx {
                let _ = event_tx.send(crate::executor::ExecutorEvent::Error {
                    message: message.clone(),
                });
            }
            return InstructionResult::failure(message);
        }
    };

    execute_exposure_with_renderer(
        &capture_config,
        ctx,
        Some(renderer),
        &BurstControl::default(),
        progress_callback,
    )
    .await
}

fn surface_cleanup_failure(result: &mut InstructionResult, cleanup_error: String) {
    let run_message = result.message.take();
    result.message = Some(match run_message {
        Some(message) => format!("{}; flat panel cleanup failed: {}", message, cleanup_error),
        None => format!("Flat panel cleanup failed: {}", cleanup_error),
    });
    if result.status == NodeStatus::Success {
        result.status = NodeStatus::Failure;
    }
}

/// Execute the flat wizard and capture flats at the optimal exposure.
///
/// This is the public entry point invoked from the sequencer node
/// dispatch ([`crate::NodeType::FlatWizard`]).
pub async fn execute_flat_wizard(
    config: &FlatWizardConfig,
    ctx: &InstructionContext,
    progress_callback: Option<&(dyn Fn(f64, String) + Send + Sync)>,
) -> InstructionResult {
    tracing::info!(
        "Starting flat wizard: target ADU={}, range={:.3}s-{:.1}s, location={:?}",
        config.target_adu,
        config.min_exposure,
        config.max_exposure,
        config.panel_location
    );

    // A missing camera is surfaced before any other work.
    if ctx.camera_id.as_deref().is_none() {
        return InstructionResult::failure("No camera connected");
    }

    let borrow_reporter = BorrowedProgressReporter {
        callback: progress_callback,
    };
    let executor = WizardExecutor::with_progress(&borrow_reporter);

    borrow_reporter.report(0.0, "Starting flat wizard".to_string());

    let panel_cleanup_required = Arc::new(AtomicBool::new(false));
    let wizard = FlatWizardRun {
        config,
        current_brightness: config.brightness,
        min_exp: config.min_exposure,
        max_exp: config.max_exposure,
        last_adu: None,
        converged: None,
        panel_cleanup_required: panel_cleanup_required.clone(),
    };
    let (mut result, _status) = executor.run(wizard, ctx).await;

    // Cleanup on exit after any panel resource was acquired, including
    // partial setup. A teardown error makes an otherwise successful run
    // fail: success must guarantee that the lamp is off and cover closed.
    if panel_cleanup_required.load(Ordering::Relaxed) {
        borrow_reporter.report(0.9, "Cleaning up flat panel".to_string());
        if let Err(e) = panel::cleanup_flat_panel(ctx).await {
            tracing::error!("Failed to cleanup flat panel: {}", e);
            surface_cleanup_failure(&mut result, e);
        }
    }

    if result.status == NodeStatus::Success {
        borrow_reporter.report(1.0, "Flat wizard complete".to_string());
    }

    result
}

/// Calculate median ADU value from image data.
///
/// Samples the central 25% of the image to avoid vignetting.
fn calculate_median_adu(image_data: &crate::device_ops::ImageData) -> u16 {
    // Why: u32 -> usize. usize is >=32 bits on all our target platforms.
    let width = image_data.width as usize;
    let height = image_data.height as usize;

    let x_start = width / 4;
    let x_end = (width * 3) / 4;
    let y_start = height / 4;
    let y_end = (height * 3) / 4;

    let mut pixels = Vec::new();
    for y in y_start..y_end {
        for x in x_start..x_end {
            let index = y * width + x;
            if index < image_data.data.len() {
                pixels.push(image_data.data[index]);
            }
        }
    }

    if pixels.is_empty() {
        tracing::warn!("No pixels in central region, using full image");
        pixels = image_data.data.clone();
    }

    pixels.sort_unstable();

    let median = if pixels.is_empty() {
        0
    } else {
        pixels[pixels.len() / 2]
    };

    tracing::debug!(
        "Median ADU: {} (from {} pixels in central region)",
        median,
        pixels.len()
    );

    median
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_test_image(width: u32, height: u32, data: Vec<u16>) -> crate::device_ops::ImageData {
        crate::device_ops::ImageData {
            width,
            height,
            data,
            bits_per_pixel: 16,
            exposure_secs: 1.0,
            gain: None,
            offset: None,
            temperature: None,
            filter: None,
            timestamp: 0,
            sensor_type: Some("Monochrome".to_string()),
            bayer_offset: None,
        }
    }

    #[test]
    fn test_median_adu_calculation() {
        let data = vec![30000u16; 10000];
        let image = make_test_image(100, 100, data);
        assert_eq!(calculate_median_adu(&image), 30000);
    }

    #[test]
    fn test_median_adu_with_variation() {
        let mut data = Vec::new();
        for i in 0..10000_u16 {
            // Why: test fixture; 0..10000, so 20000 + i <= 30000 fits in u16.
            data.push(20000 + i);
        }
        let image = make_test_image(100, 100, data);
        let median = calculate_median_adu(&image);
        assert!(median > 23000 && median < 27000);
    }

    #[test]
    fn test_altaz_to_radec_zenith() {
        // Zenith (alt=90, any azimuth) should give Dec = latitude.
        let (_ra, dec) = panel::altaz_to_radec(90.0, 180.0, 45.0, 0.0);
        assert!((dec - 45.0).abs() < 1.0);
    }

    /// Helper: build a default FlatWizardConfig for plan-tests.
    fn test_config() -> FlatWizardConfig {
        FlatWizardConfig::default()
    }

    /// Helper: build a FlatWizardRun with a no-op atomic flag.
    fn make_run(config: &FlatWizardConfig) -> FlatWizardRun<'_> {
        FlatWizardRun {
            config,
            current_brightness: config.brightness,
            min_exp: config.min_exposure,
            max_exp: config.max_exposure,
            last_adu: None,
            converged: None,
            panel_cleanup_required: Arc::new(AtomicBool::new(false)),
        }
    }

    /// Helper: extract the iteration number from a FlatStep, or None if
    /// it's a structural step.
    fn iter_of(step: &FlatStep) -> Option<u32> {
        match step {
            FlatStep::Iter(n) => Some(*n),
            _ => None,
        }
    }

    #[test]
    fn fresh_seed_plan_has_filter_position_panel_iter1() {
        // Why: regression guard — fresh runs (resume_idx=0) must keep the
        // structural setup + first binary-search step.
        let config = test_config();
        let run = make_run(&config);
        let plan = run.plan_steps(0);
        assert_eq!(plan.len(), 4);
        assert!(matches!(plan[0], FlatStep::Filter));
        assert!(matches!(plan[1], FlatStep::Position));
        assert!(matches!(plan[2], FlatStep::Panel));
        assert_eq!(iter_of(&plan[3]), Some(1));
    }

    #[test]
    fn resume_at_trial_3_extends_plan_to_include_iter_3() {
        // User-brief test: "simulate a checkpoint at exposure trial 3/N
        // — confirm resume starts at trial 4". `completed_steps` after
        // trial 3 = 6 (Filter, Position, Panel, Iter(1), Iter(2),
        // Iter(3) all done); the next step to execute is plan[6] which
        // should be Iter(4).
        let config = test_config();
        let run = make_run(&config);
        let plan = run.plan_steps(6);
        // Plan must extend at least to index 6 for the executor's
        // `while idx < plan.len()` loop body to re-enter.
        assert!(
            plan.len() > 6,
            "resume_idx=6 must produce a plan with > 6 entries, got {}",
            plan.len()
        );
        // Index 6 (the next step) is Iter(4).
        assert_eq!(iter_of(&plan[6]), Some(4));
        // Structural steps preserved at the head.
        assert!(matches!(plan[0], FlatStep::Filter));
        assert!(matches!(plan[1], FlatStep::Position));
        assert!(matches!(plan[2], FlatStep::Panel));
        // Iter(1)..Iter(3) at indices 3..5.
        assert_eq!(iter_of(&plan[3]), Some(1));
        assert_eq!(iter_of(&plan[4]), Some(2));
        assert_eq!(iter_of(&plan[5]), Some(3));
    }

    #[test]
    fn resume_at_or_beyond_max_iterations_does_not_overflow() {
        // Defensive: resume_idx larger than the max iteration cap
        // (3 structural + 10 iterations = 13 max) should bound at
        // MAX_BINARY_SEARCH_ITERATIONS.
        let config = test_config();
        let run = make_run(&config);
        let plan = run.plan_steps(100);
        // Total cap = 3 structural + MAX_BINARY_SEARCH_ITERATIONS.
        let expected_cap = 3 + MAX_BINARY_SEARCH_ITERATIONS as usize;
        assert_eq!(plan.len(), expected_cap);
        // Last entry is Iter(MAX).
        assert_eq!(
            iter_of(&plan[expected_cap - 1]),
            Some(MAX_BINARY_SEARCH_ITERATIONS)
        );
    }

    #[test]
    fn resume_at_structural_phase_does_not_extend_iter_plan() {
        // resume_idx=1 (after Filter) must NOT add extra iterations to
        // the plan — the seed plan is already long enough.
        let config = test_config();
        let run = make_run(&config);
        let plan = run.plan_steps(1);
        assert_eq!(plan.len(), 4);
    }

    #[test]
    fn final_flat_capture_uses_requested_count_and_flat_frame_type() {
        let mut config = test_config();
        config.flat_count = 17;
        config.filter = Some("Ha".to_string());
        config.filter_index = Some(3);

        let exposure = final_flat_exposure_config(&config, crate::Binning::Two, 2.5);

        assert_eq!(exposure.duration_secs, 2.5);
        assert_eq!(exposure.count, 17);
        assert_eq!(exposure.filter.as_deref(), Some("Ha"));
        assert_eq!(exposure.filter_index, Some(3));
        assert_eq!(exposure.binning, crate::Binning::Two);
        assert_eq!(exposure.dither_every, None);
        assert_eq!(exposure.frame_type, "Flat");
        assert_eq!(binning_dimensions(exposure.binning), (2, 2));
    }

    #[test]
    fn cleanup_failure_turns_success_into_failure_and_preserves_context() {
        let mut result = InstructionResult::success_with_message("Captured 30 flat frames");

        surface_cleanup_failure(&mut result, "calibrator stayed on".to_string());

        assert_eq!(result.status, NodeStatus::Failure);
        assert_eq!(
            result.message.as_deref(),
            Some("Captured 30 flat frames; flat panel cleanup failed: calibrator stayed on")
        );
    }
}
