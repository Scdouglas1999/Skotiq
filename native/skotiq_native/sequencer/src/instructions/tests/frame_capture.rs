//! The one frame-capture path (`instructions::frame_capture`): each of the
//! twelve sites that take a camera frame, and how it takes it.

use super::*;

const BROKEN: &str =
    "Failed to check exposure status: SDK error: ZWO camera reported a failed exposure";

/// Every frame taker of the sequencer and the policy it takes its frame
/// with. Every frame of a run gets the run's camera retries (and so the
/// reopen of a broken session), except the secondary rig, which has no run
/// of its own.
#[test]
fn the_twelve_capture_sites_and_their_policy() {
    use CaptureSite::*;
    use FrameRetries::{None as Once, RunCameraBudget as Retried};
    use StopWatch::{Abort, AfterTheFrame as After, Poll};
    // (site, watch, abort if dropped, retries, set-point hold after a reopen)
    let table = [
        (
            ExposureFrame,
            Abort { stop_first: true },
            true,
            Retried,
            true,
        ),
        (
            CenterFrame,
            Abort { stop_first: false },
            false,
            Retried,
            false,
        ),
        (AutofocusSample, After, true, Retried, false),
        (AutofocusVerify, After, true, Retried, false),
        (BacklashCalibration, After, true, Retried, false),
        (SecondaryRig, Poll, false, Once, false),
        (FlatWizardTest, After, false, Retried, false),
        (AllSkyPolar, After, false, Retried, false),
        (PolarAlignMeasure, After, false, Retried, false),
        (PolarAlignAdjust, After, false, Retried, false),
        (FlipCenter, After, false, Retried, false),
        (FlipNearbyRecovery, After, false, Retried, false),
    ];
    assert_eq!(
        table.map(|row| row.0),
        CaptureSite::ALL,
        "one row per site, in order"
    );
    for (site, watch, abort_if_dropped, retries, hold) in table {
        assert_eq!(
            site.policy(),
            CapturePolicy {
                watch,
                abort_if_dropped,
                retries,
                hold_set_point_after_reopen: hold,
            },
            "{site:?}"
        );
    }
}

async fn run_ctx(ops: Arc<ScriptedDomeRotatorOps>) -> InstructionContext {
    let mut ctx = ctx_with_ops(ops).await;
    ctx.run.device_retry = DeviceRetryHandle::new(DeviceRetryPolicy::default());
    ctx
}

/// Each site's frame on a camera whose session broke: the sites with the
/// run's camera retries reopen it and get the frame; the others fail with the
/// camera's own words and leave the camera as it is.
#[tokio::test(start_paused = true)]
async fn a_broken_session_is_reopened_only_where_the_site_retries() {
    for site in CaptureSite::ALL {
        let ops = Arc::new(ScriptedDomeRotatorOps::new().with_broken_camera_session(BROKEN));
        let ctx = run_ctx(ops.clone()).await;
        let result = take_frame(
            &ctx,
            site,
            crate::device_ops::ExposureRequest::new("camera-1", 0.0),
            "on a test frame",
        )
        .await;
        let reopens = ops.camera_reopens.load(Ordering::SeqCst);
        match site.policy().retries {
            FrameRetries::RunCameraBudget => {
                assert!(result.is_ok(), "{site:?}: {result:?}");
                assert_eq!(reopens, 1, "{site:?}");
            }
            FrameRetries::None => {
                match result {
                    Err(FrameEnd::Failed(failure)) => {
                        assert_eq!(failure.retries, 0, "{site:?}");
                        assert_eq!(failure.to_string(), BROKEN, "{site:?}");
                    }
                    other => panic!("{site:?}: {other:?}"),
                }
                assert_eq!(reopens, 0, "{site:?}");
            }
        }
    }
}

/// A site without retries reports its failure even when the run was stopped
/// meanwhile; only a retry's wait turns a failure into a stop.
#[tokio::test(start_paused = true)]
async fn a_single_attempt_failure_is_not_read_as_a_stop() {
    assert_eq!(
        CaptureSite::SecondaryRig.policy().retries,
        FrameRetries::None
    );
    let ops = Arc::new(ScriptedDomeRotatorOps::new().failing_exposures(&["download failed"]));
    let ctx = run_ctx(ops).await;
    ctx.cancellation_token.store(true, Ordering::SeqCst);
    let result = take_frame(
        &ctx,
        CaptureSite::SecondaryRig,
        crate::device_ops::ExposureRequest::new("camera-1", 0.0),
        "on a test frame",
    )
    .await;
    assert!(matches!(result, Err(FrameEnd::Failed(_))), "{result:?}");
}

/// A stop while the camera exposes aborts it for the sites that watch for
/// one, once; the others wait the frame out.
#[tokio::test(start_paused = true)]
async fn a_stop_mid_frame_aborts_the_camera_where_the_site_watches() {
    for site in [
        CaptureSite::ExposureFrame,
        CaptureSite::CenterFrame,
        CaptureSite::SecondaryRig,
    ] {
        let ops = Arc::new(ScriptedDomeRotatorOps::new().with_hanging_camera());
        let ctx = run_ctx(ops.clone()).await;
        let token = ctx.cancellation_token.clone();
        tokio::spawn(async move {
            sleep(Duration::from_secs(1)).await;
            token.store(true, Ordering::SeqCst);
        });
        let result = take_frame(
            &ctx,
            site,
            crate::device_ops::ExposureRequest::new("camera-1", 60.0),
            "on a test frame",
        )
        .await;
        assert!(
            matches!(result, Err(FrameEnd::Stopped { abort: Ok(()) })),
            "{site:?}: {result:?}"
        );
        assert_eq!(ops.camera_abort_calls.load(Ordering::SeqCst), 1, "{site:?}");
    }

    let ops = Arc::new(ScriptedDomeRotatorOps::new().with_hanging_camera());
    let ctx = run_ctx(ops.clone()).await;
    ctx.cancellation_token.store(true, Ordering::SeqCst);
    let waited = tokio::time::timeout(
        Duration::from_secs(5),
        take_frame(
            &ctx,
            CaptureSite::AutofocusVerify,
            crate::device_ops::ExposureRequest::new("camera-1", 60.0),
            "on a test frame",
        ),
    )
    .await;
    assert!(
        waited.is_err(),
        "the verify frame is not watched for a stop"
    );
}

/// A frame dropped mid-exposure aborts the camera where the site arms the
/// drop guard, and not where it does not.
#[tokio::test]
async fn a_dropped_frame_aborts_the_camera_where_the_site_guards_it() {
    for site in CaptureSite::ALL {
        let ops = Arc::new(ScriptedDomeRotatorOps::new().with_hanging_camera());
        let device_ops: SharedDeviceOps = ops.clone();
        let dropped = tokio::time::timeout(
            Duration::from_millis(20),
            expose_frame(
                &device_ops,
                crate::device_ops::ExposureRequest::new("camera-1", 60.0),
                site.policy(),
                &|| None,
            ),
        )
        .await;
        assert!(dropped.is_err(), "{site:?}");
        tokio::task::yield_now().await;
        tokio::time::sleep(Duration::from_millis(20)).await;
        let expected = u32::from(site.policy().abort_if_dropped);
        assert_eq!(
            ops.camera_abort_calls.load(Ordering::SeqCst),
            expected,
            "{site:?}"
        );
    }
}

/// The secondary rig's frame is cut short for a dither: the camera is
/// aborted and the stop says why.
#[tokio::test(start_paused = true)]
async fn the_secondary_rig_frame_is_cut_short_for_a_dither() {
    let ops = Arc::new(ScriptedDomeRotatorOps::new().with_hanging_camera());
    let device_ops: SharedDeviceOps = ops.clone();
    let started = tokio::time::Instant::now();
    let cut = || (started.elapsed() >= Duration::from_secs(1)).then_some(FrameStop::CutShort);
    let exposed = expose_frame(
        &device_ops,
        crate::device_ops::ExposureRequest::new("camera-1", 60.0),
        CaptureSite::SecondaryRig.policy(),
        &cut,
    )
    .await;
    assert!(
        matches!(
            exposed,
            Err(Unexposed::Stopped {
                stop: FrameStop::CutShort,
                abort: Ok(())
            })
        ),
        "{exposed:?}"
    );
    assert_eq!(ops.camera_abort_calls.load(Ordering::SeqCst), 1);
}

/// Every frame of a run, whatever takes it, gets the camera reopened when
/// its session broke and is taken again.
#[tokio::test(start_paused = true)]
async fn every_run_frame_reopens_a_broken_camera_session() {
    for site in CaptureSite::ALL {
        if site == CaptureSite::SecondaryRig {
            continue;
        }
        let ops = Arc::new(ScriptedDomeRotatorOps::new().with_broken_camera_session(BROKEN));
        let ctx = run_ctx(ops.clone()).await;
        let result = take_frame(
            &ctx,
            site,
            crate::device_ops::ExposureRequest::new("camera-1", 0.0),
            "on a test frame",
        )
        .await;
        assert!(result.is_ok(), "{site:?}: {result:?}");
        assert_eq!(ops.camera_reopens.load(Ordering::SeqCst), 1, "{site:?}");
    }
}
