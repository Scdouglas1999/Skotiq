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
    let problem = match &plan_snapshot {
        None => Some("no transparency backup plan is configured"),
        Some(plan) if plan.backup_filter.is_none() && plan.backup_target_id.is_none() => {
            Some("the transparency backup plan names neither a filter nor a target")
        }
        Some(_) => None,
    };
    // Transparency judges the sky's quality, so with nothing to switch to it
    // only notifies, unless the operator asked quality problems to stop the
    // run.
    if let Some(problem) = problem {
        tracing::warn!("[SCIENCE] SwitchTargetOrFilter fired but {problem}");
        if rig.trigger_state.read().await.stop_on_quality_problems {
            run.error(format!(
                "{trigger_name}: {problem}, so the run is paused because Stop the run for \
                 quality problems is on. Set a backup filter or target in the science \
                 settings, or resume."
            ));
            run.pause(None).await;
        } else {
            run.warning(format!(
                "{trigger_name}: {problem}, so imaging continues on the current target and \
                 filter. Set a backup filter or target in the science settings to switch \
                 automatically."
            ));
        }
        return ActionFlow::Finished;
    }
    let Some(plan) = plan_snapshot else {
        return ActionFlow::Finished;
    };
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
