//! [`TriggerManager`] — the collection of active triggers and its tick.

use super::{StandardTrigger, Trigger, TriggerOrigin, TriggerState};
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
    origin: TriggerOrigin,
    action: RecoveryAction,
}

impl Firing {
    pub fn trigger_id(&self) -> &str {
        &self.trigger_id
    }

    pub fn origin(&self) -> TriggerOrigin {
        self.origin
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

    pub fn state(&self) -> Arc<RwLock<TriggerState>> {
        self.state.clone()
    }

    pub fn add_trigger(&mut self, trigger: Trigger) {
        self.triggers.push(trigger);
    }

    pub fn remove_trigger(&mut self, id: &str) {
        self.triggers.retain(|t| t.id != id);
    }

    pub fn get_trigger(&self, id: &str) -> Option<&Trigger> {
        self.triggers.iter().find(|t| t.id == id)
    }

    pub fn get_trigger_mut(&mut self, id: &str) -> Option<&mut Trigger> {
        self.triggers.iter_mut().find(|t| t.id == id)
    }

    /// A standard trigger, when it is armed.
    pub fn standard(&self, trigger: StandardTrigger) -> Option<&Trigger> {
        self.get_trigger(trigger.id())
    }

    pub fn standard_mut(&mut self, trigger: StandardTrigger) -> Option<&mut Trigger> {
        self.get_trigger_mut(trigger.id())
    }

    /// The meridian-flip trigger's config, when one is registered.
    pub fn meridian_flip_config(&self) -> Option<&crate::MeridianFlipConfig> {
        self.standard(StandardTrigger::MeridianFlip)
            .and_then(|t| match &t.trigger_type {
                TriggerType::MeridianFlip { config } => Some(config),
                _ => None,
            })
    }

    /// Apply the operator's meridian-flip settings to the standard flip
    /// trigger: both its condition (when to fire) and its action (how the
    /// flip runs), so the threshold and the step sequence cannot drift apart.
    /// Without this a trigger-driven flip runs on the built-in defaults.
    ///
    /// Returns `true` when the trigger was found and updated.
    pub fn set_meridian_flip_config(&mut self, config: crate::MeridianFlipConfig) -> bool {
        let Some(trigger) = self.standard_mut(StandardTrigger::MeridianFlip) else {
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
            if trigger.origin().is_recovery_node() {
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
                && state.latches.autofocus_hold.is_some()
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
                    origin: trigger.origin(),
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
            self.state.write().await.latches.autofocus_wanted_while_held = true;
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
            state.trigger_config.guiding_rms_retention_secs != secs
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
            if state.trigger_config.meridian_trigger_method != meridian_method {
                state.trigger_config.meridian_trigger_method = meridian_method;
            }
            if state.trigger_config.meridian_flip_minutes_past != meridian_minutes {
                state.trigger_config.meridian_flip_minutes_past = meridian_minutes;
            }
            if state.trigger_config.meridian_pause_before_minutes != meridian_pause_before {
                state.trigger_config.meridian_pause_before_minutes = meridian_pause_before;
            }
        }
    }

    /// Arm every standard trigger with its defaults.
    pub fn create_standard_triggers(&mut self) {
        for trigger in StandardTrigger::ALL {
            self.add_trigger(trigger.build());
        }
    }
}

impl Default for TriggerManager {
    fn default() -> Self {
        Self::new()
    }
}
