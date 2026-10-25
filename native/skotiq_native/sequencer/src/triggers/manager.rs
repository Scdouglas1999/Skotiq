//! [`TriggerManager`] — the collection of active triggers and its tick.

use super::{Trigger, TriggerState};
use crate::{RecoveryAction, TriggerType};
use std::sync::Arc;
use tokio::sync::RwLock;

/// A trigger whose condition held on one evaluation.
///
/// Its cooldown starts only when the firing is handed to
/// [`TriggerManager::dispatch`]; a firing that is dropped instead leaves the
/// trigger armed, so it fires again on the next tick.
#[derive(Debug, Clone)]
#[must_use = "a firing that is neither dispatched nor deliberately dropped is lost"]
pub struct Firing {
    trigger_id: String,
    action: RecoveryAction,
}

impl Firing {
    pub fn trigger_id(&self) -> &str {
        &self.trigger_id
    }

    /// The trigger's configured action, before the operator's park and
    /// quality settings are applied.
    pub fn action(&self) -> &RecoveryAction {
        &self.action
    }
}

/// Manager for all active triggers
pub struct TriggerManager {
    triggers: Vec<Trigger>,
    state: Arc<RwLock<TriggerState>>,
    enabled: bool,
}

impl TriggerManager {
    pub fn new() -> Self {
        Self {
            triggers: Vec::new(),
            state: Arc::new(RwLock::new(TriggerState::new())),
            enabled: true,
        }
    }

    /// Get the trigger state for updates
    pub fn state(&self) -> Arc<RwLock<TriggerState>> {
        self.state.clone()
    }

    /// Add a trigger
    pub fn add_trigger(&mut self, trigger: Trigger) {
        self.triggers.push(trigger);
    }

    /// Remove a trigger by ID
    pub fn remove_trigger(&mut self, id: &str) {
        self.triggers.retain(|t| t.id != id);
    }

    /// Get a trigger by ID
    pub fn get_trigger(&self, id: &str) -> Option<&Trigger> {
        self.triggers.iter().find(|t| t.id == id)
    }

    /// Get mutable trigger by ID
    pub fn get_trigger_mut(&mut self, id: &str) -> Option<&mut Trigger> {
        self.triggers.iter_mut().find(|t| t.id == id)
    }

    /// Apply the operator's meridian-flip settings to the standard
    /// `meridian_flip` trigger.
    ///
    /// `create_standard_triggers` seeds that trigger with
    /// `MeridianFlipConfig::default()`, so without this every trigger-driven flip
    /// runs on Rust defaults and the Settings → Meridian Flip panel is inert for
    /// the path that fires on a real night. Both the trigger's own config (which
    /// decides WHEN to fire) and the recovery action's config (which decides HOW
    /// the flip runs) are updated, so the threshold and the step sequence cannot
    /// drift apart.
    ///
    /// Returns `true` when the trigger was found and updated.
    pub fn set_meridian_flip_config(&mut self, config: crate::MeridianFlipConfig) -> bool {
        let Some(trigger) = self.get_trigger_mut("meridian_flip") else {
            return false;
        };
        if let TriggerType::MeridianFlip { config: existing } = &mut trigger.trigger_type {
            *existing = config.clone();
        }
        if let RecoveryAction::MeridianFlip(existing) = &mut trigger.recovery_action {
            *existing = config;
        }
        true
    }

    /// Start a run with no state left over from the previous one: the shared
    /// trigger state (see [`TriggerState::reset_for_new_run`]) and every
    /// trigger's own cooldown and counters.
    pub async fn reset_for_new_run(&mut self) {
        self.state.write().await.reset_for_new_run();
        for trigger in &mut self.triggers {
            trigger.reset_for_new_run();
        }
    }

    /// Dispatch a firing: start its trigger's cooldown and return the
    /// trigger, or `None` when it was removed since the evaluation.
    pub fn dispatch(&mut self, firing: Firing) -> Option<&Trigger> {
        let trigger = self.get_trigger_mut(&firing.trigger_id)?;
        trigger.start_cooldown();
        Some(trigger)
    }

    /// Enable/disable a trigger
    pub fn set_trigger_enabled(&mut self, id: &str, enabled: bool) {
        if let Some(trigger) = self.triggers.iter_mut().find(|t| t.id == id) {
            trigger.enabled = enabled;
        }
    }

    /// Enable/disable all triggers
    pub fn set_all_enabled(&mut self, enabled: bool) {
        self.enabled = enabled;
    }

    /// Disarm every trigger whose recovery action is an autofocus run.
    /// Returns the ids that were disarmed.
    ///
    /// Called at `start()` when the run has no focuser. An autofocus action is
    /// physically impossible without one, so leaving those triggers armed can
    /// only produce untruth: the HFR trigger force-fires on any filter/target
    /// change (see [`TriggerState::invalidate_autofocus`]), the operator's
    /// decision log records "HFR Degradation fired -> Autofocus" for a run that
    /// never graded a frame, and the executor's Autofocus arm has no device to
    /// act on.
    ///
    /// Only the standard/global triggers are disarmed; per-sequence Recovery
    /// nodes keep whatever the operator authored (they carry their own
    /// user-visible failure reporting).
    pub fn disarm_autofocus_triggers(&mut self) -> Vec<String> {
        let mut disarmed = Vec::new();
        for trigger in &mut self.triggers {
            if trigger
                .id
                .starts_with(crate::executor::RECOVERY_NODE_TRIGGER_PREFIX)
            {
                continue;
            }
            if matches!(trigger.recovery_action, RecoveryAction::Autofocus) && trigger.enabled {
                trigger.enabled = false;
                disarmed.push(trigger.id.clone());
            }
        }
        disarmed
    }

    /// The enabled flip controller, including the manager's master switch.
    pub(crate) fn active_meridian_flip_config(&self) -> Option<crate::MeridianFlipConfig> {
        if !self.enabled {
            return None;
        }
        self.triggers.iter().find_map(|trigger| {
            if !trigger.enabled {
                return None;
            }
            match (&trigger.trigger_type, &trigger.recovery_action) {
                (TriggerType::MeridianFlip { config }, RecoveryAction::MeridianFlip(_)) => {
                    Some(config.clone())
                }
                _ => None,
            }
        })
    }

    /// Get all triggers
    pub fn triggers(&self) -> &[Trigger] {
        &self.triggers
    }

    /// Evaluate every trigger and return the ones that fired. Nothing here
    /// starts a cooldown; see [`Firing`]. While
    /// [`TriggerState::autofocus_hold`] is set an autofocus trigger that comes
    /// due is held back and fires on the first evaluation after the hold
    /// ends.
    pub async fn check_all(&mut self) -> Vec<Firing> {
        if !self.enabled {
            return Vec::new();
        }

        // propagate per-trigger retention/configuration into the
        // shared trigger state before evaluation so updates to e.g.
        // `GuidingFailed::rms_retention_secs` take effect on the next sample
        // without requiring a sequence reload.
        self.sync_state_from_config().await;

        // Clone the state once before the loop
        let state = self.state.read().await.clone();
        let mut fired = Vec::new();

        let mut filter_change_fired = false;
        let mut autofocus_held = false;
        for trigger in &mut self.triggers {
            let mut firing = trigger.check(&state).await;
            if firing
                && state.autofocus_hold.is_some()
                && matches!(trigger.recovery_action, RecoveryAction::Autofocus)
            {
                autofocus_held = true;
                firing = false;
            }
            let newly_firing = firing && !trigger.was_firing;
            trigger.was_firing = firing;
            if firing {
                // A level-type trigger with no cooldown stays due until its
                // action runs, which under a hold it never does. Warn on the
                // edge only; the dispatcher logs every firing it acts on.
                if newly_firing {
                    // A trigger whose action is Continue only marks a routine
                    // event (a filter change); it is not a warning.
                    if matches!(trigger.recovery_action, RecoveryAction::Continue) {
                        tracing::debug!("Trigger fired: {} ({})", trigger.name, trigger.id);
                    } else {
                        tracing::warn!("Trigger fired: {} ({})", trigger.name, trigger.id);
                    }
                } else {
                    tracing::trace!("Trigger still firing: {} ({})", trigger.name, trigger.id);
                }
                if matches!(trigger.trigger_type, TriggerType::FilterChange) {
                    filter_change_fired = true;
                }
                fired.push(Firing {
                    trigger_id: trigger.id.clone(),
                    action: trigger.recovery_action.clone(),
                });
            }
        }

        // `filter_changed` is an edge stored as a level: consume it once it has
        // been delivered, or a zero-cooldown FilterChange trigger re-fires on
        // every tick. After the loop, so every trigger saw the same snapshot.
        if filter_change_fired {
            self.state.write().await.clear_filter_changed();
        }
        if autofocus_held {
            self.state.write().await.autofocus_wanted_while_held = true;
        }

        fired
    }

    /// copy configurable runtime values from each trigger's
    /// config into the shared `TriggerState`. Currently only
    /// `GuidingFailed::rms_retention_secs` requires propagation; new
    /// configurable retention windows added in future audits should be
    /// wired here so the trigger evaluator never needs to mutate state
    /// behind an immutable borrow.
    pub async fn sync_state_from_config(&self) {
        let mut retention: Option<u64> = None;
        let mut meridian_method: Option<crate::MeridianTriggerMethod> = None;
        let mut meridian_minutes: Option<f64> = None;
        let mut meridian_pause_before: Option<f64> = None;
        for trigger in &self.triggers {
            if !trigger.enabled {
                continue;
            }
            if let TriggerType::GuidingFailed {
                rms_retention_secs, ..
            } = &trigger.trigger_type
            {
                if retention.is_none() {
                    retention = Some(*rms_retention_secs);
                }
            }
            // Stamp the active flip trigger's method + threshold so (a) the
            // MountTrackingLost evaluator's defer-to-OnTrackingLimitHit
            // heuristic sees the configured method and (b) the exposure
            // instruction's pre-frame meridian gate can predict when the flip
            // will fire.
            if let TriggerType::MeridianFlip { config } = &trigger.trigger_type {
                if meridian_method.is_none() {
                    meridian_method = Some(config.trigger_method);
                    if config.trigger_method == crate::MeridianTriggerMethod::MinutesPastMeridian {
                        meridian_minutes = Some(config.minutes_past_meridian);
                        meridian_pause_before = Some(config.pause_before_meridian_minutes)
                            .filter(|minutes| minutes.is_finite() && *minutes > 0.0);
                    }
                }
            }
        }
        let retention_changed = if let Some(secs) = retention {
            let state = self.state.read().await;
            state.guiding_rms_retention_secs != secs
        } else {
            false
        };
        {
            let mut state = self.state.write().await;
            if retention_changed {
                if let Some(secs) = retention {
                    state.set_guiding_rms_retention_secs(secs);
                }
            }
            if state.meridian_trigger_method != meridian_method {
                state.meridian_trigger_method = meridian_method;
            }
            if state.meridian_flip_minutes_past != meridian_minutes {
                state.meridian_flip_minutes_past = meridian_minutes;
            }
            if state.meridian_pause_before_minutes != meridian_pause_before {
                state.meridian_pause_before_minutes = meridian_pause_before;
            }
        }
    }

    /// Create standard triggers
    pub fn create_standard_triggers(&mut self) {
        // HFR degradation trigger
        self.add_trigger(
            Trigger::new(
                "hfr_degraded",
                "HFR Degradation",
                TriggerType::HfrDegraded {
                    threshold_percent: 20.0,
                    absolute_threshold: 0.0,
                    consecutive_frames: 3,
                },
                RecoveryAction::Autofocus,
            )
            // 5 min cooldown: an autofocus run takes 2-4 min on typical rigs,
            // so a shorter cooldown would re-fire before the previous AF could
            // settle the HFR baseline and would loop AF indefinitely.
            .with_cooldown(300),
        );

        // Meridian flip trigger - uses MeridianFlip recovery action
        self.add_trigger(
            Trigger::new(
                "meridian_flip",
                "Meridian Flip",
                TriggerType::MeridianFlip {
                    config: crate::MeridianFlipConfig::default(),
                },
                RecoveryAction::MeridianFlip(crate::MeridianFlipConfig::default()),
            )
            // A meridian flip + re-center + refocus takes 5-8 min; 10 min
            // cooldown is the structural guarantee against the double-flip
            // bug fixed at the state-machine level.
            .with_cooldown(600),
        );

        // Guiding failure trigger
        self.add_trigger(
            Trigger::new(
                "guiding_failed",
                "Guiding Failure",
                TriggerType::GuidingFailed {
                    rms_threshold: 2.0,
                    duration_secs: 30.0,
                    // 300s preserves the previous hardcoded
                    // retention; users can change it via UI/profile JSON.
                    rms_retention_secs: crate::default_guiding_rms_retention_secs(),
                },
                RecoveryAction::Retry { max_attempts: 3 },
            )
            .with_cooldown(60),
        );

        // Altitude limit trigger
        self.add_trigger(
            Trigger::new(
                "altitude_limit",
                "Altitude Limit",
                TriggerType::AltitudeLimit { min_altitude: 30.0 },
                RecoveryAction::NextTarget,
            )
            .with_cooldown(60),
        );

        // Weather safety trigger
        self.add_trigger(
            Trigger::new(
                "weather_unsafe",
                "Weather Unsafe",
                TriggerType::WeatherUnsafe,
                RecoveryAction::ParkAndAbort,
            )
            // Weather safety must re-fire every poll while conditions are
            // unsafe — a cooldown could mask a brief moment of clearance
            // followed by re-degradation, letting the sequence resume into
            // worsening conditions.
            .with_cooldown(0),
        );

        // Temperature shift trigger
        self.add_trigger(
            Trigger::new(
                "temperature_shift",
                "Temperature Shift",
                TriggerType::TemperatureShift { degrees: 2.0 },
                RecoveryAction::Autofocus,
            )
            .with_cooldown(600),
        );

        // Filter change trigger (for focus offsets)
        self.add_trigger(
            Trigger::new(
                "filter_change",
                "Filter Change",
                TriggerType::FilterChange,
                RecoveryAction::Continue, // Handle via filter focus offsets
            )
            .with_cooldown(0),
        );

        // Dawn approaching trigger (automatic morning shutdown)
        self.add_trigger(
            Trigger::new(
                "dawn_approaching",
                "Dawn Approaching",
                TriggerType::DawnApproaching {
                    minutes_before: 30.0,
                }, // 30 min before astronomical twilight
                RecoveryAction::ParkAndAbort,
            )
            .with_cooldown(0), // No cooldown for safety
        );

        // Mount tracking lost trigger
        self.add_trigger(
            Trigger::new(
                "mount_tracking_lost",
                "Mount Tracking Lost",
                TriggerType::MountTrackingLost,
                RecoveryAction::Pause,
            )
            .with_cooldown(60), // 60 second cooldown
        );

        // Dome shutter not open trigger
        self.add_trigger(
            Trigger::new(
                "dome_shutter_not_open",
                "Dome Shutter Not Open",
                TriggerType::DomeShutterNotOpen,
                RecoveryAction::ParkAndAbort,
            )
            .with_cooldown(0), // No cooldown for safety
        );

        // Guide star lost trigger
        self.add_trigger(
            Trigger::new(
                "guide_star_lost",
                "Guide Star Lost",
                TriggerType::GuideStarLost,
                RecoveryAction::Pause,
            )
            .with_cooldown(30), // 30 second cooldown
        );

        // Focus drift detection trigger.
        // defaults pulled from the shared
        // `default_focus_drift_*` helpers so config loaders and this builder
        // cannot diverge.
        self.add_trigger(
            Trigger::new(
                "focus_drift",
                "Focus Drift",
                TriggerType::FocusDrift {
                    window_size: crate::default_focus_drift_window_size(),
                    min_increasing_count: crate::default_focus_drift_min_increasing_count(),
                    min_total_increase: crate::default_focus_drift_min_total_increase(),
                },
                RecoveryAction::Autofocus,
            )
            .with_cooldown(600), // 10 minute cooldown (same as temperature shift)
        );

        // Humidity threshold: the ceiling has exactly ONE definition — the Dart
        // `maxHumidityPercent` → `WeatherThresholdEvaluator` → pushed verdict →
        // `WeatherUnsafe` trigger, which maps to `RecoveryCause::WeatherUnsafe`.
        // No standard humidity trigger is auto-added here: a hardcoded
        // `max_percent` would be a second, divergent gate that judges the same
        // reading differently from the operator's setting. The `HumidityThreshold`
        // trigger TYPE remains available for an explicitly added per-sequence node
        // with its own threshold and recovery action. See
        // `weather_threshold_evaluator.dart` and the parity test.

        // plate-solve drift trigger. Default 30 px is a pragmatic
        // mid-range value: small enough to catch real drift before it becomes
        // image-ruining, large enough to ignore single-pixel jitter from
        // imperfect plate-solve solutions. Recovery is `Recenter`, not Pause,
        // so the sequence keeps imaging.
        self.add_trigger(
            Trigger::new(
                "drift_limit",
                "Plate-Solve Drift Limit",
                TriggerType::DriftLimit { max_pixels: 30.0 },
                RecoveryAction::Recenter,
            )
            .with_cooldown(120), // 2 min cooldown so a single recenter is given time to settle
        );

        // standard `DitherInterval` trigger so periodic dithering
        // happens in sequences that don't include an explicit Dither node.
        // Default cadence 5 frames matches typical mosaic guidance. Recovery
        // is `Dither(default config)`; users override via UI/profile JSON.
        self.add_trigger(
            Trigger::new(
                "dither_interval",
                "Dither Interval",
                TriggerType::DitherInterval { every_n_frames: 5 },
                RecoveryAction::Dither(crate::DitherConfig::default()),
            )
            .with_cooldown(0), // Cadence is exposure-count-driven; no time-based cooldown.
        );

        // Standard `AutofocusInterval` trigger so periodic refocus happens in
        // sequences that lack an explicit Autofocus node between bursts. Wired
        // symmetrically with `DitherInterval` so disabling either is
        // straightforward.
        //
        // Default cadence `default_autofocus_interval_frames()` (25 frames)
        // matches typical "AF every ~30 min" for 60-90 s subs. Users override
        // via UI/profile JSON. Recovery is `Autofocus` so the trigger-monitor
        // dispatch reaches `execute_autofocus` with the live device IDs.
        //
        // No time-based cooldown: the cadence is already exposure-count driven,
        // and a duplicate cooldown would mask the user's setting.
        self.add_trigger(
            Trigger::new(
                "autofocus_interval",
                "Autofocus Interval",
                TriggerType::AutofocusInterval {
                    every_n_frames: crate::default_autofocus_interval_frames(),
                },
                RecoveryAction::Autofocus,
            )
            .with_cooldown(0),
        );
    }
}

impl Default for TriggerManager {
    fn default() -> Self {
        Self::new()
    }
}
