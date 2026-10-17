//! Notification instruction node.
//!
//! the title and message both flow through the variable
//! interpolation engine before being shown to the user, so templates like
//! `"${target.name} done. ${frame.total} frames captured."` render against
//! the live sequence context.

use crate::expressions::{interpolate, EvaluationFrame};
use crate::instructions::execute_notification;
use crate::node::context::ExecutionContext;
use crate::node::registry::InstructionNode;
use crate::{NodeStatus, NodeType, NotificationConfig};
use async_trait::async_trait;

pub struct NotificationInstruction;

#[async_trait]
impl InstructionNode for NotificationInstruction {
    fn type_name(&self) -> &'static str {
        "Notification"
    }

    async fn execute(
        &self,
        node_id: &str,
        node_type: &NodeType,
        context: &mut ExecutionContext,
    ) -> NodeStatus {
        let NodeType::Notification(config) = node_type else {
            tracing::error!("NotificationInstruction received non-Notification variant");
            return NodeStatus::Failure;
        };

        // Notifications fire OUTSIDE an exposure burst, so frame fields are
        // None in the EvaluationFrame and `${frame}` is Unresolvable here —
        // including in the `Frame ${frame} of ${target.name} done` example the
        // title field's own hint suggests.
        let frame = EvaluationFrame::empty();

        let title = interpolate_or_raw(&config.title, context, &frame, "title");
        let message = interpolate_or_raw(&config.message, context, &frame, "message");
        let interpolated = NotificationConfig {
            title,
            message,
            level: config.level,
            // preserve the user's per-node
            // transport override through interpolation so the bridge event
            // carries it for the Dart NotificationRouter to consume.
            explicit_transports: config.explicit_transports.clone(),
        };

        let ctx = context.to_instruction_context(node_id).await;
        execute_notification(&interpolated, &ctx)
            .await
            .log_and_get_status_with_context("Notification", &ctx)
    }
}

/// Interpolate a notification template, falling back to the raw template text
/// when a variable cannot be resolved.
///
/// A notification is advisory: it reports on the run, it does not steer it.
/// Failing the node over a text template aborts the whole sequence — the Park
/// Mount node after the notification never runs and the mount is left tracking
/// — and bypasses `log_and_get_status_with_context`, the call every other
/// instruction uses to record its error text, leaving the run record with a
/// bare "Sequence failed". Sending the literal `${...}` token is honest (the
/// operator sees exactly the template they typed) and leaves the night
/// running.
fn interpolate_or_raw(
    template: &str,
    context: &ExecutionContext,
    frame: &EvaluationFrame,
    field: &str,
) -> String {
    match interpolate(template, context, frame) {
        Ok(rendered) => rendered,
        Err(e) => {
            tracing::warn!(
                "Notification {field} `{template}` failed interpolation: {e} — \
                 sending the template text unsubstituted"
            );
            template.to_string()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::NotificationLevel;

    fn config(title: &str) -> NodeType {
        NodeType::Notification(NotificationConfig {
            title: title.to_string(),
            message: "body".to_string(),
            level: NotificationLevel::Info,
            explicit_transports: None,
        })
    }

    /// `${frame}` is the variable the title field's own hint advertises
    /// (`e.g. Frame ${frame} of ${target.name} done`) and it can NEVER resolve
    /// from a notification, which fires outside an exposure burst. The node must
    /// return Success with the literal token: failing it aborts the sequence, so
    /// any safing node after it — Park Mount, Close Dome — never runs.
    #[tokio::test]
    async fn unresolvable_variable_does_not_fail_the_node() {
        let mut ctx = ExecutionContext::new_for_test("notify-node".to_string());

        let status = NotificationInstruction
            .execute("notify-node", &config("AUDIT NOTIF ${frame}"), &mut ctx)
            .await;

        assert_eq!(
            status,
            NodeStatus::Success,
            "a template typo must not abort the run"
        );
    }

    /// The operator gets back exactly what they typed rather than a silently
    /// emptied alert, so the unsubstituted token is self-explanatory.
    #[test]
    fn unresolvable_variable_keeps_the_raw_template() {
        let ctx = ExecutionContext::new_for_test("notify-node".to_string());
        let frame = EvaluationFrame::empty();

        assert_eq!(
            interpolate_or_raw("AUDIT NOTIF ${frame}", &ctx, &frame, "title"),
            "AUDIT NOTIF ${frame}"
        );
    }
}
