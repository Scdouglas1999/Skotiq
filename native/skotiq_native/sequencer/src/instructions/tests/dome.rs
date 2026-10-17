//! `dome` tests — moved verbatim out of the former single `instructions::tests`
//! module (release-pass C3 mechanical split). Shared fixtures stay in the parent
//! `tests` module and reach here through `use super::*;`.

use super::*;

// dome-park-shutter: park surfaces the shutter-close error + verifies

/// THE hardware-safety guard: when dome park closes the shutter but the
/// close FAILS, `execute_park_dome` must return Failure with the close
/// error surfaced — NOT report "parked" while the scope sits exposed
/// under an open shutter all night. A failed roof returns an error, not
/// success.
///
/// `start_paused = true` keeps this test on the virtual clock so it can
/// never race a concurrent paused test's auto-advance under the
/// multi-threaded runner. (This path returns on the `dome_close` error
/// before reaching the shutter-wait poll loop, so it issues zero shutter
/// polls — that is correct, not a flake.)
#[tokio::test(start_paused = true)]
async fn test_park_dome_surfaces_shutter_close_error() {
    let ops = Arc::new(ScriptedDomeRotatorOps::new().with_dome_close_error("shutter motor jammed"));
    let ctx = ctx_with_ops(ops.clone()).await;
    let cfg = DomeConfig {
        shutter_only: false,
    };

    let result = execute_park_dome(&cfg, &ctx, None).await;

    assert_eq!(
        result.status,
        NodeStatus::Failure,
        "a dome park that cannot close the shutter MUST fail, not report parked"
    );
    let msg = result.message.unwrap_or_default();
    assert!(
        msg.contains("shutter motor jammed"),
        "the underlying close error must be surfaced to the operator, got: {msg}"
    );
    assert_eq!(
        ops.dome_close_calls.load(Ordering::SeqCst),
        1,
        "park must actually attempt to close the shutter"
    );
}

/// Dome park is MOVE-AND-VERIFY: after issuing the close it must poll
/// the shutter status until it actually reads Closed before reporting
/// success. Here the shutter is still "Closing" for the first two polls
/// and only reaches "Closed" on the third.
///
/// A fire-and-forget park reports "parked" while the shutter is still
/// moving.
///
/// `start_paused = true` drives `wait_for_dome_shutter_state`'s
/// `tokio::time::sleep` off the virtual clock (auto-advanced when idle).
/// The scripted shutter states advance one entry per
/// `dome_get_shutter_status` call, so the poll sequence is deterministic:
/// poll 1 → Closing, poll 2 → Closing, poll 3 → Closed (done). This
/// removes the prior wall-clock race against concurrent paused tests.
#[tokio::test(start_paused = true)]
async fn test_park_dome_waits_for_shutter_closed() {
    let ops = Arc::new(
        ScriptedDomeRotatorOps::new().with_dome_shutter_states(&["Closing", "Closing", "Closed"]),
    );
    let ctx = ctx_with_ops(ops.clone()).await;
    let cfg = DomeConfig {
        shutter_only: false,
    };

    let result = execute_park_dome(&cfg, &ctx, None).await;

    assert_eq!(
        result.status,
        NodeStatus::Success,
        "park should succeed once the shutter reads Closed: {:?}",
        result.message
    );
    assert_eq!(
        ops.dome_park_calls.load(Ordering::SeqCst),
        1,
        "the dome park must be issued"
    );
    assert!(
        ops.dome_shutter_status_calls.load(Ordering::SeqCst) >= 2,
        "park must POLL the shutter status until Closed (move-and-verify), got {}",
        ops.dome_shutter_status_calls.load(Ordering::SeqCst)
    );
}

/// A dome whose shutter reports a definite state but never reaches
/// Closed (jammed half-open) must FAIL CLOSED rather than reporting a
/// successful park — otherwise the optics stay exposed to the weather
/// that the close was meant to protect against.
#[tokio::test(start_paused = true)]
async fn test_park_dome_fails_when_shutter_never_closes() {
    // Reports a real state ("Open") forever but never "Closed".
    let ops = Arc::new(ScriptedDomeRotatorOps::new().with_dome_shutter_states(&["Open"]));
    let ctx = ctx_with_ops(ops.clone()).await;
    let cfg = DomeConfig {
        shutter_only: false,
    };

    let result = execute_park_dome(&cfg, &ctx, None).await;

    assert_eq!(
        result.status,
        NodeStatus::Failure,
        "a shutter that reports a real state but never closes must fail closed"
    );
    assert!(
        ops.dome_shutter_status_calls.load(Ordering::SeqCst) >= 2,
        "the timeout must be reached by repeated shutter-status polls"
    );
}

/// `wait_for_dome_shutter_state` must NOT return a clean "Dome shutter
/// closed" success when the shutter state could never be confirmed. A roof
/// that can never report position ("Unknown" forever) is tolerated (a working
/// roll-off must not be failed), but the success message MUST surface that
/// arrival was unconfirmed — otherwise the operator reads "closed" while the
/// roof's true state is unknown.
#[tokio::test(start_paused = true)]
async fn test_close_dome_surfaces_unconfirmed_when_shutter_never_reports_state() {
    // Never a definite state — the dome cannot report shutter position.
    let ops = Arc::new(ScriptedDomeRotatorOps::new().with_dome_shutter_states(&["Unknown"]));
    let ctx = ctx_with_ops(ops.clone()).await;
    let cfg = DomeConfig { shutter_only: true };

    let result = execute_close_dome(&cfg, &ctx, None).await;

    // We do NOT fail a roof that simply can't report position...
    assert_eq!(
        result.status,
        NodeStatus::Success,
        "a roll-off that cannot report shutter position must not be failed"
    );
    // ...but the message must say the position could not be confirmed,
    // never a bare "Dome shutter closed".
    let msg = result.message.unwrap_or_default();
    assert!(
        msg.contains("could not be confirmed"),
        "close must surface the unconfirmed shutter position, got: {msg:?}"
    );
    assert!(
        !msg.eq("Dome shutter closed"),
        "an unconfirmed close must not claim a clean 'Dome shutter closed'"
    );
}

/// Control: a healthy close that confirms Closed reports the plain
/// "Dome shutter closed" success (the verification must not add a caveat
/// to a genuinely-confirmed close).
#[tokio::test(start_paused = true)]
async fn test_close_dome_confirmed_reports_plain_success() {
    let ops =
        Arc::new(ScriptedDomeRotatorOps::new().with_dome_shutter_states(&["Closing", "Closed"]));
    let ctx = ctx_with_ops(ops.clone()).await;
    let cfg = DomeConfig { shutter_only: true };

    let result = execute_close_dome(&cfg, &ctx, None).await;

    assert_eq!(result.status, NodeStatus::Success);
    assert_eq!(
        result.message.as_deref(),
        Some("Dome shutter closed"),
        "a confirmed close reports the plain success message"
    );
}

// Dome / cover-calibrator role resolution
//
// Nothing in the Dart→FFI runtime-config path calls
// `SequenceExecutor::set_dome` / `set_cover_calibrator`, so
// `InstructionContext::dome_id` / `cover_calibrator_id` are `None` on
// every real run and all seven dome/cover node types failed with
// "No dome connected" while the device sat connected in the Equipment
// screen. These pin the fallback to the device layer's view of what is
// connected, and pin that the failure still fires when nothing is.

#[tokio::test(start_paused = true)]
async fn open_dome_uses_connected_dome_when_context_has_no_role() {
    let ops = Arc::new(
        ScriptedDomeRotatorOps::new()
            .with_active_dome_id("sim_dome_1")
            .with_dome_shutter_states(&["Open"]),
    );
    let mut ctx = ctx_with_ops(ops.clone()).await;
    // Exactly what the executor hands every real run today.
    ctx.dome_id = None;

    let result = execute_open_dome(&DomeConfig { shutter_only: true }, &ctx, None).await;

    assert_eq!(
        result.status,
        NodeStatus::Success,
        "Open Dome must command the connected dome, got {:?}",
        result.message
    );
    assert_eq!(
        ops.dome_open_ids.lock().unwrap().as_slice(),
        ["sim_dome_1".to_string()],
        "the instruction must open the dome the device layer resolved"
    );
}

#[tokio::test(start_paused = true)]
async fn open_dome_still_fails_when_no_dome_is_connected() {
    let ops = Arc::new(ScriptedDomeRotatorOps::new());
    let mut ctx = ctx_with_ops(ops.clone()).await;
    ctx.dome_id = None;

    let result = execute_open_dome(&DomeConfig { shutter_only: true }, &ctx, None).await;

    assert_eq!(result.status, NodeStatus::Failure);
    assert_eq!(result.message.as_deref(), Some("No dome connected"));
    assert!(
        ops.dome_open_ids.lock().unwrap().is_empty(),
        "no dome may be commanded when none is connected"
    );
}

/// One failed node, one error entry — even when the node-runtime retries it.
///
/// "No dome connected" is classified as a device-disconnect message, so
/// `execute_instruction_with_disconnect_retry` re-runs the node once per
/// recovery cycle. Every one of those executions published its own
/// `InstructionFailed`, and the Dart layer turns each into a session-report
/// error line and a Critical toast — which is why a single failed Open Dome
/// node listed the same sentence six times.
///
/// The test drives the real `RuntimeNode::execute` (not the private retry
/// helper) so the wiring between the runtime and the publish site is under
/// test, and asserts BOTH halves: the node really was executed six times,
/// and the operator was told once.
#[tokio::test(start_paused = true)]
async fn a_retried_node_reports_its_failure_once_not_once_per_attempt() {
    use crate::node::runtime::{Node, RuntimeNode};

    let ops = Arc::new(ScriptedDomeRotatorOps::new());
    let mut ec = crate::node::context::ExecutionContext::new_for_test("dup-error".to_string());
    ec.device_ops = ops.clone();
    let (event_tx, mut event_rx) = tokio::sync::broadcast::channel(64);
    ec.event_tx = Some(event_tx);

    // Stand in for a recovery driver that engages and completes a cycle:
    // the wrapper watches `recovery_generation` to decide the device came
    // back, so bumping it is what makes the retry loop go round instead of
    // failing closed on "no recovery driver engaged".
    let generation = ec.recovery_generation.clone();
    let driver = tokio::spawn(async move {
        loop {
            generation.fetch_add(1, std::sync::atomic::Ordering::Release);
            tokio::time::sleep(std::time::Duration::from_millis(1)).await;
        }
    });

    let mut node = RuntimeNode::from_definition(crate::NodeDefinition {
        id: "dome-node".to_string(),
        name: "Open Dome".to_string(),
        node_type: NodeType::OpenDome(DomeConfig { shutter_only: true }),
        enabled: true,
        children: Vec::new(),
    });
    let status = node.execute(&mut ec).await;
    driver.abort();

    assert_eq!(status, NodeStatus::Failure, "no dome is connected");
    assert!(
        ops.active_dome_id_calls.load(Ordering::SeqCst) > 1,
        "the retry loop must actually have re-run the node, otherwise this \
             test proves nothing about collapsing retries"
    );

    let mut reported = Vec::new();
    while let Ok(event) = event_rx.try_recv() {
        if let crate::executor::ExecutorEvent::InstructionFailed { node_name, message } = event {
            reported.push(format!("{node_name}: {message}"));
        }
    }
    assert_eq!(
        reported,
        vec!["Open Dome: No dome connected".to_string()],
        "one failed node must produce exactly one operator-facing error, got {reported:?}"
    );
}

#[tokio::test(start_paused = true)]
async fn open_cover_uses_connected_panel_when_context_has_no_role() {
    let ops = Arc::new(ScriptedDomeRotatorOps::new().with_active_cover_calibrator_id("sim_cc"));
    let mut ctx = ctx_with_ops(ops.clone()).await;
    ctx.cover_calibrator_id = None;

    let result = execute_open_cover(
        &crate::CoverCalibratorConfig { timeout_secs: 5 },
        &ctx,
        None,
    )
    .await;

    assert_eq!(
        result.status,
        NodeStatus::Success,
        "Open Cover must command the connected panel, got {:?}",
        result.message
    );
    assert_eq!(
        ops.cover_open_ids.lock().unwrap().as_slice(),
        ["sim_cc".to_string()],
        "the instruction must open the panel the device layer resolved"
    );
}
