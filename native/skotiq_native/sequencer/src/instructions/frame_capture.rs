//! One camera frame, taken the same way by every frame taker of the run.
//!
//! Twelve places in the sequencer take a frame: the light frame, the
//! centering frame, the autofocus samples and its verify frame, the backlash
//! calibration, the secondary rig, the flat wizard's test exposure, both polar
//! alignments and the meridian flip's solve frames. Each one names its
//! [`CaptureSite`], and the site's [`CapturePolicy`] says how the frame is
//! taken: whether a stop aborts the camera while it exposes, whether a
//! dropped frame aborts it, whether a failed frame is retried under the run's
//! camera retries (with the reopen of a broken camera session that comes with
//! them), and whether the light frame waits at the set-point after a reopen.
//! [`take_frame`] runs a site's frame with its retries; [`expose_frame`] is
//! one attempt, for a site that does work of its own between attempts.

use super::*;
use crate::device_ops::{DeviceError, DeviceResult, ExposureRequest};

/// Why a frame that was exposing was stopped.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum FrameStop {
    /// The run or the operation was stopped.
    Cancel,
    /// The frame is cut short so the primary rig can dither.
    CutShort,
}

/// How a stop is seen while the camera exposes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum StopWatch {
    /// The exposure is awaited to its end; the site checks for a stop after.
    AfterTheFrame,
    /// A stop aborts the camera at once. With `stop_first`, a stop and a
    /// finished frame seen in the same poll count as the stop.
    Abort { stop_first: bool },
    /// The stop is looked at every 100 ms beside the exposure, and the abort
    /// is sent while the exposure is still pending.
    Poll,
}

/// Which retries a failed frame gets.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum FrameRetries {
    /// One attempt; the failure is the site's.
    None,
    /// The run's camera retries ([`CameraRetries`]): a transient fault is
    /// taken again, and a broken camera session is reopened first.
    RunCameraBudget,
}

/// How one site takes its frame.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct CapturePolicy {
    pub(crate) watch: StopWatch,
    /// A frame whose future is dropped mid-exposure aborts the camera
    /// ([`CameraExposureAbortGuard`]).
    pub(crate) abort_if_dropped: bool,
    pub(crate) retries: FrameRetries,
    /// After a reopen the frame waits for the sensor to be back at its
    /// set-point before it is taken again.
    pub(crate) hold_set_point_after_reopen: bool,
}

/// Every place in the sequencer that takes a camera frame.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum CaptureSite {
    /// A frame of an exposure instruction (light, dark, flat, bias).
    ExposureFrame,
    /// A Center attempt's solve frame.
    CenterFrame,
    /// One sample of an autofocus sweep point.
    AutofocusSample,
    /// The frame at the focus the sweep landed on.
    AutofocusVerify,
    /// A backlash calibration sample.
    BacklashCalibration,
    /// A frame of the secondary (dual) rig.
    SecondaryRig,
    /// A test exposure of the flat wizard.
    FlatWizardTest,
    /// A frame of the all-sky polar alignment.
    AllSkyPolar,
    /// A measuring point of the three-point polar alignment.
    PolarAlignMeasure,
    /// A frame of the polar alignment's adjustment loop.
    PolarAlignAdjust,
    /// A solve frame of the meridian flip's centering.
    FlipCenter,
    /// The solve frame of the flip's nearby recovery.
    FlipNearbyRecovery,
}

impl CaptureSite {
    #[cfg(test)]
    pub(crate) const ALL: [Self; 12] = [
        Self::ExposureFrame,
        Self::CenterFrame,
        Self::AutofocusSample,
        Self::AutofocusVerify,
        Self::BacklashCalibration,
        Self::SecondaryRig,
        Self::FlatWizardTest,
        Self::AllSkyPolar,
        Self::PolarAlignMeasure,
        Self::PolarAlignAdjust,
        Self::FlipCenter,
        Self::FlipNearbyRecovery,
    ];

    pub(crate) const fn policy(self) -> CapturePolicy {
        const PLAIN: CapturePolicy = CapturePolicy {
            watch: StopWatch::AfterTheFrame,
            abort_if_dropped: false,
            retries: FrameRetries::None,
            hold_set_point_after_reopen: false,
        };
        match self {
            Self::ExposureFrame => CapturePolicy {
                watch: StopWatch::Abort { stop_first: true },
                abort_if_dropped: true,
                retries: FrameRetries::RunCameraBudget,
                hold_set_point_after_reopen: true,
            },
            Self::CenterFrame => CapturePolicy {
                watch: StopWatch::Abort { stop_first: false },
                retries: FrameRetries::RunCameraBudget,
                ..PLAIN
            },
            Self::AutofocusSample | Self::AutofocusVerify | Self::BacklashCalibration => {
                CapturePolicy {
                    abort_if_dropped: true,
                    retries: FrameRetries::RunCameraBudget,
                    ..PLAIN
                }
            }
            Self::SecondaryRig => CapturePolicy {
                watch: StopWatch::Poll,
                ..PLAIN
            },
            Self::FlatWizardTest
            | Self::AllSkyPolar
            | Self::PolarAlignMeasure
            | Self::PolarAlignAdjust
            | Self::FlipCenter
            | Self::FlipNearbyRecovery => CapturePolicy {
                retries: FrameRetries::RunCameraBudget,
                ..PLAIN
            },
        }
    }
}

/// An attempt at a frame that brought no image.
#[derive(Debug)]
pub(crate) enum Unexposed {
    Failed(DeviceError),
    /// A stop came while the camera exposed; `abort` is how the abort went.
    Stopped {
        stop: FrameStop,
        abort: DeviceResult<()>,
    },
}

/// The stop a run's instruction context watches: its cancellation token.
pub(crate) fn cancel_of(token: &AtomicBool) -> Option<FrameStop> {
    token.load(Ordering::Relaxed).then_some(FrameStop::Cancel)
}

pub(crate) async fn wait_for_stop(stop: &(dyn Fn() -> Option<FrameStop> + Sync)) -> FrameStop {
    loop {
        if let Some(stop) = stop() {
            return stop;
        }
        sleep(Duration::from_millis(100)).await;
    }
}

/// One attempt at a frame from `request.camera_id`, watched for a stop as
/// `policy` says. Only `watch` and `abort_if_dropped` apply here; the retries
/// and the set-point hold are the caller's ([`take_run_frame`], the exposure
/// instruction).
pub(crate) async fn expose_frame(
    device_ops: &SharedDeviceOps,
    request: ExposureRequest<'_>,
    policy: CapturePolicy,
    stop: &(dyn Fn() -> Option<FrameStop> + Sync),
) -> Result<ImageData, Unexposed> {
    let camera_id = request.camera_id;
    let mut abort_guard = policy
        .abort_if_dropped
        .then(|| CameraExposureAbortGuard::new(device_ops.clone(), camera_id.to_string()));
    let disarm = |guard: &mut Option<CameraExposureAbortGuard>| {
        if let Some(guard) = guard {
            guard.disarm();
        }
    };
    let exposure = device_ops.camera_start_exposure(request);
    let finished = match policy.watch {
        StopWatch::AfterTheFrame => exposure.await,
        StopWatch::Abort { stop_first } => {
            let stopped = if stop_first {
                tokio::select! {
                    biased;
                    stop = wait_for_stop(stop) => Err(stop),
                    result = exposure => Ok(result),
                }
            } else {
                tokio::select! {
                    result = exposure => Ok(result),
                    stop = wait_for_stop(stop) => Err(stop),
                }
            };
            match stopped {
                Ok(result) => result,
                Err(stop) => {
                    tracing::info!(
                        "Exposure on {camera_id} stopped ({stop:?}); aborting the camera"
                    );
                    let abort = device_ops.camera_abort_exposure(camera_id).await;
                    if abort.is_ok() {
                        disarm(&mut abort_guard);
                    }
                    return Err(Unexposed::Stopped { stop, abort });
                }
            }
        }
        StopWatch::Poll => {
            tokio::pin!(exposure);
            loop {
                tokio::select! {
                    result = &mut exposure => break result,
                    _ = sleep(Duration::from_millis(100)) => {
                        if let Some(stop) = stop() {
                            let abort = device_ops.camera_abort_exposure(camera_id).await;
                            if abort.is_ok() {
                                disarm(&mut abort_guard);
                            }
                            return Err(Unexposed::Stopped { stop, abort });
                        }
                    }
                }
            }
        }
    };
    disarm(&mut abort_guard);
    match finished {
        Ok(image) => Ok(image),
        Err(error) => Err(Unexposed::Failed(error)),
    }
}

/// How a site's frame ended without an image.
#[derive(Debug)]
pub(crate) enum FrameEnd {
    /// The run was stopped while the camera exposed; `abort` is how the
    /// abort went.
    Stopped { abort: DeviceResult<()> },
    /// The run was stopped while a retry waited.
    Cancelled,
    /// The frame failed, after the retries it had.
    Failed(DeviceFailure),
}

impl std::fmt::Display for FrameEnd {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Stopped { .. } | Self::Cancelled => f.write_str("Exposure cancelled"),
            Self::Failed(failure) => failure.fmt(f),
        }
    }
}

/// `site`'s frame for an instruction: [`take_run_frame`] watching the
/// instruction's cancellation.
pub(crate) async fn take_frame(
    ctx: &InstructionContext,
    site: CaptureSite,
    request: ExposureRequest<'_>,
    what: &str,
) -> Result<ImageData, FrameEnd> {
    let stop = || cancel_of(&ctx.cancellation_token);
    let scope = RetryScope {
        run: &ctx.run,
        stop: &stop,
    };
    take_run_frame(scope, site, request, what).await
}

/// `site`'s frame for a run: [`expose_frame`] under the site's policy, with
/// its retries. `what` names the frame in a retry's warning ("on autofocus
/// point 3").
pub(crate) async fn take_run_frame(
    scope: RetryScope<'_>,
    site: CaptureSite,
    request: ExposureRequest<'_>,
    what: &str,
) -> Result<ImageData, FrameEnd> {
    let policy = site.policy();
    let mut camera_retries = CameraRetries::new(request.camera_id);
    loop {
        let error =
            match expose_frame(&scope.run.device_ops, request.clone(), policy, scope.stop).await {
                Ok(image) => return Ok(image),
                Err(Unexposed::Stopped { abort, .. }) => return Err(FrameEnd::Stopped { abort }),
                Err(Unexposed::Failed(error)) => error,
            };
        if policy.retries == FrameRetries::None {
            return Err(FrameEnd::Failed(DeviceFailure { error, retries: 0 }));
        }
        match camera_retries.after_failure(scope, error, what).await {
            RetryOutcome::Retry => {}
            RetryOutcome::Cancelled => return Err(FrameEnd::Cancelled),
            RetryOutcome::GiveUp(failure) => return Err(FrameEnd::Failed(failure)),
        }
    }
}

#[cfg(test)]
mod all_list_tests {
    #[test]
    fn all_names_every_variant() {
        skotiq_wire_fixtures::assert_lists_every_variant!(
            super::CaptureSite::ALL,
            [
                super::CaptureSite::ExposureFrame,
                super::CaptureSite::CenterFrame,
                super::CaptureSite::AutofocusSample,
                super::CaptureSite::AutofocusVerify,
                super::CaptureSite::BacklashCalibration,
                super::CaptureSite::SecondaryRig,
                super::CaptureSite::FlatWizardTest,
                super::CaptureSite::AllSkyPolar,
                super::CaptureSite::PolarAlignMeasure,
                super::CaptureSite::PolarAlignAdjust,
                super::CaptureSite::FlipCenter,
                super::CaptureSite::FlipNearbyRecovery
            ]
        );
    }
}
