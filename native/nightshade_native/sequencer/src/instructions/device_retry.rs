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
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
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

/// What kind of failure a device error string describes, for the retry
/// decision.
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

/// Errors a device gives for a request it will refuse every time.
///
/// Image validation failures are here because the bridge already classes them
/// as the operator's exposure to fix (saturated, blank), not a fault.
const REFUSED_MARKERS: &[&str] = &[
    "image validation failed",
    "not supported",
    "not implemented",
    "invalid value",
    "invalid parameter",
    "invalid argument",
    "out of range",
    "not found",
];

pub(crate) fn classify_device_fault(error: &str) -> DeviceFault {
    let lower = error.to_ascii_lowercase();
    if lower.contains("cancel") || lower.contains("aborted") {
        DeviceFault::Cancelled
    } else if is_device_disconnected_message(error) {
        DeviceFault::Disconnected
    } else if REFUSED_MARKERS.iter().any(|marker| lower.contains(marker)) {
        DeviceFault::Refused
    } else {
        DeviceFault::Transient
    }
}

/// What the caller does after a failed attempt.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum RetryOutcome {
    /// The backoff has been waited out; run the attempt again.
    Retry,
    /// Report the failure. Carries the error to report: the device's own text,
    /// with the retries spent added when there were any.
    GiveUp(String),
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
    error: &str,
    what: &str,
) -> RetryOutcome {
    if ctx.cancellation_token.load(Ordering::Relaxed) {
        return RetryOutcome::Cancelled;
    }
    let budget = device.budget(ctx.device_retry.get());
    let give_up = || {
        if retries_done == 0 {
            RetryOutcome::GiveUp(error.to_string())
        } else {
            let plural = if retries_done == 1 {
                "retry"
            } else {
                "retries"
            };
            RetryOutcome::GiveUp(format!("{error} (after {retries_done} {plural})"))
        }
    };
    if retries_done >= budget {
        return give_up();
    }
    match classify_device_fault(error) {
        DeviceFault::Transient => {}
        DeviceFault::Cancelled => return RetryOutcome::Cancelled,
        DeviceFault::Disconnected | DeviceFault::Refused => return give_up(),
    }

    let retry = retries_done + 1;
    let delay = retry_backoff(retry);
    let message = format!(
        "{} failed {}: {}. Retrying in {} s (retry {} of {}).",
        device.label(),
        what,
        error,
        delay.as_secs(),
        retry,
        budget
    );
    tracing::warn!("[RETRY] {}", message);
    if let Some(event_tx) = &ctx.event_tx {
        let _ = event_tx.send(crate::executor::ExecutorEvent::Warning { message });
    }

    tokio::select! {
        biased;
        _ = wait_for_cancellation(ctx.cancellation_token.clone()) => RetryOutcome::Cancelled,
        _ = sleep(delay) => RetryOutcome::Retry,
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
/// The error text is unchanged from the single-attempt path: `Filter change
/// failed: …` for a refused command, the timeout text for a wheel that did not
/// arrive, `Operation cancelled` for a Stop.
pub(crate) async fn move_filter_wheel(
    ctx: &InstructionContext,
    fw_id: &str,
    target: WheelTarget<'_>,
    arrival_timeout: Option<Duration>,
) -> Result<i32, String> {
    let what = match target {
        WheelTarget::Position(index) => format!("moving to position {index}"),
        WheelTarget::Name(name) => format!("moving to {name}"),
    };
    let mut retries_done = 0u32;
    loop {
        let attempt = async {
            let position = match target {
                WheelTarget::Position(index) => ctx
                    .device_ops
                    .filterwheel_set_position(fw_id, index)
                    .await
                    .map(|()| index),
                WheelTarget::Name(name) => {
                    ctx.device_ops
                        .filterwheel_set_filter_by_name(fw_id, name)
                        .await
                }
            }
            .map_err(|e| format!("Filter change failed: {}", e))?;
            if let Some(timeout) = arrival_timeout {
                wait_for_filterwheel_idle(fw_id, position, ctx, timeout).await?;
            }
            Ok::<i32, String>(position)
        }
        .await;
        let error = match attempt {
            Ok(position) => return Ok(position),
            Err(error) => error,
        };
        match after_failed_attempt(ctx, RetriedDevice::FilterWheel, retries_done, &error, &what)
            .await
        {
            RetryOutcome::Retry => retries_done += 1,
            RetryOutcome::GiveUp(message) => return Err(message),
            RetryOutcome::Cancelled => return Err("Operation cancelled".to_string()),
        }
    }
}
