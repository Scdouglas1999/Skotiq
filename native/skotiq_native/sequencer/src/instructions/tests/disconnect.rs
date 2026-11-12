//! A failure a lost device caused goes to the run's disconnect recovery.

use super::*;

#[test]
fn a_failure_is_a_disconnect_when_a_lost_device_caused_it() {
    let lost = DeviceError::NotConnected {
        device: crate::device_ops::DeviceKind::Mount,
        message: "Device error 1031: Telescope is not connected".to_string(),
    };
    let result = InstructionResult::failure(format!("Slew failed: {lost}")).caused_by(&lost);
    assert_eq!(result.setback(), Some(Setback::Disconnected));
    assert_eq!(
        result.message.as_deref(),
        Some("Slew failed: The mount is not connected (Device error 1031: Telescope is not connected)")
    );

    // A lost device outranks what the instruction made of the failure.
    let parked = InstructionResult::failure_because("The mount is parked", Setback::MountParked)
        .caused_by(&lost);
    assert_eq!(parked.setback(), Some(Setback::Disconnected));

    for other in [
        DeviceError::from("Device not connected"),
        DeviceError::Timeout("Slew timed out".to_string()),
        DeviceError::Rejected("Declination out of range".to_string()),
    ] {
        let result = InstructionResult::failure(format!("Slew failed: {other}")).caused_by(&other);
        assert_eq!(result.setback(), None, "{other}");
    }
}

#[test]
fn disconnected_instruction_failure_posts_recovery_request() {
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    rt.block_on(async {
        let (tx, mut rx) = tokio::sync::mpsc::channel(1);
        let pending = Arc::new(AtomicBool::new(false));
        let result =
            InstructionResult::failure_because("No camera connected", Setback::Disconnected);
        let status = result.log_and_get_status_with_recovery("Exposure", Some(&tx), Some(&pending));

        assert_eq!(status, NodeStatus::Failure);
        // The disconnect failure must mark the shared pending flag so the
        // node-runtime retry wrapper waits for recovery instead of letting
        // the Failure end the sequence.
        assert!(
            pending.load(Ordering::Relaxed),
            "device-disconnect failure must set the recovery-pending flag"
        );
        assert_eq!(
            rx.recv().await,
            Some(crate::recovery::RecoveryCause::DeviceDisconnected)
        );
    });
}

#[test]
fn non_disconnect_failure_does_not_set_recovery_pending() {
    let pending = Arc::new(AtomicBool::new(false));
    let result = InstructionResult::failure("Plate solve returned no solution");
    let status = result.log_and_get_status_with_recovery("Center", None, Some(&pending));
    assert_eq!(status, NodeStatus::Failure);
    assert!(
        !pending.load(Ordering::Relaxed),
        "a non-disconnect failure must NOT trigger device-disconnect recovery"
    );
}
