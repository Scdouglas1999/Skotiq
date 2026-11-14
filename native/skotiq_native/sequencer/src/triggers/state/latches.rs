//! What a run has measured, counted and latched since it started.

use super::part::state_part;
use std::time::Instant;

state_part! {
    /// Per-run state: focus baselines, frame counters, and the latches a run
    /// sets as things happen to it. Reset as a whole at the start of every
    /// run, resumed or not (see [`super::TriggerState::reset_for_new_run`]).
    /// Two fields are not reset there and keep counting across runs:
    /// `hfr_sample_seq` and `grid_dither_index`.
    pub struct RunLatches, checkpointed as LatchesSnapshot {
        persisted {
            pub baseline_hfr: Option<f64>,
            pub current_hfr: Option<f64>,
            pub autofocus_invalidated: bool,
            pub autofocus_invalidation_reason: Option<String>,
            pub filter_changed: bool,
            pub current_filter: Option<String>,
            /// Filter focus offset (steps) currently embodied in the focuser position,
            /// relative to the reference filter. Filter offsets are reference-relative
            /// deltas; a filter change moves the focuser by
            /// `(offset_new - last_applied_filter_offset)` so offsets do not stack and
            /// walk focus off across an LRGB/SHO night. `0` means the focuser is at the
            /// reference-filter focus (the initial state and after selecting the
            /// reference filter).
            pub last_applied_filter_offset: i32,
            pub completed_exposures: u32,
            pub last_autofocus_frame: u32,
            pub last_dither_frame: u32,
            pub baseline_temperature: Option<f64>,
            pub current_temperature: Option<f64>,
            pub baseline_focuser_position: Option<i32>,
            /// Current position index in the NxN grid dither pattern (0-based).
            /// Incremented after each dither, wraps around to 0 after grid_size*grid_size.
            pub grid_dither_index: u32,
        }
        transient {
            /// The HFR each filter reached at its last successful autofocus. A filter
            /// change restores that filter's baseline instead of adopting the next
            /// frame, which may already be out of focus.
            pub focused_hfr_by_filter: std::collections::HashMap<String, f64>,
            /// monotonically increments each time a NEW frame's HFR is recorded
            /// via `update_hfr`. The HfrDegraded trigger gates its consecutive-bad-frame
            /// counter on a change here so it counts frames, not ~1Hz monitor ticks.
            pub hfr_sample_seq: u64,
            /// HFR samples available when the last sweep ended cannot request another sweep.
            pub autofocus_hfr_seq: Option<u64>,
            /// Consecutive failed dithers. A single failure is noise; a run of them
            /// means guiding has stopped, which the operator should hear about even
            /// though it does not justify ending the night.
            pub consecutive_dither_failures: u32,
            /// Nodes running now that set their own dither cadence. While any does,
            /// the Dither Interval trigger stands down: the node's per-plan "dither
            /// every N" is the more specific instruction, and the two counting the
            /// same frames on different cadences dithered twice in a row. A node with
            /// no cadence of its own leaves dithering to the trigger.
            pub dither_cadence_owners: u32,
            pub guiding_rms_history: Option<Vec<(Instant, f64)>>,
            /// The guide-star recovery that is failing, until guiding settles again.
            pub guide_recovery: Option<super::super::GuideRecoveryStall>,
            /// Why the frame watch is holding autofocus: the latest frames are
            /// trailed, starless or off target, and a sweep on them would move focus
            /// on stars that are not there. Autofocus triggers do not fire while set.
            pub autofocus_hold: Option<String>,
            /// An autofocus trigger came due while autofocus was held.
            pub autofocus_wanted_while_held: bool,
            /// The operator has been told this run's settle bar is tighter than the
            /// guiding the rig achieves.
            pub settle_bar_warning_given: bool,
            /// Unix seconds of the latest mount fault (the mount moved on its own or
            /// lost its position) that held this run. A light frame that was
            /// exposing at that moment is rejected.
            pub mount_fault_at: Option<i64>,
            /// The run was held for a mount fault and has not recentered since: the
            /// next light frame first centers on the target, because the mount is no
            /// longer where the run left it.
            pub mount_fault_recenter_pending: bool,
            /// The run's temperature compensation between light frames, when the
            /// operator turned it on. Its reference is the run's own: a new run
            /// measures from its first light frame.
            pub focus_compensation: Option<crate::temperature_compensation::FocusCompensation>,
        }
    }
}
