//! Per-run trigger preparation: clear the previous run's latches, disarm the
//! triggers this run's hardware cannot act on, carry the settings onto the
//! reset trigger state, and read the sequence's own autofocus tuning.

use super::*;

impl SequenceExecutor {
    pub(super) async fn prepare_run_triggers(&mut self) {
        // Per-run trigger hygiene. `TriggerManager` (and its `TriggerState`) are
        // built once in `SequenceExecutor::new()` and live for the whole process,
        // so without this every latch set by run N is still set when run N+1
        // starts. Observed on the live rig: run 1 selected "Filter 2" and left
        // `autofocus_invalidated` set; run 2 — a different sequence selecting
        // "Filter 4" — force-fired the HFR trigger one second after start with
        // the reason `filter changed to Filter 2`.
        //
        // Then disarm the standard autofocus-action triggers when this run has
        // no focuser. A filter or target change invalidates the autofocus state,
        // which makes the HFR trigger fire unconditionally on the next tick;
        // with no focuser the executor's Autofocus arm cannot act, and it used
        // to answer by pausing the run indefinitely (`Execution paused at
        // boundary, waiting for resume...`) while `/api/sequencer/status` kept
        // reporting `running`. Reproduced end to end: a two-node sequence
        // (change filter, then expose) hung forever on the filter node, with no
        // frames and no terminal event, on a rig whose focuser was simply not
        // connected.
        {
            let mut manager = self.trigger_manager.write().await;
            if !self.resume_prepared {
                // A run that is not the resume `resume_from_checkpoint`
                // prepared is a fresh start, whatever the trigger state was
                // restored from earlier in this launch.
                manager.state().write().await.restored_from_checkpoint = false;
            }
            manager.reset_for_new_run().await;
<<<<<<< HEAD
            self.settings.project_at_start(&mut manager).await;
=======
            let dither = crate::GuiderSettle::from(&self.runtime_config.read().dither);
            let guiding = manager
                .meridian_flip_config()
                .map(crate::GuiderSettle::from);
            let state_lock = manager.state();
            let mut state = state_lock.write().await;
            state.settings.dither_settle = dither;
            state.settings.guiding_settle = guiding;
            // A run starts at the site the executor holds now. The trigger
            // state kept the last run's site and its cached dawn, so a site
            // changed between runs still ended the next run at the old
            // site's dawn.
            if self.latitude.is_some() && self.longitude.is_some() {
                state.set_observer_location(self.latitude, self.longitude);
            }
>>>>>>> 9aab79a51 (Split TriggerState into parts; reset and checkpoint follow from the part)
        }
        if self.focuser_id.is_none() {
            let disarmed = {
                let mut manager = self.trigger_manager.write().await;
                manager.disarm_autofocus_triggers()
            };
            if !disarmed.is_empty() {
                tracing::warn!(
                    "No focuser is configured for this run; disarming autofocus-action \
                 triggers [{}]. Focus drift will NOT be corrected automatically — \
                 connect a focuser to re-enable trigger-driven refocus.",
                    disarmed.join(", ")
                );
            }
        }

<<<<<<< HEAD
        // The sequence's own autofocus tuning, for trigger-fired refocus when
        // the operator's settings were never pushed.
        let node_af = self
            .root_node
            .as_ref()
            .and_then(|root| find_first_autofocus_config(&**root));
        if self.settings.read().autofocus.is_none() {
            match &node_af {
                Some(node_af) => tracing::info!(
                    "Trigger-fired refocus uses the sequence's Autofocus node tuning \
=======
        // if the runtime config has a user-supplied
        // autofocus-interval cadence, push it into the seeded standard
        // trigger before the trigger-monitor task picks up its snapshot.
        // Without this, a value set via the equipment-profile UI before
        // start() would only take effect on the next start().
        {
            let override_value = {
                let rc = self.runtime_config.read();
                rc.autofocus_interval_frames
            };
            if let Some(every_n_frames) = override_value {
                let mut mgr = self.trigger_manager.write().await;
                if let Some(trigger) =
                    mgr.standard_mut(crate::triggers::StandardTrigger::AutofocusInterval)
                {
                    if let TriggerType::AutofocusInterval {
                        every_n_frames: live,
                    } = &mut trigger.trigger_type
                    {
                        *live = every_n_frames;
                    }
                }
            }
        }

        // Seed the trigger-driven autofocus config from the sequence's first
        // Autofocus node, so trigger-fired refocus (HFR / temperature /
        // focus-drift / interval) uses the operator's step size / exposure /
        // backlash / method rather than `AutofocusConfig::default()`. The
        // Autofocus node carries the real tuning (the Dart layer builds it from
        // the equipment profile). Only seed when a runtime command has not
        // already set it, so an explicit operator override wins.
        {
            let already_set = self.runtime_config.read().autofocus.is_some();
            if !already_set {
                if let Some(node_af) = self
                    .root_node
                    .as_ref()
                    .and_then(|root| find_first_autofocus_config(&**root))
                {
                    tracing::info!(
                        "Seeded trigger autofocus config from sequence Autofocus node \
>>>>>>> 9aab79a51 (Split TriggerState into parts; reset and checkpoint follow from the part)
                     (method={:?}, step_size={}, steps_out={}, exposure={}s, backlash={})",
                    node_af.method,
                    node_af.step_size,
                    node_af.steps_out,
                    node_af.exposure_duration,
                    node_af.backlash_compensation,
                ),
                None => tracing::warn!(
                    "No Autofocus node in the sequence to seed trigger-autofocus tuning; \
                     trigger-fired refocus will use library defaults. Add an Autofocus \
                     instruction (or push a profile AF config) so triggers use your real \
                     step size / exposure / backlash."
                ),
            }
        }
        self.settings.set_sequence_autofocus(node_af);

        // surface trigger-creation-time clamp diagnostics
        // (e.g. FocusDrift.window_size > FOCUS_DRIFT_WINDOW_MAX) as
        // user-visible errors on the run dashboard. The clamping itself
        // happens silently inside `Trigger::new` during standard-trigger
        // seeding and sequence load; emitting once per Start is enough for
        // the user to see and fix the configuration.
        {
            let mgr = self.trigger_manager.read().await;
            for trigger in mgr.triggers() {
                if let Some(warning) = &trigger.clamp_warning {
                    let msg = format!(
                        "Trigger '{}' ({}) clamped: {} was {}; clamped to maximum {}. \
                     Reduce {} in the trigger configuration to silence this warning.",
                        trigger.name,
                        trigger.id,
                        warning.field,
                        warning.original,
                        warning.clamped_to,
                        warning.field,
                    );
                    // A clamp is an advisory about configuration, not a run
                    // failure: the trigger is armed, just at the maximum
                    // instead of the number that was typed. It rode
                    // `ExecutorEvent::Error` only because no warning channel
                    // existed, which filed it under a red "Errors" heading in
                    // the Session Report of runs that completed.
                    self.run_state.emit(ExecutorEvent::Warning { message: msg });
                }
            }
        }
    }
}
