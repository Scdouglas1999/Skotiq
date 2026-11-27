//! A manual action holds the run it paused: only the action's own release
//! lets the run go on. A resume, a skip or a jump to another step from
//! anywhere else is refused, and a stop is never held back.

use super::*;
use crate::device_ops::NullDeviceOps;
use crate::{DelayConfig, NodeType, SequenceDefinition};
use std::time::{Duration, Instant};

async fn running_executor() -> SequenceExecutor {
    let mut sequence = SequenceDefinition::new("Held run".to_string());
    sequence.nodes.push(crate::NodeDefinition {
        id: "wait".to_string(),
        name: "Wait".to_string(),
        node_type: NodeType::Delay(DelayConfig { seconds: 120.0 }),
        enabled: true,
        children: vec![],
    });
    sequence.root_node_id = Some("wait".to_string());
    let mut executor = SequenceExecutor::new();
    executor.set_device_ops(Arc::new(NullDeviceOps));
    executor.load_sequence(sequence).expect("sequence loads");
    executor.start().await.expect("run starts");
    wait_for(&executor, ExecutorState::Running).await;
    executor
}

async fn wait_for(executor: &SequenceExecutor, state: ExecutorState) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while executor.get_state().await != state {
        assert!(Instant::now() < deadline, "run never reached {state:?}");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

#[tokio::test]
async fn only_the_holders_release_lets_a_held_run_go_on() {
    let mut executor = running_executor().await;
    let handle = executor.handle();
    handle.hold_for_action("host").await.expect("hold taken");
    wait_for(&executor, ExecutorState::Paused).await;
    assert!(handle.held_by_action());

    assert_eq!(handle.resume().await, Err(RunCommandError::HeldByAction));
    assert_eq!(handle.skip().await, Err(RunCommandError::HeldByAction));
    assert_eq!(
        handle.skip_to_node("wait".to_string()).await,
        Err(RunCommandError::HeldByAction)
    );
    assert_eq!(
        handle.hold_for_action("phone").await,
        Err(RunCommandError::HeldByAction)
    );
    assert!(!handle.release_action_hold("phone"));
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(executor.get_state().await, ExecutorState::Paused);

    assert!(handle.release_action_hold("host"));
    handle.resume().await.expect("released run resumes");
    wait_for(&executor, ExecutorState::Running).await;
    executor.stop().await.ok();
}

#[tokio::test]
async fn a_held_run_still_stops() {
    let mut executor = running_executor().await;
    executor
        .handle()
        .hold_for_action("host")
        .await
        .expect("hold taken");
    wait_for(&executor, ExecutorState::Paused).await;

    executor.stop().await.expect("stop is never held back");
    assert!(!executor.handle().held_by_action());
}

#[tokio::test]
async fn a_pause_that_took_over_a_held_run_outlives_the_release() {
    let mut executor = running_executor().await;
    let handle = executor.handle();
    handle.hold_for_action("host").await.expect("hold taken");
    wait_for(&executor, ExecutorState::Paused).await;
    handle
        .pause_from(Some("weather turned unsafe".to_string()))
        .await
        .expect("weather pauses the held run");
    tokio::time::sleep(Duration::from_millis(100)).await;

    assert_eq!(
        handle.release_action_hold_to_resume("host"),
        Err(RunCommandError::StillPaused(
            "weather turned unsafe".to_string()
        ))
    );
    assert!(!handle.held_by_action(), "the hold itself is released");
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(executor.get_state().await, ExecutorState::Paused);

    // The pause is an ordinary one now: a resume from anywhere lifts it.
    handle.resume().await.expect("plain pause resumes");
    wait_for(&executor, ExecutorState::Running).await;
    executor.stop().await.ok();
}

#[tokio::test]
async fn a_hold_alone_is_released_to_resume() {
    let mut executor = running_executor().await;
    let handle = executor.handle();
    handle.hold_for_action("host").await.expect("hold taken");
    wait_for(&executor, ExecutorState::Paused).await;
    tokio::time::sleep(Duration::from_millis(100)).await;

    assert_eq!(handle.release_action_hold_to_resume("host"), Ok(()));
    handle.resume().await.expect("released run resumes");
    wait_for(&executor, ExecutorState::Running).await;
    executor.stop().await.ok();
}
