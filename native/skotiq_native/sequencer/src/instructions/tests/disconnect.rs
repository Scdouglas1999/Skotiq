//! `disconnect` tests — moved verbatim out of the former single `instructions::tests`
//! module (release-pass C3 mechanical split). Shared fixtures stay in the parent
//! `tests` module and reach here through `use super::*;`.

use super::*;

#[test]
fn device_disconnect_messages_are_classified_narrowly() {
    assert!(is_device_disconnected_message("No camera connected"));
    assert!(is_device_disconnected_message(
            "Device 'cam1' is not connected. Cannot perform: exposure. Please reconnect the device first."
        ));
    assert!(is_device_disconnected_message(
        "Filter wheel is not connected"
    ));

    assert!(!is_device_disconnected_message(
        "No target coordinates available"
    ));
    assert!(!is_device_disconnected_message(
        "Plate solve returned no solution"
    ));
    assert!(!is_device_disconnected_message("Script exited with code 1"));
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
        let result = InstructionResult::failure("No camera connected");
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
