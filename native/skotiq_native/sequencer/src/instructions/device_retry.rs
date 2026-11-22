//! Retrying a camera exposure or a filter-wheel move through a transient fault.
//!
//! One failed download or one failed wheel move used to end the whole run. The
//! simulator night soak showed it directly: a single injected download error
//! (`camera.download=every(40):delaythenerror(30000)`, the INDI BLOB timeout
//! shape) or a single wheel error (`filterwheel.set_position=every(9):error`)
//! failed a night that the next attempt would have carried on with. Real gear
//! produces exactly these one-off faults: a USB stall on a shared hub, a vendor
//! SDK that reports "not ready" once, an ASCOM call that throws and then works.
//!
//! The operator sets how many retries each device kind gets ("Camera retries",
//! "Filter wheel retries", default 3). The policy and the decision live here so
//! every caller (the capture loop, the centering frame, every filter change)
//! retries the same way:
//!
//! * Only a fault that can plausibly clear is retried. Operator cancellation
//!   stops at once. A device that reports itself not connected is left to the
//!   device-disconnect recovery path, which reconnects it and re-runs the
//!   instruction; retrying the call without a reconnect cannot succeed. A
//!   request the device refuses (an invalid value, a feature it lacks, a frame
//!   that fails image validation) fails the same way every time.
//! * A camera failure that means the camera's session is broken reopens the
//!   camera before its retry (see [`CameraRetries`]).
//! * Each retry is logged and sent as a run warning, so it shows in the run
//!   dashboard's Session warnings and the Session Report without interrupting.
//! * The wait between attempts honours Stop: it returns as soon as the run is
//!   cancelled.
//!
//! When the retries are used up the failure is reported as it always was, with
//! the number of retries added to the message.

use super::*;

/// Retries each device kind gets when the operator has not set a value.
pub const DEFAULT_DEVICE_RETRIES: u32 = 3;

/// Highest retry count the setting accepts. Ten attempts with the backoff
/// below already spend a minute and a half of waiting on one frame or one
/// wheel move; a larger number only hides a device that is broken.
pub const MAX_DEVICE_RETRIES: u32 = 10;

/// How many times a failed camera exposure or filter-wheel move is retried
/// before the failure counts. `0` is a single attempt, the behavior before
/// retries existed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub struct DeviceRetryPolicy {
    pub camera_retries: u32,
    pub filter_wheel_retries: u32,
}

impl Default for DeviceRetryPolicy {
    fn default() -> Self {
        Self {
            camera_retries: DEFAULT_DEVICE_RETRIES,
            filter_wheel_retries: DEFAULT_DEVICE_RETRIES,
        }
    }
}

impl DeviceRetryPolicy {
    /// One attempt each, no retries.
    pub const SINGLE_ATTEMPT: Self = Self {
        camera_retries: 0,
        filter_wheel_retries: 0,
    };

    /// The policy with each count held to [`MAX_DEVICE_RETRIES`].
    pub fn clamped(self) -> Self {
        Self {
            camera_retries: self.camera_retries.min(MAX_DEVICE_RETRIES),
            filter_wheel_retries: self.filter_wheel_retries.min(MAX_DEVICE_RETRIES),
        }
    }
}

/// The run's live retry policy, shared between the executor (which the app
/// writes the operator's setting into) and every instruction context of the
/// run, so a change in Settings reaches the next attempt of a running
/// sequence.
#[derive(Debug, Clone)]
pub struct DeviceRetryHandle(Arc<parking_lot::RwLock<DeviceRetryPolicy>>);

impl DeviceRetryHandle {
    pub fn new(policy: DeviceRetryPolicy) -> Self {
        Self(Arc::new(parking_lot::RwLock::new(policy.clamped())))
    }

    /// A handle that never retries. Contexts with no run behind them (an
    /// Imaging-tab capture, the standalone wizards, tests) keep the
    /// one-attempt behavior; the executor installs the operator's handle on
    /// every run it starts.
    pub fn single_attempt() -> Self {
        Self::new(DeviceRetryPolicy::SINGLE_ATTEMPT)
    }

    pub fn get(&self) -> DeviceRetryPolicy {
        *self.0.read()
    }

    pub fn set(&self, policy: DeviceRetryPolicy) {
        *self.0.write() = policy.clamped();
    }
}

impl Default for DeviceRetryHandle {
    fn default() -> Self {
        Self::new(DeviceRetryPolicy::default())
    }
}

/// Which retry budget an attempt draws on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum RetriedDevice {
    Camera,
    FilterWheel,
}

impl RetriedDevice {
    fn budget(self, policy: DeviceRetryPolicy) -> u32 {
        match self {
            Self::Camera => policy.camera_retries,
            Self::FilterWheel => policy.filter_wheel_retries,
        }
    }

    fn label(self) -> &'static str {
        match self {
            Self::Camera => "Camera",
            Self::FilterWheel => "Filter wheel",
        }
    }
}

/// The wait before retry `retry` (1-based): 2 s, 5 s, then 10 s for every
/// later one.
///
/// Long enough for the faults worth retrying to clear (a USB hub re-enumerating
/// or a vendor SDK releasing its mutex takes a second or two, an INDI server
/// that timed out a BLOB a few more) and short against the frame it protects:
/// three retries wait 17 s in all. A fixed schedule rather than an open-ended
/// exponential keeps the worst case predictable at [`MAX_DEVICE_RETRIES`].
pub(crate) fn retry_backoff(retry: u32) -> Duration {
    Duration::from_secs(match retry {
        0 | 1 => 2,
        2 => 5,
        _ => 10,
    })
}

/// What a failed attempt means for the retry decision.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum DeviceFault {
    /// Could clear on its own: a timeout, a failed download, "not ready", a
    /// driver exception. Retried.
    Transient,
    /// The operator (or the run) stopped it. Never retried.
    Cancelled,
    /// The device says it is not connected. Left to the device-disconnect
    /// recovery path, which reconnects before it re-runs anything.
    Disconnected,
    /// The device refused the request itself; a retry gets the same answer.
    Refused,
}

pub(crate) fn classify_device_fault(error: &DeviceError) -> DeviceFault {
    match error {
        DeviceError::Cancelled(_) => DeviceFault::Cancelled,
        DeviceError::NotConnected { .. } => DeviceFault::Disconnected,
        // A frame that fails image validation is the operator's exposure to
        // fix (saturated, blank), not a fault.
        DeviceError::NotConfigured { .. }
        | DeviceError::Unsupported(_)
        | DeviceError::Rejected(_)
        | DeviceError::InvalidFrame(_) => DeviceFault::Refused,
        DeviceError::Timeout(_) | DeviceError::Failed(_) | DeviceError::SessionLost(_) => {
            DeviceFault::Transient
        }
    }
}

/// A device operation that failed, after the retries it had.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct DeviceFailure {
    pub(crate) error: DeviceError,
    pub(crate) retries: u32,
}

impl DeviceFailure {
    /// The failure as one device error, the retries spent in its words.
    pub(crate) fn into_error(self) -> DeviceError {
        let suffix = match self.retries {
            0 => return self.error,
            1 => " (after 1 retry)".to_string(),
            n => format!(" (after {n} retries)"),
        };
        self.error.reworded(|message| format!("{message}{suffix}"))
    }
}

impl std::fmt::Display for DeviceFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self.retries {
            0 => write!(f, "{}", self.error),
            1 => write!(f, "{} (after 1 retry)", self.error),
            n => write!(f, "{} (after {n} retries)", self.error),
        }
    }
}

/// What a retry needs of the run it belongs to: the retry budget, the warning
/// feed and the device layer, and the stop that ends the wait between
/// attempts.
#[derive(Clone, Copy)]
pub(crate) struct RetryScope<'a> {
    pub(crate) run: &'a RunShared,
    pub(crate) stop: &'a (dyn Fn() -> Option<FrameStop> + Sync),
}

/// What the caller does after a failed attempt.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum RetryOutcome {
    /// The backoff has been waited out; run the attempt again.
    Retry,
    /// Report the failure.
    GiveUp(DeviceFailure),
    /// The run was stopped while waiting to retry.
    Cancelled,
}

/// Decide whether a failed camera or filter-wheel attempt is retried, and if it
/// is, announce the retry and wait out its backoff.
///
/// `retries_done` is how many retries this operation has already had; `what`
/// names the operation for the operator ("frame 3/10", "to Ha").
pub(crate) async fn after_failed_attempt(
    ctx: &InstructionContext,
    device: RetriedDevice,
    retries_done: u32,
    error: DeviceError,
    what: &str,
) -> RetryOutcome {
    let stop = || cancel_of(&ctx.cancellation_token);
    let scope = RetryScope {
        run: &ctx.run,
        stop: &stop,
    };
    match retry_or_stop(scope, device, retries_done, error) {
        Ok(error) => {
            let budget = device.budget(ctx.run.device_retry.get());
            let retry = retries_done + 1;
            let delay = retry_backoff(retry);
            let next = format!(
                "Retrying in {} s (retry {} of {}).",
                delay.as_secs(),
                retry,
                budget
            );
            announce_and_wait(scope, device, &error, what, &next, delay).await
        }
        Err(outcome) => outcome,
    }
}

/// The error back when the failed attempt is to be retried, or the outcome
/// that ends the operation.
fn retry_or_stop(
    scope: RetryScope<'_>,
    device: RetriedDevice,
    retries_done: u32,
    error: DeviceError,
) -> Result<DeviceError, RetryOutcome> {
    if (scope.stop)().is_some() {
        return Err(RetryOutcome::Cancelled);
    }
    let budget = device.budget(scope.run.device_retry.get());
    let fault = classify_device_fault(&error);
    if fault == DeviceFault::Cancelled {
        return Err(RetryOutcome::Cancelled);
    }
    if retries_done >= budget || fault != DeviceFault::Transient {
        return Err(RetryOutcome::GiveUp(DeviceFailure {
            error,
            retries: retries_done,
        }));
    }
    Ok(error)
}

/// Log and send the retry as a run warning (`next` says what happens next),
/// then wait out `delay`.
async fn announce_and_wait(
    scope: RetryScope<'_>,
    device: RetriedDevice,
    error: &DeviceError,
    what: &str,
    next: &str,
    delay: Duration,
) -> RetryOutcome {
    let message = format!("{} failed {}: {}. {}", device.label(), what, error, next);
    tracing::warn!("[RETRY] {}", message);
    if let Some(event_tx) = &scope.run.event_tx {
        let _ = event_tx.send(crate::executor::ExecutorEvent::Warning { message });
    }

    tokio::select! {
        biased;
        _ = wait_for_stop(scope.stop) => RetryOutcome::Cancelled,
        _ = sleep(delay) => RetryOutcome::Retry,
    }
}

/// Reopens of the camera that one operation gets back from its retry budget.
/// A power box whose link flaps breaks the camera's session again and again;
/// each reopen that succeeds is free up to this many, so the flapping does not
/// use up the retries, and the operation still ends.
pub(crate) const FREE_REOPENS_PER_OPERATION: u32 = 5;

/// The retries of one camera operation (a frame, a centering frame, an
/// autofocus sample) under the run's camera retry budget.
///
/// Every failure that means the camera's session is broken (it answers
/// status reads but takes no exposure, as a ZWO camera does after its USB
/// path drops) reopens the camera before the retry: retrying on the broken
/// session fails every time. The first [`FREE_REOPENS_PER_OPERATION`]
/// successful reopens do not count against the budget; later ones do. The
/// reopen restores the cooler first, so it happens at once, before the
/// backoff. A reopen that fails ends the operation as a lost camera, for
/// device-disconnect recovery.
pub(crate) struct CameraRetries<'a> {
    camera_id: &'a str,
    done: u32,
    reopens: u32,
    /// The camera was reopened since [`Self::take_reopened`] last asked.
    reopened: bool,
}

impl<'a> CameraRetries<'a> {
    pub(crate) fn new(camera_id: &'a str) -> Self {
        Self {
            camera_id,
            done: 0,
            reopens: 0,
            reopened: false,
        }
    }

    /// Whether the camera was reopened since the last ask. A reopen after a
    /// power loss leaves the sensor warmer than its set-point.
    pub(crate) fn take_reopened(&mut self) -> bool {
        std::mem::take(&mut self.reopened)
    }

    /// [`after_failed_attempt`] for the camera, with the reopen above.
    pub(crate) async fn after_failure(
        &mut self,
        scope: RetryScope<'_>,
        error: DeviceError,
        what: &str,
    ) -> RetryOutcome {
        let error = match retry_or_stop(scope, RetriedDevice::Camera, self.done, error) {
            Ok(error) => error,
            Err(outcome) => return outcome,
        };
        let reopened = match scope
            .run
            .device_ops
            .reopen_camera_after(self.camera_id, &error)
            .await
        {
            Ok(reopened) => reopened,
            Err(reopen_error) => {
                tracing::warn!(
                    "[RETRY] Reopening camera {} after \"{}\" failed: {}",
                    self.camera_id,
                    error,
                    reopen_error
                );
                return RetryOutcome::GiveUp(DeviceFailure {
                    error: DeviceError::NotConnected {
                        device: crate::device_ops::DeviceKind::Camera,
                        message: format!("{error}; reopening the camera failed: {reopen_error}"),
                    },
                    retries: self.done,
                });
            }
        };
        // The wait grows with every retry, free or counted.
        let delay = retry_backoff(self.done + self.reopens.min(FREE_REOPENS_PER_OPERATION) + 1);
        if reopened {
            self.reopens += 1;
            self.reopened = true;
        }
        let free = reopened && self.reopens <= FREE_REOPENS_PER_OPERATION;
        let budget = RetriedDevice::Camera.budget(scope.run.device_retry.get());
        let next = if free {
            format!(
                "Reopened the camera; retrying in {} s (reopen {} of {} that do not count \
                 against the {} retries).",
                delay.as_secs(),
                self.reopens,
                FREE_REOPENS_PER_OPERATION,
                budget
            )
        } else {
            let retry = format!(
                "in {} s (retry {} of {}).",
                delay.as_secs(),
                self.done + 1,
                budget
            );
            if reopened {
                format!("Reopened the camera; retrying {retry}")
            } else {
                format!("Retrying {retry}")
            }
        };
        let outcome =
            announce_and_wait(scope, RetriedDevice::Camera, &error, what, &next, delay).await;
        if outcome == RetryOutcome::Retry && !free {
            self.done += 1;
        }
        outcome
    }
}

/// The slot a filter-wheel move is aimed at.
#[derive(Debug, Clone, Copy)]
pub(crate) enum WheelTarget<'a> {
    Position(i32),
    Name(&'a str),
}

/// Move the filter wheel, retrying transient faults under the run's filter
/// wheel retry budget. Returns the slot the wheel was sent to.
///
/// With `arrival_timeout` set the move counts only once the wheel reads back
/// at that slot, so a wheel that accepts the command and never arrives (a
/// stalled or jammed wheel) times out and is retried like any other fault.
/// Without it the command's own success is taken, as the capture loop's
/// per-burst filter set always has.
///
/// A Stop fails the move as [`DeviceError::Cancelled`].
pub(crate) async fn move_filter_wheel(
    ctx: &InstructionContext,
    fw_id: &str,
    target: WheelTarget<'_>,
    arrival_timeout: Option<Duration>,
) -> Result<i32, DeviceFailure> {
    let what = match target {
        WheelTarget::Position(index) => format!("moving to position {index}"),
        WheelTarget::Name(name) => format!("moving to {name}"),
    };
    let mut retries_done = 0u32;
    loop {
        let attempt = async {
            let position = match target {
                WheelTarget::Position(index) => ctx
                    .run
                    .device_ops
                    .filterwheel_set_position(fw_id, index)
                    .await
                    .map(|()| index),
                WheelTarget::Name(name) => {
                    ctx.run
                        .device_ops
                        .filterwheel_set_filter_by_name(fw_id, name)
                        .await
                }
            }?;
            if let Some(timeout) = arrival_timeout {
                wait_for_filterwheel_idle(fw_id, position, ctx, timeout).await?;
            }
            Ok::<i32, DeviceError>(position)
        }
        .await;
        let error = match attempt {
            Ok(position) => return Ok(position),
            Err(error) => error,
        };
        match after_failed_attempt(ctx, RetriedDevice::FilterWheel, retries_done, error, &what)
            .await
        {
            RetryOutcome::Retry => retries_done += 1,
            RetryOutcome::GiveUp(failure) => return Err(failure),
            RetryOutcome::Cancelled => {
                return Err(DeviceFailure {
                    error: DeviceError::Cancelled("Operation cancelled".to_string()),
                    retries: retries_done,
                })
            }
        }
    }
}
