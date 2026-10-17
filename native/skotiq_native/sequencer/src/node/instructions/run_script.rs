//! RunScript instruction node.
//!
//! every script argument is interpolated through the variable
//! engine before being passed to the child process, and every well-known
//! variable is exposed as a `SKOTIQ_<UPPER_SNAKE>` env var so legacy
//! shell scripts can read the sequence context without parsing template
//! syntax.

use crate::expressions::{interpolate, EvaluationFrame};
use crate::instructions::execute_script;
use crate::node::context::ExecutionContext;
use crate::node::registry::InstructionNode;
use crate::{NodeStatus, NodeType, ScriptConfig};
use async_trait::async_trait;

pub struct RunScriptInstruction;

#[async_trait]
impl InstructionNode for RunScriptInstruction {
    fn type_name(&self) -> &'static str {
        "Run Script"
    }

    async fn execute(
        &self,
        node_id: &str,
        node_type: &NodeType,
        context: &mut ExecutionContext,
    ) -> NodeStatus {
        let NodeType::RunScript(config) = node_type else {
            tracing::error!("RunScriptInstruction received non-RunScript variant");
            return NodeStatus::Failure;
        };

        // Build the per-call evaluation frame from RunScript-time state.
        // RunScript runs OUTSIDE an exposure burst so frame counters stay
        // None — references like `${frame}` in a script argument will
        // surface as InterpolationError::Unresolvable, which we turn into a
        // hard NodeStatus::Failure (per the no-silent-fallback policy).
        let frame = EvaluationFrame {
            session_start: None,
            ..EvaluationFrame::empty()
        };

        // Interpolate every argument. A failure here is a configuration
        // bug: the script can't run with a broken argument list, so we
        // abort the node and surface the error to the executor log.
        let mut rendered_args: Vec<String> = Vec::with_capacity(config.arguments.len());
        for (idx, raw) in config.arguments.iter().enumerate() {
            match interpolate(raw, context, &frame) {
                Ok(rendered) => rendered_args.push(rendered),
                Err(e) => {
                    tracing::error!("RunScript argument #{idx} `{raw}` failed interpolation: {e}");
                    return NodeStatus::Failure;
                }
            }
        }
        // Interpolate the script path too — useful for templates like
        // `${observer.scripts_dir}/notify.sh`. Same hard-failure policy.
        let rendered_path = match interpolate(&config.script_path, context, &frame) {
            Ok(p) => p,
            Err(e) => {
                tracing::error!(
                    "RunScript path `{}` failed interpolation: {e}",
                    config.script_path
                );
                return NodeStatus::Failure;
            }
        };

        let interpolated = ScriptConfig {
            script_path: rendered_path,
            arguments: rendered_args,
            timeout_secs: config.timeout_secs,
        };

        let ctx = context.to_instruction_context(node_id).await;
        execute_script(&interpolated, &ctx, context, &frame)
            .await
            .log_and_get_status_with_context("Run Script", &ctx)
    }
}
