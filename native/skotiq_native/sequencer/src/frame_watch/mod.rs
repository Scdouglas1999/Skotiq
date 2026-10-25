//! Frame watch: every saved light frame is plate solved and measured after it
//! is written, and the run acts on what that shows. A frame whose center has
//! wandered off the target triggers a recenter; a run of frames that lost
//! their stars is reported, and when it looks like the target setting behind
//! something it is probed and, if confirmed, the run moves on and the site
//! learns that patch of horizon. Every frame's solve, guide RMS, background
//! and pointing go to the app's frame record.
//!
//! [`classify`] is the judgment and has no devices; [`assess`] measures a
//! saved frame. The trigger monitor runs both (see
//! `executor/start/trigger_monitor/frame_watch.rs`).

pub mod assess;
pub mod classify;
pub mod config;
pub mod events;
pub mod next_target;

#[cfg(test)]
pub(crate) mod fixture;
#[cfg(test)]
mod replay_tests;

pub use classify::{
    angular_separation_deg, FrameObservation, FrameVerdict, FrameWatch, Pointing, SolveOutcome,
    WatchAction, OBSTRUCTED_PREFIX, OFF_TARGET_PREFIX,
};
pub use config::{FrameWatchConfig, HorizonPoint, FRAME_WATCH_METADATA_KEY};
pub use events::{FrameAssessed, FrameWatchEvent, HorizonObstructionReport};
