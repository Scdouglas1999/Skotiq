//! ChangeFilter instruction node.

use crate::instructions::execute_filter_change;
use crate::node::context::ExecutionContext;
use crate::node::progress::{step_progress, ProgressDetail, ProgressUpdate};
use crate::node::registry::InstructionNode;
use crate::{NodeStatus, NodeType};
use async_trait::async_trait;

pub struct ChangeFilterInstruction;

#[async_trait]
impl InstructionNode for ChangeFilterInstruction {
    async fn execute(
        &self,
        node_id: &str,
        node_type: &NodeType,
        context: &mut ExecutionContext,
    ) -> NodeStatus {
        let NodeType::ChangeFilter(config) = node_type else {
            tracing::error!("ChangeFilterInstruction received non-ChangeFilter variant");
            return NodeStatus::Failure;
        };

        let ctx = context.to_instruction_context(node_id).await;
        let progress_fn =
            step_progress::<String>(context.progress_callback.as_ref(), node_id, "Filter");
        let result = execute_filter_change(config, &ctx, Some(&progress_fn)).await;
        if result.status == NodeStatus::Success {
            context.send_progress(ProgressUpdate::instruction_progress(
                node_id.to_string(),
                "Filter",
                100.0,
                ProgressDetail::Filter {
                    name: config.filter_name.clone(),
                    position: config.filter_index,
                },
            ));
            context.current_filter = Some(config.filter_name.clone());
            // Record the slot as well as the name. Only the name was kept, so
            // every frame captured after a Change Filter node had a FILTER
            // card but no FILTPOS — `FrameContext.filter_index` falls back to
            // `current_filter_index`, which stayed None for the whole run.
            if let Some(index) = config.filter_index {
                context.current_filter_index = Some(index);
            }
            if let Some(trigger_state_lock) = &context.run.trigger_state {
                let mut trigger_state = trigger_state_lock.write().await;
                trigger_state.set_filter(config.filter_name.clone());
            }
        }
        result.settle("Change Filter", &ctx).await
    }
}
