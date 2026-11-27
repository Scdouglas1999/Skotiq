//! A Loop that runs "until N of integration" counts the integration its own
//! steps collect.

use super::*;
use crate::device_ops::NullDeviceOps;
use crate::{LoopCondition, LoopConfig, NodeDefinition, NodeType, SequenceDefinition};

const SUB_SECS: f64 = 0.3;

fn darks(id: &str, count: u32) -> NodeDefinition {
    NodeDefinition {
        id: id.to_string(),
        name: id.to_string(),
        node_type: NodeType::TakeExposure(crate::ExposureConfig {
            duration_secs: SUB_SECS,
            count,
            frame_type: crate::FrameType::Dark,
            ..Default::default()
        }),
        enabled: true,
        children: vec![],
    }
}

fn group(
    id: &str,
    condition: LoopCondition,
    value: Option<f64>,
    children: &[&str],
) -> NodeDefinition {
    NodeDefinition {
        id: id.to_string(),
        name: id.to_string(),
        node_type: NodeType::Loop(LoopConfig {
            iterations: (condition == LoopCondition::Count).then_some(1),
            condition,
            condition_value: value,
            horizon_profile: None,
        }),
        enabled: true,
        children: children.iter().map(|c| c.to_string()).collect(),
    }
}

fn plan(nodes: Vec<NodeDefinition>) -> SequenceDefinition {
    let mut sequence = SequenceDefinition::new("Loop integration".to_string());
    sequence.root_node_id = Some(nodes[0].id.clone());
    sequence.nodes = nodes;
    sequence
}

fn executor_for(dir: &std::path::Path) -> SequenceExecutor {
    let mut executor = SequenceExecutor::new();
    executor.set_checkpoint_dir(dir.join("checkpoint"));
    executor.set_device_ops(Arc::new(NullDeviceOps));
    executor.set_save_path(Some(dir.to_path_buf()));
    executor.set_devices(Some("cam-1".to_string()), None, None, None, None);
    executor
}

/// Frames completed until the run reached a terminal state, stopping it after
/// `stop_after` frames.
async fn run_counting_frames(executor: &mut SequenceExecutor, stop_after: Option<u32>) -> u32 {
    let mut events = executor.handle().subscribe();
    executor.start().await.expect("run starts");
    let mut frames = 0;
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(60);
    loop {
        match tokio::time::timeout_at(deadline, events.recv())
            .await
            .expect("run ends in time")
        {
            Ok(ExecutorEvent::ExposureCompleted { .. }) => {
                frames += 1;
                if stop_after == Some(frames) {
                    executor.stop().await.expect("stop is accepted");
                }
            }
            Ok(ExecutorEvent::StateChanged(
                ExecutorState::Completed | ExecutorState::Failed | ExecutorState::Cancelled,
            )) => return frames,
            Ok(_) | Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {}
            Err(tokio::sync::broadcast::error::RecvError::Closed) => return frames,
        }
    }
}

fn scratch(name: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "sk-loop-integration-{name}-{}",
        uuid::Uuid::new_v4()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// Four frames (1.2 s) come before a loop "until 0.6 s" of one-frame passes:
/// the loop takes its own two passes whatever the run collected before it.
#[tokio::test]
async fn a_loop_counts_only_the_integration_of_its_own_steps() {
    let dir = scratch("own");
    let mut executor = executor_for(&dir);
    executor
        .load_sequence(plan(vec![
            group("root", LoopCondition::Count, None, &["first", "until"]),
            darks("first", 4),
            group(
                "until",
                LoopCondition::IntegrationTime,
                Some(0.6),
                &["inner"],
            ),
            darks("inner", 1),
        ]))
        .expect("sequence loads");
    let frames = run_counting_frames(&mut executor, None).await;
    let _ = std::fs::remove_dir_all(&dir);
    assert_eq!(
        frames,
        4 + 2,
        "the loop's two passes after the first four frames"
    );
}
