//! Waiting for a mount to finish a slew it was sent: first for it to report
//! moving, then for it to report still. Each caller states its bounds and
//! decides what an outcome means; the abort a stopped or overrun wait sends is
//! returned for the caller to report.

use super::*;
use crate::device_ops::DeviceError;
use crate::slew_arrival::{watch_slew, SlewArrivalTimings, SlewEnd, SlewSample};
pub(crate) use crate::slew_arrival::{SlewPhase, SlewStartBound};

/// How a caller waits for a slew.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct SlewWaitBounds {
    /// Wait first for the mount to report it is moving. `None` goes straight
    /// to waiting for it to stop.
    pub start: Option<SlewStartBound>,
    /// How long the mount may take to stop once it moves.
    pub complete: Duration,
    pub poll: Duration,
    /// A deadline reached exactly counts as overrun (`true`), or only once
    /// passed (`false`).
    pub deadline_inclusive: bool,
    pub read_errors: SlewReadErrors,
}

/// What a failed read of the slewing state does.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) enum SlewReadErrors {
    /// Ends the wait with the error.
    Fail,
    /// Logged as `"<label>: slew-state read failed while waiting for
    /// startup|completion (<error>); retrying"` and polled again.
    Retry { label: &'static str },
}

/// How a slew wait ended. The outcomes that abort the slew carry the abort's
/// answer.
#[derive(Debug)]
pub(crate) enum SlewWait<S> {
    Done,
    /// The caller's stop check answered `S`.
    Stopped {
        reason: S,
        phase: SlewPhase,
        abort: Result<(), DeviceError>,
    },
    /// The mount never reported moving and the bound says not to wait on.
    NeverStarted {
        abort: Result<(), DeviceError>,
    },
    /// The mount was still moving at the completion bound.
    Overran {
        abort: Result<(), DeviceError>,
    },
    ReadFailed(DeviceError),
}

impl SlewWaitBounds {
    /// The watch these bounds describe: no target, and the first idle read
    /// after the start phase ends the slew.
    pub(crate) fn timings(&self) -> SlewArrivalTimings {
        SlewArrivalTimings {
            poll_interval: self.poll,
            start_grace: Duration::ZERO,
            motion_start_window: self.complete,
            timeout: self.complete,
            idle_confirm_polls: 1,
            arrival_tolerance_deg: 0.0,
            max_consecutive_failures: match self.read_errors {
                SlewReadErrors::Fail => 1,
                SlewReadErrors::Retry { .. } => 0,
            },
            start: self.start,
            deadline_inclusive: self.deadline_inclusive,
            stop_after_read: false,
        }
    }
}

/// Wait for the slew `mount_id` was sent to finish. `stop` is checked before
/// every read.
pub(crate) async fn wait_for_slew<S>(
    device_ops: &SharedDeviceOps,
    mount_id: &str,
    bounds: SlewWaitBounds,
    stop: &(dyn Fn() -> Option<S> + Send + Sync),
) -> SlewWait<S> {
    let probe = |phase: SlewPhase| async move {
        let slewing = device_ops.mount_is_slewing(mount_id).await;
        if let (Err(error), SlewReadErrors::Retry { label }) = (&slewing, bounds.read_errors) {
            let waiting_for = match phase {
                SlewPhase::Starting => "startup",
                SlewPhase::Moving => "completion",
            };
            tracing::warn!(
                "{}: slew-state read failed while waiting for {} ({}); retrying",
                label,
                waiting_for,
                error
            );
        }
        slewing.map(|slewing| SlewSample {
            slewing: Some(slewing),
            position: None,
        })
    };
    let ended = watch_slew(
        None,
        &bounds.timings(),
        probe,
        stop,
        || device_ops.mount_abort_slew(mount_id),
        |_| {},
    )
    .await;
    match ended {
        Ok(_) => SlewWait::Done,
        Err(SlewEnd::Stopped {
            reason,
            phase,
            abort,
        }) => SlewWait::Stopped {
            reason,
            phase,
            abort,
        },
        Err(SlewEnd::NeverStarted { abort }) => SlewWait::NeverStarted { abort },
        Err(SlewEnd::TimedOut { abort }) => SlewWait::Overran { abort },
        Err(SlewEnd::LostContact { error, .. }) => {
            SlewWait::ReadFailed(error.unwrap_or_else(|| {
                "the mount's slewing state could not be read"
                    .to_string()
                    .into()
            }))
        }
        // Reached only by a watch with a target; a mount that did not move
        // never started.
        Err(SlewEnd::DidNotMove) => SlewWait::NeverStarted {
            abort: device_ops.mount_abort_slew(mount_id).await,
        },
    }
}
