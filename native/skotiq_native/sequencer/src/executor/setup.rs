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
//!     [`super::RunConfig`] handle AND the command channel; the
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

use super::{ExecutorEvent, SequenceExecutor};
use crate::device_ops::SharedDeviceOps;
use crate::triggers::{TriggerManager, TriggerState};
use std::sync::atomic::Ordering;
use std::sync::Arc;
use tokio::sync::{broadcast, RwLock};

impl SequenceExecutor {
    /// Shared handle to the trigger manager. Cloned `Arc` — callers
    /// hold their own reference for the lifetime they need it. The
    /// bridge uses this to apply user-edited trigger configs after
    /// `set_*` device wiring and before `start()`.
    pub fn trigger_manager(&self) -> Arc<RwLock<TriggerManager>> {
        self.trigger_manager.clone()
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

    /// Subscribe to the executor event broadcast.
    ///
    /// Each subscriber gets a back-pressure buffer of 256 events; a
    /// slow consumer that lags is dropped to `Lagged` rather than
    /// stalling the executor. The bridge holds one long-lived
    /// subscription that fans out to the Dart event stream.
    pub fn subscribe(&self) -> broadcast::Receiver<ExecutorEvent> {
        self.run_state.subscribe()
    }

    /// How many live receivers are attached to the executor event broadcast.
    ///
    /// The bridge is supposed to hold exactly ONE, forever. A second one means
    /// every sequencer event reaches the UI twice — duplicate failure toasts,
    /// duplicate Session Report lines, duplicate frame events — so this is the
    /// number that has to be asserted, not the number of times the subscribe
    /// entry point was called.
    pub fn event_subscriber_count(&self) -> usize {
        self.run_state.events().receiver_count()
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
        self.commands.set(None);
        self.is_cancelled.store(false, Ordering::Relaxed);
        self.run_state.reset();

        if let Some(ref mut node) = self.root_node {
            node.reset();
        }
    }
}
