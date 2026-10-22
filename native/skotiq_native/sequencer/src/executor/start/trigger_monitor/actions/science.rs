//! `SwitchTargetOrFilter`: the transparency recovery, which moves to the
//! operator's backup target and/or filter.

use super::*;

pub(in super::super) async fn switch_target_or_filter(
    trigger_name: &str,
    backup: &RwLock<Option<crate::node::context::TransparencyBackupPlan>>,
    skip_to_node: &StdRwLock<Option<NodeId>>,
    rig: &Rig,
    run: &RunControl,
) -> ActionFlow {
    let plan_snapshot = backup.read().await.clone();
    // No plan, or an empty one, pauses with the reason rather than doing
    // nothing silently.
    let Some(plan) = plan_snapshot else {
        tracing::warn!(
            "[SCIENCE] SwitchTargetOrFilter fired but no backup plan configured; falling back to PauseAndWaitForClear"
        );
        run.error(format!(
            "Trigger '{}' requested SwitchTargetOrFilter but no transparency backup plan was configured. Sequence paused. Set a backup filter or backup target in the science settings before re-running.",
            trigger_name,
        ));
        run.pause(None).await;
        return ActionFlow::Finished;
    };
    if plan.backup_filter.is_none() && plan.backup_target_id.is_none() {
        tracing::warn!(
            "[SCIENCE] SwitchTargetOrFilter: backup plan has neither filter nor target; falling back to PauseAndWaitForClear"
        );
        run.error(format!(
            "Trigger '{}' requested SwitchTargetOrFilter but the configured backup plan is empty. Sequence paused.",
            trigger_name,
        ));
        run.pause(None).await;
        return ActionFlow::Finished;
    }
    tracing::warn!(
        "[SCIENCE] Trigger '{}' fired SwitchTargetOrFilter: filter={:?}, target={:?}, desc={:?}",
        trigger_name,
        plan.backup_filter,
        plan.backup_target_id,
        plan.description,
    );
    // The executor walks past the current target into the backup's subtree.
    if let Some(node_id) = &plan.backup_target_id {
        *skip_to_node.write() = Some(node_id.clone());
        tracing::info!(
            "[SCIENCE] Requested skip-to-node '{}' for transparency backup",
            node_id
        );
    }
    // A standalone instruction context: the running tree holds its own.
    if let Some(filter_name) = &plan.backup_filter {
        let inst_ctx = rig.instruction_context(TargetSnapshot::default(), run);
        let filter_cfg = crate::FilterConfig {
            filter_name: filter_name.clone(),
            filter_index: None,
            timeout_secs: None,
        };
        let result = crate::instructions::execute_filter_change(&filter_cfg, &inst_ctx, None).await;
        if result.status != NodeStatus::Success {
            tracing::warn!(
                "[SCIENCE] Backup filter change to '{}' failed: {:?}",
                filter_name,
                result.message,
            );
            run.error(format!(
                "SwitchTargetOrFilter: backup filter '{}' could not be selected: {}",
                filter_name,
                result.message.unwrap_or_default()
            ));
        } else {
            tracing::info!("[SCIENCE] Switched to backup filter '{}'", filter_name);
        }
    }
    ActionFlow::Finished
}
