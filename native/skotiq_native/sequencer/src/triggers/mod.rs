//! Trigger system for the sequencer.
//!
//! Split by concern: [`trigger`] holds the [`Trigger`] record and its
//! condition evaluation, [`standard`] the table of standard triggers, [`state`]
//! the run state the evaluation reads (in parts), [`manager`] the collection
//! that ticks them all, [`meridian_window`] the shared flip-window test,
//! [`run_mode`] what a fired trigger may do in the run's current mode, and
//! [`dawn`] the twilight helper.

mod dawn;
mod flip_state;
mod guide_recovery;
mod guiding_state;
mod manager;
mod manual_flip;
mod meridian_window;
mod run_mode;
mod standard;
mod state;
mod tracking_state;
mod trigger;

pub use dawn::*;
pub use flip_state::*;
pub use guide_recovery::*;
pub use guiding_state::*;
pub use manager::*;
pub use meridian_window::*;
pub use run_mode::*;
pub use standard::*;
pub use state::*;
pub use tracking_state::*;
pub use trigger::*;

/// Hard upper bound on the FocusDrift rolling-window length.
/// The window is user-configurable (`TriggerType::FocusDrift::window_size`,
/// `lib.rs:1115`); enforcing a ceiling here keeps the in-memory footprint
/// bounded and prevents a misconfigured sequence from allocating an
/// unbounded ring buffer per trigger evaluation. 100 samples at the typical
/// 1 Hz monitor tick is 100 s of drift history — well past any reasonable
/// focus-drift detection horizon.
pub const FOCUS_DRIFT_WINDOW_MAX: usize = 100;

#[cfg(test)]
mod cross_run_target_hygiene_tests;
#[cfg(test)]
mod east_target_flip_tests;
#[cfg(test)]
mod filter_change_edge_tests;
#[cfg(test)]
mod tests;

pub(crate) use meridian_window::{
    tracking_limit_flip_due, tracking_limit_flip_is_early, tracking_limit_flip_threshold,
};
pub(crate) use state::tracking_limit_recovery_candidate;
