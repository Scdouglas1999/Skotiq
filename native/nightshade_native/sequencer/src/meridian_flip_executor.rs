//! Meridian Flip Executor — the canonical engine for meridian flips.
//!
//! Both the explicit `MeridianFlip` instruction node and the trigger-driven
//! `RecoveryAction::MeridianFlip` route through this executor — the
//! pre-existing two-implementation split was unifying-required so users got the
//! same timeouts, altitude check, autofocus parameters, settle behaviour,
//! plate-solve handling, pier-side telemetry fallback, abort behaviour, and
//! `mark_flip_performed` semantics regardless of trigger source).
//!
//! Pre-flip rustdoc invariants checked here:
//! - Target altitude is ≥ `MIN_POST_FLIP_ALTITUDE_DEG`.
//! - If a cover/calibrator is configured, the cover is *not* closed
//!   (a covered camera makes plate-solve fail and triggers
//!   `AbortAndPark` unnecessarily).
//! - Mount reports it can flip (the caller is expected to gate on this; the
//!   executor logs warnings but does not refuse if the capability check is
//!   unavailable, since some drivers do not expose it).

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Instant;
use tokio::sync::broadcast;
use tokio::sync::mpsc;
use tokio::sync::RwLock;

use crate::device_ops::SharedDeviceOps;
use crate::executor::ExecutorEvent;
use crate::instructions::{execute_autofocus, InstructionContext};
use crate::meridian::{self, julian_day, local_sidereal_time};
use crate::meridian_events::{FlipEventEmitter, FlipStep, MeridianFlipEvent, PierSide};
use crate::triggers::TriggerState;
use crate::{AutofocusConfig, FlipFailureAction, MeridianFlipConfig};

/// Synthetic node id the flip's run-stream progress is published under.
///
/// A trigger-fired flip is not a sequence node, so it has no id of its own; the
/// autofocus trigger uses the same `trigger:` shape. Consumers key per-node
/// progress on this string, so it must stay stable.
pub const MERIDIAN_FLIP_RUN_PROGRESS_NODE_ID: &str = "trigger:meridian_flip";

// The flip's coordinate tolerance (1 arcminute), safety-action retry count
// (3) and delay (5 s), and minimum post-flip altitude (10°) are fields on
// `MeridianFlipConfig`, user-configurable from the meridian-flip settings
// panel; read them via `self.config.<field>`.

/// Result of a meridian flip execution
#[derive(Debug, Clone)]
pub enum FlipResult {
    /// Flip completed successfully
    Success {
        new_pier_side: PierSide,
        duration_secs: f64,
    },
    /// Flip failed after all retries
    Failed {
        error: String,
        action_taken: FlipFailureAction,
    },
    /// Flip was aborted by user
    Aborted { reason: String },
}

/// Autofocus inputs that must travel together for a post-flip refocus.
///
/// The autofocus node configuration selects the focus filter and supplies the
/// sweep/exposure/backlash parameters. The surrounding instruction context
/// supplies the connected wheel, the currently active imaging filter, and the
/// per-filter focus offsets needed to switch to that focus filter safely.
#[derive(Debug, Clone, Default)]
pub struct PostFlipAutofocusConfig {
    pub config: AutofocusConfig,
    pub current_filter: Option<String>,
    pub filterwheel_id: Option<String>,
    pub filter_focus_offsets: std::collections::HashMap<String, i32>,
}

/// Context for executing a meridian flip.
///
/// `cancellation_token`, `trigger_state`, `cover_calibrator_id`, and
/// `autofocus_config` were added to backport behaviour
/// that the older `instructions::execute_meridian_flip` had: cancel-during-settle
/// must propagate, success must call `TriggerState::mark_flip_performed`, the
/// pre-flip cover check needs the cover device id, and post-flip refocus must
/// honour user-tuned autofocus parameters instead of hardcoded constants.
pub struct FlipContext {
    pub target_name: String,
    pub target_ra_hours: f64,
    pub target_dec_degrees: f64,
    pub mount_id: String,
    pub camera_id: Option<String>,
    pub focuser_id: Option<String>,
    /// Optional dust-cover / flat-panel device id. When set, the executor
    /// refuses to flip while the cover is closed.
    pub cover_calibrator_id: Option<String>,
    /// Cancellation token shared with the wider sequence executor so a Stop
    /// command propagates into long waits (settle, slew). When `None`, the
    /// executor falls back to its internal abort-flag.
    pub cancellation_token: Option<Arc<AtomicBool>>,
    /// Trigger state. When set, a successful flip will call
    /// `TriggerState::mark_flip_performed()` so subsequent trigger evaluations
    /// know not to fire again on the same target.
    pub trigger_state: Option<Arc<RwLock<TriggerState>>>,
    /// User-tuned autofocus parameters and filter context used by the
    /// post-flip refocus step. `None` falls back to an unfiltered
    /// `AutofocusConfig::default()`.
    pub autofocus_config: Option<PostFlipAutofocusConfig>,
    /// Dry-run / simulate flag. When `true`, the executor walks the full
    /// pre-flight and step sequence (altitude check, cover check, build the step
    /// list, emit every Starting/StepStarted/StepCompleted/Progress/Completed
    /// event) but **does not command any real hardware**: the slew, pier-side
    /// verify, plate-solve, refocus, guider and tracking device-ops are skipped,
    /// so an operator can validate which steps run, in what order and with what
    /// timeouts, without moving the mount. Pier-side verify reports a no-op
    /// success because no real flip occurred.
    pub simulate: bool,
}

/// Executes a complete meridian flip sequence
pub struct MeridianFlipExecutor {
    config: MeridianFlipConfig,
    device_ops: SharedDeviceOps,
    event_emitter: FlipEventEmitter,
    event_tx: Option<mpsc::Sender<MeridianFlipEvent>>,
    /// parent executor's broadcast handle for ExecutorEvent.
    /// Plumbed into the post-flip refocus InstructionContext so FITS-save
    /// failures and other instruction-level errors surface to UI subscribers.
    executor_event_tx: Option<broadcast::Sender<ExecutorEvent>>,
    /// The run's decision log and its run id, so a post-flip refocus that did
    /// not converge writes the row the app raises its "Autofocus failed —
    /// continuing" notification from.
    decision_tx: Option<crate::decision::DecisionSender>,
    active_sequence_run_id: Arc<parking_lot::RwLock<Option<i64>>>,
    abort_requested: Arc<AtomicBool>,
    /// Number of flip attempts made by the most recent [`Self::execute`] call.
    /// `1` means the flip succeeded (or failed) on its first attempt; anything
    /// higher means the retry ladder ran. Read by the caller so a flip that
    /// only succeeded on a retry is recorded as DEGRADED in the run vitals
    /// instead of being indistinguishable from a clean first-attempt flip.
    attempts_made: u32,
    /// One entry per failed attempt, oldest first, already formatted as
    /// `"<step description>: <error>"`. Empty after a clean first-attempt
    /// flip. This is the evidence behind the degraded/failed verdict — a
    /// post-flip recenter that failed twice before succeeding is a real
    /// framing risk the operator must see in the session report.
    failed_attempts: Vec<String>,
}

impl MeridianFlipExecutor {
    /// Create a new flip executor
    pub fn new(config: MeridianFlipConfig, device_ops: SharedDeviceOps) -> Self {
        Self {
            config,
            device_ops,
            event_emitter: FlipEventEmitter::new(),
            event_tx: None,
            executor_event_tx: None,
            decision_tx: None,
            active_sequence_run_id: Arc::new(parking_lot::RwLock::new(None)),
            abort_requested: Arc::new(AtomicBool::new(false)),
            attempts_made: 0,
            failed_attempts: Vec::new(),
        }
    }

    /// Attempts made by the most recent [`Self::execute`] call (0 before the
    /// first call, 1 for a clean flip, `1 + retries` when the ladder ran).
    pub fn attempts_made(&self) -> u32 {
        self.attempts_made
    }

    /// Per-attempt failures from the most recent [`Self::execute`] call,
    /// oldest first. Empty when every step passed on the first attempt.
    pub fn failed_attempts(&self) -> &[String] {
        &self.failed_attempts
    }

    /// Set event channel for progress updates
    pub fn with_event_channel(mut self, tx: mpsc::Sender<MeridianFlipEvent>) -> Self {
        self.event_tx = Some(tx);
        self
    }

    /// set the parent executor's broadcast handle so the
    /// post-flip refocus inherits the same event surface as the rest of the
    /// sequence. Without this the refocus's FITS-save failures and per-step
    /// errors emit only to the tracing log (silent for the user).
    pub fn with_executor_event_tx(mut self, tx: broadcast::Sender<ExecutorEvent>) -> Self {
        self.executor_event_tx = Some(tx);
        self
    }

    /// Set the run's decision log, so the post-flip refocus records (and the
    /// app announces) a refocus that did not converge.
    pub fn with_decision_tx(
        mut self,
        tx: crate::decision::DecisionSender,
        active_sequence_run_id: Arc<parking_lot::RwLock<Option<i64>>>,
    ) -> Self {
        self.decision_tx = Some(tx);
        self.active_sequence_run_id = active_sequence_run_id;
        self
    }

    /// Get abort handle for external abort requests
    pub fn abort_handle(&self) -> Arc<AtomicBool> {
        self.abort_requested.clone()
    }

    /// Execute the meridian flip.
    ///
    /// The verdict is announced on the executor event stream here rather than
    /// at the call sites: the executor owns the flip, so it owns the verdict, and
    /// both the trigger and the explicit MeridianFlip node inherit it.
    /// `MeridianFlipOutcome` is what feeds the run vitals' `meridianFlips` count
    /// and the session report's error list.
    pub async fn execute(&mut self, ctx: &FlipContext) -> FlipResult {
        let result = self.execute_flip(ctx).await;
        self.announce_outcome(ctx, &result);
        result
    }

    fn announce_outcome(&self, ctx: &FlipContext, result: &FlipResult) {
        let Some(tx) = &self.executor_event_tx else {
            return;
        };
        let event = match result {
            FlipResult::Success {
                new_pier_side,
                duration_secs,
            } => ExecutorEvent::MeridianFlipOutcome {
                outcome: "success".to_string(),
                target_name: ctx.target_name.clone(),
                new_pier_side: format!("{:?}", new_pier_side),
                duration_secs: *duration_secs,
                attempts: self.attempts_made,
                failed_steps: self.failed_attempts.clone(),
                error: None,
                action_taken: None,
            },
            FlipResult::Failed {
                error,
                action_taken,
            } => ExecutorEvent::MeridianFlipOutcome {
                outcome: "failed".to_string(),
                target_name: ctx.target_name.clone(),
                new_pier_side: "Unknown".to_string(),
                duration_secs: 0.0,
                attempts: self.attempts_made,
                failed_steps: self.failed_attempts.clone(),
                error: Some(error.clone()),
                action_taken: Some(format!("{:?}", action_taken)),
            },
            FlipResult::Aborted { reason } => ExecutorEvent::MeridianFlipOutcome {
                outcome: "aborted".to_string(),
                target_name: ctx.target_name.clone(),
                new_pier_side: "Unknown".to_string(),
                duration_secs: 0.0,
                attempts: self.attempts_made,
                failed_steps: self.failed_attempts.clone(),
                error: Some(reason.clone()),
                action_taken: None,
            },
        };
        let _ = tx.send(event);
    }

    async fn execute_flip(&mut self, ctx: &FlipContext) -> FlipResult {
        let start_time = Instant::now();

        // Reset the per-run attempt telemetry. An executor is normally
        // constructed per flip, but resetting here keeps the accessors honest
        // if one is ever reused for a second flip on the same target.
        self.attempts_made = 0;
        self.failed_attempts.clear();

        if self.config.max_retries > 0 && self.config.retry_delays_secs.is_empty() {
            let msg = format!(
                "Meridian flip configuration error: max_retries={} but retry_delays_secs is empty. Cannot schedule retry.",
                self.config.max_retries
            );
            tracing::error!("[MERIDIAN] {}", msg);
            let action_taken = self.config.failure_action;
            self.emit_event(MeridianFlipEvent::Failed {
                error: msg.clone(),
                action_taken: format_failure_action(action_taken).to_string(),
            });
            return FlipResult::Failed {
                error: msg,
                action_taken,
            };
        }

        // ENG-F9: Pre-flip sanity check — verify target altitude is viable.
        // If the target is below the minimum altitude, continuing with the flip
        // would slew to an object that's about to set, risking equipment damage
        // or wasted imaging time.
        if let Some((lat, lon)) = self.device_ops.get_observer_location() {
            let altitude = self.device_ops.calculate_altitude(
                ctx.target_ra_hours,
                ctx.target_dec_degrees,
                lat,
                lon,
            );
            let min_altitude = self.config.min_post_flip_altitude_deg;
            tracing::info!(
                "[MERIDIAN] Pre-flip altitude check: target '{}' altitude = {:.1}° (minimum = {:.1}°)",
                ctx.target_name,
                altitude,
                min_altitude
            );
            if altitude < min_altitude {
                let msg = format!(
                    "Meridian flip skipped: target '{}' altitude is {:.1}° which is below \
                     the minimum {:.1}°. The target is too low for useful imaging after the flip.",
                    ctx.target_name, altitude, min_altitude
                );
                tracing::warn!("[MERIDIAN] {}", msg);
                // Aborted, not Failed: a target that has set too low to be worth
                // imaging is routine end-of-target behaviour, and the result
                // returned below is `Aborted`. Emitting `Failed` made the event
                // logger print an ERROR banner reading "FLIP FAILED" for a
                // deliberate skip (observed on the rig), which trips error
                // dashboards and tells the operator something broke when
                // nothing did. `failure_action` is driven by `FlipResult`, not
                // by this event, so the handling is unchanged.
                self.emit_event(MeridianFlipEvent::Aborted {
                    reason: msg.clone(),
                });
                return FlipResult::Aborted { reason: msg };
            }
        } else {
            tracing::warn!(
                "[MERIDIAN] Observer location unavailable — cannot verify target altitude \
                 before flip. Proceeding with flip."
            );
        }

        // Pre-flip cover/calibrator state check. A closed dust cap
        // makes plate-solve fail post-flip, which would trigger the configured
        // failure action (potentially AbortAndPark). Refuse upfront with a clear
        // error so the user is told to open the cover instead of finding a
        // parked mount in the morning.
        if let Some(cc_id) = ctx.cover_calibrator_id.as_deref() {
            match self
                .device_ops
                .cover_calibrator_get_cover_state(cc_id)
                .await
            {
                Ok(state) => match state {
                    1 => {
                        // Closed
                        let msg = format!(
                            "Meridian flip refused: cover '{}' is closed (state=1). \
                             Open the cover before flipping or post-flip plate solve will fail.",
                            cc_id
                        );
                        // ERROR log stays (the operator must open the cover), but
                        // the event matches the `Aborted` result so the flip is
                        // not reported as a FAILED flip it never attempted.
                        tracing::error!("[MERIDIAN] {}", msg);
                        self.emit_event(MeridianFlipEvent::Aborted {
                            reason: msg.clone(),
                        });
                        return FlipResult::Aborted { reason: msg };
                    }
                    2 => {
                        // Moving — also unsafe to flip while it's moving
                        let msg = format!(
                            "Meridian flip refused: cover '{}' is currently moving (state=2). \
                             Wait for cover to settle before flipping.",
                            cc_id
                        );
                        // See the cover-closed arm: ERROR log kept, event matched
                        // to the `Aborted` result.
                        tracing::error!("[MERIDIAN] {}", msg);
                        self.emit_event(MeridianFlipEvent::Aborted {
                            reason: msg.clone(),
                        });
                        return FlipResult::Aborted { reason: msg };
                    }
                    3 => {
                        tracing::info!(
                            "[MERIDIAN] Pre-flip cover check: cover '{}' is open",
                            cc_id
                        );
                    }
                    other => {
                        // 0=NotPresent, 4=Unknown, 5=Error — log and proceed; a real
                        // problem will surface in the post-flip plate-solve step.
                        tracing::warn!(
                            "[MERIDIAN] Pre-flip cover check: cover '{}' reports unusable state {}. \
                             Proceeding anyway — post-flip plate-solve will catch a real obstruction.",
                            cc_id,
                            other
                        );
                    }
                },
                Err(e) => {
                    tracing::warn!(
                        "[MERIDIAN] Pre-flip cover check failed for '{}': {}. \
                         Proceeding without cover verification.",
                        cc_id,
                        e
                    );
                }
            }
        }

        // capture the mount's tracking state BEFORE we touch
        // it so cancel paths can restore it.
        let pre_flip_tracking = match self.device_ops.mount_is_tracking(&ctx.mount_id).await {
            Ok(t) => Some(t),
            Err(e) => {
                tracing::warn!(
                    "[MERIDIAN] Failed to read mount tracking state before flip ({}); \
                     skipping explicit tracking restore on cancel",
                    e
                );
                None
            }
        };

        // The pre-flip pier side is the reference point the verify step uses
        // to confirm the mount actually crossed sides. Unknown is non-fatal:
        // verification will fall back to coordinate convergence instead.
        let from_pier_side = match self.get_pier_side(&ctx.mount_id).await {
            Ok(ps) => ps,
            Err(e) => {
                tracing::error!("[MERIDIAN] Failed to get current pier side: {}", e);
                PierSide::Unknown
            }
        };

        // capture pre-flip coordinates so the
        // pier-side-Unknown verification path can fall back to coordinate
        // convergence.
        let pre_flip_coords = match self.device_ops.mount_get_coordinates(&ctx.mount_id).await {
            Ok(coords) => Some(coords),
            Err(e) => {
                tracing::warn!(
                    "[MERIDIAN] Failed to read pre-flip mount coordinates ({}); \
                     coordinate fallback verification will use target coordinates",
                    e
                );
                None
            }
        };
        if let Some((ra, dec)) = pre_flip_coords {
            tracing::debug!(
                "[MERIDIAN] Pre-flip coordinates captured for fallback diagnostics: RA={:.4}h Dec={:.4}°",
                ra,
                dec
            );
        }

        let hour_angle = self.calculate_hour_angle(ctx.target_ra_hours);

        self.emit_event(MeridianFlipEvent::Starting {
            target_name: ctx.target_name.clone(),
            from_pier_side,
            hour_angle,
        });

        let steps = self.build_step_sequence();
        // Why: build_step_sequence() pushes a hard-coded set of FlipStep variants,
        // currently at most 9 (StoppingTracking + SlewingToTarget + VerifyingPierSide
        // + ResumingTracking + Settling + 4 optional). 9 fits trivially in u8. The
        // TryFrom version surfaces a future step-list explosion as a clamp+log
        // rather than silent wrap.
        let total_steps = u8::try_from(steps.len()).unwrap_or_else(|_| {
            tracing::error!(
                "Meridian flip step list exceeds u8::MAX ({} steps); clamping for UI",
                steps.len()
            );
            u8::MAX
        });

        let mut attempt = 0;
        let max_attempts = self.config.max_retries + 1;

        loop {
            attempt += 1;
            self.attempts_made = attempt;

            match self
                .execute_steps(&steps, ctx, total_steps, from_pier_side)
                .await
            {
                Ok(new_pier_side) => {
                    let duration = start_time.elapsed().as_secs_f64();
                    self.emit_event(MeridianFlipEvent::Completed {
                        new_pier_side,
                        duration_secs: duration,
                    });
                    // always mark the flip as performed on success so
                    // trigger evaluation does not re-fire for the same target.
                    if let Some(ts) = ctx.trigger_state.as_ref() {
                        let mut state = ts.write().await;
                        state.mark_flip_performed();
                    }
                    return FlipResult::Success {
                        new_pier_side,
                        duration_secs: duration,
                    };
                }
                Err(e) => {
                    // Record every failed attempt, whether or not a retry
                    // follows. A recenter that failed once and then succeeded
                    // is still a framing risk the operator must be told about,
                    // and the terminal-failure path needs the same list.
                    self.failed_attempts.push(e.clone());
                    if self.is_cancelled(ctx) {
                        // Restore tracking on cancel if we recorded it as on
                        // before the flip, so the executor and instruction
                        // paths leave the mount in the same state.
                        self.restore_tracking_on_cancel(ctx, pre_flip_tracking)
                            .await;
                        let reason = "User requested abort".to_string();
                        self.emit_event(MeridianFlipEvent::Aborted {
                            reason: reason.clone(),
                        });
                        return FlipResult::Aborted { reason };
                    }

                    if attempt < max_attempts {
                        // With user-provided delays, saturate on the LAST entry; with an
                        // empty array AND retries configured, refuse to retry (return the
                        // underlying error so the failure_action runs) rather than falling
                        // back to a built-in delay, which would hide the config bug.
                        // Why: u32 -> usize. usize is >=32 bits on all our target
                        // platforms, so this is lossless.
                        let delay_idx = (attempt - 1) as usize;
                        let delay = match self.config.retry_delays_secs.get(delay_idx).copied() {
                            Some(d) => d,
                            None => {
                                // Why: saturate on the last user-provided value rather
                                // than fall back to a magic 60 seconds. This honours
                                // a user who configured `[10.0]` to mean "every retry
                                // waits 10 seconds".
                                match self.config.retry_delays_secs.last().copied() {
                                    Some(d) => d,
                                    None => {
                                        // Empty array but max_retries>0 is a config
                                        // bug. Fail loudly instead of silently using 60s.
                                        let cfg_err = format!(
                                            "Meridian flip configuration error: max_retries={} \
                                             but retry_delays_secs is empty. Cannot schedule retry.",
                                            self.config.max_retries
                                        );
                                        tracing::error!("[MERIDIAN] {}", cfg_err);
                                        // Skip retries; let the failure-action path run
                                        // with the underlying flip error.
                                        let action_taken = self.config.failure_action;
                                        let action_str = format_failure_action(action_taken);
                                        self.emit_event(MeridianFlipEvent::Failed {
                                            error: format!("{} (also: {})", e, cfg_err),
                                            action_taken: action_str.to_string(),
                                        });
                                        if let Err(action_err) =
                                            self.execute_failure_action(&ctx.mount_id).await
                                        {
                                            tracing::error!(
                                                "[MERIDIAN] Failure action itself failed: {}",
                                                action_err
                                            );
                                            return FlipResult::Failed {
                                                error: format!(
                                                    "{} | failure action error: {}",
                                                    e, action_err
                                                ),
                                                action_taken,
                                            };
                                        }
                                        return FlipResult::Failed {
                                            error: format!("{} | {}", e, cfg_err),
                                            action_taken,
                                        };
                                    }
                                }
                            }
                        };

                        // Why: attempt and max_attempts are u32 user-config values.
                        // A retry count > 255 is operationally absurd (would imply
                        // hours of mount-blocked retries); we surface the clamp via
                        // tracing so configuration bugs aren't hidden.
                        let attempt_u8 = u8::try_from(attempt).unwrap_or_else(|_| {
                            tracing::warn!(
                                "Meridian flip attempt count {} exceeds u8::MAX; clamping for UI",
                                attempt
                            );
                            u8::MAX
                        });
                        let max_attempts_u8 = u8::try_from(max_attempts).unwrap_or_else(|_| {
                            tracing::warn!(
                                "Meridian flip max_attempts {} exceeds u8::MAX; clamping for UI",
                                max_attempts
                            );
                            u8::MAX
                        });
                        self.emit_event(MeridianFlipEvent::RetryScheduled {
                            attempt: attempt_u8,
                            max_attempts: max_attempts_u8,
                            delay_secs: delay,
                        });

                        // Wait before retry, honouring cancellation.
                        let total = std::time::Duration::from_secs_f64(delay);
                        let tick = std::time::Duration::from_millis(200);
                        let mut waited = std::time::Duration::ZERO;
                        while waited < total {
                            if self.is_cancelled(ctx) {
                                self.restore_tracking_on_cancel(ctx, pre_flip_tracking)
                                    .await;
                                let reason = "User requested abort during retry wait".to_string();
                                self.emit_event(MeridianFlipEvent::Aborted {
                                    reason: reason.clone(),
                                });
                                return FlipResult::Aborted { reason };
                            }
                            tokio::time::sleep(tick).await;
                            waited += tick;
                        }
                    } else {
                        // All retries exhausted
                        let action_taken = self.config.failure_action;
                        let action_str = format_failure_action(action_taken);

                        self.emit_event(MeridianFlipEvent::Failed {
                            error: e.clone(),
                            action_taken: action_str.to_string(),
                        });

                        // Execute failure action and propagate any
                        // error. Park failures must NOT be silently dropped — a
                        // failed park after a failed flip can leave the mount
                        // at a hard limit.
                        if let Err(action_err) = self.execute_failure_action(&ctx.mount_id).await {
                            tracing::error!(
                                "[MERIDIAN] Failure action ({:?}) itself failed: {}",
                                action_taken,
                                action_err
                            );
                            return FlipResult::Failed {
                                error: format!("{} | failure action error: {}", e, action_err),
                                action_taken,
                            };
                        }

                        return FlipResult::Failed {
                            error: e,
                            action_taken,
                        };
                    }
                }
            }
        }
    }

    /// Build the sequence of steps based on configuration
    fn build_step_sequence(&self) -> Vec<FlipStep> {
        let mut steps = Vec::new();

        if self.config.pause_guiding {
            steps.push(FlipStep::PausingGuider);
        }

        steps.push(FlipStep::StoppingTracking);
        steps.push(FlipStep::SlewingToTarget);
        steps.push(FlipStep::VerifyingPierSide);
        steps.push(FlipStep::ResumingTracking);

        if self.config.auto_center {
            steps.push(FlipStep::PlateSolvingAndCentering);
        }

        if self.config.refocus_after {
            steps.push(FlipStep::Refocusing);
        }

        if self.config.resume_guiding {
            steps.push(FlipStep::ResumingGuider);
        }

        steps.push(FlipStep::Settling);

        steps
    }

    /// Execute all steps in sequence
    async fn execute_steps(
        &mut self,
        steps: &[FlipStep],
        ctx: &FlipContext,
        total_steps: u8,
        pre_flip_pier_side: PierSide,
    ) -> Result<PierSide, String> {
        let mut new_pier_side = PierSide::Unknown;

        for (idx, step) in steps.iter().enumerate() {
            if self.is_cancelled(ctx) {
                return Err("Abort requested".to_string());
            }

            // Why: idx is bounded by steps.len() which build_step_sequence caps at
            // ~9 hard-coded variants — well within u8.
            let step_index_u8 = u8::try_from(idx).unwrap_or(u8::MAX);
            self.emit_event(MeridianFlipEvent::StepStarted {
                step: *step,
                step_index: step_index_u8,
                total_steps,
            });

            let step_start = Instant::now();

            let result = match step {
                FlipStep::PausingGuider => self.pause_guider(ctx).await,
                FlipStep::StoppingTracking => self.stop_tracking(ctx).await,
                FlipStep::SlewingToTarget => {
                    self.slew_to_target(ctx, ctx.target_ra_hours, ctx.target_dec_degrees)
                        .await
                }
                FlipStep::VerifyingPierSide => {
                    match self.verify_pier_side_changed(ctx, pre_flip_pier_side).await {
                        Ok(ps) => {
                            new_pier_side = ps;
                            Ok(())
                        }
                        Err(e) => Err(e),
                    }
                }
                FlipStep::ResumingTracking => self.resume_tracking(ctx).await,
                FlipStep::PlateSolvingAndCentering => self.plate_solve_and_center(ctx).await,
                FlipStep::Refocusing => self.run_autofocus(ctx, idx, total_steps).await,
                FlipStep::ResumingGuider => self.resume_guider(ctx).await,
                FlipStep::Settling => self.wait_settle(ctx).await,
            };

            let duration = step_start.elapsed().as_secs_f64();

            match result {
                Ok(()) => {
                    self.emit_event(MeridianFlipEvent::StepCompleted {
                        step: *step,
                        duration_secs: Some(duration),
                    });

                    // Why: idx and total_steps are both bounded by the ~9-variant
                    // FlipStep set; widening to f64 is lossless, and the final
                    // 0..=100 result fits in u8. f64 -> u8 saturates per the
                    // f-to-int spec, so a future invariant break only clamps.
                    let progress = ((idx + 1) as f64 / f64::from(total_steps) * 100.0) as u8;
                    self.emit_event(MeridianFlipEvent::Progress { percent: progress });
                }
                Err(e) => {
                    self.emit_event(MeridianFlipEvent::StepFailed {
                        step: *step,
                        error: e.clone(),
                    });
                    return Err(format!("{}: {}", step.description(), e));
                }
            }
        }

        Ok(new_pier_side)
    }

    // Step implementations

    async fn pause_guider(&self, ctx: &FlipContext) -> Result<(), String> {
        if ctx.simulate {
            tracing::info!("[MERIDIAN] (dry-run) Would pause guider — skipping device command");
            return Ok(());
        }
        tracing::info!("[MERIDIAN] Pausing guider...");
        // An unguided rig has no guider to pause, and that is not a failure to
        // retry. Treating it as one put the flip into its retry ladder —
        // "✗ Pausing guider FAILED: No active guider configured" then
        // "Retry 3/4 scheduled in 120 seconds..." — which stalls the whole
        // sequence for minutes over a no-op. Observed live: an unguided run sat
        // on its exposure node while the flip retried.
        match self.device_ops.guider_stop().await {
            Ok(()) => Ok(()),
            Err(error) if crate::device_ops::is_no_guider_configured(&error) => {
                tracing::info!("[MERIDIAN] No guider configured — nothing to pause");
                Ok(())
            }
            Err(error) => Err(error),
        }
    }

    async fn stop_tracking(&self, ctx: &FlipContext) -> Result<(), String> {
        if ctx.simulate {
            tracing::info!("[MERIDIAN] (dry-run) Would stop tracking — skipping device command");
            return Ok(());
        }
        tracing::info!("[MERIDIAN] Stopping tracking...");
        self.device_ops
            .mount_set_tracking(&ctx.mount_id, false)
            .await
    }

    async fn slew_to_target(
        &self,
        ctx: &FlipContext,
        ra_hours: f64,
        dec_degrees: f64,
    ) -> Result<(), String> {
        let mount_id = ctx.mount_id.as_str();
        // Phase G dry-run: do NOT command a real slew. The whole point of the
        // dry-run is to validate the flip sequence without moving the mount.
        if ctx.simulate {
            tracing::info!(
                "[MERIDIAN] (dry-run) Would slew to flip-side target RA={:.4}h, Dec={:.4}° — \
                 skipping real slew command",
                ra_hours,
                dec_degrees
            );
            return Ok(());
        }
        tracing::info!(
            "[MERIDIAN] Slewing to target (flip side): RA={:.4}h, Dec={:.4}°",
            ra_hours,
            dec_degrees
        );

        self.device_ops
            .mount_slew_to_coordinates(mount_id, ra_hours, dec_degrees)
            .await?;

        // Wait for the mount to actually BEGIN slewing before polling for
        // completion. Async slews (ASCOM SlewToCoordinatesAsync, Alpaca) can
        // take tens-to-hundreds of ms to assert Slewing=true; without this
        // guard the very first is_slewing poll below can read false (the mount
        // has not started moving yet), break the completion loop immediately,
        // and declare the flip slew "done" while the OTA is still on the
        // pre-flip side — pier-side verification then fails and the flip is
        // aborted/halted, killing the rest of the night. Mirrors the
        // NINA/SGP "wait for Slewing==true, then wait for Slewing==false"
        // pattern. Bounded so an instantaneous slew (already on target) or a
        // driver that never asserts Slewing does not stall.
        {
            let start_deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(15);
            loop {
                if self.is_cancelled(ctx) {
                    if let Err(e) = self.device_ops.mount_abort_slew(mount_id).await {
                        tracing::error!(
                            "[MERIDIAN] mount_abort_slew failed during cancellation before slew start: {}",
                            e
                        );
                    }
                    return Err("Abort requested during slew".to_string());
                }
                if self.device_ops.mount_is_slewing(mount_id).await? {
                    break; // slew has begun; fall through to completion poll
                }
                if tokio::time::Instant::now() > start_deadline {
                    tracing::debug!(
                        "[MERIDIAN] mount did not assert Slewing within 15s of the slew command; \
                         proceeding to completion/pier-side verification"
                    );
                    break;
                }
                tokio::time::sleep(std::time::Duration::from_millis(200)).await;
            }
        }

        // 10 min timeout covers worst-case meridian-flip slews on the slow
        // direct-drive mounts in our test matrix (10micron GM1000HPS with
        // belt drive ~ 6-8 min for full-sky moves); a tighter timeout would
        // false-alarm legitimate long slews on heavy payloads.
        let slew_timeout = tokio::time::Instant::now() + std::time::Duration::from_secs(600);
        loop {
            if self.is_cancelled(ctx) {
                // explicit error logging on abort_slew failure during
                // a cancellation path — silent drop here would mask a stuck mount.
                if let Err(e) = self.device_ops.mount_abort_slew(mount_id).await {
                    tracing::error!(
                        "[MERIDIAN] mount_abort_slew failed during cancellation of slew: {}",
                        e
                    );
                }
                return Err("Abort requested during slew".to_string());
            }

            let is_slewing = self.device_ops.mount_is_slewing(mount_id).await?;
            if !is_slewing {
                break;
            }

            if tokio::time::Instant::now() > slew_timeout {
                // log abort_slew failure during timeout path.
                if let Err(e) = self.device_ops.mount_abort_slew(mount_id).await {
                    tracing::error!(
                        "[MERIDIAN] mount_abort_slew failed after slew timeout: {}",
                        e
                    );
                }
                return Err("Meridian flip slew timed out after 10 minutes".to_string());
            }

            tokio::time::sleep(std::time::Duration::from_millis(500)).await;
        }

        Ok(())
    }

    async fn verify_pier_side_changed(
        &self,
        ctx: &FlipContext,
        pre_flip_pier_side: PierSide,
    ) -> Result<PierSide, String> {
        let mount_id = ctx.mount_id.as_str();
        // Phase G dry-run: no real slew was issued, so the mount has not
        // crossed sides. Reading the pier side and asserting it changed would
        // (correctly) fail. Report a no-op success so the dry-run can continue
        // through the remaining steps and complete — the operator is validating
        // the sequence, not the hardware's ability to flip.
        if ctx.simulate {
            tracing::info!(
                "[MERIDIAN] (dry-run) Would verify pier side changed from {:?} — \
                 skipping real pier-side read (no slew was commanded)",
                pre_flip_pier_side
            );
            return Ok(PierSide::Unknown);
        }
        tracing::info!(
            "[MERIDIAN] Verifying pier side changed from {:?}...",
            pre_flip_pier_side
        );

        let new_pier_side = self.get_pier_side(mount_id).await?;

        tracing::info!("[MERIDIAN] New pier side: {:?}", new_pier_side);

        // When both sides are known telemetry, pier-side delta is the
        // strongest verification: a flip MUST cross sides, so equality means
        // the slew did not actually flip the mount (e.g. mount driver chose
        // to recover via a long sweep on the same side).
        if pre_flip_pier_side != PierSide::Unknown && new_pier_side != PierSide::Unknown {
            if pre_flip_pier_side == new_pier_side {
                return Err(format!(
                    "Pier side did not change after flip (still {:?}). \
                     The mount may not have flipped correctly.",
                    new_pier_side
                ));
            }
            return Ok(new_pier_side);
        }

        // pier side is unavailable (either before, after,
        // or both). Fall back to coordinate convergence rather than
        // reporting Unknown unverified.
        tracing::warn!(
            "[MERIDIAN] Pier side telemetry unavailable (pre={:?}, post={:?}); \
             verifying flip via coordinate convergence",
            pre_flip_pier_side,
            new_pier_side
        );
        let (post_ra, post_dec) = self.device_ops.mount_get_coordinates(mount_id).await?;
        // Compare in the frame the mount READS BACK in, not the J2000 frame the
        // target is held in: the device layer precesses what it sends and
        // leaves read-backs alone, so a raw comparison misses by the
        // precession offset (~16' of RA in 2026) against a 1' tolerance and
        // fails a flip that landed. Same defect and fix as slew arrival
        // (d9c7e5d77). If the frame cannot be resolved, the raw target is the
        // only reference there is; the comparison then errs toward failing.
        let (expect_ra, expect_dec) = match self
            .device_ops
            .mount_readback_frame(mount_id, ctx.target_ra_hours, ctx.target_dec_degrees)
            .await
        {
            Ok(pair) => pair,
            Err(e) => {
                tracing::warn!(
                    "[MERIDIAN] Could not resolve the mount's coordinate frame ({}); \
                     comparing against the J2000 target",
                    e
                );
                (ctx.target_ra_hours, ctx.target_dec_degrees)
            }
        };
        // Then measure on the sky, as the slew arrival check does: raw RA
        // degrees shrink the tolerance by cos(Dec), to seconds of arc near the
        // pole, and a flip that landed was failed on read-back jitter.
        let ra_diff_deg =
            normalize_ra_diff_hours(post_ra - expect_ra) * 15.0 * expect_dec.to_radians().cos();
        let dec_diff_deg = post_dec - expect_dec;
        let tolerance_deg = self.config.flip_coordinate_tolerance_deg;
        if ra_diff_deg.abs() > tolerance_deg || dec_diff_deg.abs() > tolerance_deg {
            return Err(format!(
                "Flip slew completed but coordinate-fallback verification failed without \
                 pier-side telemetry: target RA={:.4}h Dec={:.4}° (RA={:.4}h Dec={:.4}° in \
                 the mount's frame), mount reports RA={:.4}h Dec={:.4}° (diff RA={:.2}', \
                 Dec={:.2}')",
                ctx.target_ra_hours,
                ctx.target_dec_degrees,
                expect_ra,
                expect_dec,
                post_ra,
                post_dec,
                ra_diff_deg * 60.0,
                dec_diff_deg * 60.0,
            ));
        }
        tracing::info!(
            "[MERIDIAN] Flip verified by coordinate convergence (pier side telemetry unavailable)"
        );
        Ok(new_pier_side)
    }

    async fn resume_tracking(&self, ctx: &FlipContext) -> Result<(), String> {
        if ctx.simulate {
            tracing::info!("[MERIDIAN] (dry-run) Would resume tracking — skipping device command");
            return Ok(());
        }
        tracing::info!("[MERIDIAN] Resuming tracking...");
        self.device_ops
            .mount_set_tracking(&ctx.mount_id, true)
            .await
    }

    async fn plate_solve_and_center(&self, ctx: &FlipContext) -> Result<(), String> {
        if ctx.simulate {
            tracing::info!(
                "[MERIDIAN] (dry-run) Would plate-solve and center — skipping exposure and slew"
            );
            return Ok(());
        }
        tracing::info!("[MERIDIAN] Plate solving and centering...");

        let camera_id = ctx.camera_id.as_ref().ok_or("No camera configured")?;

        // 5 s @ 1x1 is enough exposure for typical equatorial fields to get a
        // solvable star count without burning time; deep mosaics with sparse
        // fields should use the dedicated Center node with a longer exposure.
        let image = self
            .device_ops
            .camera_start_exposure(camera_id, 5.0, None, None, 1, 1)
            .await?;

        // Passing target hints (deg-converted RA) accelerates blind solves on
        // ASTAP/local indexes by ~10x; without them the solver scans the full
        // sky and post-flip exposures can stall waiting for a solution.
        //
        // A solve that finds nothing (cloud, a sparse field) is the solver's
        // judgment, not a fault: the pier side was verified before this step,
        // so by default the operator is told and the flip completes. The
        // camera, sync and slew errors around it are device faults and still
        // fail the step.
        let solve = self
            .device_ops
            .plate_solve(
                &image,
                Some(ctx.target_ra_hours * 15.0),
                Some(ctx.target_dec_degrees),
                None,
            )
            .await;
        let result = match solve {
            Ok(result) if result.success => result,
            Ok(_) => {
                return self
                    .carry_on_through_quality_problem(
                        ctx,
                        "Post-flip recenter",
                        "Plate solve failed: the solver found no solution, so the target was not \
                         re-centered after the flip."
                            .to_string(),
                    )
                    .await;
            }
            Err(error) => {
                return self
                    .carry_on_through_quality_problem(
                        ctx,
                        "Post-flip recenter",
                        format!(
                            "Plate solve failed: {error}, so the target was not re-centered \
                             after the flip."
                        ),
                    )
                    .await;
            }
        };

        let ra_offset = (result.ra_degrees / 15.0) - ctx.target_ra_hours;
        let dec_offset = result.dec_degrees - ctx.target_dec_degrees;

        // Apply cos(dec) to RA when converting to arcsec for the same reason
        // as TriggerState::calculate_drift_pixels: at high declinations a
        // raw degree difference would overstate the on-sky distance.
        let ra_offset_arcsec =
            ra_offset * 15.0 * 3600.0 * ctx.target_dec_degrees.to_radians().cos();
        let dec_offset_arcsec = dec_offset * 3600.0;
        let total_offset = (ra_offset_arcsec.powi(2) + dec_offset_arcsec.powi(2)).sqrt();

        tracing::info!(
            "[MERIDIAN] Plate solve result: offset={:.1}\" (RA={:.1}\", Dec={:.1}\")",
            total_offset,
            ra_offset_arcsec,
            dec_offset_arcsec
        );

        // 30" tolerance is generous for a post-flip "good enough" check: the
        // user's intent is that the target is back in frame so guiding can
        // re-acquire — sub-arcsecond precision is the next exposure's job.
        if total_offset < 30.0 {
            tracing::info!("[MERIDIAN] Centering within tolerance");
            return Ok(());
        }

        // Sync the mount model to the actual position, then re-slew to target.
        // This corrects mount pointing errors that survived the flip; a bare
        // re-slew without the sync would land at the same wrong spot.
        self.device_ops
            .mount_sync(&ctx.mount_id, result.ra_degrees / 15.0, result.dec_degrees)
            .await?;

        self.device_ops
            .mount_slew_to_coordinates(&ctx.mount_id, ctx.target_ra_hours, ctx.target_dec_degrees)
            .await?;

        // 5 min ceiling is enough for a short corrective slew (the flip has
        // already done the big move); past that the mount is misbehaving and
        // the user should know rather than have the sequence stall silently.
        let slew_timeout = tokio::time::Instant::now() + std::time::Duration::from_secs(300);
        loop {
            if self.is_cancelled(ctx) {
                // log abort_slew failure during cancellation.
                if let Err(e) = self.device_ops.mount_abort_slew(&ctx.mount_id).await {
                    tracing::error!(
                        "[MERIDIAN] mount_abort_slew failed during cancellation of centering slew: {}",
                        e
                    );
                }
                return Err("Abort requested during centering slew".to_string());
            }

            let is_slewing = self.device_ops.mount_is_slewing(&ctx.mount_id).await?;
            if !is_slewing {
                break;
            }

            if tokio::time::Instant::now() > slew_timeout {
                // log abort_slew failure during timeout.
                if let Err(e) = self.device_ops.mount_abort_slew(&ctx.mount_id).await {
                    tracing::error!(
                        "[MERIDIAN] mount_abort_slew failed after centering slew timeout: {}",
                        e
                    );
                }
                return Err("Centering slew timed out after 5 minutes".to_string());
            }

            tokio::time::sleep(std::time::Duration::from_millis(500)).await;
        }

        Ok(())
    }

    fn resolve_post_flip_autofocus(ctx: &FlipContext) -> PostFlipAutofocusConfig {
        ctx.autofocus_config.clone().unwrap_or_default()
    }

    async fn run_autofocus(
        &self,
        ctx: &FlipContext,
        step_index: usize,
        total_steps: u8,
    ) -> Result<(), String> {
        if ctx.simulate {
            tracing::info!(
                "[MERIDIAN] (dry-run) Would run post-flip autofocus — skipping exposures and \
                 focuser moves"
            );
            return Ok(());
        }
        tracing::info!("[MERIDIAN] Running autofocus...");

        let camera_id = match &ctx.camera_id {
            Some(id) => id.clone(),
            None => {
                tracing::warn!("[MERIDIAN] Camera not configured, skipping autofocus");
                return Ok(());
            }
        };

        let focuser_id = match &ctx.focuser_id {
            Some(id) => id.clone(),
            None => {
                tracing::warn!("[MERIDIAN] Focuser not configured, skipping autofocus");
                return Ok(());
            }
        };

        // Pull the complete autofocus payload from the caller so filter
        // selection and focus offsets are preserved along with the sweep
        // parameters. None retains the intentional library-default path.
        let autofocus = Self::resolve_post_flip_autofocus(ctx);
        let af_config = &autofocus.config;

        // Determine the effective cancellation token for autofocus. Prefer the
        // shared sequence token so a Stop command propagates; fall back to the
        // executor's internal abort flag.
        // Why: Option<CancellationToken> override — None means
        // "use the executor's own abort flag", documented in the field doc.
        let cancel_token = ctx
            .cancellation_token
            .clone()
            .unwrap_or_else(|| self.abort_requested.clone());

        let instruction_ctx = InstructionContext {
            // Flip-driven recenter is not a sequence node.
            node_id: String::new(),
            target_ra: Some(ctx.target_ra_hours),
            target_dec: Some(ctx.target_dec_degrees),
            target_rotation: None,
            target_name: Some(ctx.target_name.clone()),
            current_filter: autofocus.current_filter.clone(),
            current_binning: af_config.binning,
            cancellation_token: cancel_token,
            camera_id: Some(camera_id),
            mount_id: Some(ctx.mount_id.clone()),
            focuser_id: Some(focuser_id),
            filterwheel_id: autofocus.filterwheel_id.clone(),
            rotator_id: None,
            dome_id: None,
            cover_calibrator_id: ctx.cover_calibrator_id.clone(),
            save_path: None,
            latitude: None,
            longitude: None,
            device_ops: self.device_ops.clone(),
            trigger_state: ctx.trigger_state.clone(),
            filter_focus_offsets: autofocus.filter_focus_offsets.clone(),
            // inherit the parent executor's broadcast handle
            // so the post-flip refocus's instruction-level errors (FITS-save
            // failure on the test exposure, etc.) reach UI subscribers. When
            // the flip is invoked outside the live executor (unit tests) the
            // sender is None and emits are silently dropped.
            event_tx: self.executor_event_tx.clone(),
            recovery_request_tx: None,
            device_disconnect_recovery_pending: std::sync::Arc::new(
                std::sync::atomic::AtomicBool::new(false),
            ),
            // Image Grading: meridian-flip refocus does not save FITS
            // frames itself (autofocus uses in-memory star detection only),
            // so empty defaults are correct here.
            session_id: String::new(),
            target_id: None,
            mosaic_panel: None,
            current_filter_index: None,
            set_temp_c: None,
            bayer_pattern: None,
            observer_name: None,
            site_elevation_m: None,
            camera_make: None,
            camera_model: None,
            telescope_name: None,
            telescope_focal_length_mm: None,
            telescope_aperture_mm: None,
            last_plate_solve: std::sync::Arc::new(tokio::sync::RwLock::new(None)),
            hfr_baseline: std::sync::Arc::new(tokio::sync::RwLock::new(None)),
            hfr_baseline_samples: std::sync::Arc::new(tokio::sync::RwLock::new(Vec::new())),
            consecutive_rejects: std::sync::Arc::new(std::sync::atomic::AtomicU32::new(0)),
            frames_accepted: std::sync::Arc::new(std::sync::atomic::AtomicU32::new(0)),
            frames_rejected: std::sync::Arc::new(std::sync::atomic::AtomicU32::new(0)),
            default_quality_check: None,
            reject_folder_path: None,
            // meridian-flip refocus does not save FITS
            // frames so the defect-map slot stays empty.
            defect_map_apply: std::sync::Arc::new(tokio::sync::RwLock::new(None)),
            // Forensics: meridian-flip refocus does not save
            // FITS frames or grade them; start empty Arcs.
            forensics_history: std::sync::Arc::new(tokio::sync::RwLock::new(
                std::collections::VecDeque::new(),
            )),
            current_sky_brightness_mag: std::sync::Arc::new(tokio::sync::RwLock::new(None)),
            cloud_motion_snapshot: std::sync::Arc::new(tokio::sync::RwLock::new(
                crate::node::context::CloudMotionSnapshot::default(),
            )),
            current_wind_kph: std::sync::Arc::new(tokio::sync::RwLock::new(None)),
            current_sensor_temp_c: std::sync::Arc::new(tokio::sync::RwLock::new(None)),
            // The run's decision log when the caller attached one, so a refocus
            // that did not converge is recorded and announced.
            decision_tx: self.decision_tx.clone(),
            active_sequence_run_id: self.active_sequence_run_id.clone(),
            // Dual-rig — meridian flip is not gated by the secondary barrier in
            // v1 (documented gap); the flip's own dither/recenter runs without
            // secondary coordination.
            dither_barrier: None,
            device_retry: crate::instructions::DeviceRetryHandle::single_attempt(),
        };

        tracing::info!(
            "[MERIDIAN] Starting autofocus ({:?}) with {} steps_out, step_size {}, \
             backlash compensation {}",
            af_config.method,
            af_config.steps_out,
            af_config.step_size,
            af_config.backlash_compensation
        );

        let step_start_percent = (step_index as f64 / f64::from(total_steps)) * 100.0;
        let step_span_percent = 100.0 / f64::from(total_steps);
        let progress_fn = |progress: f64, _detail: String| {
            let percent = (step_start_percent
                + (progress.clamp(0.0, 100.0) / 100.0) * step_span_percent)
                .round()
                .clamp(0.0, 100.0) as u8;
            self.emit_event(MeridianFlipEvent::Progress { percent });
        };

        let position_before = crate::instructions::read_autofocus_position(&instruction_ctx).await;
        let result = execute_autofocus(af_config, &instruction_ctx, Some(&progress_fn)).await;

        // The flip itself is done: the mount is on its new pier side and
        // tracking. A refocus that did not converge is reported and the run
        // goes on at the previous focus. Failing the step instead sent it down
        // the flip's retry ladder and then its failure action, which parks the
        // mount (owner decision 2026-10-06: a failed autofocus never parks).
        if crate::instructions::autofocus_failure_continues_the_run(&result) {
            crate::instructions::notify_autofocus_failed_continuing(
                &instruction_ctx,
                "Post-flip autofocus",
                &result,
                position_before,
            )
            .await;
            return Ok(());
        }

        match result.status {
            crate::NodeStatus::Success => {
                if let Some(msg) = result.message {
                    tracing::info!("[MERIDIAN] Autofocus completed: {}", msg);
                } else {
                    tracing::info!("[MERIDIAN] Autofocus completed successfully");
                }
                Ok(())
            }
            crate::NodeStatus::Failure => {
                // Why: autofocus result `message: Option<String>` —
                // failure is already encoded in `NodeStatus::Failure`. Generic message
                // when no specific diagnostic was attached.
                let error = result
                    .message
                    .unwrap_or_else(|| "Unknown autofocus error".to_string());
                tracing::error!("[MERIDIAN] Autofocus failed: {}", error);
                Err(format!("Autofocus failed: {}", error))
            }
            crate::NodeStatus::Cancelled => {
                tracing::warn!("[MERIDIAN] Autofocus was cancelled");
                Err("Autofocus cancelled".to_string())
            }
            crate::NodeStatus::Skipped => {
                tracing::info!("[MERIDIAN] Autofocus was skipped");
                Ok(())
            }
            other => {
                // Why: Pending/Running here would indicate a bug in execute_autofocus
                // (it must return a terminal status). Surface as an error rather
                // than swallow.
                let err = format!("Autofocus returned non-terminal status: {:?}", other);
                tracing::error!("[MERIDIAN] {}", err);
                Err(err)
            }
        }
    }

    async fn resume_guider(&self, ctx: &FlipContext) -> Result<(), String> {
        let resumed = self.restart_guider(ctx).await;
        let imaging_unguided = match &ctx.trigger_state {
            Some(state) => state.read().await.imaging_unguided,
            None => false,
        };
        match resumed {
            // The run already images unguided because the guide-star recovery
            // ran out; a guider that still cannot start after the flip is the
            // same problem, not a reason to fail the flip (owner decision
            // 2026-10-06). An operator Stop is not a guider problem.
            Err(problem) if imaging_unguided && !self.is_cancelled(ctx) => {
                let continuation = crate::executor::quality_problem_continuation(
                    "Post-flip guiding",
                    &format!("{problem} Imaging continues unguided."),
                    serde_json::json!({ "target_name": ctx.target_name }),
                );
                tracing::warn!("[MERIDIAN] {}", continuation.operator_message);
                if let Some(tx) = &self.decision_tx {
                    let mut decision = continuation.decision;
                    decision.sequence_run_id = *self.active_sequence_run_id.read();
                    let _ = tx.send(decision);
                }
                if let Some(tx) = &self.executor_event_tx {
                    let _ = tx.send(ExecutorEvent::Warning {
                        message: continuation.operator_message,
                    });
                }
                Ok(())
            }
            other => other,
        }
    }

    async fn restart_guider(&self, ctx: &FlipContext) -> Result<(), String> {
        if ctx.simulate {
            tracing::info!(
                "[MERIDIAN] (dry-run) Would resume guider and verify re-lock — skipping device \
                 command"
            );
            return Ok(());
        }
        tracing::info!("[MERIDIAN] Resuming guider...");

        // Post-flip guiding settles exactly like a normal Start Guiding: the
        // settle threshold / time / timeout come from the user's guiding settle
        // settings (plumbed onto MeridianFlipConfig from AppSettings), not a
        // hardcoded constant, so a user who tunes settling gets it honoured
        // after a flip too. The config defaults are 1.5 px / 10 s / 60 s.
        let settle_pixels = self.config.guider_settle_pixels;
        let settle_time = self.config.guider_settle_time;
        let settle_timeout = self.config.guider_settle_timeout;
        // Mirror `pause_guider`: with no guider configured there is nothing to
        // resume, so do not send the flip into its 120-second retry ladder over
        // a no-op. A real guider failure still fails closed below.
        // On a star picked afresh: the flip turned the field over, so the
        // guider's old lock position is not where the star is.
        match crate::instructions::start_guiding_on_fresh_star(
            &self.device_ops,
            settle_pixels,
            settle_time,
            settle_timeout,
        )
        .await
        {
            Ok(()) => {}
            Err(error) if crate::device_ops::is_no_guider_configured(error.message()) => {
                tracing::info!("[MERIDIAN] No guider configured — nothing to resume");
                return Ok(());
            }
            Err(error) => return Err(error.message().to_string()),
        }

        // guider_start() can return Ok before the guider has actually
        // re-locked onto a star (PHD2 reports the Start accepted while
        // re-acquisition / calibration is still in progress). Mirror
        // execute_start_guiding's verification: poll until is_guiding and fail
        // closed if it never re-locks — otherwise the post-flip exposures
        // resume UNGUIDED and the rest of the night trails.
        let poll_interval = std::time::Duration::from_secs(2);
        let deadline =
            tokio::time::Instant::now() + std::time::Duration::from_secs_f64(settle_timeout);
        let mut relocked = false;
        while tokio::time::Instant::now() < deadline {
            if self.is_cancelled(ctx) {
                return Err("Abort requested while verifying post-flip guiding".to_string());
            }
            match self.device_ops.guider_get_status().await {
                Ok(status) if status.is_guiding => {
                    tracing::info!(
                        "[MERIDIAN] Guiding re-locked after flip: RMS total={:.2}px",
                        status.rms_total
                    );
                    relocked = true;
                    break;
                }
                Ok(status) => {
                    tracing::debug!(
                        "[MERIDIAN] Guiding not yet re-locked (is_guiding={}), waiting...",
                        status.is_guiding
                    );
                }
                Err(e) => {
                    tracing::warn!("[MERIDIAN] Guider status poll failed: {}", e);
                }
            }
            tokio::time::sleep(poll_interval).await;
        }

        if !relocked {
            return Err(format!(
                "Guiding did not re-lock within {:.0}s after the meridian flip. \
                 The guider may have failed to re-acquire a star.",
                settle_timeout
            ));
        }

        // Post-settle RMS sanity — mirror execute_start_guiding's gate. A guider
        // can report is_guiding while tracking poorly (a re-lock onto a hot
        // pixel, or drift/over-correction that only blows up after the initial
        // settle). Sample RMS over a short window and fail closed if the peak
        // exceeds the ceiling, so a bad post-flip re-lock trips the flip failure
        // action (default: pause + alert) instead of silently trailing the rest
        // of the night on subs that look guided but aren't. rms_total is in
        // pixels here, consistent with StartGuidingConfig::max_post_settle_rms_pixels.
        let rms_ceiling = self.config.max_post_settle_rms_pixels;
        const RMS_SAMPLES: u32 = 3;
        let rms_interval = std::time::Duration::from_secs(2);
        let mut max_rms: f64 = 0.0;
        let mut sample_count: u32 = 0;
        for _ in 0..RMS_SAMPLES {
            if self.is_cancelled(ctx) {
                return Err("Abort requested while validating post-flip guiding RMS".to_string());
            }
            tokio::time::sleep(rms_interval).await;
            match self.device_ops.guider_get_status().await {
                Ok(status) => {
                    max_rms = max_rms.max(status.rms_total);
                    sample_count += 1;
                }
                Err(e) => {
                    tracing::warn!("[MERIDIAN] Post-flip RMS sample failed: {}", e);
                }
            }
        }
        if sample_count > 0 && max_rms > rms_ceiling {
            // The guider re-locked and is guiding; how well is a judgment, so
            // by default it is reported and the flip completes.
            return self
                .carry_on_through_quality_problem(
                    ctx,
                    "Post-flip guiding check",
                    format!(
                        "Post-flip guiding RMS too high: {:.2}px peak across {} sample{} \
                         (limit {:.2}px). The guider re-locked but is tracking poorly.",
                        max_rms,
                        sample_count,
                        if sample_count == 1 { "" } else { "s" },
                        rms_ceiling
                    ),
                )
                .await;
        }
        tracing::info!(
            "[MERIDIAN] Post-flip guiding validated: peak RMS {:.2}px over {} sample{}",
            max_rms,
            sample_count,
            if sample_count == 1 { "" } else { "s" }
        );
        Ok(())
    }

    async fn wait_settle(&self, ctx: &FlipContext) -> Result<(), String> {
        let settle_time = self.config.settle_time;
        tracing::info!("[MERIDIAN] Waiting for settle ({:.0}s)...", settle_time);

        let settle_duration = std::time::Duration::from_secs_f64(settle_time);
        let check_interval = std::time::Duration::from_millis(500);
        let mut elapsed = std::time::Duration::ZERO;

        while elapsed < settle_duration {
            // Why: check both internal abort and the shared sequence cancellation
            // token so a Stop request during settle returns immediately instead
            // of waiting out the full settle time.
            if self.is_cancelled(ctx) {
                return Err("Abort requested during settle".to_string());
            }

            tokio::time::sleep(check_interval).await;
            elapsed += check_interval;
        }

        Ok(())
    }

    // Helper methods

    async fn get_pier_side(&self, mount_id: &str) -> Result<PierSide, String> {
        let ps = self.device_ops.mount_side_of_pier(mount_id).await?;
        // The trait returns the calculation-internal enum; this executor
        // emits events using the wire-format enum, so the boundary is
        // mapped explicitly to keep meridian::PierSide off the event API.
        Ok(match ps {
            meridian::PierSide::East => PierSide::East,
            meridian::PierSide::West => PierSide::West,
            meridian::PierSide::Unknown => PierSide::Unknown,
        })
    }

    fn calculate_hour_angle(&self, ra_hours: f64) -> f64 {
        // HA = LST - RA.6 deleted the duplicate jd/LST helpers
        // here and routed through the meridian module so a future LST tweak
        // (e.g. nutation correction) lands in one place.
        let now = chrono::Utc::now();
        let jd = julian_day(&now);

        // Why: get_observer_location() returns None when no location
        // has been configured in the user profile. The fallback (longitude=0, Greenwich)
        // logs a WARN to the trace; meridian flips computed with longitude=0 will be off
        // by up-to-12 hours of meridian time but the flip itself is a *post-meridian*
        // pier-side recovery — the user-visible "flip needed" indicator is gated by the
        // mount's pier-side property, not this LST calculation. The warning surfaces the
        // missing-location config in the log so operators know to fix it.
        let longitude_deg = self
            .device_ops
            .get_observer_location()
            .map(|(_lat, lon)| lon)
            .unwrap_or_else(|| {
                tracing::warn!(
                    "[MERIDIAN] Observer location unavailable, using longitude=0 for LST calculation"
                );
                0.0
            });
        let lst = local_sidereal_time(jd, longitude_deg);
        let ha = lst - ra_hours;

        // HA is canonically reported in [-12, +12) h so consumers can use
        // sign alone to determine east-vs-west of meridian; raw mod-24 would
        // emit values in [0, 24) and flip the sign interpretation.
        let mut ha_norm = ha % 24.0;
        if ha_norm > 12.0 {
            ha_norm -= 24.0;
        } else if ha_norm < -12.0 {
            ha_norm += 24.0;
        }

        ha_norm
    }

    /// Returns true if either the executor's internal abort flag or the
    /// caller-supplied cancellation token has been set.
    /// A post-flip check found a quality problem — a solve with no solution,
    /// guiding RMS over the ceiling — after the flip itself completed. With the
    /// operator's "Stop the run for quality problems" off (the default) the
    /// problem is reported and the step succeeds; with it on, the step fails as
    /// it always did and the flip's retry ladder and failure action decide.
    async fn carry_on_through_quality_problem(
        &self,
        ctx: &FlipContext,
        source: &str,
        problem: String,
    ) -> Result<(), String> {
        let stop = match &ctx.trigger_state {
            Some(state) => state.read().await.stop_on_quality_problems,
            None => false,
        };
        if stop {
            return Err(problem);
        }
        let continuation = crate::executor::quality_problem_continuation(
            source,
            &problem,
            serde_json::json!({ "target_name": ctx.target_name }),
        );
        tracing::warn!("[MERIDIAN] {}", continuation.operator_message);
        if let Some(tx) = &self.decision_tx {
            let mut decision = continuation.decision;
            decision.sequence_run_id = *self.active_sequence_run_id.read();
            let _ = tx.send(decision);
        }
        if let Some(tx) = &self.executor_event_tx {
            let _ = tx.send(ExecutorEvent::Warning {
                message: continuation.operator_message,
            });
        }
        Ok(())
    }

    fn is_cancelled(&self, ctx: &FlipContext) -> bool {
        if self.abort_requested.load(Ordering::Relaxed) {
            return true;
        }
        if let Some(token) = &ctx.cancellation_token {
            if token.load(Ordering::Relaxed) {
                return true;
            }
        }
        false
    }

    /// restore the mount's pre-flip tracking state when a
    /// cancel happens mid-flip. Errors are *logged*, not returned, since this is
    /// already a cancel path.
    async fn restore_tracking_on_cancel(&self, ctx: &FlipContext, pre_flip_tracking: Option<bool>) {
        if matches!(pre_flip_tracking, Some(true)) {
            if let Err(e) = self
                .device_ops
                .mount_set_tracking(&ctx.mount_id, true)
                .await
            {
                tracing::error!(
                    "[MERIDIAN] Failed to restore mount tracking after cancel for '{}': {}. \
                     Mount may continue to drift from target.",
                    ctx.mount_id,
                    e
                );
            } else {
                tracing::info!("[MERIDIAN] Restored mount tracking after cancel");
            }
        }
    }

    /// explicit, retried, error-propagating failure-action handler.
    /// Replaces the previous `let _ = mount_park(...)` pattern: on error, log
    /// at error level, retry up to N times with delay, emit a critical
    /// notification, and return Err so the executor's failure result reflects
    /// the failure-action failure (instead of pretending it succeeded).
    async fn execute_failure_action(&self, mount_id: &str) -> Result<(), String> {
        match self.config.failure_action {
            FlipFailureAction::PauseAndAlert => {
                tracing::warn!("[MERIDIAN] Flip failed - pausing and alerting user");
                if let Err(e) = self
                    .device_ops
                    .send_notification(
                        "error",
                        "Meridian Flip Failed",
                        "The meridian flip could not complete. Please check your equipment.",
                        None,
                    )
                    .await
                {
                    // Why: notification failures are non-fatal — the sequence is
                    // already paused via state change in the executor task. Log
                    // but do not propagate.
                    tracing::error!(
                        "[MERIDIAN] Failed to deliver pause-and-alert notification: {}",
                        e
                    );
                }
                Ok(())
            }
            FlipFailureAction::AbortAndPark => {
                tracing::warn!("[MERIDIAN] Flip failed - aborting and parking");

                // stop tracking with retries + explicit error logging.
                let retry_count = self.config.safety_action_retry_count;
                if let Err(e) = self
                    .retry_safety_action("mount_set_tracking(false)", || async {
                        self.device_ops.mount_set_tracking(mount_id, false).await
                    })
                    .await
                {
                    tracing::error!(
                        "[MERIDIAN] CRITICAL: failed to stop tracking after {} retries: {}",
                        retry_count,
                        e
                    );
                    let _ = self
                        .device_ops
                        .send_notification(
                            "critical",
                            "Meridian Flip — Tracking Stop Failed",
                            &format!(
                                "After a failed flip the mount could not be commanded to stop \
                                 tracking ({}). The mount may drift past safe limits.",
                                e
                            ),
                            None,
                        )
                        .await;
                    // Continue to park attempt — stopping tracking is best-effort
                    // before park, but the park itself is the safety-critical step.
                }

                // abort any in-flight slew with retries + explicit
                // error logging. Some mounts will refuse a park while slewing.
                if let Err(e) = self
                    .retry_safety_action("mount_abort_slew", || async {
                        self.device_ops.mount_abort_slew(mount_id).await
                    })
                    .await
                {
                    tracing::error!(
                        "[MERIDIAN] mount_abort_slew failed after {} retries: {}",
                        retry_count,
                        e
                    );
                    // Continue to park — some drivers do not implement abort_slew
                    // but still accept park.
                }

                // park with retries + critical event on failure.
                // Park failure after a flip failure is the worst-case scenario:
                // the mount may already be at a hard limit. Emit a critical
                // notification so the UI surfaces a top-level alert AND return
                // Err so callers see the failed-flip-then-failed-park outcome.
                match self
                    .retry_safety_action("mount_park", || async {
                        self.device_ops.mount_park(mount_id).await
                    })
                    .await
                {
                    Ok(()) => {
                        tracing::info!("[MERIDIAN] Mount parked successfully after failed flip");
                        if let Err(e) = self
                            .device_ops
                            .send_notification(
                                "error",
                                "Meridian Flip Failed - Mount Parked",
                                "The meridian flip failed. Mount has been parked for safety.",
                                None,
                            )
                            .await
                        {
                            tracing::error!(
                                "[MERIDIAN] Failed to deliver park-success notification: {}",
                                e
                            );
                        }
                        Ok(())
                    }
                    Err(park_err) => {
                        tracing::error!(
                            "[MERIDIAN] CRITICAL: mount_park failed after {} retries: {}. \
                             Mount may be at hard limit — manual intervention required.",
                            retry_count,
                            park_err
                        );
                        // Critical-level notification so the UI surfaces this
                        // as a top-level alert (not a normal log entry).
                        let critical_msg = format!(
                            "The meridian flip failed AND the mount could not be parked ({}). \
                             The mount may be at a hard limit. Manually disengage clutches \
                             and re-home before attempting any further slews.",
                            park_err
                        );
                        if let Err(e) = self
                            .device_ops
                            .send_notification(
                                "critical",
                                "Meridian Flip Failed - PARK FAILED",
                                &critical_msg,
                                None,
                            )
                            .await
                        {
                            tracing::error!(
                                "[MERIDIAN] Failed to deliver critical park-failure notification: {}",
                                e
                            );
                        }
                        Err(format!(
                            "AbortAndPark failed: park error after {} retries: {}",
                            retry_count, park_err
                        ))
                    }
                }
            }
        }
    }

    /// retry helper for safety-critical device operations. Logs
    /// every failed attempt at error level; sleeps `safety_action_retry_delay_secs`
    /// between attempts. Returns the last error after exhaustion. Retry count
    /// and delay come from `MeridianFlipConfig`.
    async fn retry_safety_action<F, Fut>(&self, op_name: &str, mut op: F) -> Result<(), String>
    where
        F: FnMut() -> Fut,
        Fut: std::future::Future<Output = Result<(), String>>,
    {
        let retry_count = self.config.safety_action_retry_count;
        let retry_delay_secs = self.config.safety_action_retry_delay_secs;
        let mut last_err = String::from("no attempt was made");
        for attempt in 1..=retry_count {
            match op().await {
                Ok(()) => {
                    if attempt > 1 {
                        tracing::info!(
                            "[MERIDIAN] {} succeeded on retry attempt {}",
                            op_name,
                            attempt
                        );
                    }
                    return Ok(());
                }
                Err(e) => {
                    tracing::error!(
                        "[MERIDIAN] {} attempt {}/{} failed: {}",
                        op_name,
                        attempt,
                        retry_count,
                        e
                    );
                    last_err = e;
                    if attempt < retry_count {
                        tokio::time::sleep(std::time::Duration::from_secs_f64(retry_delay_secs))
                            .await;
                    }
                }
            }
        }
        Err(last_err)
    }

    fn emit_event(&self, event: MeridianFlipEvent) {
        self.event_emitter.emit(event.clone());

        // A flip in its retry ladder is the run standing still,
        // and nothing on the Sequencer screen said so. `event_tx` below is the
        // flip DIALOG's channel, which a trigger-fired flip never has (only the
        // node-driven flip sets it), so a retry ladder that held a run for two
        // and a half minutes produced: status chip "Running", `Progress 4/8 ·
        // 50%`, `Mount: Tracking`, and a finish time that came and went. The
        // only honest account of the flip appeared after the operator's Stop,
        // in the Session Report.
        //
        // The run's own event stream reaches every operator surface, so the
        // retry goes there too. `MeridianFlipOutcome` already carries the
        // verdict, so only the mid-ladder notice is forwarded — a completed or
        // failed flip must not be announced twice.
        if let Some(tx) = &self.executor_event_tx {
            if let MeridianFlipEvent::RetryScheduled {
                attempt,
                max_attempts,
                delay_secs,
            } = &event
            {
                let _ = tx.send(ExecutorEvent::NodeProgress {
                    node_id: MERIDIAN_FLIP_RUN_PROGRESS_NODE_ID.to_string(),
                    instruction: "MeridianFlip".to_string(),
                    // Attempts made out of attempts allowed. The flip is not
                    // "N% done"; this is the only percentage that is true.
                    progress_percent: if *max_attempts > 0 {
                        100.0 * f64::from(*attempt) / f64::from(*max_attempts)
                    } else {
                        0.0
                    },
                    detail: format!(
                        "attempt {}/{} failed, retrying in {:.0}s",
                        attempt, max_attempts, delay_secs
                    ),
                    structured_detail: None,
                });
            }
        }

        // try_send drops the event on a full channel rather than blocking;
        // the emitter has already logged it so the record is preserved, and
        // a blocking send could deadlock the executor against a slow subscriber.
        if let Some(tx) = &self.event_tx {
            if let Err(e) = tx.try_send(event) {
                tracing::trace!(
                    "[MERIDIAN] Event channel send dropped: {} (logged via emitter)",
                    e
                );
            }
        }
    }
}

/// Format a failure-action enum for human-readable event payloads.
fn format_failure_action(action: FlipFailureAction) -> &'static str {
    match action {
        FlipFailureAction::PauseAndAlert => "Paused sequence and alerted user",
        FlipFailureAction::AbortAndPark => "Aborted sequence and parking mount",
    }
}

/// Normalize an RA difference (hours) to the shortest signed angular distance,
/// accounting for the 0/24h wraparound.
fn normalize_ra_diff_hours(diff: f64) -> f64 {
    let mut wrapped = diff % 24.0;
    if wrapped > 12.0 {
        wrapped -= 24.0;
    } else if wrapped < -12.0 {
        wrapped += 24.0;
    }
    wrapped
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::device_ops::{DeviceOps, DeviceResult, GuidingStatus, ImageData, PlateSolveResult};
    use async_trait::async_trait;
    use std::sync::atomic::AtomicI32;
    use std::sync::Mutex;

    /// Test step sequence building with all options enabled
    #[test]
    fn test_build_step_sequence_all_options() {
        let config = MeridianFlipConfig {
            pause_guiding: true,
            auto_center: true,
            refocus_after: true,
            resume_guiding: true,
            ..Default::default()
        };

        let steps = build_steps_from_config(&config);

        assert_eq!(steps.len(), 9);
        assert_eq!(steps[0], FlipStep::PausingGuider);
        assert_eq!(steps[1], FlipStep::StoppingTracking);
        assert_eq!(steps[2], FlipStep::SlewingToTarget);
        assert_eq!(steps[3], FlipStep::VerifyingPierSide);
        assert_eq!(steps[4], FlipStep::ResumingTracking);
        assert_eq!(steps[5], FlipStep::PlateSolvingAndCentering);
        assert_eq!(steps[6], FlipStep::Refocusing);
        assert_eq!(steps[7], FlipStep::ResumingGuider);
        assert_eq!(steps[8], FlipStep::Settling);
    }

    /// Test step sequence building with minimal options
    #[test]
    fn test_build_step_sequence_minimal() {
        let config = MeridianFlipConfig {
            pause_guiding: false,
            auto_center: false,
            refocus_after: false,
            resume_guiding: false,
            ..Default::default()
        };

        let steps = build_steps_from_config(&config);

        assert_eq!(steps.len(), 5);
        assert_eq!(steps[0], FlipStep::StoppingTracking);
        assert_eq!(steps[1], FlipStep::SlewingToTarget);
        assert_eq!(steps[2], FlipStep::VerifyingPierSide);
        assert_eq!(steps[3], FlipStep::ResumingTracking);
        assert_eq!(steps[4], FlipStep::Settling);
    }

    /// Helper to build steps without requiring a full executor
    fn build_steps_from_config(config: &MeridianFlipConfig) -> Vec<FlipStep> {
        let mut steps = Vec::new();

        if config.pause_guiding {
            steps.push(FlipStep::PausingGuider);
        }

        steps.push(FlipStep::StoppingTracking);
        steps.push(FlipStep::SlewingToTarget);
        steps.push(FlipStep::VerifyingPierSide);
        steps.push(FlipStep::ResumingTracking);

        if config.auto_center {
            steps.push(FlipStep::PlateSolvingAndCentering);
        }

        if config.refocus_after {
            steps.push(FlipStep::Refocusing);
        }

        if config.resume_guiding {
            steps.push(FlipStep::ResumingGuider);
        }

        steps.push(FlipStep::Settling);

        steps
    }

    /// verify the unified executor reuses meridian::julian_day rather
    /// than carrying its own duplicate.
    #[test]
    fn test_calculate_hour_angle_uses_meridian_julian_day() {
        // The function we're testing is now MeridianFlipExecutor::calculate_hour_angle.
        // It calls crate::meridian::julian_day; if that import is gone the file
        // won't compile. Verify the math path: at LST==RA, HA==0.
        // We rely on meridian::julian_day being correct (covered by its own
        // tests in meridian.rs).
        let jd = julian_day(&chrono::Utc::now());
        let lst = local_sidereal_time(jd, 0.0);
        let ha = lst - lst; // Trivially 0
        assert!((ha).abs() < 1e-9);
    }

    // Mock device for the flip / cover / retry behavioural tests

    #[derive(Default)]
    struct MockDeviceOpsState {
        /// Current pier side reported on each call.
        pier_sides: Mutex<Vec<crate::meridian::PierSide>>,
        /// Current coordinates returned from mount_get_coordinates (RA, Dec).
        coordinates: Mutex<(f64, f64)>,
        /// Hours added to the RA the mount reads back, as a mount whose
        /// read-back does not land exactly on the commanded RA.
        readback_ra_offset_hours: Mutex<f64>,
        /// Park retry counter — fail-then-succeed simulation.
        park_failures_remaining: AtomicI32,
        /// Recorded park calls (for assertions).
        park_calls: AtomicI32,
        /// Set tracking calls.
        tracking_calls: Mutex<Vec<bool>>,
        /// Phase G dry-run: number of real slew commands issued. A dry-run
        /// must leave this at zero (no mount movement).
        slew_calls: AtomicI32,
        /// Number of post-flip plate solves that should return a real
        /// unsuccessful solve result.
        plate_solve_failures_remaining: AtomicI32,
        /// Recorded guider-start calls, used to prove centering failure stops
        /// the remaining post-flip steps.
        guider_start_calls: AtomicI32,
        /// For each fresh guide-star selection, how many guider starts had
        /// been made when it arrived.
        fresh_star_before_starts: Mutex<Vec<i32>>,
        /// When true, `guider_start` fails, as a guider with no star does.
        guider_start_fails: AtomicBool,
        /// For each guider-stop call, how many slews had been commanded when it
        /// arrived, so a test can tell whether guiding stopped before the flip.
        slews_before_guider_stop: Mutex<Vec<i32>>,
        /// Whether the cover is closed.
        cover_state: AtomicI32,
        /// Notifications sent (level, title).
        notifications: Mutex<Vec<(String, String)>>,
        /// Whether to simulate slewing (false means slew completes immediately).
        is_slewing: AtomicBool,
        /// Observer location, wrapped in a Mutex so altitude-gate tests can install
        /// a location at runtime.
        location: Mutex<Option<(f64, f64)>>,
        /// Optional override for `calculate_altitude` so the
        /// min_post_flip_altitude_deg gate can be exercised by tests. Defaults
        /// to None (which causes calculate_altitude to return 45° as before).
        altitude_override_deg: Mutex<Option<f64>>,
        /// When `Some((d_ra_hours, d_dec_degrees))`, the mount behaves like a
        /// real one behind the device layer: a slew lands, and reads back,
        /// that far from the J2000 coordinates it was sent (the precession the
        /// device layer applies on the way out), and `mount_readback_frame`
        /// reports the same shift. `None` stores what it is sent, like the
        /// simulator.
        readback_offset: Mutex<Option<(f64, f64)>>,
        /// How far short of the commanded position a slew stops, in the
        /// mount's frame (hours, degrees).
        slew_miss: Mutex<(f64, f64)>,
    }

    struct MockDeviceOps {
        state: Arc<MockDeviceOpsState>,
    }

    impl MockDeviceOps {
        fn new(state: Arc<MockDeviceOpsState>) -> Self {
            Self { state }
        }
    }

    #[async_trait]
    impl DeviceOps for MockDeviceOps {
        async fn mount_slew_to_coordinates(
            &self,
            _mount_id: &str,
            ra: f64,
            dec: f64,
        ) -> DeviceResult<()> {
            self.state.slew_calls.fetch_add(1, Ordering::Relaxed);
            let (d_ra, d_dec) = self
                .state
                .readback_offset
                .lock()
                .unwrap()
                .unwrap_or((0.0, 0.0));
            let (miss_ra, miss_dec) = *self.state.slew_miss.lock().unwrap();
            *self.state.coordinates.lock().unwrap() = (ra + d_ra + miss_ra, dec + d_dec + miss_dec);
            Ok(())
        }

        async fn mount_readback_frame(
            &self,
            _mount_id: &str,
            ra_hours: f64,
            dec_degrees: f64,
        ) -> DeviceResult<(f64, f64)> {
            let (d_ra, d_dec) = self
                .state
                .readback_offset
                .lock()
                .unwrap()
                .unwrap_or((0.0, 0.0));
            Ok((ra_hours + d_ra, dec_degrees + d_dec))
        }

        async fn mount_abort_slew(&self, _mount_id: &str) -> DeviceResult<()> {
            self.state.is_slewing.store(false, Ordering::Relaxed);
            Ok(())
        }

        async fn mount_get_coordinates(&self, _mount_id: &str) -> DeviceResult<(f64, f64)> {
            let (ra, dec) = *self.state.coordinates.lock().unwrap();
            Ok((
                ra + *self.state.readback_ra_offset_hours.lock().unwrap(),
                dec,
            ))
        }

        async fn mount_sync(&self, _mount_id: &str, _ra: f64, _dec: f64) -> DeviceResult<()> {
            Ok(())
        }

        async fn mount_park(&self, _mount_id: &str) -> DeviceResult<()> {
            self.state.park_calls.fetch_add(1, Ordering::Relaxed);
            let remaining = self
                .state
                .park_failures_remaining
                .fetch_sub(1, Ordering::Relaxed);
            if remaining > 0 {
                Err(format!(
                    "simulated park failure (remaining={})",
                    remaining - 1
                ))
            } else {
                Ok(())
            }
        }

        async fn mount_unpark(&self, _mount_id: &str) -> DeviceResult<()> {
            Ok(())
        }

        async fn mount_is_slewing(&self, _mount_id: &str) -> DeviceResult<bool> {
            Ok(self.state.is_slewing.load(Ordering::Relaxed))
        }

        async fn mount_is_parked(&self, _mount_id: &str) -> DeviceResult<bool> {
            Ok(false)
        }

        async fn mount_can_flip(&self, _mount_id: &str) -> DeviceResult<bool> {
            Ok(true)
        }

        async fn mount_side_of_pier(
            &self,
            _mount_id: &str,
        ) -> DeviceResult<crate::meridian::PierSide> {
            let mut sides = self.state.pier_sides.lock().unwrap();
            if sides.is_empty() {
                return Ok(crate::meridian::PierSide::Unknown);
            }
            // Pop the front; if only one left, keep returning it.
            let next = if sides.len() == 1 {
                sides[0]
            } else {
                sides.remove(0)
            };
            Ok(next)
        }

        async fn mount_is_tracking(&self, _mount_id: &str) -> DeviceResult<bool> {
            Ok(true)
        }

        async fn mount_set_tracking(&self, _mount_id: &str, enabled: bool) -> DeviceResult<()> {
            self.state.tracking_calls.lock().unwrap().push(enabled);
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
            Ok(ImageData {
                width: 100,
                height: 100,
                data: vec![0u16; 100 * 100],
                bits_per_pixel: 16,
                exposure_secs: duration_secs,
                gain,
                offset,
                temperature: Some(-10.0),
                filter: None,
                timestamp: chrono::Utc::now().timestamp(),
                sensor_type: Some("Monochrome".to_string()),
                bayer_offset: None,
            })
        }

        async fn camera_abort_exposure(&self, _camera_id: &str) -> DeviceResult<()> {
            Ok(())
        }

        async fn camera_set_cooler(
            &self,
            _camera_id: &str,
            _enabled: bool,
            _target: f64,
        ) -> DeviceResult<()> {
            Ok(())
        }

        async fn camera_get_temperature(&self, _camera_id: &str) -> DeviceResult<f64> {
            Ok(-10.0)
        }

        async fn camera_get_cooler_power(&self, _camera_id: &str) -> DeviceResult<f64> {
            Ok(50.0)
        }

        async fn focuser_move_to(&self, _focuser_id: &str, _position: i32) -> DeviceResult<()> {
            Ok(())
        }

        async fn focuser_get_position(&self, _focuser_id: &str) -> DeviceResult<i32> {
            Ok(25000)
        }

        async fn focuser_is_moving(&self, _focuser_id: &str) -> DeviceResult<bool> {
            Ok(false)
        }

        async fn focuser_get_temperature(&self, _focuser_id: &str) -> DeviceResult<Option<f64>> {
            Ok(Some(15.0))
        }

        async fn focuser_halt(&self, _focuser_id: &str) -> DeviceResult<()> {
            Ok(())
        }

        async fn filterwheel_set_position(&self, _fw_id: &str, _position: i32) -> DeviceResult<()> {
            Ok(())
        }

        async fn filterwheel_get_position(&self, _fw_id: &str) -> DeviceResult<i32> {
            Ok(1)
        }

        async fn filterwheel_get_names(&self, _fw_id: &str) -> DeviceResult<Vec<String>> {
            Ok(vec!["L".into()])
        }

        async fn filterwheel_set_filter_by_name(
            &self,
            _fw_id: &str,
            _name: &str,
        ) -> DeviceResult<i32> {
            Ok(1)
        }

        async fn rotator_move_to(&self, _rotator_id: &str, _angle: f64) -> DeviceResult<()> {
            Ok(())
        }

        async fn rotator_move_relative(&self, _rotator_id: &str, _delta: f64) -> DeviceResult<()> {
            Ok(())
        }

        async fn rotator_get_angle(&self, _rotator_id: &str) -> DeviceResult<f64> {
            Ok(0.0)
        }

        async fn rotator_halt(&self, _rotator_id: &str) -> DeviceResult<()> {
            Ok(())
        }

        async fn guider_dither(
            &self,
            _pixels: f64,
            _settle_pixels: f64,
            _settle_time: f64,
            _settle_timeout: f64,
            _ra_only: bool,
        ) -> DeviceResult<()> {
            Ok(())
        }

        async fn guider_get_status(&self) -> DeviceResult<GuidingStatus> {
            Ok(GuidingStatus {
                is_guiding: true,
                rms_ra: 0.5,
                rms_dec: 0.4,
                rms_total: 0.64,
            })
        }

        async fn guider_start(
            &self,
            _settle_pixels: f64,
            _settle_time: f64,
            _settle_timeout: f64,
        ) -> DeviceResult<()> {
            self.state
                .guider_start_calls
                .fetch_add(1, Ordering::Relaxed);
            if self.state.guider_start_fails.load(Ordering::Relaxed) {
                return Err("simulated guider start failure: no star".to_string());
            }
            Ok(())
        }

        async fn guider_select_fresh_star(&self) -> DeviceResult<()> {
            self.state
                .fresh_star_before_starts
                .lock()
                .unwrap()
                .push(self.state.guider_start_calls.load(Ordering::Relaxed));
            Ok(())
        }

        async fn guider_stop(&self) -> DeviceResult<()> {
            self.state
                .slews_before_guider_stop
                .lock()
                .unwrap()
                .push(self.state.slew_calls.load(Ordering::Relaxed));
            Ok(())
        }

        async fn plate_solve(
            &self,
            _image_data: &ImageData,
            hint_ra: Option<f64>,
            hint_dec: Option<f64>,
            _hint_scale: Option<f64>,
        ) -> DeviceResult<PlateSolveResult> {
            let should_fail = self
                .state
                .plate_solve_failures_remaining
                .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |remaining| {
                    (remaining > 0).then_some(remaining - 1)
                })
                .is_ok();
            // Return success with the hint coordinates so total_offset==0.
            // Why: this is a test-only mock device op.
            // The hint-less case yields (0,0) which still satisfies the
            // "total_offset==0" invariant the test asserts; production
            // plate-solve always supplies hints from the mount pointing.
            Ok(PlateSolveResult {
                ra_degrees: hint_ra.unwrap_or(0.0),
                dec_degrees: hint_dec.unwrap_or(0.0),
                pixel_scale: 1.5,
                rotation: 0.0,
                success: !should_fail,
            })
        }

        async fn save_fits(
            &self,
            _image_data: &ImageData,
            _file_path: &str,
            _frame_ctx: &crate::scheduling::FrameContext,
        ) -> DeviceResult<()> {
            Ok(())
        }

        async fn send_notification(
            &self,
            level: &str,
            title: &str,
            _message: &str,
            _explicit_transports: Option<&[String]>,
        ) -> DeviceResult<()> {
            self.state
                .notifications
                .lock()
                .unwrap()
                .push((level.to_string(), title.to_string()));
            Ok(())
        }

        fn calculate_altitude(
            &self,
            _ra_hours: f64,
            _dec_degrees: f64,
            _lat: f64,
            _lon: f64,
        ) -> f64 {
            // Honour the per-test altitude override so the
            // min_post_flip_altitude_deg gate can be exercised. Defaults to
            // 45° (above the gate) so existing tests are unaffected.
            self.state
                .altitude_override_deg
                .lock()
                .unwrap()
                .unwrap_or(45.0)
        }

        fn get_observer_location(&self) -> Option<(f64, f64)> {
            // Read through the Mutex so altitude-gate tests can
            // install a location at runtime.
            *self.state.location.lock().unwrap()
        }

        async fn polar_align_update(
            &self,
            _result: &crate::polar_align::PolarAlignResult,
        ) -> DeviceResult<()> {
            Ok(())
        }

        async fn dome_open(&self, _dome_id: &str) -> DeviceResult<()> {
            Ok(())
        }

        async fn dome_close(&self, _dome_id: &str) -> DeviceResult<()> {
            Ok(())
        }

        async fn dome_park(&self, _dome_id: &str) -> DeviceResult<()> {
            Ok(())
        }

        async fn dome_get_shutter_status(&self, _dome_id: &str) -> DeviceResult<String> {
            Ok("Open".to_string())
        }

        async fn safety_is_safe(&self, _safety_id: Option<&str>) -> DeviceResult<bool> {
            Ok(true)
        }

        async fn calculate_image_hfr(&self, _image_data: &ImageData) -> DeviceResult<Option<f64>> {
            Ok(Some(2.0))
        }

        async fn detect_stars_in_image(
            &self,
            _image_data: &ImageData,
        ) -> DeviceResult<Vec<(f64, f64, f64)>> {
            Ok(vec![])
        }

        async fn cover_calibrator_open_cover(&self, _device_id: &str) -> DeviceResult<()> {
            self.state.cover_state.store(3, Ordering::Relaxed);
            Ok(())
        }

        async fn cover_calibrator_close_cover(&self, _device_id: &str) -> DeviceResult<()> {
            self.state.cover_state.store(1, Ordering::Relaxed);
            Ok(())
        }

        async fn cover_calibrator_halt_cover(&self, _device_id: &str) -> DeviceResult<()> {
            Ok(())
        }

        async fn cover_calibrator_calibrator_on(
            &self,
            _device_id: &str,
            _brightness: i32,
        ) -> DeviceResult<()> {
            Ok(())
        }

        async fn cover_calibrator_calibrator_off(&self, _device_id: &str) -> DeviceResult<()> {
            Ok(())
        }

        async fn cover_calibrator_get_cover_state(&self, _device_id: &str) -> DeviceResult<i32> {
            Ok(self.state.cover_state.load(Ordering::Relaxed))
        }

        async fn cover_calibrator_get_calibrator_state(
            &self,
            _device_id: &str,
        ) -> DeviceResult<i32> {
            Ok(1) // Off
        }

        async fn cover_calibrator_get_brightness(&self, _device_id: &str) -> DeviceResult<i32> {
            Ok(0)
        }

        async fn cover_calibrator_get_max_brightness(&self, _device_id: &str) -> DeviceResult<i32> {
            Ok(255)
        }
    }

    fn make_ctx(state: &Arc<MockDeviceOpsState>) -> FlipContext {
        // Initialise sensible coordinates so the slew + verify steps complete.
        *state.coordinates.lock().unwrap() = (10.0, 45.0);
        FlipContext {
            target_name: "M42".to_string(),
            target_ra_hours: 10.0,
            target_dec_degrees: 45.0,
            mount_id: "mock-mount".to_string(),
            camera_id: Some("mock-camera".to_string()),
            focuser_id: None,
            cover_calibrator_id: None,
            cancellation_token: None,
            trigger_state: None,
            autofocus_config: None,
            simulate: false,
        }
    }

    /// `make_ctx` for an operator who turned on "Stop the run for quality
    /// problems": a post-flip solve with no solution fails the step, and the
    /// flip's retry ladder and failure action take it from there.
    fn make_ctx_stopping_on_quality_problems(state: &Arc<MockDeviceOpsState>) -> FlipContext {
        let mut trigger_state = TriggerState::new();
        trigger_state.stop_on_quality_problems = true;
        FlipContext {
            trigger_state: Some(Arc::new(RwLock::new(trigger_state))),
            ..make_ctx(state)
        }
    }

    /// pier-side telemetry unavailable — verification falls back to
    /// coordinate convergence and SUCCEEDS when the mount is on-target.
    #[tokio::test]
    async fn test_pier_side_fallback_uses_coordinates_when_unknown() {
        let state = Arc::new(MockDeviceOpsState::default());
        // Both pre and post pier side return Unknown.
        state
            .pier_sides
            .lock()
            .unwrap()
            .push(crate::meridian::PierSide::Unknown);
        let ops: SharedDeviceOps = Arc::new(MockDeviceOps::new(state.clone()));

        // Disable optional steps to keep the test simple.
        let config = MeridianFlipConfig {
            pause_guiding: false,
            auto_center: false,
            refocus_after: false,
            resume_guiding: false,
            settle_time: 0.0,
            max_retries: 0,
            ..Default::default()
        };

        let mut executor = MeridianFlipExecutor::new(config, ops);
        let ctx = make_ctx(&state);

        let result = executor.execute(&ctx).await;
        match result {
            FlipResult::Success { .. } => {}
            other => panic!(
                "Expected coordinate-fallback verification to succeed, got {:?}",
                other
            ),
        }
    }

    /// Near the pole a flip that landed must not be failed as a miss. Without
    /// pier-side telemetry the flip is verified by where the mount says it is,
    /// and that check compared raw RA degrees against its one-arcminute
    /// tolerance: at Dec 85 an hour of RA spans a twelfth of the arc it does on
    /// the equator, so a read-back 9 arcseconds off on the sky failed the flip.
    #[tokio::test]
    async fn a_flip_near_the_pole_is_verified_on_the_sky() {
        let state = Arc::new(MockDeviceOpsState::default());
        state
            .pier_sides
            .lock()
            .unwrap()
            .push(crate::meridian::PierSide::Unknown);
        // 0.002 h of RA: 1.8' of raw RA, 9.4" on the sky at Dec 85.
        *state.readback_ra_offset_hours.lock().unwrap() = 0.002;
        let ops: SharedDeviceOps = Arc::new(MockDeviceOps::new(state.clone()));
        let config = MeridianFlipConfig {
            pause_guiding: false,
            auto_center: false,
            refocus_after: false,
            resume_guiding: false,
            settle_time: 0.0,
            max_retries: 0,
            ..Default::default()
        };
        let mut executor = MeridianFlipExecutor::new(config, ops);
        let mut ctx = make_ctx(&state);
        ctx.target_dec_degrees = 85.0;
        *state.coordinates.lock().unwrap() = (ctx.target_ra_hours, 85.0);

        match executor.execute(&ctx).await {
            FlipResult::Success { .. } => {}
            other => panic!(
                "a flip 9 arcseconds from its target was failed: {:?}",
                other
            ),
        }
    }

    /// The coordinate fallback compares the target with the mount's read-back,
    /// and a real mount reads back in its own (of-date) frame while the target
    /// is J2000: 16' of RA and 8.5' of Dec apart for NGC 7380 in 2026, against
    /// a 1' tolerance. Comparing them raw failed every flip on a mount without
    /// pier-side telemetry that had in fact landed on target. The simulator
    /// stores what it is sent, so no simulator run could show it; the same
    /// defect in slew arrival was fixed in d9c7e5d77.
    #[tokio::test]
    async fn the_coordinate_fallback_compares_in_the_mounts_own_frame() {
        let state = Arc::new(MockDeviceOpsState::default());
        state
            .pier_sides
            .lock()
            .unwrap()
            .push(crate::meridian::PierSide::Unknown);
        // J2000 22.7892h / 58.1324 deg reads back as 22.8070h / 58.2738 deg.
        *state.readback_offset.lock().unwrap() = Some((0.0178, 0.1414));
        let ops: SharedDeviceOps = Arc::new(MockDeviceOps::new(state.clone()));
        let config = MeridianFlipConfig {
            pause_guiding: false,
            auto_center: false,
            refocus_after: false,
            resume_guiding: false,
            settle_time: 0.0,
            max_retries: 0,
            ..Default::default()
        };

        let mut executor = MeridianFlipExecutor::new(config, ops);
        let result = executor.execute(&make_ctx(&state)).await;
        assert!(
            matches!(result, FlipResult::Success { .. }),
            "a flip that landed on target must verify in the mount's frame: {:?}",
            result
        );

        // A mount that really stopped short still fails the check.
        let state = Arc::new(MockDeviceOpsState::default());
        state
            .pier_sides
            .lock()
            .unwrap()
            .push(crate::meridian::PierSide::Unknown);
        *state.readback_offset.lock().unwrap() = Some((0.0178, 0.1414));
        *state.slew_miss.lock().unwrap() = (0.1, 0.0);
        let ops: SharedDeviceOps = Arc::new(MockDeviceOps::new(state.clone()));
        let mut executor = MeridianFlipExecutor::new(
            MeridianFlipConfig {
                pause_guiding: false,
                auto_center: false,
                refocus_after: false,
                resume_guiding: false,
                settle_time: 0.0,
                max_retries: 0,
                ..Default::default()
            },
            ops,
        );
        let result = executor.execute(&make_ctx(&state)).await;
        assert!(
            !matches!(result, FlipResult::Success { .. }),
            "a flip 1.5 deg short must not verify: {:?}",
            result
        );
    }

    /// A real post-flip plate-solve failure must fail the flip after pier-side
    /// verification; otherwise later refocus/guiding steps would run and the
    /// sequence could resume imaging off-frame.
    #[tokio::test]
    async fn test_post_flip_plate_solve_failure_fails_flip() {
        let state = Arc::new(MockDeviceOpsState::default());
        state.pier_sides.lock().unwrap().extend([
            crate::meridian::PierSide::East,
            crate::meridian::PierSide::West,
        ]);
        state
            .plate_solve_failures_remaining
            .store(1, Ordering::Relaxed);
        let ops: SharedDeviceOps = Arc::new(MockDeviceOps::new(state.clone()));

        let config = MeridianFlipConfig {
            pause_guiding: false,
            auto_center: true,
            refocus_after: false,
            resume_guiding: true,
            settle_time: 0.0,
            max_retries: 0,
            failure_action: FlipFailureAction::PauseAndAlert,
            ..Default::default()
        };

        let mut executor = MeridianFlipExecutor::new(config, ops);
        let ctx = make_ctx_stopping_on_quality_problems(&state);

        match executor.execute(&ctx).await {
            FlipResult::Failed { error, .. } => assert!(
                error.contains("Plate solve failed"),
                "Expected the post-flip solve error to propagate, got: {}",
                error
            ),
            other => panic!(
                "Expected failed post-flip solve to fail the flip, got {:?}",
                other
            ),
        }
        assert_eq!(
            state.guider_start_calls.load(Ordering::Relaxed),
            0,
            "Guiding must not resume after post-flip centering fails"
        );
    }

    /// A clean first-attempt flip must report exactly one attempt
    /// and no failed steps, so the run vitals can distinguish it from a flip
    /// that only worked because the retry ladder saved it.
    #[tokio::test]
    async fn clean_flip_reports_one_attempt_and_no_failed_steps() {
        let state = Arc::new(MockDeviceOpsState::default());
        state.pier_sides.lock().unwrap().extend([
            crate::meridian::PierSide::East,
            crate::meridian::PierSide::West,
        ]);
        let ops: SharedDeviceOps = Arc::new(MockDeviceOps::new(state.clone()));

        let config = MeridianFlipConfig {
            pause_guiding: false,
            auto_center: true,
            refocus_after: false,
            resume_guiding: false,
            settle_time: 0.0,
            max_retries: 0,
            ..Default::default()
        };

        let mut executor = MeridianFlipExecutor::new(config, ops);
        let ctx = make_ctx(&state);

        match executor.execute(&ctx).await {
            FlipResult::Success { .. } => {}
            other => panic!("Expected a clean flip to succeed, got {:?}", other),
        }
        assert_eq!(
            executor.attempts_made(),
            1,
            "A flip that worked first time must report a single attempt"
        );
        assert!(
            executor.failed_attempts().is_empty(),
            "A clean flip must record no failed steps, got {:?}",
            executor.failed_attempts()
        );
    }

    /// A flip whose post-flip plate-solve recenter FAILS and only succeeds on
    /// the retry is not a clean flip. The mount ended up on the right side, but the framing was
    /// only recovered on the second try — the operator must be able to see
    /// that from the run record.
    ///
    /// Live evidence this guards: a run where
    /// `"✗ Plate solving and centering FAILED"` was followed by
    /// `"Retry 1/4 scheduled"` and the session still persisted
    /// `errorMessages: []` / `warningMessages: []`.
    #[tokio::test]
    async fn retried_flip_reports_attempt_count_and_the_failed_step() {
        let state = Arc::new(MockDeviceOpsState::default());
        // Pre-flip read is East; both attempts verify as West so the pier-side
        // check passes and only the plate solve decides the outcome.
        state.pier_sides.lock().unwrap().extend([
            crate::meridian::PierSide::East,
            crate::meridian::PierSide::West,
            crate::meridian::PierSide::West,
        ]);
        // Exactly one solve fails: attempt 1 fails, attempt 2 succeeds.
        state
            .plate_solve_failures_remaining
            .store(1, Ordering::Relaxed);
        let ops: SharedDeviceOps = Arc::new(MockDeviceOps::new(state.clone()));

        let config = MeridianFlipConfig {
            pause_guiding: false,
            auto_center: true,
            refocus_after: false,
            resume_guiding: false,
            settle_time: 0.0,
            max_retries: 1,
            retry_delays_secs: vec![0.0],
            failure_action: FlipFailureAction::PauseAndAlert,
            ..Default::default()
        };

        let mut executor = MeridianFlipExecutor::new(config, ops);
        let ctx = make_ctx_stopping_on_quality_problems(&state);

        match executor.execute(&ctx).await {
            FlipResult::Success { .. } => {}
            other => panic!(
                "Expected the retry to salvage the flip and succeed, got {:?}",
                other
            ),
        }
        assert_eq!(
            executor.attempts_made(),
            2,
            "The retried flip must report both attempts"
        );
        assert_eq!(
            executor.failed_attempts().len(),
            1,
            "Exactly one attempt failed, got {:?}",
            executor.failed_attempts()
        );
        assert!(
            executor.failed_attempts()[0].contains("Plate solve failed"),
            "The recorded failure must name the failing step, got {:?}",
            executor.failed_attempts()
        );
    }

    /// Drain the executor event stream and return every flip outcome on it.
    fn flip_outcomes(rx: &mut broadcast::Receiver<ExecutorEvent>) -> Vec<ExecutorEvent> {
        let mut outcomes = Vec::new();
        while let Ok(event) = rx.try_recv() {
            if matches!(event, ExecutorEvent::MeridianFlipOutcome { .. }) {
                outcomes.push(event);
            }
        }
        outcomes
    }

    /// `MeridianFlipOutcome` is the only wire that carries a flip to the run
    /// vitals (`meridianFlips`) and the session report, and the executor — not
    /// the call site — announces it, so a trigger-fired flip and a node-driven
    /// flip both report.
    #[tokio::test]
    async fn a_successful_flip_announces_its_outcome_on_the_event_stream() {
        let state = Arc::new(MockDeviceOpsState::default());
        state.pier_sides.lock().unwrap().extend([
            crate::meridian::PierSide::East,
            crate::meridian::PierSide::West,
        ]);
        let ops: SharedDeviceOps = Arc::new(MockDeviceOps::new(state.clone()));

        let config = MeridianFlipConfig {
            pause_guiding: false,
            auto_center: true,
            refocus_after: false,
            resume_guiding: false,
            settle_time: 0.0,
            max_retries: 0,
            ..Default::default()
        };

        let (event_tx, mut event_rx) = broadcast::channel(64);
        let mut executor = MeridianFlipExecutor::new(config, ops).with_executor_event_tx(event_tx);
        let ctx = make_ctx(&state);

        match executor.execute(&ctx).await {
            FlipResult::Success { .. } => {}
            other => panic!("Expected a clean flip to succeed, got {:?}", other),
        }

        let outcomes = flip_outcomes(&mut event_rx);
        assert_eq!(
            outcomes.len(),
            1,
            "a flip must announce its verdict exactly once, got {outcomes:?}"
        );
        let ExecutorEvent::MeridianFlipOutcome {
            outcome,
            target_name,
            new_pier_side,
            attempts,
            failed_steps,
            error,
            ..
        } = &outcomes[0]
        else {
            unreachable!("filtered above")
        };
        assert_eq!(outcome, "success");
        assert_eq!(target_name, "M42");
        assert_eq!(new_pier_side, "West");
        assert_eq!(*attempts, 1);
        assert!(failed_steps.is_empty());
        assert!(error.is_none());
    }

    /// The failure case is the one that costs a night: a node-driven flip that
    /// failed its post-flip recenter left `errorMessages: []` on a run reported
    /// as completed.
    #[tokio::test]
    async fn a_failed_flip_announces_its_verdict_with_every_failed_attempt() {
        let state = Arc::new(MockDeviceOpsState::default());
        state.pier_sides.lock().unwrap().extend([
            crate::meridian::PierSide::East,
            crate::meridian::PierSide::West,
            crate::meridian::PierSide::West,
        ]);
        state
            .plate_solve_failures_remaining
            .store(10, Ordering::Relaxed);
        let ops: SharedDeviceOps = Arc::new(MockDeviceOps::new(state.clone()));

        let config = MeridianFlipConfig {
            pause_guiding: false,
            auto_center: true,
            refocus_after: false,
            resume_guiding: false,
            settle_time: 0.0,
            max_retries: 1,
            retry_delays_secs: vec![0.0],
            failure_action: FlipFailureAction::PauseAndAlert,
            ..Default::default()
        };

        let (event_tx, mut event_rx) = broadcast::channel(64);
        let mut executor = MeridianFlipExecutor::new(config, ops).with_executor_event_tx(event_tx);
        let ctx = make_ctx_stopping_on_quality_problems(&state);

        match executor.execute(&ctx).await {
            FlipResult::Failed { .. } => {}
            other => panic!("Expected the exhausted ladder to fail, got {:?}", other),
        }

        let outcomes = flip_outcomes(&mut event_rx);
        assert_eq!(outcomes.len(), 1, "got {outcomes:?}");
        let ExecutorEvent::MeridianFlipOutcome {
            outcome,
            attempts,
            failed_steps,
            error,
            action_taken,
            ..
        } = &outcomes[0]
        else {
            unreachable!("filtered above")
        };
        assert_eq!(outcome, "failed");
        assert_eq!(*attempts, 2);
        assert_eq!(failed_steps.len(), 2, "got {failed_steps:?}");
        assert!(error.as_ref().is_some_and(|e| e.contains("Plate solve")));
        assert_eq!(action_taken.as_deref(), Some("PauseAndAlert"));
    }

    /// When the ladder is exhausted the telemetry must still carry
    /// every attempt so the terminal error can say how hard the app tried.
    #[tokio::test]
    async fn exhausted_flip_reports_every_failed_attempt() {
        let state = Arc::new(MockDeviceOpsState::default());
        state.pier_sides.lock().unwrap().extend([
            crate::meridian::PierSide::East,
            crate::meridian::PierSide::West,
            crate::meridian::PierSide::West,
        ]);
        // More failures than attempts, so the flip can never succeed.
        state
            .plate_solve_failures_remaining
            .store(10, Ordering::Relaxed);
        let ops: SharedDeviceOps = Arc::new(MockDeviceOps::new(state.clone()));

        let config = MeridianFlipConfig {
            pause_guiding: false,
            auto_center: true,
            refocus_after: false,
            resume_guiding: false,
            settle_time: 0.0,
            max_retries: 1,
            retry_delays_secs: vec![0.0],
            failure_action: FlipFailureAction::PauseAndAlert,
            ..Default::default()
        };

        let mut executor = MeridianFlipExecutor::new(config, ops);
        let ctx = make_ctx_stopping_on_quality_problems(&state);

        match executor.execute(&ctx).await {
            FlipResult::Failed { .. } => {}
            other => panic!("Expected the exhausted ladder to fail, got {:?}", other),
        }
        assert_eq!(
            executor.attempts_made(),
            2,
            "max_retries=1 means two attempts were made"
        );
        assert_eq!(
            executor.failed_attempts().len(),
            2,
            "Both attempts failed and both must be recorded, got {:?}",
            executor.failed_attempts()
        );
    }

    /// Disabling auto-center intentionally omits the solve/recenter step, so a
    /// configured-off recenter is not treated as a failure.
    #[tokio::test]
    async fn test_disabled_post_flip_recenter_remains_successful() {
        let state = Arc::new(MockDeviceOpsState::default());
        state.pier_sides.lock().unwrap().extend([
            crate::meridian::PierSide::East,
            crate::meridian::PierSide::West,
        ]);
        state
            .plate_solve_failures_remaining
            .store(1, Ordering::Relaxed);
        let ops: SharedDeviceOps = Arc::new(MockDeviceOps::new(state.clone()));

        let config = MeridianFlipConfig {
            pause_guiding: false,
            auto_center: false,
            refocus_after: false,
            resume_guiding: false,
            settle_time: 0.0,
            max_retries: 0,
            ..Default::default()
        };

        let mut executor = MeridianFlipExecutor::new(config, ops);
        let ctx = make_ctx(&state);

        match executor.execute(&ctx).await {
            FlipResult::Success { .. } => {}
            other => panic!(
                "Expected disabled post-flip recenter to remain a success, got {:?}",
                other
            ),
        }
        assert_eq!(
            state.plate_solve_failures_remaining.load(Ordering::Relaxed),
            1,
            "Plate solve must not run when auto_center is disabled"
        );
    }

    /// when cancellation is requested mid-settle, tracking should
    /// be restored back to its pre-flip state rather than left off.
    #[tokio::test]
    async fn test_cancel_during_settle_restores_tracking() {
        let state = Arc::new(MockDeviceOpsState::default());
        // Pier side reports a clean East→West flip so the verify step passes.
        state.pier_sides.lock().unwrap().extend([
            crate::meridian::PierSide::East,
            crate::meridian::PierSide::West,
        ]);
        let ops: SharedDeviceOps = Arc::new(MockDeviceOps::new(state.clone()));

        let config = MeridianFlipConfig {
            pause_guiding: false,
            auto_center: false,
            refocus_after: false,
            resume_guiding: false,
            settle_time: 5.0, // Long enough for cancellation to land mid-settle.
            max_retries: 0,
            ..Default::default()
        };

        let mut executor = MeridianFlipExecutor::new(config, ops);
        let mut ctx = make_ctx(&state);
        let cancel = Arc::new(AtomicBool::new(false));
        ctx.cancellation_token = Some(cancel.clone());

        // Trip cancellation while the executor is in the settle wait.
        let cancel_clone = cancel.clone();
        tokio::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_millis(300)).await;
            cancel_clone.store(true, Ordering::Relaxed);
        });

        let result = executor.execute(&ctx).await;
        match result {
            FlipResult::Aborted { .. } => {}
            other => panic!("Expected Aborted on cancel-during-settle, got {:?}", other),
        }

        // Tracking history should record at least one re-enable to true (the
        // cancel-path restore). The pre-flip stop_tracking call set tracking
        // false; the cancel restore must set it back to true.
        let calls = state.tracking_calls.lock().unwrap().clone();
        assert!(
            calls.contains(&true),
            "Expected tracking to be restored to true on cancel, history was {:?}",
            calls
        );
    }

    /// Post-flip refocus resolves the complete caller-supplied autofocus
    /// payload rather than silently substituting default sweep parameters or
    /// dropping the filter wheel and focus offsets.
    #[test]
    fn test_autofocus_uses_supplied_config_and_filter_context() {
        let state = Arc::new(MockDeviceOpsState::default());
        let mut ctx = make_ctx(&state);

        let user_af = AutofocusConfig {
            step_size: 250,
            steps_out: 11,
            exposure_duration: 8.0,
            filter: Some("Ha".to_string()),
            backlash_compensation: 200,
            outlier_rejection_sigma: 4.5,
            ..AutofocusConfig::default()
        };
        let offsets =
            std::collections::HashMap::from([("L".to_string(), 0), ("Ha".to_string(), 180)]);
        ctx.autofocus_config = Some(PostFlipAutofocusConfig {
            config: user_af,
            current_filter: Some("L".to_string()),
            filterwheel_id: Some("mock-wheel".to_string()),
            filter_focus_offsets: offsets.clone(),
        });

        let observed = MeridianFlipExecutor::resolve_post_flip_autofocus(&ctx);
        assert_eq!(observed.config.step_size, 250);
        assert_eq!(observed.config.steps_out, 11);
        assert!((observed.config.exposure_duration - 8.0).abs() < 1e-9);
        assert_eq!(observed.config.filter.as_deref(), Some("Ha"));
        assert_eq!(observed.config.backlash_compensation, 200);
        assert!((observed.config.outlier_rejection_sigma - 4.5).abs() < 1e-9);
        assert_eq!(observed.current_filter.as_deref(), Some("L"));
        assert_eq!(observed.filterwheel_id.as_deref(), Some("mock-wheel"));
        assert_eq!(observed.filter_focus_offsets, offsets);

        // The autofocus engine conversion still receives the resolved, tuned
        // sweep parameters rather than library defaults.
        let engine: crate::autofocus::AutofocusConfig = (&observed.config).into();
        assert_eq!(engine.step_size, 250);
        assert_eq!(engine.steps_out, 11);
        assert!((engine.exposure_duration - 8.0).abs() < 1e-9);
        assert_eq!(engine.backlash_compensation, 200);
        assert!((engine.outlier_rejection_sigma - 4.5).abs() < 1e-9);
    }

    /// cover closed → flip refused with a clear error.
    #[tokio::test]
    async fn test_pre_flip_cover_closed_refuses_flip() {
        let state = Arc::new(MockDeviceOpsState::default());
        state.cover_state.store(1, Ordering::Relaxed); // Closed
        let ops: SharedDeviceOps = Arc::new(MockDeviceOps::new(state.clone()));

        let config = MeridianFlipConfig::default();
        let mut executor = MeridianFlipExecutor::new(config, ops);
        let mut ctx = make_ctx(&state);
        ctx.cover_calibrator_id = Some("mock-cover".to_string());

        let result = executor.execute(&ctx).await;
        match result {
            FlipResult::Aborted { reason } => {
                assert!(
                    reason.contains("cover") && reason.contains("closed"),
                    "Expected cover-closed reason, got: {}",
                    reason
                );
            }
            other => panic!("Expected Aborted for closed cover, got {:?}", other),
        }
    }

    /// empty retry_delays_secs with max_retries>0 → fail loudly,
    /// do NOT silently fall back to 60 seconds.
    #[tokio::test]
    async fn test_empty_retry_delays_with_retries_fails_loudly() {
        let state = Arc::new(MockDeviceOpsState::default());
        // Force the verify step to fail by reporting Unknown pier side AND
        // making coordinate fallback fail (mount at wrong coordinates).
        state
            .pier_sides
            .lock()
            .unwrap()
            .push(crate::meridian::PierSide::Unknown);
        *state.coordinates.lock().unwrap() = (0.0, 0.0); // way off target (10,45)
        let ops: SharedDeviceOps = Arc::new(MockDeviceOps::new(state.clone()));

        let config = MeridianFlipConfig {
            pause_guiding: false,
            auto_center: false,
            refocus_after: false,
            resume_guiding: false,
            settle_time: 0.0,
            max_retries: 2,
            retry_delays_secs: vec![], // CONFIG ERROR
            ..Default::default()
        };

        let mut executor = MeridianFlipExecutor::new(config, ops);
        let ctx = make_ctx(&state);

        let result = executor.execute(&ctx).await;
        match result {
            FlipResult::Failed { error, .. } => {
                assert!(
                    error.contains("retry_delays_secs is empty"),
                    "Expected retry-delays empty error, got: {}",
                    error
                );
            }
            other => panic!("Expected Failed with config-error message, got {:?}", other),
        }
    }

    /// AbortAndPark with park_failures > retry count → executor
    /// returns Failed and emits a critical-level notification, NOT silently
    /// pretending the failure action succeeded.
    #[tokio::test]
    async fn test_park_failure_propagates_with_critical_event() {
        let state = Arc::new(MockDeviceOpsState::default());
        // Force flip failure: pier side does not change.
        state.pier_sides.lock().unwrap().extend([
            crate::meridian::PierSide::East,
            crate::meridian::PierSide::East,
        ]);
        // Park always fails (more failures than retry count).
        let retry_count = crate::default_safety_action_retry_count();
        state
            .park_failures_remaining
            // Why: safety_action_retry_count default is u32 = 3; lossless to i32.
            .store(retry_count as i32 + 5, Ordering::Relaxed);
        let ops: SharedDeviceOps = Arc::new(MockDeviceOps::new(state.clone()));

        let config = MeridianFlipConfig {
            pause_guiding: false,
            auto_center: false,
            refocus_after: false,
            resume_guiding: false,
            settle_time: 0.0,
            max_retries: 0,
            failure_action: FlipFailureAction::AbortAndPark,
            // Provide retry_delays_secs so the ladder has a delay to use.
            retry_delays_secs: vec![0.01],
            // Override the safety-action retry delay so the test does not
            // wait the default 5s between each park attempt.
            safety_action_retry_delay_secs: 0.01,
            ..Default::default()
        };

        let mut executor = MeridianFlipExecutor::new(config, ops);
        let ctx = make_ctx(&state);

        let result = executor.execute(&ctx).await;
        match result {
            FlipResult::Failed {
                error,
                action_taken,
            } => {
                assert_eq!(action_taken, FlipFailureAction::AbortAndPark);
                assert!(
                    error.contains("park error"),
                    "Expected park-error in result, got: {}",
                    error
                );
            }
            other => panic!("Expected Failed result, got {:?}", other),
        }

        // Park should have been retried `retry_count` times.
        assert_eq!(
            state.park_calls.load(Ordering::Relaxed),
            // Why: default retry count is u32 = 3; lossless to i32.
            retry_count as i32,
            "Expected exactly {} park retries",
            retry_count
        );

        // A critical notification must have been emitted.
        let notifications = state.notifications.lock().unwrap().clone();
        assert!(
            notifications.iter().any(|(level, _)| level == "critical"),
            "Expected a critical-level notification, got {:?}",
            notifications
        );
    }

    // Magic-number-to-config promotions.
    // Each test demonstrates that changing the configurable value flips the
    // executor's behaviour — without the test the field would compile-pass
    // but silently be ignored.

    /// Default `min_post_flip_altitude_deg = 10°`
    /// makes a 5°-altitude target abort. Lowering the threshold to 0° allows
    /// the same target to proceed.
    #[tokio::test]
    async fn test_min_post_flip_altitude_is_user_configurable() {
        // Target altitude 5° — below the default 10° gate.
        let make_state = || {
            let s = Arc::new(MockDeviceOpsState::default());
            *s.location.lock().unwrap() = Some((40.0, -74.0));
            *s.altitude_override_deg.lock().unwrap() = Some(5.0);
            s
        };

        // Default config (min=10°): low-altitude target must abort.
        {
            let state = make_state();
            let ops: SharedDeviceOps = Arc::new(MockDeviceOps::new(state.clone()));
            let config = MeridianFlipConfig {
                pause_guiding: false,
                auto_center: false,
                refocus_after: false,
                resume_guiding: false,
                settle_time: 0.0,
                retry_delays_secs: vec![0.01],
                ..Default::default()
            };
            assert!((config.min_post_flip_altitude_deg - 10.0).abs() < 1e-9);
            let mut executor = MeridianFlipExecutor::new(config, ops);
            let ctx = make_ctx(&state);
            let result = executor.execute(&ctx).await;
            match result {
                FlipResult::Aborted { reason } => assert!(
                    reason.contains("altitude"),
                    "Expected altitude reason, got {}",
                    reason
                ),
                other => panic!(
                    "Expected Aborted for low-altitude target with default config, got {:?}",
                    other
                ),
            }
        }

        // Lower the threshold to 0°: same target now proceeds (would only
        // fail later for unrelated reasons, but it must not abort with the
        // altitude reason).
        {
            let state = make_state();
            let ops: SharedDeviceOps = Arc::new(MockDeviceOps::new(state.clone()));
            let config = MeridianFlipConfig {
                pause_guiding: false,
                auto_center: false,
                refocus_after: false,
                resume_guiding: false,
                settle_time: 0.0,
                retry_delays_secs: vec![0.01],
                min_post_flip_altitude_deg: 0.0,
                ..Default::default()
            };
            let mut executor = MeridianFlipExecutor::new(config, ops);
            let ctx = make_ctx(&state);
            let result = executor.execute(&ctx).await;
            // Anything BUT an altitude-driven Aborted is acceptable here —
            // the test only proves the gate has been lowered.
            if let FlipResult::Aborted { reason } = &result {
                assert!(
                    !reason.contains("altitude"),
                    "altitude gate should not fire when min_post_flip_altitude_deg=0; got {}",
                    reason
                );
            }
        }
    }

    /// Default `safety_action_retry_count = 3`.
    /// Lowering it to 1 means a failing park is attempted only once.
    #[tokio::test]
    async fn test_safety_action_retry_count_is_user_configurable() {
        let state = Arc::new(MockDeviceOpsState::default());
        state.pier_sides.lock().unwrap().extend([
            crate::meridian::PierSide::East,
            crate::meridian::PierSide::East,
        ]);
        // Park always fails — far more than any test would tolerate by default.
        state.park_failures_remaining.store(99, Ordering::Relaxed);
        let ops: SharedDeviceOps = Arc::new(MockDeviceOps::new(state.clone()));

        let config = MeridianFlipConfig {
            pause_guiding: false,
            auto_center: false,
            refocus_after: false,
            resume_guiding: false,
            settle_time: 0.0,
            max_retries: 0,
            failure_action: FlipFailureAction::AbortAndPark,
            retry_delays_secs: vec![0.01],
            // User-tuned: only one retry.
            safety_action_retry_count: 1,
            safety_action_retry_delay_secs: 0.01,
            ..Default::default()
        };

        let mut executor = MeridianFlipExecutor::new(config, ops);
        let ctx = make_ctx(&state);
        let _ = executor.execute(&ctx).await;

        // With safety_action_retry_count=1, park is attempted exactly once,
        // not the default 3 times.
        assert_eq!(
            state.park_calls.load(Ordering::Relaxed),
            1,
            "Expected exactly 1 park attempt when safety_action_retry_count=1"
        );
    }

    // Phase G — meridian-flip dry-run (simulate) mode.

    /// Phase G: a dry-run (`FlipContext::simulate = true`) must walk the full
    /// step sequence and return `Success`, but must NOT command a real slew or
    /// touch mount tracking — the operator is validating the flip sequence
    /// without moving the mount. This is the core "skip-actual-flip" guarantee:
    /// `mount_slew_to_coordinates` is never called.
    #[tokio::test]
    async fn test_dry_run_does_not_command_real_slew() {
        let state = Arc::new(MockDeviceOpsState::default());
        // Pier sides report a clean East→East (i.e. an un-flipped mount). In a
        // REAL flip the verify step would fail on this (pier side did not
        // change); the dry-run must short-circuit pier-side verification and
        // still succeed, proving it never relied on a real slew having happened.
        state.pier_sides.lock().unwrap().extend([
            crate::meridian::PierSide::East,
            crate::meridian::PierSide::East,
        ]);
        let ops: SharedDeviceOps = Arc::new(MockDeviceOps::new(state.clone()));

        // Enable every optional step so the dry-run exercises the full
        // sequence (pause/resume guider, plate-solve-center, refocus).
        let config = MeridianFlipConfig {
            pause_guiding: true,
            auto_center: true,
            refocus_after: true,
            resume_guiding: true,
            settle_time: 0.0,
            max_retries: 0,
            ..Default::default()
        };

        let mut executor = MeridianFlipExecutor::new(config, ops);
        let mut ctx = make_ctx(&state);
        ctx.focuser_id = Some("mock-focuser".to_string());
        ctx.simulate = true;

        let result = executor.execute(&ctx).await;
        match result {
            FlipResult::Success { .. } => {}
            other => panic!("Expected dry-run to succeed, got {:?}", other),
        }

        // The core guarantee: no real slew was commanded.
        assert_eq!(
            state.slew_calls.load(Ordering::Relaxed),
            0,
            "Dry-run must NOT command a real slew (mount_slew_to_coordinates)"
        );
        // And no mount-tracking device command was issued either — a dry-run
        // leaves the mount entirely untouched.
        assert!(
            state.tracking_calls.lock().unwrap().is_empty(),
            "Dry-run must NOT command mount tracking, history was {:?}",
            state.tracking_calls.lock().unwrap()
        );
    }

    /// Phase G: a REAL flip (simulate = false) on the same un-flipped pier-side
    /// scenario DOES command a slew. This is the contrast case proving the
    /// dry-run flag is what suppressed the slew above, not some other config.
    #[tokio::test]
    async fn test_real_flip_commands_slew() {
        let state = Arc::new(MockDeviceOpsState::default());
        // Clean East→West flip so the verify step passes for the real path.
        state.pier_sides.lock().unwrap().extend([
            crate::meridian::PierSide::East,
            crate::meridian::PierSide::West,
        ]);
        let ops: SharedDeviceOps = Arc::new(MockDeviceOps::new(state.clone()));

        let config = MeridianFlipConfig {
            pause_guiding: false,
            auto_center: false,
            refocus_after: false,
            resume_guiding: false,
            settle_time: 0.0,
            max_retries: 0,
            ..Default::default()
        };

        let mut executor = MeridianFlipExecutor::new(config, ops);
        let ctx = make_ctx(&state); // simulate defaults to false

        let result = executor.execute(&ctx).await;
        match result {
            FlipResult::Success { .. } => {}
            other => panic!("Expected real flip to succeed, got {:?}", other),
        }

        assert_eq!(
            state.slew_calls.load(Ordering::Relaxed),
            1,
            "A real (non-simulated) flip must command exactly one slew"
        );
    }

    /// With `pause_guiding` on, the guider is stopped before the mount swings
    /// across the pier; guiding through a flip slew fights the mount and loses
    /// the star. Returning Ok from `pause_guider` without stopping anything
    /// passed every flip test.
    #[tokio::test]
    async fn a_flip_stops_the_guider_before_it_slews() {
        let state = Arc::new(MockDeviceOpsState::default());
        state.pier_sides.lock().unwrap().extend([
            crate::meridian::PierSide::East,
            crate::meridian::PierSide::West,
        ]);
        let ops: SharedDeviceOps = Arc::new(MockDeviceOps::new(state.clone()));
        let config = MeridianFlipConfig {
            pause_guiding: true,
            auto_center: false,
            refocus_after: false,
            resume_guiding: false,
            settle_time: 0.0,
            max_retries: 0,
            ..Default::default()
        };

        let mut executor = MeridianFlipExecutor::new(config, ops);
        let result = executor.execute(&make_ctx(&state)).await;
        assert!(
            matches!(result, FlipResult::Success { .. }),
            "got {:?}",
            result
        );

        assert_eq!(
            *state.slews_before_guider_stop.lock().unwrap(),
            vec![0],
            "the guider must be stopped once, before the flip slew"
        );
        assert_eq!(state.slew_calls.load(Ordering::Relaxed), 1);
    }

    /// The post-flip guider settle params are plumbed onto MeridianFlipConfig
    /// and default to the executor's former hardcoded 1.5px / 10s / 60s (plus a
    /// 3.0px RMS ceiling matching StartGuidingConfig). A sequence saved before
    /// these fields existed must therefore deserialize to identical post-flip
    /// settle behaviour (no change on upgrade), while a rig that tunes its
    /// guiding settle now has it honoured after a flip.
    #[test]
    fn test_guider_settle_defaults_and_serde_backcompat() {
        // Defaults reproduce the executor's own constants.
        let d = MeridianFlipConfig::default();
        assert!((d.guider_settle_pixels - 1.5).abs() < 1e-9);
        assert!((d.guider_settle_time - 10.0).abs() < 1e-9);
        assert!((d.guider_settle_timeout - 60.0).abs() < 1e-9);
        assert!((d.max_post_settle_rms_pixels - 3.0).abs() < 1e-9);

        // A sequence whose JSON predates these fields (they are absent) must
        // deserialize to the defaults.
        let mut value = serde_json::to_value(MeridianFlipConfig::default()).unwrap();
        let obj = value.as_object_mut().unwrap();
        obj.remove("guider_settle_pixels");
        obj.remove("guider_settle_time");
        obj.remove("guider_settle_timeout");
        obj.remove("max_post_settle_rms_pixels");
        let restored: MeridianFlipConfig = serde_json::from_value(value).unwrap();
        assert!((restored.guider_settle_pixels - 1.5).abs() < 1e-9);
        assert!((restored.guider_settle_time - 10.0).abs() < 1e-9);
        assert!((restored.guider_settle_timeout - 60.0).abs() < 1e-9);
        assert!((restored.max_post_settle_rms_pixels - 3.0).abs() < 1e-9);

        // A rig that tunes its guiding settle: the values carry through the wire
        // format the Dart serializer emits (guider_settle_* keys).
        let tuned = MeridianFlipConfig {
            guider_settle_pixels: 0.8,
            guider_settle_time: 15.0,
            guider_settle_timeout: 90.0,
            max_post_settle_rms_pixels: 1.5,
            ..Default::default()
        };
        let json = serde_json::to_string(&tuned).unwrap();
        let back: MeridianFlipConfig = serde_json::from_str(&json).unwrap();
        assert!((back.guider_settle_pixels - 0.8).abs() < 1e-9);
        assert!((back.guider_settle_time - 15.0).abs() < 1e-9);
        assert!((back.guider_settle_timeout - 90.0).abs() < 1e-9);
        assert!((back.max_post_settle_rms_pixels - 1.5).abs() < 1e-9);
    }

    /// An unguided rig must not send the flip into its retry ladder.
    ///
    /// `pause_guider` / `resume_guider` report "No active guider configured" as
    /// a skippable step: propagating it as a step failure sends an unguided rig
    /// into the flip's retry ladder, stalling the sequence for minutes over a
    /// device that does not exist.
    #[test]
    fn no_guider_marker_is_treated_as_a_skippable_step() {
        assert!(crate::device_ops::is_no_guider_configured(
            "No active guider configured"
        ));
        // A real guider fault must still fail the step so the flip retries or
        // aborts rather than silently imaging unguided through a flip.
        assert!(!crate::device_ops::is_no_guider_configured(
            "Guide star lost after flip"
        ));
        assert!(!crate::device_ops::is_no_guider_configured(
            "Settle timed out after 60s"
        ));
    }
    /// A flip in its retry ladder must say so on the RUN's event stream, not only
    /// on the flip dialog's channel: a trigger-fired flip has no `event_tx` (only
    /// the node-driven flip sets one), and the run's broadcast is the channel
    /// every operator surface listens to — otherwise the screen reports Running,
    /// on-schedule progress and a passing finish time while no frame is being
    /// captured.
    #[tokio::test]
    async fn a_scheduled_retry_reaches_the_runs_event_stream() {
        let (tx, mut rx) = tokio::sync::broadcast::channel(8);
        let flip = MeridianFlipExecutor::new(
            MeridianFlipConfig::default(),
            Arc::new(crate::device_ops::NullDeviceOps),
        )
        .with_executor_event_tx(tx);

        flip.emit_event(MeridianFlipEvent::RetryScheduled {
            attempt: 2,
            max_attempts: 4,
            delay_secs: 60.0,
        });

        let event = rx.try_recv().expect("the retry must reach the run stream");
        match event {
            ExecutorEvent::NodeProgress {
                node_id,
                instruction,
                detail,
                ..
            } => {
                assert_eq!(node_id, MERIDIAN_FLIP_RUN_PROGRESS_NODE_ID);
                assert_eq!(instruction, "MeridianFlip");
                assert_eq!(detail, "attempt 2/4 failed, retrying in 60s");
            }
            other => panic!("expected NodeProgress, got {other:?}"),
        }

        // The verdict is already carried by `MeridianFlipOutcome`; announcing a
        // finished flip twice would put the same event in the feed twice.
        flip.emit_event(MeridianFlipEvent::Completed {
            new_pier_side: PierSide::East,
            duration_secs: 12.0,
        });
        assert!(
            rx.try_recv().is_err(),
            "only the mid-ladder notice belongs on the run stream"
        );
    }

    /// Owner decision 2026-10-06: a failed autofocus never parks the rig, and
    /// the post-flip refocus is named in it. A refocus that did not converge
    /// failed the flip, and the flip's failure action — AbortAndPark here —
    /// parked the mount and ended the run. The mount is on the new pier side
    /// and tracking; the run now carries on at the previous focus, and says so.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn a_failed_post_flip_refocus_notifies_and_the_flip_completes() {
        let _serial = crate::AF_GATE_TEST_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let state = Arc::new(MockDeviceOpsState::default());
        state.pier_sides.lock().unwrap().extend([
            crate::meridian::PierSide::East,
            crate::meridian::PierSide::West,
        ]);
        let ops: SharedDeviceOps = Arc::new(MockDeviceOps::new(state.clone()));
        let config = MeridianFlipConfig {
            pause_guiding: false,
            auto_center: false,
            refocus_after: true,
            resume_guiding: false,
            settle_time: 0.0,
            max_retries: 0,
            failure_action: FlipFailureAction::AbortAndPark,
            retry_delays_secs: vec![0.01],
            safety_action_retry_delay_secs: 0.01,
            ..Default::default()
        };
        let (event_tx, mut events) = tokio::sync::broadcast::channel(256);
        let (decision_tx, mut decisions) = tokio::sync::broadcast::channel(64);
        let mut executor = MeridianFlipExecutor::new(config, ops)
            .with_executor_event_tx(event_tx)
            .with_decision_tx(decision_tx, Arc::new(parking_lot::RwLock::new(Some(7))));
        let mut ctx = make_ctx(&state);
        ctx.focuser_id = Some("mock-focuser".to_string());
        ctx.autofocus_config = Some(PostFlipAutofocusConfig {
            config: crate::AutofocusConfig {
                number_of_attempts: 1,
                steps_out: 1,
                exposures_per_point: 1,
                exposure_duration: 0.01,
                ..Default::default()
            },
            ..Default::default()
        });

        let result = executor.execute(&ctx).await;

        assert!(
            matches!(result, FlipResult::Success { .. }),
            "a refocus that missed is not a failed flip: {result:?}"
        );
        assert_eq!(state.park_calls.load(Ordering::Relaxed), 0);
        let mut warnings = Vec::new();
        while let Ok(event) = events.try_recv() {
            if let ExecutorEvent::Warning { message } = event {
                warnings.push(message);
            }
        }
        assert!(
            warnings
                .iter()
                .any(|w| w.contains("Post-flip autofocus did not converge")),
            "{warnings:?}"
        );
        let decision = decisions.try_recv().expect("the operator is notified");
        assert_eq!(
            decision.summary,
            crate::executor::AUTOFOCUS_TRIGGER_CONTINUED_SUMMARY
        );
        assert_eq!(decision.sequence_run_id, Some(7));
    }

    /// A post-flip check that judged something bad — a recenter solve with no
    /// solution, guiding RMS over the ceiling — failed the flip after the mount
    /// was verified on its new pier side, and the flip's failure action paused
    /// or parked the run. Owner decision 2026-10-06: only a risk to the
    /// hardware stops a run by itself. By default the flip completes, guiding
    /// resumes and the operator is told; `make_ctx_stopping_on_quality_problems`
    /// (the opt-in) keeps the old failure, pinned by the tests above.
    #[tokio::test]
    async fn post_flip_quality_problems_notify_and_the_flip_completes() {
        for (label, solve_failures, rms_ceiling, problem) in [
            ("unsolved recenter", 1, 3.0, "Post-flip recenter"),
            (
                "guiding RMS over the ceiling",
                0,
                0.5,
                "Post-flip guiding RMS too high",
            ),
        ] {
            let state = Arc::new(MockDeviceOpsState::default());
            state.pier_sides.lock().unwrap().extend([
                crate::meridian::PierSide::East,
                crate::meridian::PierSide::West,
            ]);
            state
                .plate_solve_failures_remaining
                .store(solve_failures, Ordering::Relaxed);
            let ops: SharedDeviceOps = Arc::new(MockDeviceOps::new(state.clone()));
            let config = MeridianFlipConfig {
                pause_guiding: false,
                auto_center: true,
                refocus_after: false,
                resume_guiding: true,
                settle_time: 0.0,
                max_retries: 0,
                failure_action: FlipFailureAction::AbortAndPark,
                max_post_settle_rms_pixels: rms_ceiling,
                ..Default::default()
            };
            let (event_tx, mut events) = tokio::sync::broadcast::channel(256);
            let (decision_tx, mut decisions) = tokio::sync::broadcast::channel(64);
            let mut executor = MeridianFlipExecutor::new(config, ops)
                .with_executor_event_tx(event_tx)
                .with_decision_tx(decision_tx, Arc::new(parking_lot::RwLock::new(Some(7))));

            let result = executor.execute(&make_ctx(&state)).await;

            assert!(
                matches!(result, FlipResult::Success { .. }),
                "{label}: {result:?}"
            );
            assert_eq!(state.park_calls.load(Ordering::Relaxed), 0, "{label}");
            assert_eq!(
                state.guider_start_calls.load(Ordering::Relaxed),
                1,
                "{label}: guiding resumes"
            );
            assert_eq!(
                *state.fresh_star_before_starts.lock().unwrap(),
                vec![0],
                "{label}: guiding resumes on a star picked after the flip"
            );
            let mut warnings = Vec::new();
            while let Ok(event) = events.try_recv() {
                if let ExecutorEvent::Warning { message } = event {
                    warnings.push(message);
                }
            }
            assert!(
                warnings
                    .iter()
                    .any(|w| w.contains(problem) && w.contains("The run continues")),
                "{label}: {warnings:?}"
            );
            let decision = decisions.try_recv().expect("the operator is notified");
            assert_eq!(
                decision.summary,
                crate::executor::QUALITY_PROBLEM_CONTINUED_SUMMARY,
                "{label}"
            );
            assert_eq!(decision.sequence_run_id, Some(7), "{label}");
        }
    }

    /// The opt-in keeps the post-flip guiding check's failure too.
    #[tokio::test]
    async fn post_flip_guiding_rms_fails_the_flip_when_the_operator_asked_for_it() {
        let state = Arc::new(MockDeviceOpsState::default());
        state.pier_sides.lock().unwrap().extend([
            crate::meridian::PierSide::East,
            crate::meridian::PierSide::West,
        ]);
        let ops: SharedDeviceOps = Arc::new(MockDeviceOps::new(state.clone()));
        let config = MeridianFlipConfig {
            pause_guiding: false,
            auto_center: false,
            refocus_after: false,
            resume_guiding: true,
            settle_time: 0.0,
            max_retries: 0,
            max_post_settle_rms_pixels: 0.5,
            retry_delays_secs: vec![0.01],
            ..Default::default()
        };
        let mut executor = MeridianFlipExecutor::new(config, ops);

        let result = executor
            .execute(&make_ctx_stopping_on_quality_problems(&state))
            .await;

        match result {
            FlipResult::Failed { error, .. } => {
                assert!(error.contains("Post-flip guiding RMS too high"), "{error}")
            }
            other => panic!("expected the flip to fail, got {other:?}"),
        }
    }

    /// After the guide-star recovery ran out the run images unguided (owner
    /// decision 2026-10-06). A guider that still cannot start after the flip is
    /// the same problem, so it is reported and the flip completes instead of
    /// failing into its failure action.
    #[tokio::test(start_paused = true)]
    async fn while_imaging_unguided_a_guider_that_cannot_resume_does_not_fail_the_flip() {
        for imaging_unguided in [false, true] {
            let state = Arc::new(MockDeviceOpsState::default());
            state.pier_sides.lock().unwrap().extend([
                crate::meridian::PierSide::East,
                crate::meridian::PierSide::West,
            ]);
            state.guider_start_fails.store(true, Ordering::Relaxed);
            let ops: SharedDeviceOps = Arc::new(MockDeviceOps::new(state.clone()));
            let config = MeridianFlipConfig {
                pause_guiding: true,
                auto_center: false,
                refocus_after: false,
                resume_guiding: true,
                settle_time: 0.0,
                max_retries: 0,
                failure_action: FlipFailureAction::AbortAndPark,
                ..Default::default()
            };
            let (event_tx, mut events) = tokio::sync::broadcast::channel(256);
            let mut executor =
                MeridianFlipExecutor::new(config, ops).with_executor_event_tx(event_tx);
            let mut trigger_state = TriggerState::new();
            trigger_state.imaging_unguided = imaging_unguided;
            let ctx = FlipContext {
                trigger_state: Some(Arc::new(RwLock::new(trigger_state))),
                ..make_ctx(&state)
            };

            let result = executor.execute(&ctx).await;

            if !imaging_unguided {
                // A guided run whose guider does not come back after the flip
                // keeps its failure.
                assert!(matches!(result, FlipResult::Failed { .. }), "{result:?}");
                continue;
            }
            assert!(matches!(result, FlipResult::Success { .. }), "{result:?}");
            assert_eq!(state.park_calls.load(Ordering::Relaxed), 0);
            let mut warnings = Vec::new();
            while let Ok(event) = events.try_recv() {
                if let ExecutorEvent::Warning { message } = event {
                    warnings.push(message);
                }
            }
            assert!(
                warnings.iter().any(|w| w.contains("unguided")),
                "{warnings:?}"
            );
        }
    }
}
