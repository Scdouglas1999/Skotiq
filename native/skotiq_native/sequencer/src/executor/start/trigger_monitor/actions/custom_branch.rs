//! `CustomBranch`: run the Recovery node the operator registered for this
//! trigger.

use super::*;

/// The operator's recovery branches and what running one needs.
pub(in super::super) struct CustomBranches {
    /// Trigger id to recovery node id.
    pub branches: Arc<HashMap<String, String>>,
    pub sequence: Option<SequenceDefinition>,
    pub context: ExecutionContext,
}

pub(in super::super) async fn run(
    trigger_id: &str,
    trigger_name: &str,
    custom: &CustomBranches,
    run: &RunControl,
) -> ActionFlow {
    let Some(recovery_node_id) = custom.branches.get(trigger_id).cloned() else {
        tracing::error!(
            "Trigger '{}' fired CustomBranch but no recovery branch was registered",
            trigger_name
        );
        run.pause(None).await;
        run.error(format!(
            "Trigger '{}' requested Custom Branch recovery, but no branch was registered. Sequence paused.",
            trigger_name
        ));
        return ActionFlow::Finished;
    };
    let Some(sequence) = custom.sequence.as_ref() else {
        tracing::error!(
            "Trigger '{}' fired CustomBranch but no loaded sequence snapshot is available",
            trigger_name
        );
        run.pause(None).await;
        run.error(format!(
            "Trigger '{}' requested Custom Branch recovery, but the sequence snapshot was unavailable. Sequence paused.",
            trigger_name
        ));
        return ActionFlow::Finished;
    };
    let node_map: HashMap<&str, &NodeDefinition> =
        sequence.nodes.iter().map(|n| (n.id.as_str(), n)).collect();
    let Some(recovery_def) = node_map.get(recovery_node_id.as_str()) else {
        tracing::error!(
            "Trigger '{}' fired CustomBranch but recovery node '{}' was not found",
            trigger_name,
            recovery_node_id
        );
        run.pause(None).await;
        run.error(format!(
            "Trigger '{}' requested Custom Branch node '{}', but it was not found. Sequence paused.",
            trigger_name, recovery_node_id
        ));
        return ActionFlow::Finished;
    };

    let mut branch_node = build_runtime_node_from_map(recovery_def, &node_map);
    let mut branch_context = custom.context.clone();
    branch_context.node_id = recovery_node_id.clone();
    tracing::warn!(
        "Trigger '{}' executing CustomBranch recovery node '{}'",
        trigger_name,
        recovery_node_id
    );
    let result = crate::node::logic::recovery::execute_custom_branch_children(
        &mut branch_node,
        &mut branch_context,
    )
    .await;
    match result {
        NodeStatus::Success | NodeStatus::Skipped => {
            tracing::info!(
                "CustomBranch recovery node '{}' completed with {:?}",
                recovery_node_id,
                result
            );
        }
        NodeStatus::Cancelled => {
            return ActionFlow::Terminate {
                recorded: RecoveryAction::CustomBranch,
                reason: "RecoveryAction::CustomBranch cancelled",
            };
        }
        NodeStatus::Pending | NodeStatus::Running | NodeStatus::Failure => {
            tracing::error!(
                "CustomBranch recovery node '{}' failed with {:?}; pausing sequence",
                recovery_node_id,
                result
            );
            run.pause(None).await;
            run.error(format!(
                "Custom Branch recovery '{}' failed after trigger '{}'. Sequence paused.",
                recovery_node_id, trigger_name
            ));
        }
    }
    ActionFlow::Finished
}
