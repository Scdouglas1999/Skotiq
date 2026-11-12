//! What a node reports for an instruction that fell short: the run's one
//! policy over [`Setback`].

use super::*;

struct Settled {
    status: NodeStatus,
    warnings: Vec<String>,
    failures: Vec<String>,
    recovery_requested: bool,
}

async fn settle_with(result: InstructionResult, stop_on_quality_problems: bool) -> Settled {
    let mut ctx = expose_ctx(Arc::new(NullDeviceOps), None, live_sun_alt() + 5.0).await;
    if let Some(state) = &ctx.run.trigger_state {
        state.write().await.settings.stop_on_quality_problems = stop_on_quality_problems;
    }
    let (event_tx, mut events) = tokio::sync::broadcast::channel(16);
    ctx.run.event_tx = Some(event_tx);
    let status = result.settle("Step", &ctx).await;
    let mut warnings = Vec::new();
    let mut failures = Vec::new();
    while let Ok(event) = events.try_recv() {
        match event {
            crate::executor::ExecutorEvent::Warning { message } => warnings.push(message),
            crate::executor::ExecutorEvent::InstructionFailed { message, .. } => {
                failures.push(message)
            }
            _ => {}
        }
    }
    Settled {
        status,
        warnings,
        failures,
        recovery_requested: ctx
            .run
            .device_disconnect_recovery_pending
            .load(std::sync::atomic::Ordering::Relaxed),
    }
}

/// Quality problems notify and the run goes on past the step; only an
/// operator who chose to stop on quality problems stops for a slew off target
/// or a centering that did not converge.
#[tokio::test]
async fn quality_problems_notify_and_the_run_goes_on() {
    for setback in [Setback::OffTarget, Setback::CenterNotConverged] {
        let carried_on =
            settle_with(InstructionResult::failure_because("off", setback), false).await;
        assert_eq!(carried_on.status, NodeStatus::Skipped, "{setback:?}");
        assert_eq!(carried_on.warnings.len(), 1, "{setback:?}");
        assert!(carried_on.failures.is_empty(), "{setback:?}");

        let stopped = settle_with(InstructionResult::failure_because("off", setback), true).await;
        assert_eq!(stopped.status, NodeStatus::Failure, "{setback:?}");
        assert_eq!(stopped.failures, vec!["off".to_string()], "{setback:?}");
    }
}

/// Flats that did not converge and a missed focus never stop the run, even
/// for an operator who stops on quality problems.
#[tokio::test]
async fn missed_flats_and_focus_always_carry_on() {
    for setback in [
        Setback::FlatsNotConverged,
        Setback::FocusNotFound {
            focuser_before: Some(1200),
        },
    ] {
        let settled =
            settle_with(InstructionResult::failure_because("missed", setback), true).await;
        assert_eq!(settled.status, NodeStatus::Skipped, "{setback:?}");
        assert_eq!(settled.warnings.len(), 1, "{setback:?}");
        assert!(settled.failures.is_empty(), "{setback:?}");
    }
}

/// A device that dropped is recovered before anything else is judged, so a
/// lost device wins over the setback the instruction named.
#[tokio::test]
async fn a_dropped_device_is_recovered_whatever_the_instruction_said() {
    let lost = DeviceError::NotConnected {
        device: crate::device_ops::DeviceKind::Camera,
        message: "Not connected to INDI server".to_string(),
    };
    let settled = settle_with(
        InstructionResult::failure_because(
            format!("Autofocus exposure failed: {lost}"),
            Setback::FocusNotFound {
                focuser_before: None,
            },
        )
        .caused_by(&lost),
        false,
    )
    .await;
    assert_eq!(settled.status, NodeStatus::Failure);
    assert!(settled.recovery_requested);
    assert!(settled.warnings.is_empty());
}

/// A sweep that left the guider stopped is not a missed focus: it fails, so
/// the caller that can hold the run decides.
#[tokio::test]
async fn a_guider_left_stopped_fails_the_step() {
    let settled = settle_with(
        InstructionResult::failure_because("guider did not resume", Setback::GuidingNotRestored),
        false,
    )
    .await;
    assert_eq!(settled.status, NodeStatus::Failure);
    assert!(!settled.recovery_requested);
    assert_eq!(settled.failures, vec!["guider did not resume".to_string()]);
}
