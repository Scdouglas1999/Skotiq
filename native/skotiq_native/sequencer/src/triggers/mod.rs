//! Trigger system for the sequencer.
//!
//! Split by concern: [`trigger`] holds the [`Trigger`] record and its
//! condition evaluation, [`state`] the observed-condition snapshot the
//! evaluation reads, [`manager`] the collection that ticks them all,
//! [`meridian_window`] the shared flip-window test, and [`dawn`] the twilight
//! helper. This module is declarations and shared constants only.

mod dawn;
mod manager;
mod meridian_window;
mod state;
mod trigger;

pub use dawn::*;
pub use manager::*;
pub use meridian_window::*;
pub use state::*;
pub use trigger::*;

/// Hard upper bound on the FocusDrift rolling-window length.
/// The window is user-configurable (`TriggerType::FocusDrift::window_size`,
/// `lib.rs:1115`); enforcing a ceiling here keeps the in-memory footprint
/// bounded and prevents a misconfigured sequence from allocating an
/// unbounded ring buffer per trigger evaluation. 100 samples at the typical
/// 1 Hz monitor tick is 100 s of drift history — well past any reasonable
/// focus-drift detection horizon.
pub const FOCUS_DRIFT_WINDOW_MAX: usize = 100;

/// Extra time past the end of an exposure during which the camera still counts
/// as busy, covering sensor readout and download. Generous on purpose: the
/// cost of over-waiting is that a trigger-fired autofocus starts a few seconds
/// late, and the cost of under-waiting is a destroyed frame and a dead run.
pub const CAMERA_BUSY_DOWNLOAD_SLACK_SECS: f64 = 20.0;

/// How far past its own expected finish an imaging-train claim survives before
/// the token self-heals back to free.
///
/// This is deliberately NOT the same number as
/// [`CAMERA_BUSY_DOWNLOAD_SLACK_SECS`], and keeping them apart is the fix for a
/// measured defect. The old claim had one deadline doing both jobs: `exposure
/// duration + 20 s` was simultaneously the estimate a waiter read AND the
/// instant the token became free. So a 180 s light whose readout ran a little
/// long handed the camera to a waiting trigger while the sensor was still
/// integrating. The trigger then started its own 5 s plate-solve exposure on a
/// busy camera and failed on a timeout of its own request plus margin —
/// `Exposure on native:zwo:1 did not complete within 65.0s timeout` — a number
/// with no relationship to the 180 s frame it was actually queued behind.
///
/// An estimate that is slightly wrong must not transfer ownership. So the
/// expected finish is what a waiter reads to size its wait, and the hard expiry
/// sits this much further out: long enough that no plausible readout, settle or
/// USB stall releases the devices under their holder, short enough that a
/// holder that panicked without releasing costs minutes rather than the night.
pub const IMAGING_TRAIN_CLAIM_OVERRUN_GRACE_SECS: f64 = 300.0;

#[cfg(test)]
mod cross_run_target_hygiene_tests;
#[cfg(test)]
mod east_target_flip_tests;
#[cfg(test)]
mod filter_change_edge_tests;
#[cfg(test)]
mod tests;
