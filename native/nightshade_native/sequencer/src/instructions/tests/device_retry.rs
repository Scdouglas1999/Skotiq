//! Camera and filter-wheel retries (`instructions::device_retry`).
//!
//! The simulator night soak lost whole runs to a single failed download and a
//! single failed wheel move. These pin the retry: a transient fault is retried
//! under the operator's budget, the frame or filter lands, nothing is written
//! twice; a fault that cannot clear is not retried; zero retries is the old
//! single attempt; Stop during the wait between attempts stops at once.

use super::*;

const DOWNLOAD_ERROR: &str =
    "Failed to download image: Injected simulator fault: the driver reported a failure";
const WHEEL_ERROR: &str =
    "Set position failed: Injected simulator fault: the driver reported a failure";

async fn retrying_ctx(
    ops: Arc<ScriptedDomeRotatorOps>,
    policy: DeviceRetryPolicy,
) -> (
    InstructionContext,
    tokio::sync::broadcast::Receiver<crate::executor::ExecutorEvent>,
    std::path::PathBuf,
) {
    let mut ctx = ctx_with_ops(ops).await;
    let dir = std::env::temp_dir().join(format!("ns-device-retry-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&dir).expect("temp dir");
    ctx.save_path = Some(dir.clone());
    ctx.device_retry = DeviceRetryHandle::new(policy);
    let (tx, rx) = tokio::sync::broadcast::channel(64);
    ctx.event_tx = Some(tx);
    (ctx, rx, dir)
}

fn darks(count: u32) -> ExposureConfig {
    ExposureConfig {
        count,
        duration_secs: 0.0,
        frame_type: "dark".to_string(),
        ..ExposureConfig::default()
    }
}

fn retry_warnings(
    events: &mut tokio::sync::broadcast::Receiver<crate::executor::ExecutorEvent>,
) -> Vec<String> {
    let mut warnings = Vec::new();
    while let Ok(event) = events.try_recv() {
        if let crate::executor::ExecutorEvent::Warning { message } = event {
            warnings.push(message);
        }
    }
    warnings
}

#[tokio::test(start_paused = true)]
async fn a_failed_download_retries_the_frame_and_the_burst_completes() {
    let ops = Arc::new(ScriptedDomeRotatorOps::new().failing_exposures(&[DOWNLOAD_ERROR]));
    let (ctx, mut events, dir) = retrying_ctx(ops.clone(), DeviceRetryPolicy::default()).await;

    let result = execute_exposure(&darks(3), &ctx, |_, _, _| {}).await;
    let _ = std::fs::remove_dir_all(&dir);

    assert_eq!(result.status, NodeStatus::Success, "{:?}", result.message);
    assert_eq!(
        ops.camera_exposure_calls.load(Ordering::SeqCst),
        4,
        "frame 1 is exposed again after its failed download"
    );
    let saved = ops.saved_frame_paths.lock().unwrap().clone();
    assert_eq!(
        saved.len(),
        3,
        "one file per frame and none for the failed attempt: {saved:?}"
    );
    let distinct: std::collections::HashSet<_> = saved.iter().collect();
    assert_eq!(distinct.len(), 3, "no frame is written twice: {saved:?}");
    let contexts = ops.saved_frame_contexts.lock().unwrap().clone();
    let numbers: Vec<_> = contexts.iter().map(|c| c.frame_index).collect();
    assert_eq!(numbers, vec![1, 2, 3], "the retried frame keeps its number");

    let warnings = retry_warnings(&mut events);
    assert_eq!(warnings.len(), 1, "{warnings:?}");
    assert!(
        warnings[0].contains("Camera failed on frame 1/3")
            && warnings[0].contains(DOWNLOAD_ERROR)
            && warnings[0].contains("Retrying in 2 s (retry 1 of 3)"),
        "the operator is told what failed and that it is being retried: {}",
        warnings[0]
    );
}

#[tokio::test(start_paused = true)]
async fn camera_retries_exhausted_fail_the_burst_as_before() {
    let ops = Arc::new(ScriptedDomeRotatorOps::new().failing_exposures(&[DOWNLOAD_ERROR; 4]));
    let (ctx, mut events, dir) = retrying_ctx(ops.clone(), DeviceRetryPolicy::default()).await;

    let started = tokio::time::Instant::now();
    let result = execute_exposure(&darks(2), &ctx, |_, _, _| {}).await;
    let waited = started.elapsed();
    let _ = std::fs::remove_dir_all(&dir);

    assert_eq!(result.status, NodeStatus::Failure);
    assert_eq!(
        result.message.as_deref(),
        Some(format!("Exposure failed: {DOWNLOAD_ERROR} (after 3 retries)").as_str())
    );
    assert_eq!(ops.camera_exposure_calls.load(Ordering::SeqCst), 4);
    assert!(ops.saved_frame_paths.lock().unwrap().is_empty());
    assert_eq!(retry_warnings(&mut events).len(), 3);
    assert_eq!(
        waited.as_secs(),
        2 + 5 + 10,
        "the backoff is 2 s, 5 s, 10 s"
    );
}

#[tokio::test(start_paused = true)]
async fn zero_camera_retries_is_a_single_attempt() {
    let ops = Arc::new(ScriptedDomeRotatorOps::new().failing_exposures(&[DOWNLOAD_ERROR]));
    let (ctx, mut events, dir) = retrying_ctx(
        ops.clone(),
        DeviceRetryPolicy {
            camera_retries: 0,
            filter_wheel_retries: 3,
        },
    )
    .await;

    let result = execute_exposure(&darks(2), &ctx, |_, _, _| {}).await;
    let _ = std::fs::remove_dir_all(&dir);

    assert_eq!(result.status, NodeStatus::Failure);
    assert_eq!(
        result.message.as_deref(),
        Some(format!("Exposure failed: {DOWNLOAD_ERROR}").as_str()),
        "the message is exactly what it was before retries existed"
    );
    assert_eq!(ops.camera_exposure_calls.load(Ordering::SeqCst), 1);
    assert!(retry_warnings(&mut events).is_empty());
}

/// A context with no run behind it (an Imaging-tab capture, a wizard) keeps
/// the single attempt.
#[tokio::test(start_paused = true)]
async fn a_context_outside_a_run_does_not_retry() {
    let ops = Arc::new(ScriptedDomeRotatorOps::new().failing_exposures(&[DOWNLOAD_ERROR]));
    let ctx = ctx_with_ops(ops.clone()).await;
    assert_eq!(ctx.device_retry.get(), DeviceRetryPolicy::SINGLE_ATTEMPT);

    let result = execute_exposure(&darks(1), &ctx, |_, _, _| {}).await;

    assert_eq!(result.status, NodeStatus::Failure);
    assert_eq!(ops.camera_exposure_calls.load(Ordering::SeqCst), 1);
}

#[tokio::test(start_paused = true)]
async fn a_disconnected_camera_is_left_to_disconnect_recovery() {
    let error = "Camera is not connected";
    let ops = Arc::new(ScriptedDomeRotatorOps::new().failing_exposures(&[error]));
    let (ctx, mut events, dir) = retrying_ctx(ops.clone(), DeviceRetryPolicy::default()).await;

    let result = execute_exposure(&darks(1), &ctx, |_, _, _| {}).await;
    let _ = std::fs::remove_dir_all(&dir);

    assert_eq!(result.status, NodeStatus::Failure);
    assert_eq!(
        ops.camera_exposure_calls.load(Ordering::SeqCst),
        1,
        "retrying a call to a device that is gone cannot work; the disconnect \
         recovery reconnects it and re-runs the node"
    );
    let message = result.message.unwrap_or_default();
    assert!(
        is_device_disconnected_message(&message),
        "the failure must still read as a disconnect so recovery picks it up: {message}"
    );
    assert!(retry_warnings(&mut events).is_empty());
}

#[tokio::test(start_paused = true)]
async fn a_frame_that_fails_image_validation_is_not_retried() {
    let error = "Image validation failed: image is saturated";
    let ops = Arc::new(ScriptedDomeRotatorOps::new().failing_exposures(&[error]));
    let (ctx, _events, dir) = retrying_ctx(ops.clone(), DeviceRetryPolicy::default()).await;

    let result = execute_exposure(&darks(1), &ctx, |_, _, _| {}).await;
    let _ = std::fs::remove_dir_all(&dir);

    assert_eq!(result.status, NodeStatus::Failure);
    assert_eq!(ops.camera_exposure_calls.load(Ordering::SeqCst), 1);
}

/// Stop while the retry waits returns at once, not after the backoff. Real
/// time, so the 2 s wait is genuinely in the way.
#[tokio::test]
async fn stop_during_the_retry_wait_returns_promptly() {
    let ops = Arc::new(ScriptedDomeRotatorOps::new().failing_exposures(&[DOWNLOAD_ERROR]));
    let (ctx, mut events, dir) = retrying_ctx(ops.clone(), DeviceRetryPolicy::default()).await;
    let cancel = ctx.cancellation_token.clone();

    let task = tokio::spawn(async move { execute_exposure(&darks(2), &ctx, |_, _, _| {}).await });
    loop {
        match events.recv().await {
            Ok(crate::executor::ExecutorEvent::Warning { message })
                if message.contains("Retrying in") =>
            {
                break
            }
            Ok(_) => {}
            Err(e) => panic!("no retry announced: {e}"),
        }
    }
    let stopped_at = std::time::Instant::now();
    cancel.store(true, Ordering::SeqCst);
    let result = tokio::time::timeout(Duration::from_secs(1), task)
        .await
        .expect("Stop must not wait out the backoff")
        .expect("task");
    let _ = std::fs::remove_dir_all(&dir);

    assert!(stopped_at.elapsed() < Duration::from_millis(500));
    assert_eq!(result.status, NodeStatus::Cancelled);
    assert_eq!(
        ops.camera_exposure_calls.load(Ordering::SeqCst),
        1,
        "no new attempt after Stop"
    );
}

#[tokio::test(start_paused = true)]
async fn a_failed_wheel_move_is_retried_and_the_filter_lands() {
    let ops = Arc::new(ScriptedDomeRotatorOps::new().failing_filter_moves(&[WHEEL_ERROR]));
    let (ctx, mut events, dir) = retrying_ctx(ops.clone(), DeviceRetryPolicy::default()).await;
    let config = FilterConfig {
        filter_name: "R".to_string(),
        filter_index: Some(2),
        timeout_secs: None,
    };

    let result = execute_filter_change(&config, &ctx, None).await;
    let _ = std::fs::remove_dir_all(&dir);

    assert_eq!(result.status, NodeStatus::Success, "{:?}", result.message);
    assert_eq!(*ops.filter_moves.lock().unwrap(), vec![2, 2]);
    assert_eq!(ops.filter_position.load(Ordering::SeqCst), 2);
    let warnings = retry_warnings(&mut events);
    assert_eq!(warnings.len(), 1, "{warnings:?}");
    assert!(
        warnings[0].contains("Filter wheel failed moving to position 2"),
        "{}",
        warnings[0]
    );
}

/// A wheel that accepts the move and never arrives is caught by the
/// position read-back timeout, and the move is commanded again.
#[tokio::test(start_paused = true)]
async fn a_stalled_wheel_times_out_and_the_move_is_retried() {
    let ops = Arc::new(ScriptedDomeRotatorOps::new().stalling_filter_moves(1));
    let (ctx, mut events, dir) = retrying_ctx(ops.clone(), DeviceRetryPolicy::default()).await;
    let config = FilterConfig {
        filter_name: "R".to_string(),
        filter_index: Some(2),
        timeout_secs: Some(5),
    };

    let result = execute_filter_change(&config, &ctx, None).await;
    let _ = std::fs::remove_dir_all(&dir);

    assert_eq!(result.status, NodeStatus::Success, "{:?}", result.message);
    assert_eq!(*ops.filter_moves.lock().unwrap(), vec![2, 2]);
    let warnings = retry_warnings(&mut events);
    assert_eq!(warnings.len(), 1, "{warnings:?}");
    assert!(warnings[0].contains("timed out"), "{}", warnings[0]);
}

#[tokio::test(start_paused = true)]
async fn wheel_retries_exhausted_fail_the_change_as_before() {
    let ops = Arc::new(ScriptedDomeRotatorOps::new().failing_filter_moves(&[WHEEL_ERROR; 4]));
    let (ctx, _events, dir) = retrying_ctx(ops.clone(), DeviceRetryPolicy::default()).await;
    let config = FilterConfig {
        filter_name: "R".to_string(),
        filter_index: Some(2),
        timeout_secs: None,
    };

    let result = execute_filter_change(&config, &ctx, None).await;
    let _ = std::fs::remove_dir_all(&dir);

    assert_eq!(result.status, NodeStatus::Failure);
    assert_eq!(
        result.message.as_deref(),
        Some(format!("Filter change failed: {WHEEL_ERROR} (after 3 retries)").as_str())
    );
    assert_eq!(ops.filter_moves.lock().unwrap().len(), 4);
}

#[tokio::test(start_paused = true)]
async fn zero_wheel_retries_is_a_single_attempt() {
    let ops = Arc::new(ScriptedDomeRotatorOps::new().failing_filter_moves(&[WHEEL_ERROR]));
    let (ctx, _events, dir) = retrying_ctx(
        ops.clone(),
        DeviceRetryPolicy {
            camera_retries: 3,
            filter_wheel_retries: 0,
        },
    )
    .await;
    let config = FilterConfig {
        filter_name: "R".to_string(),
        filter_index: Some(2),
        timeout_secs: None,
    };

    let result = execute_filter_change(&config, &ctx, None).await;
    let _ = std::fs::remove_dir_all(&dir);

    assert_eq!(result.status, NodeStatus::Failure);
    assert_eq!(
        result.message.as_deref(),
        Some(format!("Filter change failed: {WHEEL_ERROR}").as_str())
    );
    assert_eq!(ops.filter_moves.lock().unwrap().len(), 1);
}

/// The capture loop's own per-burst filter set retries too.
#[tokio::test(start_paused = true)]
async fn the_burst_filter_set_is_retried() {
    let ops = Arc::new(ScriptedDomeRotatorOps::new().failing_filter_moves(&[WHEEL_ERROR]));
    let (ctx, _events, dir) = retrying_ctx(ops.clone(), DeviceRetryPolicy::default()).await;
    let config = ExposureConfig {
        filter: Some("R".to_string()),
        filter_index: Some(1),
        ..darks(1)
    };

    let result = execute_exposure(&config, &ctx, |_, _, _| {}).await;
    let _ = std::fs::remove_dir_all(&dir);

    assert_eq!(result.status, NodeStatus::Success, "{:?}", result.message);
    assert_eq!(*ops.filter_moves.lock().unwrap(), vec![1, 1]);
    assert_eq!(ops.saved_frame_paths.lock().unwrap().len(), 1);
}

/// The centering frame retries a failed download instead of failing Center.
#[tokio::test(start_paused = true)]
async fn the_centering_frame_retries_a_failed_download() {
    let ops = Arc::new(ScriptedDomeRotatorOps::new().failing_exposures(&[DOWNLOAD_ERROR]));
    let (mut ctx, _events, dir) = retrying_ctx(ops.clone(), DeviceRetryPolicy::default()).await;
    ctx.mount_id = Some("mount-1".to_string());
    let config = CenterConfig {
        use_target_coords: false,
        custom_ra: Some(12.0),
        custom_dec: Some(45.0),
        max_attempts: 1,
        ..CenterConfig::default()
    };

    let result = execute_center(&config, &ctx, None).await;
    let _ = std::fs::remove_dir_all(&dir);

    assert_eq!(ops.camera_exposure_calls.load(Ordering::SeqCst), 2);
    assert!(
        !result
            .message
            .as_deref()
            .is_some_and(|m| m.contains("Failed to capture image")),
        "{:?}",
        result.message
    );
}

#[test]
fn faults_are_classified_by_whether_a_retry_can_help() {
    use DeviceFault::*;
    for (error, expected) in [
        (DOWNLOAD_ERROR, Transient),
        (
            "Image download on cam exceeded the 120s timeout — failing the frame so recovery can run",
            Transient,
        ),
        ("Camera not ready", Transient),
        (
            "Exception occurred. (Exception from HRESULT: 0x80020009 (DISP_E_MEMBERNOTFOUND))",
            Transient,
        ),
        (
            "Native filter wheel fw did not reach slot 3 within 60s (last position: Some(1))",
            Transient,
        ),
        ("Exposure cancelled", Cancelled),
        ("Operation cancelled", Cancelled),
        ("Camera is not connected", Disconnected),
        (
            "Simulator device for 'camera.download' is not connected: the driver handle was lost \
             mid-session (injected fault).",
            Disconnected,
        ),
        ("Image validation failed: image is saturated", Refused),
        ("Filter 'Hb' not found", Refused),
        ("Camera subframes are not supported by this device backend", Refused),
        ("Invalid value for gain", Refused),
    ] {
        assert_eq!(classify_device_fault(error), expected, "{error}");
    }
}

#[test]
fn the_policy_is_held_to_the_maximum() {
    let handle = DeviceRetryHandle::new(DeviceRetryPolicy {
        camera_retries: 50,
        filter_wheel_retries: 2,
    });
    assert_eq!(
        handle.get(),
        DeviceRetryPolicy {
            camera_retries: MAX_DEVICE_RETRIES,
            filter_wheel_retries: 2,
        }
    );
    assert_eq!(DeviceRetryPolicy::default().camera_retries, 3);
    assert_eq!(DeviceRetryPolicy::default().filter_wheel_retries, 3);
}
