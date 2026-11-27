//! A Loop that runs "until N of integration" counts the integration its own
//! steps collect, in this run and in the run a resume continues.

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

/// A loop "until 1.2 s" of two-frame passes, stopped in its second pass and
/// restored, finishes that pass and starts no third: the restored loop's own
/// integration starts at what its finished first pass collected.
#[tokio::test]
async fn a_restored_loop_continues_from_the_integration_it_had() {
    let dir = scratch("restore");
    let sequence = plan(vec![
        group(
            "until",
            LoopCondition::IntegrationTime,
            Some(1.2),
            &["inner"],
        ),
        darks("inner", 2),
    ]);
    let mut first = executor_for(&dir);
    first.load_sequence(sequence).expect("sequence loads");
    let before = run_counting_frames(&mut first, Some(3)).await;
    drop(first);

    let mut second = executor_for(&dir);
    second
        .resume_from_checkpoint()
        .await
        .expect("resume prepares");
    let after = run_counting_frames(&mut second, None).await;
    let _ = std::fs::remove_dir_all(&dir);
    assert_eq!(before, 3);
    assert_eq!(after, 1, "the restored run finishes the second pass only");
}

/// The same stop restored from a checkpoint written before loops' integration
/// was kept: the loop's integration is worked out from the frames its bursts
/// finished, so the resume again takes only the frame it owes.
#[tokio::test]
async fn a_loop_restored_from_an_older_checkpoint_does_not_start_over() {
    let dir = scratch("older");
    let sequence = plan(vec![
        group(
            "until",
            LoopCondition::IntegrationTime,
            Some(1.2),
            &["inner"],
        ),
        darks("inner", 2),
    ]);
    let mut first = executor_for(&dir);
    first.load_sequence(sequence).expect("sequence loads");
    assert_eq!(run_counting_frames(&mut first, Some(3)).await, 3);
    drop(first);

    let primary = dir.join("checkpoint").join("skotiq_session.checkpoint");
    let _ = std::fs::remove_file(dir.join("checkpoint").join("skotiq_session.checkpoint.bak"));
    let mut checkpoint: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&primary).unwrap()).unwrap();
    assert!(
        checkpoint
            .as_object_mut()
            .and_then(|fields| fields.remove("loop_integration_secs"))
            .is_some_and(|recorded| !recorded.is_null()),
        "the checkpoint recorded the loop's integration"
    );
    std::fs::write(&primary, serde_json::to_string(&checkpoint).unwrap()).unwrap();

    let mut second = executor_for(&dir);
    second
        .resume_from_checkpoint()
        .await
        .expect("resume prepares");
    let after = run_counting_frames(&mut second, None).await;
    let _ = std::fs::remove_dir_all(&dir);
    assert_eq!(after, 1);
}

/// A loop inside another loop counts from zero again in each outer pass.
#[tokio::test]
async fn an_inner_loop_counts_each_outer_pass_from_zero() {
    let dir = scratch("nested");
    let mut executor = executor_for(&dir);
    let mut outer = group("outer", LoopCondition::Count, None, &["until"]);
    if let NodeType::Loop(config) = &mut outer.node_type {
        config.iterations = Some(2);
    }
    executor
        .load_sequence(plan(vec![
            outer,
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
    assert_eq!(frames, 2 * 2);
}
