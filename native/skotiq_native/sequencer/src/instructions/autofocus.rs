//! `autofocus.rs` — moved verbatim out of the former single-file `instructions.rs`
//! (release-pass C3 mechanical split). No logic changed; private items were
//! widened to `pub(crate)` so the sibling modules and the tests module still
//! see them, and `super::*` supplies the imports the original file had.

use super::*;

// Autofocus instruction

/// Result-data key set when autofocus stopped guiding for its sweep and could
/// not prove guiding running again afterwards.
///
/// The distinction this key carries is the whole point of it. A trigger-fired
/// autofocus that merely misses its curve fit costs the run slightly soft subs
/// the operator can cull, so imaging continues on the last-good focus (see
/// `executor::autofocus_trigger_continuation`). An autofocus that left the
/// guider stopped costs the run EVERY subsequent frame: the mount is
/// unguided, so each light trails. Both arrive here as
/// `NodeStatus::Failure` with a "CRITICAL CLEANUP FAILURE" message, and
/// without a machine-readable marker the caller cannot tell them apart —
/// which is how a live run took three 180 s trailed frames (HFR 15.6 px
/// against a 3.50 px limit) after its own log said the guider never came back.
pub(crate) const AUTOFOCUS_GUIDING_NOT_RESTORED_KEY: &str = "autofocus_guiding_not_restored";

/// Whether the run carries on past this autofocus result on the previous
/// focus, rather than handing it to the caller's failure path.
///
/// Owner decision 2026-10-06: a failed autofocus never parks the rig or ends
/// the night; the operator is notified and imaging continues on the focus the
/// sweep restored. Two failures are not a missed focus and keep their own
/// handling: a device that dropped off the bus (the disconnect-recovery path
/// retries the instruction), and a sweep that left the guider stopped, after
/// which every frame would be trailed.
pub(crate) fn autofocus_failure_continues_the_run(result: &InstructionResult) -> bool {
    if result.status != NodeStatus::Failure {
        return false;
    }
    if result
        .message
        .as_deref()
        .is_some_and(super::disconnect::is_device_disconnected_message)
    {
        return false;
    }
    crate::executor::autofocus_trigger_failure_cost(result.data.as_ref())
        != crate::executor::AutofocusTriggerFailureCost::EveryFrameUnguided
}

/// Where the focuser is, or `None` with no focuser or a driver that will not
/// answer. Read either side of a sweep so a failure notice can name the focus
/// the run kept.
pub(crate) async fn read_autofocus_position(ctx: &InstructionContext) -> Option<i32> {
    ctx.device_ops
        .focuser_get_position(ctx.focuser_id.as_deref()?)
        .await
        .ok()
}

/// Tell the operator that `source` did not converge and that imaging carries
/// on: the continuation decision row (which raises the app's "Autofocus failed
/// — continuing" notification) and a Warning in the run's feed naming the
/// cause and where the focuser is. A Warning, not an Error: every sequencer
/// Error is reported as a failed sequence, and this run has not failed.
pub(crate) async fn notify_autofocus_failed_continuing(
    ctx: &InstructionContext,
    source: &str,
    result: &InstructionResult,
    position_before: Option<i32>,
) {
    let position_after = read_autofocus_position(ctx).await;
    let origin_restored = result
        .data
        .as_ref()
        .and_then(|data| data.get("autofocus_origin_restored"))
        .and_then(serde_json::Value::as_bool);
    // Why: the result's `message` is only set when the focus pipeline has a
    // specific diagnostic; the failure itself is the status.
    let reason = result
        .message
        .clone()
        .unwrap_or_else(|| "autofocus did not converge".to_string());
    let continuation = crate::executor::autofocus_failure_continuation(
        source,
        serde_json::json!({ "node_id": ctx.node_id }),
        &reason,
        position_before,
        position_after,
        origin_restored,
    );
    ctx.emit_decision(continuation.decision);
    tracing::warn!("{}", continuation.operator_message);
    if let Some(event_tx) = &ctx.event_tx {
        let _ = event_tx.send(crate::executor::ExecutorEvent::Warning {
            message: continuation.operator_message,
        });
    }
}

/// Process-wide hardware admission for autofocus. Every entry path ultimately
/// calls this module (standalone bridge, sequence node, recovery, meridian
/// flip), so a single atomic gate prevents two callers from sweeping the same
/// camera/focuser pair concurrently.
pub(crate) static AUTOFOCUS_RUN_ACTIVE: AtomicBool = AtomicBool::new(false);

/// Serializes tests that touch the process-global [`AUTOFOCUS_RUN_ACTIVE`]
/// gate — cargo runs tests across threads and the gate is shared state, so
/// without this they race (one test's held gate turns another's autofocus
/// away). Instruction tests and executor tests that fire a trigger autofocus
/// both take it.
#[cfg(test)]
pub(crate) static AF_GATE_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

pub struct AutofocusRunGuard;

impl Drop for AutofocusRunGuard {
    fn drop(&mut self) {
        AUTOFOCUS_RUN_ACTIVE.store(false, Ordering::Release);
    }
}

pub fn try_admit_autofocus_run() -> Option<AutofocusRunGuard> {
    AUTOFOCUS_RUN_ACTIVE
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .ok()
        .map(|_| AutofocusRunGuard)
}

/// A run-up exactly equal to the backlash leaves the gear train on the very
/// edge of its dead band, where a step of motor slop puts the drawtube on the
/// wrong face — so the run-up always clears the figure by a margin: a quarter
/// of it, but never less than one sweep step, and never less than
/// [`MIN_RUN_UP_MARGIN_STEPS`] on a focuser whose steps are tiny.
/// The phrase that identifies a landing-verification failure — autofocus
/// moving to the fitted position and then measuring a materially worse HFR
/// there.
///
/// Held as a constant because Dart matches on it: two of these in a row on the
/// same focuser is the signature of an uncalibrated or changed drive train, and
/// is what re-opens the offer to measure its backlash
/// (`packages/skotiq_core/lib/src/providers/focuser_backlash_provider.dart`,
/// `autofocusLandingVerificationFailureMarker`). Rewording the sentence without
/// this constant would silently stop that offer from ever appearing again.
pub const LANDING_VERIFICATION_FAILURE_PHRASE: &str = "but the frame taken there measures HFR";

const RUN_UP_MARGIN_DIVISOR: i32 = 4;
const MIN_RUN_UP_MARGIN_STEPS: i32 = 10;

/// Which figure the final run-up was sized from. Reported so the run's log and
/// its result say whose number moved the focuser.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RunUpSource {
    /// A backlash figure the operator typed in. Outranks everything else.
    OperatorEntered,
    /// A backlash figure this app measured on this focuser.
    Measured,
    /// No figure for this focuser: run back to the sweep's own start.
    SweepStart,
}

impl RunUpSource {
    pub fn label(self) -> &'static str {
        match self {
            Self::OperatorEntered => "the backlash you entered",
            Self::Measured => "the measured backlash",
            Self::SweepStart => "the sweep start (no backlash figure for this focuser)",
        }
    }
}

/// Steps to run back below best focus, and whose figure that came from.
///
/// The precedence is the point of this function. An operator who has measured
/// their own focuser, or who knows this drive train, must never have their
/// number quietly replaced by one the app worked out — so a non-zero
/// `operator_backlash_in` wins outright, and the measured figure is only
/// consulted when the operator has left theirs at the shipped 0.
///
/// `None` means there is no figure at all, and the caller falls back to the
/// sweep start.
fn resolve_run_up(
    operator_backlash_in: i32,
    measured_backlash: Option<i32>,
    step_size: i32,
) -> (Option<i32>, RunUpSource) {
    let clear = |backlash: i32| {
        let margin = (backlash / RUN_UP_MARGIN_DIVISOR)
            .max(step_size)
            .max(MIN_RUN_UP_MARGIN_STEPS);
        backlash.saturating_add(margin)
    };

    if operator_backlash_in > 0 {
        return (
            Some(clear(operator_backlash_in)),
            RunUpSource::OperatorEntered,
        );
    }
    // A measured zero is a real result — "this focuser has no backlash worth
    // compensating" — and it is not a figure to size a run-up from, so it
    // falls through to the sweep-start rule like an absent measurement.
    match measured_backlash.filter(|steps| *steps > 0) {
        Some(steps) => (Some(clear(steps)), RunUpSource::Measured),
        None => (None, RunUpSource::SweepStart),
    }
}

/// Where the final move must start from so that best focus is reached moving
/// UPWARD — the same direction every sweep point was measured in.
///
/// With a backlash figure in hand the run-up is that figure plus a margin, and
/// nothing more: a known-good clearance is a shorter, faster move than running
/// all the way back down the sweep.
///
/// With no figure, this is 38bf2b25a's rule unchanged — back at least one
/// sweep step, and at least to the sweep's own start, which is below best
/// focus by construction and inside ground the focuser has just covered. It is
/// blunt, but it is safe without knowing anything about the hardware, which is
/// the situation an uncalibrated focuser is in.
fn final_run_up_position(
    best_position: i32,
    sweep_start: i32,
    operator_backlash_in: i32,
    measured_backlash: Option<i32>,
    step_size: i32,
) -> (i32, RunUpSource) {
    match resolve_run_up(operator_backlash_in, measured_backlash, step_size) {
        // Never below zero, unless the sweep itself already went there: near
        // the bottom of travel a figure-sized run-up commanded a negative
        // position the driver refuses, and a good sweep ended as a failure. A
        // shorter run-up is the best this travel allows.
        (Some(run_up), source) => (
            best_position.saturating_sub(run_up).max(sweep_start.min(0)),
            source,
        ),
        (None, source) => (
            best_position
                .saturating_sub(step_size.max(1))
                .min(sweep_start),
            source,
        ),
    }
}

/// Execute autofocus using V-curve or curve fitting, acquiring the shared
/// camera/focuser admission gate first.
///
/// Fail-fast: if the gate is already held, returns immediately with the
/// "already running" error so the one-shot / REST layer can surface a typed
/// `DeviceBusy`. Sequence NODES should use [execute_autofocus_for_node]
/// instead, which waits for an in-flight run rather than aborting the run.
pub async fn execute_autofocus(
    config: &AutofocusConfig,
    ctx: &InstructionContext,
    progress_callback: Option<&(dyn Fn(f64, String) + Send + Sync)>,
) -> InstructionResult {
    let Some(guard) = try_admit_autofocus_run() else {
        return InstructionResult::failure(
            "Autofocus is already running on this equipment host".to_string(),
        );
    };
    execute_autofocus_admitted(config, ctx, progress_callback, guard).await
}

/// Execute autofocus for a SEQUENCE NODE, waiting for any in-flight autofocus
/// to release the shared admission gate before running.
///
/// An explicit `Autofocus` node routinely races a concurrently-fired
/// trigger-autofocus: the HFR-degradation / focus-invalidation trigger fires
/// its own run (grabbing the gate) at the same tick the node is dispatched.
/// With plain fail-fast [execute_autofocus] the node then failed with
/// "Autofocus is already running", which aborted the ENTIRE sequence — a
/// benign scheduling race turning into a night-ending failure. A node must
/// never abort the run for this reason: wait for the in-flight run to finish
/// (the operator asked for an autofocus HERE), then perform this node's own
/// run. Bounded so a leaked/stuck gate can't hang the sequence forever.
pub async fn execute_autofocus_for_node(
    config: &AutofocusConfig,
    ctx: &InstructionContext,
    progress_callback: Option<&(dyn Fn(f64, String) + Send + Sync)>,
    pause: &crate::node::context::PauseGate,
) -> InstructionResult {
    // An autofocus run is at most a few minutes (per-node timeout); cap the
    // admission wait generously above that so a genuine concurrent run always
    // completes first, while a leaked gate still surfaces as a failure rather
    // than hanging.
    const MAX_ADMISSION_WAIT: Duration = Duration::from_secs(600);
    let Some(guard) = admit_autofocus_run_waiting(MAX_ADMISSION_WAIT).await else {
        return InstructionResult::failure(
            "Autofocus could not start: another autofocus held the \
             equipment for over 10 minutes"
                .to_string(),
        );
    };
    execute_autofocus_admitted_with_pause(config, ctx, progress_callback, guard, pause).await
}

/// Acquire the shared autofocus admission gate, waiting (bounded) for any
/// in-flight run to release it. Returns the guard, or `None` on timeout.
///
/// Uses `tokio::time` so the deadline honours a paused test clock (and so the
/// timeout is driven by the same runtime as the poll sleeps).
pub(crate) async fn admit_autofocus_run_waiting(max_wait: Duration) -> Option<AutofocusRunGuard> {
    tokio::time::timeout(max_wait, async {
        let mut announced = false;
        loop {
            if let Some(guard) = try_admit_autofocus_run() {
                return guard;
            }
            if !announced {
                announced = true;
                tracing::info!(
                    "Autofocus node deferring to an in-flight autofocus run; \
                     waiting for it to finish before starting this node's run"
                );
            }
            sleep(Duration::from_millis(200)).await;
        }
    })
    .await
    .ok()
}

/// Execute a run for a caller that already owns [AutofocusRunGuard]. This is
/// public so the bridge can translate an admission rejection into the typed
/// `DeviceBusy` error expected by the REST layer.
///
/// One-shot callers have no run to pause, so this entry point uses the
/// never-paused gate. Sequence callers go through
/// [execute_autofocus_admitted_with_pause].
pub async fn execute_autofocus_admitted(
    config: &AutofocusConfig,
    ctx: &InstructionContext,
    progress_callback: Option<&(dyn Fn(f64, String) + Send + Sync)>,
    guard: AutofocusRunGuard,
) -> InstructionResult {
    execute_autofocus_admitted_with_pause(
        config,
        ctx,
        progress_callback,
        guard,
        &crate::node::context::PauseGate::default(),
    )
    .await
}

/// [execute_autofocus_admitted] with the run's operator-pause handle attached,
/// so the V-curve sweep holds between sample points instead of driving the
/// focuser and opening the shutter for the rest of the sweep while the UI
/// says PAUSED.
pub async fn execute_autofocus_admitted_with_pause(
    config: &AutofocusConfig,
    ctx: &InstructionContext,
    progress_callback: Option<&(dyn Fn(f64, String) + Send + Sync)>,
    _guard: AutofocusRunGuard,
    pause: &crate::node::context::PauseGate,
) -> InstructionResult {
    let mut effective_config = config.clone();

    // Resolve the imaging filter at runtime. A sequence can reach the same AF
    // node through different filter branches, so choosing per-filter exposure,
    // binning, gain, and offset during Dart serialization would be wrong.
    let mut original_filter: Option<(String, i32)> = None;
    let mut filter_names = Vec::new();
    let needs_filter_context = !config.filter_settings.is_empty()
        || config
            .filter
            .as_deref()
            .is_some_and(|name| !name.trim().is_empty());
    if needs_filter_context {
        if let Some(filterwheel_id) = ctx.filterwheel_id.as_deref() {
            let position = match ctx
                .device_ops
                .filterwheel_get_position(filterwheel_id)
                .await
            {
                Ok(position) if position >= 0 => position,
                Ok(position) => {
                    return InstructionResult::failure(format!(
                        "Cannot start autofocus while the filter wheel reports moving position {}",
                        position
                    ))
                }
                Err(error) => {
                    return InstructionResult::failure(format!(
                        "Cannot read the current filter before autofocus: {}",
                        error
                    ))
                }
            };
            filter_names = match ctx.device_ops.filterwheel_get_names(filterwheel_id).await {
                Ok(names) => names,
                Err(error) => {
                    return InstructionResult::failure(format!(
                        "Cannot read filter names before autofocus: {}",
                        error
                    ))
                }
            };
            let Some(name) = filter_names.get(position as usize).cloned() else {
                return InstructionResult::failure(format!(
                    "Filter wheel position {} has no configured name; autofocus cannot apply per-filter settings safely",
                    position
                ));
            };
            original_filter = Some((name, position));
        } else if config
            .filter
            .as_deref()
            .is_some_and(|name| !name.trim().is_empty())
        {
            return InstructionResult::failure(format!(
                "Autofocus is configured to use filter \"{}\", but no filter wheel is connected",
                config.filter.as_deref().unwrap_or_default().trim()
            ));
        }
    }

    let active_filter_name = original_filter
        .as_ref()
        .map(|(name, _)| name.as_str())
        .or(ctx.current_filter.as_deref());
    let active_override = active_filter_name
        .and_then(|name| config.filter_settings.get(name))
        .cloned();
    if let Some(filter_config) = &active_override {
        if let Some(exposure) = filter_config.af_exposure_time {
            effective_config.exposure_duration = exposure;
        }
        effective_config.binning = filter_config.binning;
        effective_config.gain = filter_config.gain;
        effective_config.offset = filter_config.offset;
    }

    let requested_filter = active_override
        .as_ref()
        .and_then(|settings| settings.af_filter_name.as_deref())
        .filter(|name| !name.trim().is_empty())
        .or(effective_config.filter.as_deref())
        .map(str::trim)
        .filter(|name| !name.is_empty())
        .map(str::to_string);

    if let Err(message) = validate_autofocus_config(&effective_config) {
        return InstructionResult::failure(message);
    }

    let mut guiding_was_paused = false;
    if effective_config.disable_guiding_during_af {
        let guider_status = match ctx.device_ops.guider_get_status().await {
            Ok(status) => status,
            Err(error) => {
                return InstructionResult::failure(format!(
                "Autofocus is configured to pause guiding, but guider status could not be read: {}",
                error
            ))
            }
        };
        if guider_status.is_guiding {
            if let Err(error) = ctx.device_ops.guider_stop().await {
                return InstructionResult::failure(format!(
                    "Autofocus is configured to pause guiding, but guiding could not be stopped: {}",
                    error
                ));
            }
            guiding_was_paused = true;
            if let Some(trigger_state) = &ctx.trigger_state {
                let mut state = trigger_state.write().await;
                state.set_guiding_enabled(false);
                state.set_guide_star_lost(false);
            }
        }
    }

    let mut filter_restore_required = false;
    let mut pre_run_error = None;
    if let Some(target_name) = requested_filter.as_deref() {
        match &original_filter {
            Some((original_name, _original_position)) if original_name != target_name => {
                if let Some(target_position) =
                    filter_names.iter().position(|name| name == target_name)
                {
                    // The wheel may move before verification fails, so restoration
                    // responsibility begins before the command is sent.
                    filter_restore_required = true;
                    if let Err(error) =
                        move_autofocus_filter(ctx, target_name, target_position as i32).await
                    {
                        pre_run_error = Some(format!(
                            "Failed to switch to autofocus filter \"{}\": {}",
                            target_name, error
                        ));
                    }
                } else {
                    pre_run_error = Some(format!(
                        "Configured autofocus filter \"{}\" is not present in the connected wheel",
                        target_name
                    ));
                }
            }
            Some(_) => {}
            None => {
                pre_run_error = Some(format!(
                    "Autofocus is configured to use filter \"{}\", but no filter wheel is connected",
                    target_name
                ));
            }
        }
    }

    let mut result = match pre_run_error {
        Some(error) => InstructionResult::failure(error),
        None => execute_autofocus_attempts(&effective_config, ctx, progress_callback, pause).await,
    };

    if filter_restore_required {
        if let Some((original_name, original_position)) = &original_filter {
            if let Err(error) = move_autofocus_filter(ctx, original_name, *original_position).await
            {
                result = append_autofocus_cleanup_failure(
                    result,
                    format!(
                        "failed to restore original filter \"{}\" at position {}: {}",
                        original_name, original_position, error
                    ),
                );
            }
        }
    }

    if guiding_was_paused {
        result = resume_guiding_after_autofocus(ctx, result).await;
    }

    result
}

pub(crate) async fn execute_autofocus_attempts(
    config: &AutofocusConfig,
    ctx: &InstructionContext,
    progress_callback: Option<&(dyn Fn(f64, String) + Send + Sync)>,
    pause: &crate::node::context::PauseGate,
) -> InstructionResult {
    let attempts = config.number_of_attempts.max(1);
    for attempt in 1..=attempts {
        if !pause.wait_while_paused(&ctx.cancellation_token).await {
            return InstructionResult::cancelled("Autofocus cancelled while paused");
        }
        let result = execute_autofocus_once(config, ctx, progress_callback, pause).await;
        if !matches!(result.status, NodeStatus::Failure) || attempt == attempts {
            return result;
        }
        if result
            .data
            .as_ref()
            .and_then(|data| data.get("autofocus_origin_restored"))
            .and_then(serde_json::Value::as_bool)
            == Some(false)
        {
            return result;
        }
        // A sweep whose cleanup could not prove guiding running again must not
        // be repeated: the next attempt's exposures are taken on an unguided
        // mount, and each one stops the guider again on entry. Surface the
        // cleanup failure to the caller instead, which is the only party that
        // can halt the run.
        if result
            .data
            .as_ref()
            .and_then(|data| data.get(AUTOFOCUS_GUIDING_NOT_RESTORED_KEY))
            .and_then(serde_json::Value::as_bool)
            == Some(true)
        {
            return result;
        }
        if let Some(cb) = progress_callback {
            cb(
                0.0,
                format!("Autofocus attempt {attempt}/{attempts} failed; retrying full sweep"),
            );
        }
        tracing::warn!(
            "Autofocus attempt {}/{} failed; starting the next configured attempt",
            attempt,
            attempts
        );
    }
    unreachable!("attempt count is clamped to at least one")
}

pub(crate) async fn move_autofocus_filter(
    ctx: &InstructionContext,
    filter_name: &str,
    target_position: i32,
) -> Result<(), String> {
    let filterwheel_id = ctx
        .filterwheel_id
        .as_deref()
        .filter(|id| !id.is_empty())
        .ok_or_else(|| "no filter wheel is connected".to_string())?;

    // The command is retried through transient wheel faults like any other
    // filter change; the arrival check below stays this function's own.
    move_filter_wheel(
        ctx,
        filterwheel_id,
        WheelTarget::Position(target_position),
        None,
    )
    .await
    .map_err(|error| format!("filter move command failed: {}", error))?;

    // Cleanup still owns the wheel after cancellation, so this verification
    // intentionally does not consult the sequence cancellation token.
    let start = std::time::Instant::now();
    let timeout = Duration::from_secs(DEFAULT_FILTER_WHEEL_TIMEOUT_SECS);
    sleep(Duration::from_millis(100)).await;
    // Last position read back, so a timeout can say WHERE the wheel is instead
    // of only where it isn't. A wheel that is idle at somebody else's slot and
    // a wheel that never moved produce the same message otherwise, and the
    // first is an arbitration bug while the second is broken hardware — the
    // owner spent a night on the wrong one of those. The imaging-train claim
    // makes the interleaving impossible; this makes it legible if it ever
    // happens again through a path that does not take the claim.
    let mut last_observed: Option<i32> = None;
    loop {
        match ctx
            .device_ops
            .filterwheel_get_position(filterwheel_id)
            .await
        {
            Ok(position) if position == target_position => break,
            Ok(position) => last_observed = Some(position),
            Err(error) => tracing::warn!(
                "Error verifying autofocus filter move to {}: {}",
                target_position,
                error
            ),
        }
        if start.elapsed() > timeout {
            return Err(match last_observed {
                Some(observed) => format!(
                    "filter wheel did not reach position {} within {} seconds; it is sitting at \
                     position {} — something else moved it",
                    target_position,
                    timeout.as_secs(),
                    observed
                ),
                None => format!(
                    "filter wheel did not reach position {} within {} seconds and its position \
                     could not be read",
                    target_position,
                    timeout.as_secs()
                ),
            });
        }
        sleep(Duration::from_millis(200)).await;
    }

    apply_filter_focus_offset(filter_name, ctx, None)
        .await
        .map_err(|error| format!("focus offset failed: {}", error))
}

/// How long the autofocus cleanup waits for a resumed guider to settle: the
/// 60 s settle timeout it asks the guider for, plus the time to loop, select a
/// star and send the first guide frames before that clock starts.
const GUIDING_RESUME_DEADLINE: Duration = Duration::from_secs(120);
const GUIDING_RESUME_POLL_INTERVAL: Duration = Duration::from_secs(2);

/// Restart the guider autofocus stopped, and prove it is guiding again.
///
/// Proven means settled, by the bar the recovery ladder holds a re-acquired
/// star to ([`crate::executor::guiding_is_settled`]), polled until a deadline.
/// One status read straight after the resume was wrong both ways. PHD2's
/// `guide` RPC answers before PHD2 is guiding, so a guider still selecting its
/// star was called dead, which now holds the run. And PHD2 reports Guiding
/// while it chases a star it has lost at tens of pixels, which was called
/// restored and trailed every frame after it.
pub(crate) async fn resume_guiding_after_autofocus(
    ctx: &InstructionContext,
    result: InstructionResult,
) -> InstructionResult {
    // A fresh star: the autofocus run may have moved the field under the
    // guider's old lock position.
    if let Err(error) = start_guiding_on_fresh_star(&ctx.device_ops, 1.0, 10.0, 60.0).await {
        return append_guiding_not_restored(
            ctx,
            result,
            format!(
                "failed to resume guiding after autofocus: {}",
                error.message()
            ),
        )
        .await;
    }
    let deadline = tokio::time::Instant::now() + GUIDING_RESUME_DEADLINE;
    let mut last_seen: Result<crate::GuidingStatus, String>;
    loop {
        last_seen = ctx.device_ops.guider_get_status().await;
        if let Ok(status) = &last_seen {
            if crate::executor::guiding_is_settled(status) {
                if let Some(trigger_state) = &ctx.trigger_state {
                    trigger_state.write().await.set_guiding_enabled(true);
                }
                return result;
            }
        }
        if tokio::time::Instant::now() >= deadline {
            break;
        }
        // A Stop ends the wait. The run's end waits for this cleanup, so a
        // guider that was never coming back held the operator's Stop for the
        // whole two minutes. Nothing more is owed to a run that is ending
        // than not claiming the guider is back.
        if ctx.cancellation_token.load(Ordering::Relaxed) {
            tracing::info!(
                "Autofocus cleanup stopped waiting for the guider to settle: the run is stopping"
            );
            if let Some(trigger_state) = &ctx.trigger_state {
                trigger_state.write().await.set_guiding_enabled(false);
            }
            return result;
        }
        sleep(GUIDING_RESUME_POLL_INTERVAL).await;
    }
    let failure = match last_seen {
        Ok(status) if status.is_guiding => format!(
            "guider reported guiding after the resume but never settled: RMS {:.1} px \
             against a {:.1} px limit after {} s",
            status.rms_total,
            crate::executor::REACQUIRE_SETTLE_PIXELS,
            GUIDING_RESUME_DEADLINE.as_secs()
        ),
        Ok(_) => "guider accepted resume but did not report guiding".to_string(),
        Err(error) => format!(
            "could not verify guiding resumed after autofocus: {}",
            error
        ),
    };
    append_guiding_not_restored(ctx, result, failure).await
}

/// Record a cleanup failure that left the guider stopped: stamp the
/// [`AUTOFOCUS_GUIDING_NOT_RESTORED_KEY`] marker the caller branches on, and
/// clear the trigger state's `guiding_enabled` latch.
///
/// Clearing the latch is not bookkeeping. The monitor's guide-poll block arms
/// `guide_star_lost` from that latch, and PHD2 answers `is_guiding = true`
/// whenever it is still emitting GuideStep frames — which it does while
/// chasing a lost star with the offsets at ±57 px. Leaving the latch set
/// therefore left the run believing guiding was healthy from the one device
/// that could not tell it otherwise. The autofocus cleanup is the only place
/// that KNOWS the guider was stopped and not proven back, so it is the place
/// that must say so.
async fn append_guiding_not_restored(
    ctx: &InstructionContext,
    result: InstructionResult,
    failure: String,
) -> InstructionResult {
    if let Some(trigger_state) = &ctx.trigger_state {
        trigger_state.write().await.set_guiding_enabled(false);
    }
    let mut result = append_autofocus_cleanup_failure(result, failure);
    let mut metadata = match result.data.take() {
        Some(serde_json::Value::Object(object)) => object,
        _ => serde_json::Map::new(),
    };
    metadata.insert(
        AUTOFOCUS_GUIDING_NOT_RESTORED_KEY.to_string(),
        serde_json::Value::Bool(true),
    );
    result.data = Some(serde_json::Value::Object(metadata));
    result
}

pub(crate) fn append_autofocus_cleanup_failure(
    mut result: InstructionResult,
    failure: String,
) -> InstructionResult {
    let prior = result
        .message
        .take()
        .unwrap_or_else(|| "Autofocus did not complete".to_string());
    result.status = NodeStatus::Failure;
    result.message = Some(format!("{}; CRITICAL CLEANUP FAILURE: {}", prior, failure));
    result
}

pub(crate) fn validate_autofocus_config(config: &AutofocusConfig) -> Result<(), String> {
    if !config.exposure_duration.is_finite() || config.exposure_duration <= 0.0 {
        return Err("Autofocus exposure duration must be finite and positive".to_string());
    }
    if !config.max_duration_secs.is_finite() || config.max_duration_secs <= 0.0 {
        return Err("Autofocus maximum duration must be finite and positive".to_string());
    }
    if config.step_size <= 0 {
        return Err("Autofocus step size must be positive".to_string());
    }
    if !(1..=50).contains(&config.steps_out) {
        return Err("Autofocus steps out must be between 1 and 50".to_string());
    }
    if !(1..=10).contains(&config.number_of_attempts) {
        return Err("Autofocus attempt count must be between 1 and 10".to_string());
    }
    if !(1..=20).contains(&config.exposures_per_point) {
        return Err("Autofocus exposures per point must be between 1 and 20".to_string());
    }
    if !config.r_squared_threshold.is_finite() || !(0.0..=1.0).contains(&config.r_squared_threshold)
    {
        return Err("Autofocus R² threshold must be between 0 and 1".to_string());
    }
    if !config.outer_crop_ratio.is_finite()
        || !config.inner_crop_ratio.is_finite()
        || config.outer_crop_ratio <= 0.0
        || config.outer_crop_ratio > 1.0
        || config.inner_crop_ratio < 0.0
        || config.inner_crop_ratio >= config.outer_crop_ratio
    {
        return Err("Autofocus crop ratios must satisfy 0 <= inner < outer <= 1".to_string());
    }
    if config.focuser_settle_time_ms > 10_000 {
        return Err("Autofocus focuser settle time cannot exceed 10000 ms".to_string());
    }
    if config.backlash_compensation < 0 || config.backlash_out_compensation < 0 {
        return Err("Autofocus backlash values cannot be negative".to_string());
    }
    if config.gain.is_some_and(|gain| gain < 0) || config.offset.is_some_and(|offset| offset < 0) {
        return Err("Autofocus gain and offset cannot be negative".to_string());
    }
    for (filter_name, filter_config) in &config.filter_settings {
        if filter_name.trim().is_empty() {
            return Err("Autofocus per-filter settings contain an empty filter name".to_string());
        }
        if filter_config
            .af_exposure_time
            .is_some_and(|exposure| !exposure.is_finite() || exposure <= 0.0)
        {
            return Err(format!(
                "Autofocus exposure override for filter \"{}\" must be finite and positive",
                filter_name
            ));
        }
        if filter_config.gain.is_some_and(|gain| gain < 0)
            || filter_config.offset.is_some_and(|offset| offset < 0)
        {
            return Err(format!(
                "Autofocus gain and offset overrides for filter \"{}\" cannot be negative",
                filter_name
            ));
        }
    }
    Ok(())
}

pub(crate) async fn execute_autofocus_once(
    config: &AutofocusConfig,
    ctx: &InstructionContext,
    progress_callback: Option<&(dyn Fn(f64, String) + Send + Sync)>,
    pause: &crate::node::context::PauseGate,
) -> InstructionResult {
    let camera_id = match ctx.camera_id() {
        Ok(id) => id.to_string(),
        Err(e) => return e,
    };
    let focuser_id = match ctx.focuser_id() {
        Ok(id) => id.to_string(),
        Err(e) => return e,
    };

    tracing::info!(
        "Starting autofocus: {:?} method, {} steps, step size {}",
        config.method,
        config.steps_out,
        config.step_size
    );

    if let Some(result) = ctx.check_cancelled() {
        return result;
    }

    if let Some(cb) = progress_callback {
        cb(0.0, "Starting autofocus...".to_string());
    }

    // Sweep positions are calculated from the current position outward;
    // failing the read here is fatal because the alternative is to sweep
    // from a guessed origin and land somewhere unrelated to focus.
    tracing::debug!("Getting focuser position for focuser_id: {}", focuser_id);
    let current_position = match ctx.device_ops.focuser_get_position(&focuser_id).await {
        Ok(pos) => pos,
        Err(e) => {
            tracing::error!("Autofocus failed: Could not get focuser position: {}", e);
            return InstructionResult::failure(format!("Failed to get focuser position: {}", e));
        }
    };

    tracing::info!("Current focuser position: {}", current_position);

    let af_timeout = Duration::from_secs_f64(config.max_duration_secs);
    let af_start_time = tokio::time::Instant::now();
    let autofocus_operation = async {
        let af_config: crate::autofocus::AutofocusConfig = config.into();

        let af_engine = crate::autofocus::VCurveAutofocus::new(af_config.clone());
        // The move down to the sweep start overshoots and comes back up by
        // the same figure, and margin, that sizes the final run-up. Using the
        // operator's figure alone left a measured backlash out of it, and a
        // dead band wider than one step then swallowed the first upward sweep
        // moves: two "different" points measured at one optical position.
        let approach_in = resolve_run_up(
            config.backlash_compensation,
            config.measured_backlash_in,
            config.step_size,
        )
        .0
        .unwrap_or(0);
        let backlash = crate::autofocus::BacklashCompensation::new_directional(
            approach_in,
            af_config.backlash_out_compensation,
        );

        let positions = af_engine.calculate_positions(current_position);
        let total_points = positions.len();
        let start_position = positions[0];

        let mut focus_data: Vec<crate::autofocus::FocusDataPoint> =
            Vec::with_capacity(total_points);

        if let Some(cb) = progress_callback {
            cb(5.0, format!("Moving to start position: {}", start_position));
        }

        if backlash.is_needed(current_position, start_position) {
            let (intermediate, final_pos) =
                backlash.calculate_approach(current_position, start_position);

            if let Some(overshoot) = intermediate {
                tracing::info!(
                    "Applying backlash compensation: {} -> {} -> {}",
                    current_position,
                    overshoot,
                    final_pos
                );

                if let Err(e) = ctx.device_ops.focuser_move_to(&focuser_id, overshoot).await {
                    return InstructionResult::failure(format!(
                        "Failed to move focuser (backlash): {}",
                        e
                    ));
                }
                if let Err(e) =
                    wait_for_focuser_idle(&focuser_id, ctx, Duration::from_secs(120)).await
                {
                    return InstructionResult::failure(e);
                }
            }

            if let Err(e) = ctx.device_ops.focuser_move_to(&focuser_id, final_pos).await {
                return InstructionResult::failure(format!("Failed to move focuser: {}", e));
            }
        } else {
            tracing::info!("Moving to start position: {}", start_position);
            if let Err(e) = ctx
                .device_ops
                .focuser_move_to(&focuser_id, start_position)
                .await
            {
                return InstructionResult::failure(format!("Failed to move focuser: {}", e));
            }
        }

        if let Err(e) = wait_for_focuser_idle(&focuser_id, ctx, Duration::from_secs(300)).await {
            return InstructionResult::failure(e);
        }
        if let Some(result) = wait_for_autofocus_settle(config, ctx).await {
            return result;
        }

        let (bin_x, bin_y) = match config.binning {
            Binning::One => (1, 1),
            Binning::Two => (2, 2),
            Binning::Three => (3, 3),
            Binning::Four => (4, 4),
        };

        // The minimum star count is `config.min_star_count` (default 10 from
        // `default_af_min_star_count`), so a user with a fast or dim setup can
        // lower it without patching the binary.
        let min_star_count: u32 = config.min_star_count.max(1);
        // 1.0 px² is the noise floor: a V-curve with smaller HFR variance is
        // indistinguishable from flat noise and the fit would extrapolate to
        // nonsense.
        const MIN_HFR_VARIANCE: f64 = 1.0;
        let mut low_star_count_warnings = 0;
        // Time the operator spent holding the run paused mid-sweep. Excluded
        // from the autofocus deadline below: a Pause is not the focuser being
        // slow, and charging it to the budget would fail a sweep that was
        // healthy right up to the moment the operator stepped away.
        let mut paused_duration = Duration::ZERO;

        for point in 0..total_points {
            // Check timeout
            let working_elapsed = af_start_time.elapsed().saturating_sub(paused_duration);
            if working_elapsed > af_timeout {
                tracing::warn!(
                "Autofocus timed out after {:.0}s (limit: {:.0}s), returning focuser to original position",
                working_elapsed.as_secs_f64(),
                config.max_duration_secs,
            );
                return InstructionResult::failure(format!(
                    "Autofocus timed out after {:.0}s (max duration: {:.0}s)",
                    working_elapsed.as_secs_f64(),
                    config.max_duration_secs,
                ));
            }

            if let Some(result) = ctx.check_cancelled() {
                return result;
            }

            // Honour an operator Pause between sample points. A V-curve sweep
            // is ~15 exposures plus focuser motion inside ONE instruction, so
            // the node-boundary check the tree does never sees a Pause pressed
            // during the sweep.
            if pause.is_paused() {
                let paused_at = tokio::time::Instant::now();
                if !pause.wait_while_paused(&ctx.cancellation_token).await {
                    return InstructionResult::cancelled("Autofocus cancelled while paused");
                }
                paused_duration += paused_at.elapsed();
            }

            let position = positions[point];

            // 10-90% covers the V-curve sample loop; the remaining 10% is the
            // final move + settle + curve fit, which is the noticeable wait the
            // user sees after the last sample is taken.
            // Why: point and total_points are usize bounded by sweep size (<=50 in UI);
            // lossless to f64.
            let point_progress = 10.0 + (point as f64 / total_points as f64 * 80.0);

            tracing::info!(
                "Focus point {}/{} at position {}",
                point + 1,
                total_points,
                position
            );
            if let Some(cb) = progress_callback {
                cb(
                    point_progress,
                    format!("Point {}/{}: pos {}", point + 1, total_points, position),
                );
            }

            if let Err(e) = ctx.device_ops.focuser_move_to(&focuser_id, position).await {
                return InstructionResult::failure(format!("Failed to move focuser: {}", e));
            }

            if let Err(e) = wait_for_focuser_idle(&focuser_id, ctx, Duration::from_secs(120)).await
            {
                return InstructionResult::failure(e);
            }
            if let Some(result) = wait_for_autofocus_settle(config, ctx).await {
                return result;
            }

            let mut measurements = Vec::with_capacity(config.exposures_per_point as usize);
            for sample in 0..config.exposures_per_point {
                if let Some(result) = ctx.check_cancelled() {
                    return result;
                }
                let mut abort_guard =
                    CameraExposureAbortGuard::new(ctx.device_ops.clone(), camera_id.clone());
                let exposure_result = ctx
                    .device_ops
                    .camera_start_exposure(
                        &camera_id,
                        config.exposure_duration,
                        config.gain,
                        config.offset,
                        bin_x,
                        bin_y,
                    )
                    .await;
                abort_guard.disarm();
                let image_data = match exposure_result {
                    Ok(data) => {
                        tracing::info!(
                            "[SEQ] Autofocus point {} sample {}/{} completed: {}x{} ({} pixels)",
                            point + 1,
                            sample + 1,
                            config.exposures_per_point,
                            data.width,
                            data.height,
                            data.data.len()
                        );
                        data
                    }
                    Err(e) => {
                        return InstructionResult::failure(format!(
                            "Autofocus exposure failed: {}",
                            e
                        ))
                    }
                };
                measurements.push(calculate_hfr_with_crops(
                    &image_data,
                    config.outer_crop_ratio,
                    config.inner_crop_ratio,
                    config.use_brightest_n_stars,
                ));
            }
            measurements.sort_by(|a, b| a.hfr.total_cmp(&b.hfr));
            let measurement = measurements.swap_remove(measurements.len() / 2);

            tracing::info!(
                "Position {} HFR: {:.2}, Stars: {} detected, {} beyond the HFR window",
                position,
                measurement.hfr,
                measurement.star_count,
                measurement.unmeasurable_star_count
            );

            if measurement.star_count < min_star_count {
                low_star_count_warnings += 1;
                tracing::warn!(
                    "Low star count at position {}: {} stars (minimum: {})",
                    position,
                    measurement.star_count,
                    min_star_count
                );

                // >50% of sweep points failing star detection means seeing /
                // clouds / pointing has degraded so badly that no fit will be
                // meaningful; failing fast saves the user the rest of the sweep
                // and a useless curve-fit error.
                if low_star_count_warnings > total_points / 2 {
                    return InstructionResult::failure(format!(
                    "Autofocus failed: Insufficient stars detected. Only {} stars found (minimum: {}). \
                     This may indicate clouds, poor seeing, or incorrect camera settings.",
                    measurement.star_count, min_star_count
                ));
                }
            }

            focus_data.push(crate::autofocus::FocusDataPoint {
                position,
                hfr: measurement.hfr,
                fwhm: None,
                star_count: measurement.star_count,
            });

            let progress_json = serde_json::json!({
                "type": "autofocus_progress",
                "point": point + 1,
                "total_points": total_points,
                "hfr": measurement.hfr,
                "star_count": measurement.star_count,
                "focus_range": {
                    "min": positions[0],
                    "max": positions[total_points - 1]
                },
                "vcurve_points": focus_data.iter().map(|point| {
                    serde_json::json!({"position": point.position, "hfr": point.hfr})
                }).collect::<Vec<_>>(),
                "star_crops": measurement.star_crops.iter().map(|crop| {
                    serde_json::json!({
                        "pixels_base64": crop.pixels_base64,
                        "width": crop.width,
                        "height": crop.height,
                        "hfr": crop.hfr,
                        "snr": crop.snr
                    })
                }).collect::<Vec<_>>()
            });

            if let Some(cb) = progress_callback {
                cb(point_progress, progress_json.to_string());
            }
        }

        if let Some(cb) = progress_callback {
            cb(92.0, "Validating focus data...".to_string());
        }

        // A flat HFR curve (variance < MIN_HFR_VARIANCE) is not a V-curve to fit
        // — it usually means clouds rolled in, the focuser is far outside the
        // critical zone, or the sensor is misreporting. Fitting anyway would
        // produce a meaningless "best focus" position.
        let hfr_values: Vec<f64> = focus_data.iter().map(|point| point.hfr).collect();
        let min_hfr = hfr_values.iter().cloned().fold(f64::INFINITY, f64::min);
        let max_hfr = hfr_values.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
        let hfr_variance = max_hfr - min_hfr;

        tracing::info!(
            "HFR variance: {:.2} (min: {:.2}, max: {:.2})",
            hfr_variance,
            min_hfr,
            max_hfr
        );

        if hfr_variance < MIN_HFR_VARIANCE {
            return InstructionResult::failure(format!(
            "Autofocus failed: No valid V-curve detected. HFR variance is only {:.2} (minimum: {:.1}). \
             The HFR is not changing with focus position, which may indicate: \
             - Clouds or obstructions blocking the sky \
             - Hot pixels being detected instead of real stars \
             - Focus range is too narrow or too far from true focus \
             - Camera is not properly connected or imaging",
            hfr_variance, MIN_HFR_VARIANCE
        ));
        }

        let af_result = match af_engine.find_best_focus(focus_data) {
            Ok(mut result) => {
                result.temperature_celsius = ctx
                    .device_ops
                    .focuser_get_temperature(&focuser_id)
                    .await
                    .ok()
                    .flatten();
                result
            }
            Err(e) => {
                tracing::warn!(
                "Autofocus curve fit failed ({}); shared attempt cleanup will restore position {}",
                e, current_position
            );
                return InstructionResult::failure(format!(
                    "Autofocus curve fitting failed: {}",
                    e
                ));
            }
        };

        // Clamp the fitted best-focus position to the swept range. The parabolic
        // and hyperbolic fits return the analytic vertex, which for a poor-quality
        // (low-R²) curve can land far outside the sampled bracket — an
        // extrapolation that is by definition untrustworthy and, on a permissive
        // driver, would drive the focuser wildly out of position. A vertex outside
        // the bracket means true focus was not bracketed; clamping bounds the move
        // to the sampled window (worst case: a sweep endpoint near where we
        // started) instead of an arbitrary extrapolated step.
        let sweep_lo = positions[0].min(positions[total_points - 1]);
        let sweep_hi = positions[0].max(positions[total_points - 1]);
        let best_position = {
            let raw = af_result.best_position;
            let clamped = raw.clamp(sweep_lo, sweep_hi);
            if clamped != raw {
                tracing::warn!(
                    "Autofocus best-focus vertex {} fell outside the swept range [{}, {}]; \
                 clamping to {}. The curve minimum was an extrapolation (poor fit) — \
                 true focus may lie outside the sweep window.",
                    raw,
                    sweep_lo,
                    sweep_hi,
                    clamped
                );
            }
            clamped
        };
        let best_hfr = af_result.best_hfr;
        let r_squared = af_result.curve_fit_quality;

        // The configured R² value is a real acceptance threshold, not a cosmetic
        // warning. Shared attempt cleanup restores the pre-run position before a
        // retry or terminal failure is returned.
        if r_squared < config.r_squared_threshold {
            tracing::warn!(
                "Low curve fit quality: R²={:.3} (required: {:.3}); returning to original position",
                r_squared,
                config.r_squared_threshold
            );
            return InstructionResult::failure(format!(
                "Autofocus curve fit R² {:.3} is below the configured threshold {:.3}",
                r_squared, config.r_squared_threshold
            ));
        }

        tracing::info!(
            "Best focus at position {}, HFR: {:.2}, R²: {:.3}",
            best_position,
            best_hfr,
            r_squared
        );

        if let Some(cb) = progress_callback {
            cb(95.0, format!("Moving to best focus: {}", best_position));
        }

        // EVERY sweep point is measured while moving UP: `calculate_positions`
        // starts at `start - steps_out * step_size` and steps outward. So the
        // fitted minimum is expressed in the "approached from below" frame, and
        // it is only true focus if the focuser arrives there the same way.
        //
        // The sweep always ends at its far extreme, so a direct move to best
        // focus arrives DOWNWARD — the opposite face of the gear's backlash.
        // Measured on the owner's ZWO EAF on 2026-09-14: the from-below optimum
        // was 6620 and the from-above optimum 6515, so landing from above left
        // the optics 105 steps out and the same commanded 6620 measured
        // HFR 5.60 instead of 2.94. Stars were visibly donut-shaped while the
        // curve and its reported HFR looked perfect.
        //
        // So the final approach is ALWAYS a run-up from below, regardless of
        // travel direction and regardless of whether the operator has entered a
        // backlash figure. The run-up only has to EXCEED the mechanical
        // backlash; overshooting further costs one extra move and nothing else,
        // and it never leaves the span the sweep just traversed.
        let (run_up_from, run_up_source) = final_run_up_position(
            best_position,
            start_position,
            config.backlash_compensation,
            config.measured_backlash_in,
            config.step_size,
        );

        tracing::info!(
            "Final approach: run up from {} to {} so focus is reached moving in the \
             same direction the sweep measured it, sized from {}",
            run_up_from,
            best_position,
            run_up_source.label()
        );

        if let Err(e) = ctx
            .device_ops
            .focuser_move_to(&focuser_id, run_up_from)
            .await
        {
            return InstructionResult::failure(format!(
                "Failed to move focuser (final run-up): {}",
                e
            ));
        }
        if let Err(e) = wait_for_focuser_idle(&focuser_id, ctx, Duration::from_secs(120)).await {
            return InstructionResult::failure(e);
        }

        if let Err(e) = ctx
            .device_ops
            .focuser_move_to(&focuser_id, best_position)
            .await
        {
            return InstructionResult::failure(format!("Failed to move to best focus: {}", e));
        }

        if let Err(e) = wait_for_focuser_idle(&focuser_id, ctx, Duration::from_secs(120)).await {
            return InstructionResult::failure(format!("Failed to settle at best focus: {}", e));
        }
        if let Some(result) = wait_for_autofocus_settle(config, ctx).await {
            return result;
        }

        // Measure what we ACTUALLY landed on, and report that.
        //
        // `best_hfr` is the fitted curve's predicted minimum — a property of the
        // model, not of the focuser's final state. Reporting it as the outcome
        // is how a run that left the stars visibly donut-shaped still announced
        // a near-perfect curve: nothing ever looked through the telescope after
        // the final move. One frame closes that gap, and it is the only number
        // here an operator can check against their own screen.
        let verified_hfr = {
            let mut abort_guard =
                CameraExposureAbortGuard::new(ctx.device_ops.clone(), camera_id.clone());
            let exposure_result = ctx
                .device_ops
                .camera_start_exposure(
                    &camera_id,
                    config.exposure_duration,
                    config.gain,
                    config.offset,
                    bin_x,
                    bin_y,
                )
                .await;
            abort_guard.disarm();
            match exposure_result {
                Ok(image_data) => {
                    let measurement = calculate_hfr_with_crops(
                        &image_data,
                        config.outer_crop_ratio,
                        config.inner_crop_ratio,
                        config.use_brightest_n_stars,
                    );
                    // A frame with too few stars to measure (cloud, a satellite
                    // trail swamping detection) returns the no-focus sentinel,
                    // which would read as a landing far worse than the curve
                    // and blame the focuser. It measures nothing, so the
                    // landing goes unverified, as with a failed exposure.
                    if measurement.star_count < config.min_star_count {
                        tracing::warn!(
                            "Autofocus could not verify the landing: the frame at best focus \
                             has {} measurable stars, fewer than the {} the sweep required",
                            measurement.star_count,
                            config.min_star_count
                        );
                        None
                    } else {
                        Some(measurement.hfr)
                    }
                }
                // A failed verification frame is not a failed focus run: the
                // curve fit and the move both succeeded. Say the check could
                // not be made rather than discarding a good result.
                Err(e) => {
                    tracing::warn!("Autofocus could not verify the landing: {}", e);
                    None
                }
            }
        };

        // The landing is only trusted if it is within the configured tolerance
        // of what the curve promised. A landing materially worse than the fit
        // means the focuser did not end up where the curve was measured —
        // backlash, slip, or a focuser that ignored the command — and that is a
        // failure the operator must see, not a success with a quiet number.
        if let Some(measured) = verified_hfr {
            // `failure_hfr_tolerance_ratio` is borrowed as the landing
            // tolerance, but at or below 1 it means something else ("every
            // failure is unrecoverable", or a limit no noisy frame can meet)
            // and turned this check into "no worse than the best sample",
            // which a correct landing fails on noise alone. Such settings
            // fall back to the shipped ratio here.
            let tolerance = if config.failure_hfr_tolerance_ratio > 1.0 {
                config.failure_hfr_tolerance_ratio
            } else {
                crate::default_af_failure_hfr_tolerance_ratio()
            };
            if best_hfr > 0.0 && measured > best_hfr * tolerance {
                tracing::warn!(
                    "Autofocus landed at {} measuring HFR {:.2}, worse than the fitted {:.2} \
                     by more than the {:.2}x tolerance",
                    best_position,
                    measured,
                    best_hfr,
                    tolerance
                );
                return InstructionResult::failure(format!(
                    "Autofocus moved to {} {} {:.2}, \
                     against the curve's {:.2} (tolerance {:.2}x). The focuser did not end up \
                     where the curve was measured.",
                    best_position,
                    LANDING_VERIFICATION_FAILURE_PHRASE,
                    measured,
                    best_hfr,
                    tolerance
                ));
            }
        }

        let reported_hfr = verified_hfr.unwrap_or(best_hfr);
        let hfr_note = if verified_hfr.is_some() {
            "measured"
        } else {
            "predicted; the verification frame could not be measured"
        };

        if let Some(cb) = progress_callback {
            cb(
                100.0,
                format!(
                    "Complete: pos {}, HFR {:.2} ({}), R² {:.3}",
                    best_position, reported_hfr, hfr_note, r_squared
                ),
            );
        }

        InstructionResult {
            status: NodeStatus::Success,
            message: Some(format!(
                "Autofocus complete: position {}, HFR {:.2} ({}), R² {:.3}",
                best_position, reported_hfr, hfr_note, r_squared
            )),
            data: serde_json::to_value(&af_result).ok(),
            hfr_values: vec![reported_hfr],
        }
    };

    // One deadline encloses every move command, idle poll, mechanical settle,
    // camera exposure, curve fit, and final move. Point-boundary checks alone
    // cannot enforce the advertised limit when any one of those awaits hangs.
    let mut result = match tokio::time::timeout(af_timeout, autofocus_operation).await {
        Ok(result) => result,
        Err(_) => {
            tracing::warn!(
                "Autofocus timed out after {:.0}s (limit: {:.0}s), returning focuser to original position",
                af_start_time.elapsed().as_secs_f64(),
                config.max_duration_secs,
            );
            InstructionResult::failure(format!(
                "Autofocus timed out after {:.0}s (max duration: {:.0}s)",
                af_start_time.elapsed().as_secs_f64(),
                config.max_duration_secs,
            ))
        }
    };

    if matches!(result.status, NodeStatus::Failure | NodeStatus::Cancelled) {
        // The origin goes back on the same face of the backlash a landing
        // uses. A failed run ends at or above the sweep, so a plain return
        // arrived moving down: on a focuser with backlash that is the full
        // dead band away from an origin the last successful run landed on
        // from below, while the result still said the origin was restored.
        let sweep_start = crate::autofocus::VCurveAutofocus::new(config.into())
            .calculate_positions(current_position)
            .first()
            .copied()
            .unwrap_or(current_position);
        let (restore_run_up, _) = final_run_up_position(
            current_position,
            sweep_start,
            config.backlash_compensation,
            config.measured_backlash_in,
            config.step_size,
        );
        let restored =
            restore_autofocus_origin(&focuser_id, ctx, current_position, Some(restore_run_up))
                .await;
        if let Err(error) = &restored {
            tracing::error!(
                "Autofocus could not restore original position {}: {}",
                current_position,
                error
            );
            let prior = result
                .message
                .take()
                .unwrap_or_else(|| "Autofocus did not complete".to_string());
            result.message = Some(format!(
                "{}; CRITICAL: failed to restore original focuser position {}: {}",
                prior, current_position, error
            ));
        }
        let mut metadata = match result.data.take() {
            Some(serde_json::Value::Object(object)) => object,
            _ => serde_json::Map::new(),
        };
        metadata.insert(
            "autofocus_origin_restored".to_string(),
            serde_json::Value::Bool(restored.is_ok()),
        );
        result.data = Some(serde_json::Value::Object(metadata));
    }

    result
}

/// Restore the pre-attempt focuser position before returning any failed or
/// cancelled autofocus result. This deliberately ignores the sequence cancel
/// token: cleanup is still hardware work owned by the autofocus Future, and a
/// caller must not be told the run is terminal while the motor is moving.
///
/// `run_up_from`, when given, is visited first so the origin is reached
/// moving up; it must be below `original_position`.
pub(crate) async fn restore_autofocus_origin(
    focuser_id: &str,
    ctx: &InstructionContext,
    original_position: i32,
    run_up_from: Option<i32>,
) -> Result<(), String> {
    let mut errors = Vec::new();

    if let Err(error) = ctx.device_ops.focuser_halt(focuser_id).await {
        errors.push(format!("halt failed: {}", error));
    }
    if !wait_for_focuser_stop_after_halt(focuser_id, &ctx.device_ops, Duration::from_secs(10)).await
    {
        errors.push("motor did not stop within 10 seconds".to_string());
    }

    if let Some(run_up) = run_up_from.filter(|run_up| *run_up < original_position) {
        match ctx.device_ops.focuser_move_to(focuser_id, run_up).await {
            Ok(()) => {
                if !wait_for_focuser_stop_after_halt(
                    focuser_id,
                    &ctx.device_ops,
                    Duration::from_secs(120),
                )
                .await
                {
                    errors.push(format!(
                        "run-up move to {} did not settle within 120 seconds",
                        run_up
                    ));
                }
            }
            // Still try the return itself: the origin from the wrong side
            // is better than the focuser left wherever the run stopped.
            Err(error) => errors.push(format!("run-up move to {} was rejected: {}", run_up, error)),
        }
    }

    match ctx
        .device_ops
        .focuser_move_to(focuser_id, original_position)
        .await
    {
        Ok(()) => {
            if !wait_for_focuser_stop_after_halt(
                focuser_id,
                &ctx.device_ops,
                Duration::from_secs(120),
            )
            .await
            {
                errors.push(format!(
                    "return move to {} did not settle within 120 seconds",
                    original_position
                ));
            }
        }
        Err(error) => errors.push(format!(
            "return move to {} was rejected: {}",
            original_position, error
        )),
    }

    if errors.is_empty() {
        Ok(())
    } else {
        Err(errors.join("; "))
    }
}

pub(crate) async fn wait_for_autofocus_settle(
    config: &AutofocusConfig,
    ctx: &InstructionContext,
) -> Option<InstructionResult> {
    let mut remaining = config.focuser_settle_time_ms;
    while remaining > 0 {
        if let Some(result) = ctx.check_cancelled() {
            return Some(result);
        }
        let chunk = remaining.min(100);
        sleep(Duration::from_millis(chunk)).await;
        remaining -= chunk;
    }
    ctx.check_cancelled()
}

/// Enhanced HFR measurement with star crops for UI display
pub(crate) struct HfrMeasurementWithCrops {
    pub(crate) hfr: f64,
    /// Stars detected inside the configured crop, counted BEFORE the
    /// brightest-N cap is applied. Reporting the post-cap length instead
    /// makes every sweep point report the cap itself, which silently
    /// disarms `min_star_count` (both default to 10, so `10 < 10` is never
    /// true) and leaves the operator reading a constant where the sweep's
    /// most diagnostic number should be.
    pub(crate) star_count: u32,
    /// Of the stars actually considered for the median, how many had an HFR
    /// outside the validity window. These are dropped from the median, so a
    /// heavily defocused point can report the HFR of the few tight stars
    /// that survived rather than the defocus it really has.
    pub(crate) unmeasurable_star_count: u32,
    /// Base64-encoded star crops (80x80 grayscale), up to 5 brightest stars
    star_crops: Vec<StarCropInfo>,
}

/// Star crop info for UI display
#[derive(Clone)]
pub(crate) struct StarCropInfo {
    /// Base64-encoded grayscale pixels
    pixels_base64: String,
    width: u32,
    height: u32,
    hfr: f64,
    snr: f64,
}

/// Calculate HFR from image data, honoring the configured central crop and
/// brightest-star cap rather than merely transporting those settings.
pub(crate) fn calculate_hfr_with_crops(
    image: &ImageData,
    outer_crop_ratio: f64,
    inner_crop_ratio: f64,
    use_brightest_n_stars: u32,
) -> HfrMeasurementWithCrops {
    use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
    use skotiq_imaging::{detect_stars_with_stats, extract_top_star_crops, StarDetectionConfig};

    // 1 channel = monochrome; raw imager output is treated as mono for HFR
    // regardless of Bayer pattern, because debayering before star detection
    // would smear PSFs and inflate HFR.
    let imaging_data =
        skotiq_imaging::ImageData::from_u16(image.width, image.height, 1, &image.data);

    let config = StarDetectionConfig::default();
    let result = detect_stars_with_stats(&imaging_data, &config);

    let center_x = image.width as f64 / 2.0;
    let center_y = image.height as f64 / 2.0;
    let outer_half_width = image.width as f64 * outer_crop_ratio / 2.0;
    let outer_half_height = image.height as f64 * outer_crop_ratio / 2.0;
    let inner_half_width = image.width as f64 * inner_crop_ratio / 2.0;
    let inner_half_height = image.height as f64 * inner_crop_ratio / 2.0;

    // detect_stars returns brightness-ranked stars. Preserve that order so a
    // non-zero brightest-N setting is deterministic before calculating the
    // median HFR.
    let mut eligible_stars: Vec<_> = result
        .stars
        .into_iter()
        .filter(|star| {
            let dx = (star.x - center_x).abs();
            let dy = (star.y - center_y).abs();
            let inside_outer = dx <= outer_half_width && dy <= outer_half_height;
            let inside_inner =
                inner_crop_ratio > 0.0 && dx < inner_half_width && dy < inner_half_height;
            inside_outer && !inside_inner
        })
        .collect();
    let star_count = eligible_stars.len() as u32;
    if use_brightest_n_stars > 0 {
        eligible_stars.truncate(use_brightest_n_stars as usize);
    }

    let considered = eligible_stars.len();
    let mut hfr_values: Vec<f64> = eligible_stars
        .iter()
        .map(|star| star.hfr)
        .filter(|hfr| hfr.is_finite() && *hfr > 0.0 && *hfr < 20.0)
        .collect();
    let unmeasurable_star_count = considered.saturating_sub(hfr_values.len()) as u32;
    hfr_values.sort_by(f64::total_cmp);

    // 20.0 px is the "no valid focus" sentinel: an HFR this high is far
    // beyond any realistic well-focused setup, so the V-curve fit will
    // treat the point as the extreme of the curve (or reject as outlier).
    let hfr = if hfr_values.is_empty() {
        20.0
    } else {
        hfr_values[hfr_values.len() / 2]
    };

    // 5 crops @ 80 px is the upper bound the autofocus UI displays; more
    // would saturate the operator's view and inflate the JSON payload sent
    // over the FRB bridge.
    let crops = extract_top_star_crops(&imaging_data, &eligible_stars, 5, 80);

    let star_crops: Vec<StarCropInfo> = crops
        .into_iter()
        .map(|crop| StarCropInfo {
            pixels_base64: BASE64.encode(&crop.pixels),
            width: crop.width,
            height: crop.height,
            hfr: crop.hfr,
            snr: crop.snr,
        })
        .collect();

    HfrMeasurementWithCrops {
        hfr,
        star_count,
        unmeasurable_star_count,
        star_crops,
    }
}

#[cfg(test)]
mod final_approach_tests {
    use super::{final_run_up_position, RunUpSource};

    /// The owner's rig on 2026-09-14: sweep 6250..6850 (start 6250, 4 steps of
    /// 75), fit 6620, `af_backlash_in` 0, and no calibration stored yet. The
    /// EAF's backlash there measured ~105 steps that night, so the run-up has
    /// to clear that without knowing it. Landing straight down measured
    /// HFR 5.60; running up from below, 2.94.
    #[test]
    fn with_no_figure_at_all_it_falls_back_to_the_sweep_start() {
        let (run_up, source) = final_run_up_position(6620, 6250, 0, None, 75);
        assert!(
            run_up <= 6620 - 105,
            "run-up {} does not clear the 105-step backlash measured on the rig",
            run_up
        );
        assert_eq!(run_up, 6250, "should fall back to the sweep start");
        assert_eq!(source, RunUpSource::SweepStart);
    }

    /// Once that 105 steps has been measured, the run-up is sized from it and
    /// clears it by a margin instead of running all the way down the sweep —
    /// a shorter move to the same guaranteed side of the dead band.
    #[test]
    fn a_measured_backlash_sizes_the_run_up_and_clears_it_by_a_margin() {
        let (run_up, source) = final_run_up_position(6620, 6250, 0, Some(105), 75);

        assert_eq!(source, RunUpSource::Measured);
        assert!(
            run_up < 6620 - 105,
            "run-up {} must EXCEED the backlash, not equal it",
            run_up
        );
        // 105 + max(105/4, 75, 10) = 105 + 75.
        assert_eq!(run_up, 6440);
        assert!(
            run_up > 6250,
            "a known clearance should be a shorter move than the sweep start"
        );
    }

    /// The precedence rule: what the operator typed wins, and the measured
    /// figure is not allowed anywhere near it.
    #[test]
    fn an_operator_entered_figure_outranks_the_measured_one() {
        let (run_up, source) = final_run_up_position(6620, 6250, 200, Some(105), 75);

        assert_eq!(source, RunUpSource::OperatorEntered);
        // 200 + max(50, 75, 10) = 275, from their 200 — not from our 105.
        assert_eq!(run_up, 6345);
    }

    /// An operator-supplied backlash larger than the sweep still wins: the
    /// run-up goes below the sweep start rather than being clamped up to it.
    #[test]
    fn a_large_operator_backlash_overrides_the_sweep_start() {
        // 500 + max(125, 75, 10) = 625.
        let (run_up, source) = final_run_up_position(6620, 6250, 500, None, 75);
        assert_eq!(run_up, 5995);
        assert_eq!(source, RunUpSource::OperatorEntered);
    }

    /// "No measurable backlash" is a real calibration result, and it is not a
    /// figure to size a run-up from. The run-up falls back to the sweep start,
    /// which still lands from below — the direction correctness depends on.
    #[test]
    fn a_measured_zero_falls_back_rather_than_sizing_a_zero_run_up() {
        let (run_up, source) = final_run_up_position(6620, 6250, 0, Some(0), 75);
        assert_eq!(run_up, 6250);
        assert_eq!(source, RunUpSource::SweepStart);
        assert!(run_up < 6620, "the last move must still travel upward");
    }

    /// Always strictly below best focus, so the final leg always travels
    /// upward — the direction the sweep measured in.
    #[test]
    fn always_lands_moving_upward() {
        for (best, start, operator, measured, step) in [
            (6620, 6250, 0, None, 75),
            (6620, 6250, 0, Some(105), 75),
            (100, 100, 0, None, 1),
            (5000, 4000, 0, None, 0),
            (5000, 4000, 0, Some(1), 0),
            (0, 0, 0, None, 0),
        ] {
            let (run_up, _) = final_run_up_position(best, start, operator, measured, step);
            assert!(
                run_up < best || best == i32::MIN,
                "run_up {} must be below best {} so the last move goes up",
                run_up,
                best
            );
        }
    }

    /// A focuser with tiny steps still gets a real margin over its backlash
    /// rather than a one-step hair.
    #[test]
    fn a_tiny_step_size_still_yields_a_usable_margin() {
        let (run_up, _) = final_run_up_position(1000, 900, 0, Some(8), 1);
        // 8 + max(2, 1, 10) = 18.
        assert_eq!(run_up, 982);
    }

    /// A backlash-sized run-up near the bottom of travel must not command a
    /// position below zero that the sweep never visited: the driver refuses
    /// it, and a good sweep then ends as a failure.
    #[test]
    fn a_run_up_never_goes_below_travel_the_sweep_did_not_cover() {
        let (run_up, _) = final_run_up_position(60, 25, 0, Some(105), 75);
        assert!(
            run_up >= 0,
            "run-up to {} is below the focuser's travel",
            run_up
        );
        assert!(run_up < 60, "the last move must still travel upward");
    }

    /// A best focus at the very bottom of the sweep still gets a run-up; the
    /// sweep start alone would be a no-op move.
    #[test]
    fn best_at_the_sweep_floor_still_runs_up() {
        let (run_up, _) = final_run_up_position(6250, 6250, 0, None, 75);
        assert_eq!(run_up, 6175);
    }
}
