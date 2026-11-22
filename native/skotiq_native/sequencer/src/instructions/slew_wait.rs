//! Waiting for a mount to finish a slew it was sent: first for it to report
//! moving, then for it to report still. Each caller states its bounds and
//! decides what an outcome means; the abort a stopped or overrun wait sends is
//! returned for the caller to report.

use super::*;
use crate::device_ops::DeviceError;

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

#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct SlewStartBound {
    pub within: Duration,
    pub poll: Duration,
    /// A mount that never reports moving within the bound: wait for it to
    /// stop anyway (`true`), or end the wait (`false`).
    pub proceed_if_never: bool,
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

/// Which part of the wait an outcome came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SlewPhase {
    Starting,
    Moving,
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

/// Wait for the slew `mount_id` was sent to finish. `stop` is checked before
/// every read.
pub(crate) async fn wait_for_slew<S>(
    device_ops: &SharedDeviceOps,
    mount_id: &str,
    bounds: SlewWaitBounds,
    stop: &(dyn Fn() -> Option<S> + Send + Sync),
) -> SlewWait<S> {
    let overran = |deadline: tokio::time::Instant| {
        let now = tokio::time::Instant::now();
        if bounds.deadline_inclusive {
            now >= deadline
        } else {
            now > deadline
        }
    };
    if let Some(start) = bounds.start {
        let deadline = tokio::time::Instant::now() + start.within;
        loop {
            if let Some(reason) = stop() {
                return SlewWait::Stopped {
                    reason,
                    phase: SlewPhase::Starting,
                    abort: device_ops.mount_abort_slew(mount_id).await,
                };
            }
            match device_ops.mount_is_slewing(mount_id).await {
                Ok(true) => break,
                Ok(false) => {}
                Err(error) => match bounds.read_errors {
                    SlewReadErrors::Fail => return SlewWait::ReadFailed(error),
                    SlewReadErrors::Retry { label } => tracing::warn!(
                        "{}: slew-state read failed while waiting for startup ({}); retrying",
                        label,
                        error
                    ),
                },
            }
            if overran(deadline) {
                if start.proceed_if_never {
                    tracing::debug!(
                        "The mount did not report slewing within {}s of the slew command; \
                         waiting for it to stop",
                        start.within.as_secs()
                    );
                    break;
                }
                return SlewWait::NeverStarted {
                    abort: device_ops.mount_abort_slew(mount_id).await,
                };
            }
            sleep(start.poll).await;
        }
    }

    let deadline = tokio::time::Instant::now() + bounds.complete;
    loop {
        if let Some(reason) = stop() {
            return SlewWait::Stopped {
                reason,
                phase: SlewPhase::Moving,
                abort: device_ops.mount_abort_slew(mount_id).await,
            };
        }
        match device_ops.mount_is_slewing(mount_id).await {
            Ok(false) => return SlewWait::Done,
            Ok(true) => {}
            Err(error) => match bounds.read_errors {
                SlewReadErrors::Fail => return SlewWait::ReadFailed(error),
                SlewReadErrors::Retry { label } => tracing::warn!(
                    "{}: slew-state read failed while waiting for completion ({}); retrying",
                    label,
                    error
                ),
            },
        }
        if overran(deadline) {
            return SlewWait::Overran {
                abort: device_ops.mount_abort_slew(mount_id).await,
            };
        }
        sleep(bounds.poll).await;
    }
}
