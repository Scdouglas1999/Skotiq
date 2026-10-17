//! `wait_time` tests — moved verbatim out of the former single `instructions::tests`
//! module (release-pass C3 mechanical split). Shared fixtures stay in the parent
//! `tests` module and reach here through `use super::*;`.

use super::*;

// Wait node with no condition

/// An unconfigured Wait node must fail rather than return Success in
/// microseconds: the canonical use is "wait until astronomical dark", so
/// skipping it starts the run in daylight.
#[tokio::test]
async fn wait_time_without_any_condition_fails() {
    let ctx = crate::node::context::ExecutionContext::new_for_test("test-node".to_string())
        .to_instruction_context("test-node")
        .await;

    let result = execute_wait_time(&WaitTimeConfig::default(), &ctx, None).await;

    assert_eq!(
        result.status,
        NodeStatus::Failure,
        "a Wait node with neither a time nor a twilight condition must not report Success"
    );
    let msg = result.message.unwrap_or_default();
    assert!(
        msg.contains("no wait condition"),
        "the failure must name the missing configuration, got: {msg}"
    );
}
