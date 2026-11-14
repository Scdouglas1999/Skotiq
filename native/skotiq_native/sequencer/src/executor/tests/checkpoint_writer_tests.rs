//! What a checkpoint saved while a run is in flight holds.

use super::*;
use crate::device_ops::NullDeviceOps;
use crate::{DelayConfig, LoopCondition, LoopConfig, NodeType, SequenceDefinition};

/// A three-pass loop whose body is one short wait.
fn looping_plan() -> SequenceDefinition {
    let mut sequence = SequenceDefinition::new("Looping".to_string());
    sequence.nodes.push(crate::NodeDefinition {
        id: "loop".to_string(),
        name: "Loop".to_string(),
        node_type: NodeType::Loop(LoopConfig {
            iterations: Some(3),
            condition: LoopCondition::Count,
            condition_value: None,
            horizon_profile: None,
        }),
        enabled: true,
        children: vec!["wait".to_string()],
    });
    sequence.nodes.push(crate::NodeDefinition {
        id: "wait".to_string(),
        name: "Wait".to_string(),
        node_type: NodeType::Delay(DelayConfig { seconds: 1.0 }),
        enabled: true,
        children: vec![],
    });
    sequence.root_node_id = Some("loop".to_string());
    sequence
}

/// A checkpoint saved during the loop's second pass records one finished
/// pass, so a resume runs the interrupted pass again and then the third,
/// instead of starting the loop over.
#[tokio::test]
async fn a_checkpoint_saved_mid_run_records_the_loop_passes_finished() {
    let dir = std::env::temp_dir().join(format!("sk-ckpt-writer-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    let mut executor = SequenceExecutor::new();
    executor.set_checkpoint_dir(dir.join("checkpoint"));
    executor.set_device_ops(Arc::new(NullDeviceOps));
    executor
        .load_sequence(looping_plan())
        .expect("sequence loads");
    executor.start().await.expect("run starts");

    // Into the second pass.
    tokio::time::sleep(std::time::Duration::from_millis(1_500)).await;
    assert_eq!(executor.get_state().await, ExecutorState::Running);
    executor.save_checkpoint().await.expect("checkpoint saves");

    let saved = crate::checkpoint::CheckpointManager::new(dir.join("checkpoint"))
        .load()
        .expect("checkpoint reads")
        .expect("a checkpoint was written");
    executor.stop().await.ok();
    let _ = std::fs::remove_dir_all(&dir);

    assert_eq!(
        saved.loop_iterations.get("loop").copied(),
        Some(1),
        "one pass was finished when the checkpoint was saved"
    );
}
