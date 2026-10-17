//! Pre-start configuration and wire-up surface on the [`SequenceExecutor`].
//!
//! Everything here is one of two things:
//!
//!   1. A `set_*` setter the bridge / tests call between `new()` and
//!      `start()` to wire device ids, safety policy, save paths, trigger
//!      gating, and the per-run event subscription handle into the
//!      executor. These methods MUST be cheap and non-blocking — the
//!      bridge calls a dozen of them in sequence right before `start()`.
//!   2. The post-run teardown (`reset`) that the bridge calls to flip an
//!      executor back to `Idle` after a sequence finishes, so the next
//!      `start()` begins from a known-empty state.
//!
//! What is deliberately NOT here:
//!   * `update_*` mid-flight mutators — those live in
//!     [`super::runtime_config`] because they push through the
//!     [`super::RuntimeConfig`] handle AND the command channel; the
//!     setters here only write executor fields.
//!   * Sequence loading (`load_sequence`, `calculate_totals`) — those
//!     live in [`super::loading`] because they build the runtime node
//!     tree and compute its scalar metadata.
//!   * `set_checkpoint_dir` — lives in [`super::checkpoint`] because
//!     it is the entry point for the checkpoint persistence surface,
//!     not a generic device-wiring setter.
//!
//! Visibility note: every method on this file's `impl` is `pub` because
//! the bridge layer is the canonical caller. The struct fields these
//! methods mutate are crate-private; only sibling executor modules can
//! see them (Rust child-module privacy), which is exactly what we want.

use super::{ExecutorCommand, ExecutorEvent, ExecutorState, SequenceExecutor};
use crate::device_ops::SharedDeviceOps;
use crate::triggers::{TriggerManager, TriggerState};
use crate::SafetyFailMode;
use std::sync::atomic::Ordering;
use std::sync::Arc;
use tokio::sync::{broadcast, RwLock};

impl SequenceExecutor {
    /// Set whether the standard weather and dawn triggers may park (the
    /// operator's "Park on unsafe weather" and "Park before dawn" settings).
    ///
    /// Written into the shared [`super::RuntimeConfig`], which the trigger
    /// monitor reads each time a trigger fires, so a change reaches a running
    /// executor at once and an idle one on its next `start()`.
    pub fn set_park_policy(&mut self, policy: super::ParkPolicy) {
        self.runtime_config.write().park_policy = policy;
    }

    /// Set how many times a failed camera exposure or filter-wheel move is
    /// retried before it counts as a failure (the operator's "Camera retries"
    /// and "Filter wheel retries"; 3 each until the app pushes its values).
    ///
    /// Written through the handle every run's contexts share, so it applies
    /// to the next attempt of a running sequence and to every later start.
    pub fn set_device_retry_policy(&mut self, policy: crate::instructions::DeviceRetryPolicy) {
        self.runtime_config.read().device_retry.set(policy);
    }

    /// The retry policy the next attempt will use.
    pub fn device_retry_policy(&self) -> crate::instructions::DeviceRetryPolicy {
        self.runtime_config.read().device_retry.get()
    }

    /// Set whether a quality problem the software judges — guiding RMS over the
    /// limit, a Center that did not converge, a dither that did not settle, a
    /// failed post-flip recenter or guiding check — stops the run (`true`) or
    /// notifies the operator while imaging continues (`false`, the default).
    ///
    /// Written into the trigger state the run shares with this executor, so a
    /// running sequence follows the change at its next decision and an idle
    /// one starts with it. See
    /// [`crate::triggers::TriggerState::stop_on_quality_problems`].
    pub async fn set_stop_on_quality_problems(&self, stop: bool) {
        let manager = self.trigger_manager.read().await;
        let state_lock = manager.state();
        state_lock.write().await.stop_on_quality_problems = stop;
    }

    /// Set the safety fail mode for the sequencer.
    ///
    /// Mirrors the value into [`super::RuntimeConfig`] so a running
    /// executor's trigger-monitor task sees the change on its next poll
    /// (via [`ExecutorCommand::UpdateSafetyFailMode`]); an idle executor
    /// picks it up on the next `start()`.
    pub fn set_safety_fail_mode(&mut self, mode: SafetyFailMode) {
        self.safety_fail_mode = mode;
        {
            let mut rc = self.runtime_config.write();
            rc.safety_fail_mode = mode;
        }
        if let Some(tx) = &self.command_tx {
            let _ = tx.try_send(ExecutorCommand::UpdateSafetyFailMode { mode });
        }
    }

    /// Set the safety/humidity polling interval for the sequencer.
    ///
    /// The input is clamped by
    /// [`super::effective_safety_check_interval_secs`] — values of 0
    /// fall back to the documented default, the rest are clamped to
    /// `[5, 3600]` seconds. This keeps a fat-fingered `0` from disabling
    /// safety polling entirely.
    pub fn set_safety_check_interval_secs(&mut self, seconds: u64) {
        let seconds = super::effective_safety_check_interval_secs(seconds);
        {
            let mut rc = self.runtime_config.write();
            rc.safety_check_interval_secs = seconds;
        }
        if let Some(tx) = &self.command_tx {
            let _ = tx.try_send(ExecutorCommand::UpdateSafetyCheckInterval { seconds });
        }
    }

    /// Shared handle to the trigger manager. Cloned `Arc` — callers
    /// hold their own reference for the lifetime they need it. The
    /// bridge uses this to apply user-edited trigger configs after
    /// `set_*` device wiring and before `start()`.
    pub fn trigger_manager(&self) -> Arc<RwLock<TriggerManager>> {
        self.trigger_manager.clone()
    }

    /// Enable or disable trigger monitoring at the gating level.
    ///
    /// `false` keeps the trigger manager wired but skips evaluation
    /// inside the spawned task — used by the bridge when the operator
    /// has opted out of all unattended-imaging triggers (rare, mostly
    /// for diagnostic runs).
    pub fn set_triggers_enabled(&mut self, enabled: bool) {
        self.triggers_enabled = enabled;
    }

    /// Run a closure against the live [`TriggerState`] inside the
    /// trigger manager. Holds the write lock for the duration of the
    /// closure so callers can atomically update multiple fields without
    /// risking a concurrent evaluator read seeing a partial mutation.
    pub async fn update_trigger_state<F>(&self, updater: F)
    where
        F: FnOnce(&mut TriggerState),
    {
        let manager = self.trigger_manager.read().await;
        let state_lock = manager.state();
        let mut state = state_lock.write().await;
        updater(&mut state);
    }

    /// Set the device operations handler.
    ///
    /// This MUST be called before [`SequenceExecutor::start`], otherwise
    /// `start()` returns an error. The handler is the single chokepoint
    /// every instruction (slew, expose, autofocus) routes through, so `None`
    /// would let a sequence "run" while doing nothing.
    pub fn set_device_ops(&mut self, ops: SharedDeviceOps) {
        self.device_ops = Some(ops);
    }

    /// Install the DepthLock verdict source consulted by bound Smart
    /// Exposure plans. Optional: without it a bound plan warns once per run
    /// and runs to its authored count.
    pub fn set_depth_goal_ops(&mut self, ops: Option<crate::depth_goal::SharedDepthGoalOps>) {
        self.depth_goal_ops = ops;
    }

    /// Diagnostic accessor — `true` iff [`Self::set_device_ops`] has
    /// been called. The bridge surfaces this on the connect-readiness
    /// indicator so the operator can see why `start()` would refuse.
    pub fn has_device_ops(&self) -> bool {
        self.device_ops.is_some()
    }

    /// Wire the five core imaging device ids (camera, mount, focuser,
    /// filter wheel, rotator) into the executor.
    ///
    /// Each id is the canonical `driver:vendor:id` string the bridge
    /// uses for device dispatch; the executor doesn't parse them
    /// further (that's the device_ops handler's job).
    pub fn set_devices(
        &mut self,
        camera: Option<String>,
        mount: Option<String>,
        focuser: Option<String>,
        filterwheel: Option<String>,
        rotator: Option<String>,
    ) {
        self.camera_id = camera;
        self.mount_id = mount;
        self.focuser_id = focuser;
        self.filterwheel_id = filterwheel;
        self.rotator_id = rotator;
    }

    /// Set the dome device id. Separate from [`Self::set_devices`]
    /// because dome integration was added after the core five and
    /// keeping the signatures stable matters more than tidying up.
    pub fn set_dome(&mut self, dome_id: Option<String>) {
        self.dome_id = dome_id;
    }

    /// Set the cover-calibrator (flat panel) device id. Separate setter
    /// for the same reason as [`Self::set_dome`].
    pub fn set_cover_calibrator(&mut self, cover_calibrator_id: Option<String>) {
        self.cover_calibrator_id = cover_calibrator_id;
    }

    /// Set the base save path for captured images. The exposure
    /// instruction joins per-target / per-filter sub-folders onto this
    /// root.
    pub fn set_save_path(&mut self, path: Option<std::path::PathBuf>) {
        self.save_path = path;
    }

    /// Set observer latitude / longitude in degrees.
    ///
    /// This is the pre-start setter; the mid-flight equivalent is
    /// [`SequenceExecutor::update_location`] which also pushes through
    /// the runtime-config Arc. They write the same fields; the split is
    /// because pre-start setters are sync and mid-flight setters route
    /// through the command channel.
    /// (0, 0) is normalized to unset — see
    /// [`crate::node::context::normalized_observer_location`].
    pub fn set_location(&mut self, lat: Option<f64>, lon: Option<f64>) {
        let (lat, lon) = crate::node::context::normalized_observer_location(lat, lon);
        self.latitude = lat;
        self.longitude = lon;
    }

    /// Set per-filter focus offsets from the equipment profile.
    ///
    /// The map is `filter_name -> steps`; autofocus on filter change
    /// reads this to pre-position the focuser. Mid-flight updates go
    /// through [`SequenceExecutor::update_filter_offsets`].
    pub fn set_filter_focus_offsets(&mut self, offsets: std::collections::HashMap<String, i32>) {
        self.filter_focus_offsets = offsets;
    }

    /// Subscribe to the executor event broadcast.
    ///
    /// Each subscriber gets a back-pressure buffer of 256 events; a
    /// slow consumer that lags is dropped to `Lagged` rather than
    /// stalling the executor. The bridge holds one long-lived
    /// subscription that fans out to the Dart event stream.
    pub fn subscribe(&self) -> broadcast::Receiver<ExecutorEvent> {
        self.event_tx.subscribe()
    }

    /// How many live receivers are attached to the executor event broadcast.
    ///
    /// The bridge is supposed to hold exactly ONE, forever. A second one means
    /// every sequencer event reaches the UI twice — duplicate failure toasts,
    /// duplicate Session Report lines, duplicate frame events — so this is the
    /// number that has to be asserted, not the number of times the subscribe
    /// entry point was called.
    pub fn event_subscriber_count(&self) -> usize {
        self.event_tx.receiver_count()
    }

    /// Reset the executor back to its `Idle` state.
    ///
    /// Drops the command channel (so subsequent lifecycle calls hit the
    /// "not running" path), clears the cancellation flag, wipes
    /// [`super::SequenceProgress`] back to default, and resets every
    /// node in the runtime tree if one is loaded. The sequence
    /// definition itself is retained so the same tree can be re-run
    /// without re-loading.
    pub async fn reset(&mut self) {
        self.command_tx = None;
        self.is_cancelled.store(false, Ordering::Relaxed);
        *self.state.write().await = ExecutorState::Idle;
        *self.progress.write() = super::SequenceProgress::default();

        if let Some(ref mut node) = self.root_node {
            node.reset();
        }
    }
}
