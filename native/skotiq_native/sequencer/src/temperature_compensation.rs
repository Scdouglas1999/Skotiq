//! Temperature Compensation Instruction
//!
//! Monitors focuser temperature and adjusts focus position based on thermal coefficient
//! to compensate for focus drift during long imaging sessions.

use crate::instructions::{
    wait_for_focuser_stop_after_halt, InstructionContext, InstructionResult,
};
use std::time::Duration;

/// Execute temperature compensation
///
/// This instruction monitors the focuser temperature and moves the focuser to compensate
/// for thermal expansion/contraction. Unlike autofocus, this uses the learned thermal
/// coefficient to make targeted moves without a full focus sweep.
pub async fn execute_temperature_compensation(
    config: &TemperatureCompensationConfig,
    ctx: &InstructionContext,
    progress_callback: Option<&(dyn Fn(f64, String) + Send + Sync)>,
) -> InstructionResult {
    let focuser_id = match ctx.focuser_id() {
        Ok(id) => id.to_string(),
        Err(e) => return e,
    };

    if let Some(cb) = progress_callback {
        cb(0.0, "Starting temperature compensation".to_string());
    }

    tracing::info!(
        "Temperature compensation: coefficient={} steps/°C, mode={:?}",
        config.thermal_coefficient,
        config.mode
    );

    if let Some(cb) = progress_callback {
        cb(10.0, "Reading focuser temperature...".to_string());
    }

    let current_temp = match ctx
        .run
        .device_ops
        .focuser_get_temperature(&focuser_id)
        .await
    {
        Ok(Some(temp)) => temp,
        Ok(None) => {
            return InstructionResult::failure(
                "Focuser does not report temperature - temperature compensation requires a focuser with temperature sensor"
            );
        }
        Err(e) => {
            return InstructionResult::failure(format!(
                "Failed to read focuser temperature: {}",
                e
            ))
            .caused_by(&e);
        }
    };

    tracing::info!("Current focuser temperature: {:.2}°C", current_temp);

    if let Some(cb) = progress_callback {
        cb(
            20.0,
            format!("Reading focuser temperature: {:.1}°C", current_temp),
        );
    }

    // Check if we have trigger state with baseline temperature
    let trigger_state_lock = match &ctx.run.trigger_state {
        Some(lock) => lock,
        None => {
            return InstructionResult::failure(
                "Temperature compensation requires trigger state for baseline tracking",
            );
        }
    };

    let mut trigger_state = trigger_state_lock.write().await;

    let baseline_temp = match trigger_state.latches.baseline_temperature {
        Some(temp) => temp,
        None => {
            // First time - establish baseline
            tracing::info!("Establishing temperature baseline: {:.2}°C", current_temp);
            trigger_state.latches.baseline_temperature = Some(current_temp);
            trigger_state.latches.current_temperature = Some(current_temp);
            drop(trigger_state);

            return InstructionResult::success_with_message(format!(
                "Temperature baseline established at {:.2}°C",
                current_temp
            ));
        }
    };

    trigger_state.latches.current_temperature = Some(current_temp);

    let temp_delta = current_temp - baseline_temp;

    tracing::info!(
        "Temperature delta: {:.2}°C (baseline: {:.2}°C, current: {:.2}°C)",
        temp_delta,
        baseline_temp,
        current_temp
    );

    if let Some(cb) = progress_callback {
        cb(
            40.0,
            format!("Calculating compensation: delta temp = {:.2}°C", temp_delta),
        );
    }

    if temp_delta.abs() < config.min_temp_change {
        tracing::debug!(
            "Temperature change ({:.2}°C) below threshold ({:.2}°C), no compensation needed",
            temp_delta.abs(),
            config.min_temp_change
        );
        drop(trigger_state);

        return InstructionResult::success_with_message(format!(
            "No compensation needed (delta: {:.2}°C)",
            temp_delta
        ));
    }

    // Calculate focus position change
    // Why: `temp_delta` is single-digit °C in practice
    // (months between sessions would be outliers), `thermal_coefficient` is
    // configured in [-100, 100] steps/°C for any real focuser; the product
    // is well inside i32 range. Rust 1.45+ saturating f64 → i32 catches
    // pathological configs.
    let position_delta = (temp_delta * config.thermal_coefficient).round() as i32;

    if position_delta.abs() < config.min_step_change {
        tracing::debug!(
            "Position change ({} steps) below threshold ({} steps), no compensation needed",
            position_delta.abs(),
            config.min_step_change
        );
        drop(trigger_state);

        return InstructionResult::success_with_message(format!(
            "No compensation needed (steps: {})",
            position_delta
        ));
    }

    tracing::info!(
        "Temperature compensation required: {} steps ({:.2}°C × {} steps/°C)",
        position_delta,
        temp_delta,
        config.thermal_coefficient
    );

    let existing_baseline_position = trigger_state.latches.baseline_focuser_position;
    drop(trigger_state);

    // Get current focuser position without holding the trigger-state write lock.
    let current_position = match ctx.run.device_ops.focuser_get_position(&focuser_id).await {
        Ok(pos) => pos,
        Err(e) => {
            return InstructionResult::failure(format!("Failed to get focuser position: {}", e))
                .caused_by(&e);
        }
    };

    tracing::debug!("Current focuser position: {}", current_position);

    let new_position = match config.mode {
        CompensationMode::Relative => current_position + position_delta,
        CompensationMode::Absolute => {
            let baseline_position = match existing_baseline_position {
                Some(pos) => pos,
                None => {
                    tracing::info!(
                        "Establishing focuser baseline position for absolute compensation: {}",
                        current_position
                    );
                    let mut trigger_state = trigger_state_lock.write().await;
                    trigger_state.latches.baseline_focuser_position = Some(current_position);
                    current_position
                }
            };
            baseline_position + position_delta
        }
    };

    tracing::info!(
        "Moving focuser from {} to {} ({:+} steps)",
        current_position,
        new_position,
        position_delta
    );

    if let Some(cb) = progress_callback {
        cb(
            60.0,
            format!("Moving focuser by {:+} steps", position_delta),
        );
    }

    if let Some(result) = ctx.check_cancelled() {
        return result;
    }

    if let Some(cb) = progress_callback {
        cb(70.0, "Waiting for focuser to reach position".to_string());
    }
    if let Err(stopped) = move_focuser_and_wait(
        ctx,
        &focuser_id,
        new_position,
        config.timeout_secs,
        progress_callback,
    )
    .await
    {
        return stopped;
    }

    let final_position = match ctx.run.device_ops.focuser_get_position(&focuser_id).await {
        Ok(pos) => pos,
        Err(e) => {
            return InstructionResult::failure(format!(
                "Failed to verify final focuser position after temperature compensation move: {}",
                e
            ))
            .caused_by(&e);
        }
    };

    let position_error = (final_position - new_position).abs();
    if position_error > 10 {
        tracing::warn!(
            "Focuser position error: {} steps (target: {}, actual: {})",
            position_error,
            new_position,
            final_position
        );
    }

    // Optionally reset baseline after compensation
    if config.reset_baseline_after_move {
        let mut trigger_state = trigger_state_lock.write().await;
        trigger_state.reset_baseline_temperature();
        trigger_state.reset_baseline_focuser_position(final_position);
        tracing::info!("Temperature baseline reset to {:.2}°C", current_temp);
    }

    if let Some(cb) = progress_callback {
        cb(
            100.0,
            format!(
                "Temperature compensation complete: {:+} steps",
                position_delta
            ),
        );
    }

    InstructionResult::success_with_message(format!(
        "Temperature compensation complete: moved {:+} steps ({:.2}°C change)",
        position_delta, temp_delta
    ))
}

/// Command the focuser to `target` and wait until it stops. Cancellation and
/// the timeout halt it first, so it is still when this returns.
async fn move_focuser_and_wait(
    ctx: &InstructionContext,
    focuser_id: &str,
    target: i32,
    timeout_secs: u32,
    progress_callback: Option<&(dyn Fn(f64, String) + Send + Sync)>,
) -> Result<(), InstructionResult> {
    if let Err(e) = ctx.run.device_ops.focuser_move_to(focuser_id, target).await {
        return Err(
            InstructionResult::failure(format!("Failed to move focuser: {}", e)).caused_by(&e),
        );
    }

    let move_start = std::time::Instant::now();
    let timeout = Duration::from_secs(u64::from(timeout_secs));
    let mut poll_count: u32 = 0;
    loop {
        if ctx
            .cancellation_token
            .load(std::sync::atomic::Ordering::Relaxed)
        {
            tracing::warn!("Temperature compensation cancelled, halting focuser");
            let _ = ctx.run.device_ops.focuser_halt(focuser_id).await;
            wait_for_focuser_stop_after_halt(
                focuser_id,
                &ctx.run.device_ops,
                Duration::from_secs(10),
            )
            .await;
            return Err(InstructionResult::cancelled(
                "Temperature compensation cancelled",
            ));
        }

        match ctx.run.device_ops.focuser_is_moving(focuser_id).await {
            Ok(false) => {
                // Settling time before the next exposure.
                tokio::time::sleep(Duration::from_millis(100)).await;
                return Ok(());
            }
            Ok(true) => {
                poll_count += 1;
                if poll_count.is_multiple_of(5) {
                    let elapsed_secs = move_start.elapsed().as_secs();
                    // Progress from 70 to 90% across the timeout budget.
                    let move_progress = if timeout_secs > 0 {
                        70.0 + ((elapsed_secs as f64 / f64::from(timeout_secs)) * 20.0).min(20.0)
                    } else {
                        70.0
                    };
                    if let Some(cb) = progress_callback {
                        cb(
                            move_progress,
                            format!("Focuser moving... ({:.0}s)", elapsed_secs),
                        );
                    }
                }
            }
            // A failed status read is transient; the timeout bounds the wait.
            Err(e) => tracing::warn!("Error checking focuser status: {}", e),
        }

        if move_start.elapsed() > timeout {
            let _ = ctx.run.device_ops.focuser_halt(focuser_id).await;
            wait_for_focuser_stop_after_halt(
                focuser_id,
                &ctx.run.device_ops,
                Duration::from_secs(10),
            )
            .await;
            return Err(InstructionResult::failure(format!(
                "Focuser move timed out after {} seconds",
                timeout_secs
            )));
        }

        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

/// Where a plan carries the operator's temperature compensation settings.
pub const TEMPERATURE_COMPENSATION_METADATA_KEY: &str = "temperature_compensation";

/// The operator's temperature compensation (Equipment, Focuser settings): the
/// same coefficient and smallest move the app applies while no run is going.
#[derive(Debug, Clone, Copy, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct FocusCompensationSettings {
    /// Focuser steps per °C of temperature rise.
    pub steps_per_degree: f64,
    /// The smallest correction worth a move, in steps.
    pub min_steps: u32,
}

impl FocusCompensationSettings {
    /// The settings a run compensates with: the plan's, when the operator
    /// turned compensation on. A plan that places its own Temperature
    /// Compensation steps compensates with those instead, so the run does
    /// not also correct between frames.
    pub fn for_run(sequence: &crate::SequenceDefinition) -> Option<Self> {
        let raw = sequence
            .metadata
            .get(TEMPERATURE_COMPENSATION_METADATA_KEY)?;
        let settings = match serde_json::from_str::<Self>(raw) {
            Ok(settings) => settings,
            Err(e) => {
                tracing::warn!(
                    "The plan's temperature compensation settings could not be read ({e}): {raw}. \
                     Focus is not compensated during this run."
                );
                return None;
            }
        };
        let plan_compensates = sequence
            .enabled_nodes()
            .iter()
            .any(|node| matches!(node.node_type, crate::NodeType::TemperatureCompensation(_)));
        if plan_compensates {
            tracing::info!(
                "The plan has its own Temperature Compensation steps; the run does not also \
                 compensate between frames"
            );
            return None;
        }
        Some(settings)
    }
}

/// A focuser may report a step or two off a commanded target.
const ARRIVAL_TOLERANCE_STEPS: i32 = 2;

/// The run's temperature compensation between light frames.
///
/// It follows the app's idle compensator, so a night reads the same in and
/// out of a run: the reference (temperature, position) stays fixed while it
/// works, so rounding is never thrown away, and the focuser moves only once
/// the correction owed reaches the smallest move. A move it did not make (an
/// autofocus, a jog) is the new focus to hold, so it takes a new reference
/// instead of undoing it. A filter's focus offset is not a new focus: the
/// reference moves with it (see [`Self::shifted_by`]).
#[derive(Debug, Clone)]
pub struct FocusCompensation {
    settings: FocusCompensationSettings,
    reference: Option<FocusReference>,
    /// Where it last put the focuser, or the reference position.
    expected_position: i32,
    /// The operator has been told compensation cannot work this run.
    told_it_cannot_work: bool,
}

#[derive(Debug, Clone, Copy, PartialEq)]
struct FocusReference {
    temperature: f64,
    position: i32,
}

/// What one temperature and position reading calls for.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) enum CompensationStep {
    /// Measure from this reading on. `moved_from` is where the focuser was
    /// expected when something else moved it.
    TakeReference { moved_from: Option<i32> },
    /// Nothing worth a move is owed.
    Hold,
    Move {
        target: i32,
        owed: i32,
        degrees_since_reference: f64,
    },
    /// The correction would put the focuser below zero.
    Refuse { target: i32 },
}

impl FocusCompensation {
    pub fn new(settings: FocusCompensationSettings) -> Self {
        Self {
            settings,
            reference: None,
            expected_position: 0,
            told_it_cannot_work: false,
        }
    }

    /// Measure from the next reading: an autofocus just set the focus to
    /// hold.
    pub fn forget_reference(&mut self) {
        self.reference = None;
    }

    pub(crate) fn step(&mut self, temperature: f64, position: i32) -> CompensationStep {
        let Some(reference) = self.reference else {
            self.take_reference(temperature, position);
            return CompensationStep::TakeReference { moved_from: None };
        };
        if (position - self.expected_position).abs() > ARRIVAL_TOLERANCE_STEPS {
            let moved_from = self.expected_position;
            self.take_reference(temperature, position);
            return CompensationStep::TakeReference {
                moved_from: Some(moved_from),
            };
        }
        let coefficient = self.settings.steps_per_degree;
        if coefficient == 0.0 || !coefficient.is_finite() {
            return CompensationStep::Hold;
        }
        let degrees_since_reference = temperature - reference.temperature;
        // Steps per °C times a few °C: far inside i32, and `as` saturates.
        let target = reference.position + (degrees_since_reference * coefficient).round() as i32;
        let owed = target - position;
        if owed.unsigned_abs() < self.settings.min_steps.clamp(1, 10_000) {
            return CompensationStep::Hold;
        }
        if target < 0 {
            return CompensationStep::Refuse { target };
        }
        CompensationStep::Move {
            target,
            owed,
            degrees_since_reference,
        }
    }

    /// A filter's focus offset moved the focuser `steps`. The reference moves
    /// with it, so the correction owed for the temperature so far is kept.
    pub fn shifted_by(&mut self, steps: i32) {
        if let Some(reference) = self.reference.as_mut() {
            reference.position += steps;
        }
        self.expected_position += steps;
    }

    /// The focuser reached `target`; the reference stays where it is.
    pub(crate) fn moved_to(&mut self, target: i32) {
        self.expected_position = target;
    }

    fn take_reference(&mut self, temperature: f64, position: i32) {
        self.reference = Some(FocusReference {
            temperature,
            position,
        });
        self.expected_position = position;
    }
}

/// Compensate focus for the temperature change since the reference, before a
/// light frame. The caller holds the imaging train, so no autofocus or other
/// trigger action is moving the focuser. Never fails the frame: a problem is
/// logged, and told to the operator once per run.
pub(crate) async fn compensate_before_frame(ctx: &InstructionContext) {
    let (Some(state), Some(focuser_id)) = (
        ctx.run.trigger_state.as_ref(),
        ctx.run.rig.focuser_id.as_deref(),
    ) else {
        return;
    };
    if state.read().await.latches.focus_compensation.is_none() {
        return;
    }
    let ops = &ctx.run.device_ops;
    let temperature = match ops.focuser_get_temperature(focuser_id).await {
        Ok(Some(temperature)) => temperature,
        Ok(None) => {
            tell_once(
                ctx,
                "Temperature compensation is on, but the focuser reports no temperature, so \
                 focus is not compensated during this run.",
            )
            .await;
            return;
        }
        Err(e) => {
            tracing::warn!(
                "Temperature compensation skipped: the focuser temperature read failed: {e}"
            );
            return;
        }
    };
    let position = match ops.focuser_get_position(focuser_id).await {
        Ok(position) => position,
        Err(e) => {
            tracing::warn!(
                "Temperature compensation skipped: the focuser position read failed: {e}"
            );
            return;
        }
    };

    let step = match state.write().await.latches.focus_compensation.as_mut() {
        Some(compensation) => compensation.step(temperature, position),
        None => return,
    };
    match step {
        CompensationStep::Hold => {}
        CompensationStep::TakeReference { moved_from: None } => tracing::info!(
            "Temperature compensation measures from {temperature:.2}°C at position {position}"
        ),
        CompensationStep::TakeReference {
            moved_from: Some(expected),
        } => tracing::info!(
            "Temperature compensation took a new reference at {position} ({temperature:.2}°C): \
             the focuser was moved from {expected}"
        ),
        CompensationStep::Refuse { target } => tracing::warn!(
            "Temperature compensation computed a negative focuser position ({target}); not moving"
        ),
        CompensationStep::Move {
            target,
            owed,
            degrees_since_reference,
        } => {
            match move_focuser_and_wait(ctx, focuser_id, target, default_timeout_secs(), None).await
            {
                Ok(()) => {
                    if let Some(compensation) =
                        state.write().await.latches.focus_compensation.as_mut()
                    {
                        compensation.moved_to(target);
                    }
                    let summary = format!(
                        "Temperature compensation moved the focuser {owed:+} steps to {target} \
                         ({temperature:.2}°C, {degrees_since_reference:+.2}°C since its reference)"
                    );
                    tracing::info!("{summary}");
                    ctx.run.emit_decision(crate::decision::DecisionEvent::new(
                        crate::decision::DecisionCategory::SystemEvent,
                        summary,
                        serde_json::json!({
                            "kind": "temperature_compensation",
                            "temperature_c": temperature,
                            "degrees_since_reference": degrees_since_reference,
                            "from_position": position,
                            "to_position": target,
                        }),
                    ));
                }
                Err(stopped) if stopped.status == crate::NodeStatus::Cancelled => {}
                Err(failed) => {
                    let reason = failed.message.unwrap_or_default();
                    tracing::warn!("Temperature compensation move failed: {reason}");
                    tell_once(
                        ctx,
                        &format!(
                            "Temperature compensation could not move the focuser ({reason}). \
                             Imaging continues; it tries again before the next frame."
                        ),
                    )
                    .await;
                }
            }
        }
    }
}

async fn tell_once(ctx: &InstructionContext, message: &str) {
    let Some(state) = ctx.run.trigger_state.as_ref() else {
        return;
    };
    {
        let mut state = state.write().await;
        let Some(compensation) = state.latches.focus_compensation.as_mut() else {
            return;
        };
        if std::mem::replace(&mut compensation.told_it_cannot_work, true) {
            return;
        }
    }
    tracing::warn!("{message}");
    if let Some(event_tx) = &ctx.run.event_tx {
        let _ = event_tx.send(crate::executor::ExecutorEvent::Warning {
            message: message.to_string(),
        });
    }
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct TemperatureCompensationConfig {
    /// Thermal coefficient in steps per degree Celsius
    /// Positive: focus moves outward when temperature increases
    /// Negative: focus moves inward when temperature increases
    /// Typical values: -5 to -50 steps/°C for most systems
    pub thermal_coefficient: f64,

    /// Minimum temperature change (°C) to trigger compensation
    /// Below this threshold, no move is made
    #[serde(default = "default_min_temp_change")]
    pub min_temp_change: f64,

    /// Minimum step change to trigger compensation
    /// Below this threshold, no move is made (even if temp changed)
    #[serde(default = "default_min_step_change")]
    pub min_step_change: i32,

    #[serde(default)]
    pub mode: CompensationMode,

    /// Reset temperature baseline after successful move
    /// If true, next compensation will be relative to current temp
    /// If false, compensation accumulates from original baseline
    #[serde(default = "default_reset_baseline")]
    pub reset_baseline_after_move: bool,

    /// Timeout for focuser move (seconds)
    #[serde(default = "default_timeout_secs")]
    pub timeout_secs: u32,
}

impl Default for TemperatureCompensationConfig {
    fn default() -> Self {
        Self {
            thermal_coefficient: -20.0, // Typical value for many systems
            min_temp_change: 0.5,       // 0.5°C minimum change
            min_step_change: 5,         // 5 steps minimum move
            mode: CompensationMode::Relative,
            reset_baseline_after_move: true,
            timeout_secs: 120,
        }
    }
}

fn default_min_temp_change() -> f64 {
    0.5
}

fn default_min_step_change() -> i32 {
    5
}

fn default_reset_baseline() -> bool {
    true
}

fn default_timeout_secs() -> u32 {
    120
}

#[derive(Debug, Clone, Copy, serde::Serialize, serde::Deserialize, PartialEq, Eq, Default)]
pub enum CompensationMode {
    /// Move relative to current position based on temp delta
    #[default]
    Relative,
    /// Calculate absolute position from baseline (requires baseline position tracking)
    Absolute,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_compensation_config_defaults() {
        let config = TemperatureCompensationConfig::default();
        assert_eq!(config.thermal_coefficient, -20.0);
        assert_eq!(config.min_temp_change, 0.5);
        assert_eq!(config.min_step_change, 5);
        assert_eq!(config.mode, CompensationMode::Relative);
        assert!(config.reset_baseline_after_move);
    }

    #[test]
    fn test_compensation_calculation() {
        let config = TemperatureCompensationConfig {
            thermal_coefficient: -20.0,
            min_temp_change: 0.5,
            min_step_change: 5,
            mode: CompensationMode::Relative,
            reset_baseline_after_move: true,
            timeout_secs: 120,
        };

        // 2°C temperature drop should cause +40 steps movement
        let temp_delta = -2.0;
        let expected_steps = (temp_delta * config.thermal_coefficient).round() as i32;
        assert_eq!(expected_steps, 40);

        // Small temperature change below threshold
        let small_delta: f64 = 0.3;
        assert!(small_delta.abs() < config.min_temp_change);
    }

    #[test]
    fn test_serde() {
        let config = TemperatureCompensationConfig::default();
        let json = serde_json::to_string(&config).unwrap();
        let deserialized: TemperatureCompensationConfig = serde_json::from_str(&json).unwrap();
        assert_eq!(config.thermal_coefficient, deserialized.thermal_coefficient);
    }

    /// The owner's rig: -12.5 steps/°C, moves of at least 5 steps.
    fn rig_compensation() -> FocusCompensation {
        FocusCompensation::new(FocusCompensationSettings {
            steps_per_degree: -12.5,
            min_steps: 5,
        })
    }

    /// Follow `readings` (°C) the way the run does before each frame,
    /// moving the simulated focuser whenever a move is called for.
    fn follow(
        compensation: &mut FocusCompensation,
        start: i32,
        readings: &[f64],
    ) -> (i32, Vec<i32>) {
        let mut position = start;
        let mut moves = Vec::new();
        for &temperature in readings {
            if let CompensationStep::Move { target, .. } = compensation.step(temperature, position)
            {
                position = target;
                compensation.moved_to(target);
                moves.push(target);
            }
        }
        (position, moves)
    }

    #[test]
    fn the_first_reading_is_the_reference() {
        let mut compensation = rig_compensation();
        assert_eq!(
            compensation.step(10.0, 25_000),
            CompensationStep::TakeReference { moved_from: None }
        );
        assert_eq!(compensation.step(10.0, 25_000), CompensationStep::Hold);
    }

    /// A 0.05 °C probe cooling 2 °C: the fixed reference keeps every
    /// fraction, so the focuser ends 25 steps out (2 °C × 12.5), in moves of
    /// at least 5 steps, not one step per reading.
    #[test]
    fn small_readings_add_up_to_the_coefficient_in_moves_of_at_least_the_minimum() {
        let mut compensation = rig_compensation();
        let readings: Vec<f64> = (0..=40).map(|i| 10.0 - f64::from(i) * 0.05).collect();
        let (end, moves) = follow(&mut compensation, 25_000, &readings);

        assert_eq!(end, 25_025);
        assert!(!moves.is_empty());
        let mut from = 25_000;
        for target in &moves {
            assert!((target - from).abs() >= 5, "{moves:?}");
            from = *target;
        }
    }

    #[test]
    fn a_correction_below_the_minimum_waits() {
        let mut compensation = rig_compensation();
        let _ = compensation.step(10.0, 25_000);
        // 0.3 °C warmer owes 3.75 -> 4 steps inward.
        assert_eq!(compensation.step(10.3, 25_000), CompensationStep::Hold);
        assert_eq!(
            compensation.step(10.4, 25_000),
            CompensationStep::Move {
                target: 24_995,
                owed: -5,
                degrees_since_reference: 10.4 - 10.0,
            }
        );
    }

    /// An autofocus or a jog set a new focus: hold that one.
    #[test]
    fn a_move_it_did_not_make_is_the_new_reference_not_drift_to_undo() {
        let mut compensation = rig_compensation();
        let _ = compensation.step(10.0, 25_000);
        assert_eq!(
            compensation.step(9.0, 25_400),
            CompensationStep::TakeReference {
                moved_from: Some(25_000)
            }
        );
        assert_eq!(compensation.step(9.0, 25_400), CompensationStep::Hold);
        // A step or two off the commanded target is arrival, not a move.
        let _ = compensation.step(8.6, 25_400);
        compensation.moved_to(25_405);
        assert_eq!(compensation.step(8.6, 25_407), CompensationStep::Hold);
    }

    /// An LRGB plan changes filter every few frames, and each change moves
    /// the focuser by the filters' offset. Over a 2 °C cooling the focuser
    /// still ends 25 steps out of where the reference filter started.
    #[test]
    fn filter_offsets_between_frames_do_not_drop_the_correction_owed() {
        let mut state = crate::triggers::TriggerState::new();
        state.latches.focus_compensation = Some(rig_compensation());
        let offsets = [0, 30, -12, 18];
        let mut position = 25_000;
        for frame in 0..=40 {
            if frame % 2 == 0 {
                let offset = offsets[(frame / 2) % offsets.len()];
                position += offset - state.latches.last_applied_filter_offset;
                state.set_last_applied_filter_offset(offset);
            }
            let temperature = 10.0 - frame as f64 * 0.05;
            let compensation = state.latches.focus_compensation.as_mut().unwrap();
            if let CompensationStep::Move { target, .. } = compensation.step(temperature, position)
            {
                position = target;
                compensation.moved_to(target);
            }
        }

        assert_eq!(position - state.latches.last_applied_filter_offset, 25_025);
    }

    /// The app's idle compensator is this rule written again in Dart
    /// (`FocusCompensationRule`). Both run every case in this file, so the
    /// two cannot come apart without a test failing on one side.
    #[test]
    fn the_rule_gives_what_the_shared_cases_say() {
        let cases: serde_json::Value =
            serde_json::from_str(include_str!("temperature_compensation_cases.json")).unwrap();
        for case in cases.as_array().unwrap() {
            let name = case["name"].as_str().unwrap();
            let mut compensation = FocusCompensation::new(FocusCompensationSettings {
                steps_per_degree: case["steps_per_degree"].as_f64().unwrap(),
                min_steps: case["min_steps"].as_u64().unwrap() as u32,
            });
            for (index, op) in case["ops"].as_array().unwrap().iter().enumerate() {
                let int = |key: &str| op[key].as_i64().unwrap() as i32;
                match op["op"].as_str().unwrap() {
                    "shifted_by" => compensation.shifted_by(int("steps")),
                    "moved_to" => compensation.moved_to(int("target")),
                    "forget_reference" => compensation.forget_reference(),
                    "step" => {
                        let step =
                            compensation.step(op["temperature"].as_f64().unwrap(), int("position"));
                        let got = match step {
                            CompensationStep::TakeReference { moved_from } => {
                                serde_json::json!({ "kind": "take_reference", "moved_from": moved_from })
                            }
                            CompensationStep::Hold => serde_json::json!({ "kind": "hold" }),
                            CompensationStep::Move { target, owed, .. } => {
                                serde_json::json!({ "kind": "move", "target": target, "owed": owed })
                            }
                            CompensationStep::Refuse { target } => {
                                serde_json::json!({ "kind": "refuse", "target": target })
                            }
                        };
                        assert_eq!(got, op["expect"], "case '{name}', op {index}");
                    }
                    other => panic!("case '{name}': unknown op {other}"),
                }
            }
        }
    }

    #[test]
    fn forgetting_the_reference_measures_from_the_next_reading() {
        let mut compensation = rig_compensation();
        let _ = compensation.step(10.0, 25_000);
        compensation.forget_reference();
        assert_eq!(
            compensation.step(8.0, 25_000),
            CompensationStep::TakeReference { moved_from: None }
        );
    }

    #[test]
    fn a_zero_coefficient_tracks_without_moving_and_a_negative_target_is_refused() {
        let mut idle = FocusCompensation::new(FocusCompensationSettings {
            steps_per_degree: 0.0,
            min_steps: 5,
        });
        let _ = idle.step(10.0, 100);
        assert_eq!(idle.step(2.0, 100), CompensationStep::Hold);

        let mut compensation = rig_compensation();
        let _ = compensation.step(0.0, 10);
        assert_eq!(
            compensation.step(2.0, 10),
            CompensationStep::Refuse { target: -15 }
        );
    }

    fn plan_with(metadata: Option<&str>, compensation_step: bool) -> crate::SequenceDefinition {
        let mut sequence = crate::SequenceDefinition::new("Night".to_string());
        if let Some(raw) = metadata {
            sequence.metadata.insert(
                TEMPERATURE_COMPENSATION_METADATA_KEY.to_string(),
                raw.to_string(),
            );
        }
        sequence.root_node_id = Some("root".to_string());
        sequence.nodes.push(crate::NodeDefinition {
            id: "root".to_string(),
            name: "Night".to_string(),
            node_type: crate::NodeType::Loop(Default::default()),
            enabled: true,
            children: if compensation_step {
                vec!["tc".to_string()]
            } else {
                vec![]
            },
        });
        if compensation_step {
            sequence.nodes.push(crate::NodeDefinition {
                id: "tc".to_string(),
                name: "Temp Comp".to_string(),
                node_type: crate::NodeType::TemperatureCompensation(Default::default()),
                enabled: true,
                children: vec![],
            });
        }
        sequence
    }

    #[test]
    fn a_run_compensates_with_the_settings_its_plan_carries() {
        let settings = r#"{"steps_per_degree":-12.5,"min_steps":5}"#;
        assert_eq!(
            FocusCompensationSettings::for_run(&plan_with(Some(settings), false)),
            Some(FocusCompensationSettings {
                steps_per_degree: -12.5,
                min_steps: 5
            })
        );
        assert_eq!(
            FocusCompensationSettings::for_run(&plan_with(None, false)),
            None
        );
        assert_eq!(
            FocusCompensationSettings::for_run(&plan_with(Some("not json"), false)),
            None
        );
    }

    /// One compensator at a time: a plan that places its own steps owns
    /// compensation for its run.
    #[test]
    fn a_plan_with_its_own_compensation_steps_is_not_also_compensated_between_frames() {
        let settings = r#"{"steps_per_degree":-12.5,"min_steps":5}"#;
        assert_eq!(
            FocusCompensationSettings::for_run(&plan_with(Some(settings), true)),
            None
        );
    }
}
