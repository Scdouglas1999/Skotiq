//! The operator's Resume / Restart choice from the session-handoff dialog,
//! against a checkpoint resume that carries budget accounting of its own.

use super::*;
use crate::device_ops::NullDeviceOps;
use crate::scheduling::{BudgetRegistrySnapshot, BudgetState};
use crate::{IntegrationBudget, NodeType, SequenceDefinition};
use std::collections::HashMap;

const SUB_SECS: f64 = 0.2;
const BUDGET_SECS: f64 = 100.0;

/// One target with a 100 s budget and a single unfiltered frame under it.
fn budgeted_target() -> SequenceDefinition {
    let mut sequence = SequenceDefinition::new("Budgeted".to_string());
    sequence.nodes.push(crate::NodeDefinition {
        id: "target".to_string(),
        name: "Target".to_string(),
        node_type: NodeType::TargetHeader(crate::TargetHeaderConfig {
            target_name: "Faint Nebula".to_string(),
            ra_hours: 5.5,
            dec_degrees: 22.0,
            integration_budget: Some(IntegrationBudget {
                total_secs: BUDGET_SECS,
                ..IntegrationBudget::default()
            }),
            ..Default::default()
        }),
        enabled: true,
        children: vec!["frame".to_string()],
    });
    sequence.nodes.push(crate::NodeDefinition {
        id: "frame".to_string(),
        name: "frame".to_string(),
        node_type: NodeType::TakeExposure(crate::ExposureConfig {
            duration_secs: SUB_SECS,
            count: 1,
            ..Default::default()
        }),
        enabled: true,
        children: vec![],
    });
    sequence.root_node_id = Some("target".to_string());
    sequence
}

/// A checkpoint of an interrupted run whose budget accounting says the
/// target already holds `secs` of integration.
fn checkpoint_crediting(
    sequence: &SequenceDefinition,
    secs: f64,
) -> crate::checkpoint::SessionCheckpoint {
    let mut checkpoint = crate::checkpoint::SessionCheckpoint::new(sequence.clone());
    checkpoint.is_active = true;
    checkpoint.executor_state = ExecutorState::Running;
    let mut state = BudgetState::new("target");
    state.credit(None, secs);
    checkpoint.budget_states = BudgetRegistrySnapshot {
        states: vec![state],
    };
    checkpoint
}

struct Outcome {
    state: ExecutorState,
    frames: u32,
    /// What the run's budget said the target held after its last frame, or
    /// `None` when the run took no frame.
    credited_secs: Option<f64>,
}

/// Resume from a checkpoint crediting `checkpoint_secs`, with the operator's
/// handoff choice staged the way the bridge stages it.
async fn resume_with_choice(checkpoint_secs: f64, choice: Option<HashMap<String, f64>>) -> Outcome {
    let sequence = budgeted_target();
    let dir = std::env::temp_dir().join(format!("sk-carry-over-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    let mut executor = SequenceExecutor::new();
    executor.set_checkpoint_dir(dir.join("checkpoint"));
    crate::checkpoint::CheckpointManager::new(dir.join("checkpoint"))
        .save(&checkpoint_crediting(&sequence, checkpoint_secs))
        .expect("checkpoint saves");
    executor.set_device_ops(Arc::new(NullDeviceOps));
    executor
        .resume_from_checkpoint()
        .await
        .expect("resume prepares");
    executor.set_save_path(Some(dir.clone()));
    executor.set_devices(Some("cam-1".to_string()), None, None, None, None);
    if let Some(per_filter) = choice {
        executor.update_pending_integration_carry_over(HashMap::from([(
            "target".to_string(),
            per_filter,
        )]));
    }

    executor.start().await.expect("run starts");
    let mut state = executor.get_state().await;
    for _ in 0..2_000 {
        state = executor.get_state().await;
        if matches!(
            state,
            ExecutorState::Completed | ExecutorState::Failed | ExecutorState::Cancelled
        ) {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    executor.stop().await.ok();
    let progress = executor.get_progress();
    let _ = std::fs::remove_dir_all(&dir);
    Outcome {
        state,
        frames: progress.completed_exposures,
        credited_secs: progress
            .integration_by_target_filter
            .get("target")
            .and_then(|by_filter| by_filter.get(""))
            .copied(),
    }
}

/// With no handoff choice the checkpoint's accounting stands: a target whose
/// budget the interrupted run already met takes no further frame.
#[tokio::test]
async fn a_resume_without_a_choice_keeps_the_checkpoint_budget() {
    let outcome = resume_with_choice(BUDGET_SECS + 50.0, None).await;

    assert_eq!(outcome.state, ExecutorState::Completed);
    assert_eq!(outcome.frames, 0, "the budget was already met");
}

/// Resume: the operator's totals replace what the checkpoint parked.
#[tokio::test]
async fn the_operators_resume_totals_override_the_checkpoint_budget() {
    let outcome = resume_with_choice(
        BUDGET_SECS + 50.0,
        Some(HashMap::from([(String::new(), 10.0)])),
    )
    .await;

    assert_eq!(outcome.state, ExecutorState::Completed);
    assert_eq!(
        outcome.frames, 1,
        "10 s of a 100 s budget leaves the frame to take"
    );
    let credited = outcome.credited_secs.expect("the frame was credited");
    assert!(
        (credited - (10.0 + SUB_SECS)).abs() < 1e-6,
        "the frame is credited on top of the operator's 10 s, got {credited}"
    );
}

/// Restart: an explicit empty map zeroes the target, whatever the checkpoint
/// credited.
#[tokio::test]
async fn the_operators_restart_zeroes_the_checkpoint_budget() {
    let outcome = resume_with_choice(BUDGET_SECS + 50.0, Some(HashMap::new())).await;

    assert_eq!(outcome.state, ExecutorState::Completed);
    assert_eq!(outcome.frames, 1, "a restarted target images again");
    let credited = outcome.credited_secs.expect("the frame was credited");
    assert!(
        (credited - SUB_SECS).abs() < 1e-6,
        "a restarted target counts from zero, got {credited}"
    );
}
