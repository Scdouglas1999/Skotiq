//! What a run ended by the end of the night still owes the rig.
//!
//! A trigger that ends the night (dawn, an obstruction) cancels the node tree,
//! so the plan's own shutdown steps after its targets never run. They are run
//! here instead, once the tree has stopped and the rig is parked or left, on a
//! context of their own so the run's cancellation does not cancel them.

use super::*;

/// Node kinds that put the rig away. Only these may follow a plan's last
/// target and still count as its shutdown.
fn is_shutdown_step(node_type: &NodeType) -> bool {
    matches!(
        node_type,
        NodeType::StopGuiding
            | NodeType::Park
            | NodeType::HomeMount
            | NodeType::WarmCamera(_)
            | NodeType::CloseDome(_)
            | NodeType::ParkDome(_)
            | NodeType::CloseCover(_)
            | NodeType::CalibratorOff(_)
            | NodeType::Notification(_)
    )
}

/// Whether a fired trigger ends the night rather than only the run.
pub(crate) fn ends_the_night(trigger_id: &str) -> bool {
    END_OF_NIGHT_TRIGGER_IDS.contains(&trigger_id)
}

/// The plan's shutdown steps: the enabled instructions at the end of the
/// root, after its last target, that only put the rig away. Disabled steps are
/// passed over; anything else ends the run of steps.
pub(crate) fn plan_shutdown_steps(sequence: &SequenceDefinition) -> Vec<&NodeDefinition> {
    let Some(root) = sequence
        .root_node_id
        .as_ref()
        .and_then(|id| sequence.nodes.iter().find(|n| &n.id == id))
    else {
        return Vec::new();
    };
    let mut steps = Vec::new();
    for id in root.children.iter().rev() {
        let Some(node) = sequence.nodes.iter().find(|n| &n.id == id) else {
            break;
        };
        if !node.enabled {
            continue;
        }
        if !node.children.is_empty() || !is_shutdown_step(&node.node_type) {
            break;
        }
        steps.push(node);
    }
    steps.reverse();
    steps
}

/// What the end-of-night sweep already did before the plan's steps run.
#[derive(Default, Clone, Copy)]
pub(crate) struct AlreadySafe {
    /// The guider was stopped.
    pub guiding_stopped: bool,
    /// The mount was parked.
    pub mount_parked: bool,
    pub cover_closed: bool,
    pub dome_closed: bool,
}

impl AlreadySafe {
    /// Why `node_type` need not run again, if it need not.
    fn covers(&self, node_type: &NodeType) -> Option<&'static str> {
        match node_type {
            NodeType::StopGuiding if self.guiding_stopped => Some("guiding was already stopped"),
            NodeType::Park | NodeType::HomeMount if self.mount_parked => {
                Some("the mount was already parked and stays parked")
            }
            NodeType::CloseCover(_) if self.cover_closed => Some("the cover was already closed"),
            NodeType::CloseDome(_) if self.dome_closed => Some("the dome was already closed"),
            NodeType::WarmCamera(config) if config.defer_to_calibration => {
                Some("end-of-night calibration warms the camera after its darks")
            }
            _ => None,
        }
    }
}

/// How one shutdown step went, for the operator.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct StepOutcome {
    pub name: String,
    pub status: NodeStatus,
    /// Why the step was not run, when it was not.
    pub passed_over: Option<&'static str>,
    /// The step parks or homes the mount.
    pub moves_mount: bool,
}

impl StepOutcome {
    /// The step ran and moved the mount to its park or home position.
    pub fn moved_mount(&self) -> bool {
        self.moves_mount && self.status == NodeStatus::Success
    }
}

/// Run the plan's shutdown steps after a trigger ended the night, telling the
/// operator about each one through the notification channel.
///
/// `base` is the run's context. The steps get fresh cancel, pause and skip
/// flags: the run's own are already set by the stop that ended it.
pub(crate) async fn run_plan_shutdown_steps(
    trigger_name: &str,
    sequence: &SequenceDefinition,
    base: &ExecutionContext,
    device_ops: &SharedDeviceOps,
    already: AlreadySafe,
) -> Vec<StepOutcome> {
    let steps = plan_shutdown_steps(sequence);
    if steps.is_empty() {
        return Vec::new();
    }
    let node_map: HashMap<&str, &NodeDefinition> =
        sequence.nodes.iter().map(|n| (n.id.as_str(), n)).collect();
    let mut context = base.clone();
    context.is_cancelled = Arc::new(AtomicBool::new(false));
    context.is_paused = Arc::new(AtomicBool::new(false));
    context.skip_to_next_target = Arc::new(AtomicBool::new(false));

    notify(
        device_ops,
        "info",
        &format!(
            "{trigger_name}: running the plan's shutdown steps ({})",
            steps
                .iter()
                .map(|s| s.name.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        ),
    )
    .await;

    let mut outcomes = Vec::with_capacity(steps.len());
    for step in steps {
        let moves_mount = matches!(step.node_type, NodeType::Park | NodeType::HomeMount);
        if let Some(reason) = already.covers(&step.node_type) {
            tracing::info!("End of night: {} not run: {}", step.name, reason);
            notify(
                device_ops,
                "info",
                &format!("{}: not run, {}", step.name, reason),
            )
            .await;
            outcomes.push(StepOutcome {
                name: step.name.clone(),
                status: NodeStatus::Skipped,
                passed_over: Some(reason),
                moves_mount,
            });
            continue;
        }
        tracing::info!("End of night: running {}", step.name);
        let mut node = build_runtime_node_from_map(step, &node_map);
        context.node_id = step.id.clone();
        let status = node.execute(&mut context).await;
        let (level, text) = match status {
            NodeStatus::Success => ("info", format!("{}: done", step.name)),
            NodeStatus::Skipped => ("info", format!("{}: nothing to do", step.name)),
            _ => (
                "warning",
                format!(
                    "{}: did not finish ({:?}). Check the rig; the steps after it still run.",
                    step.name, status
                ),
            ),
        };
        tracing::info!("End of night: {}", text);
        notify(device_ops, level, &text).await;
        outcomes.push(StepOutcome {
            name: step.name.clone(),
            status,
            passed_over: None,
            moves_mount,
        });
    }
    outcomes
}

async fn notify(device_ops: &SharedDeviceOps, level: &str, message: &str) {
    if let Err(error) = device_ops
        .send_notification(level, "Ending the night", message, None)
        .await
    {
        tracing::warn!("End of night: notification not sent: {}", error);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{ExposureConfig, LoopCondition, LoopConfig, WarmConfig};

    fn light() -> NodeType {
        NodeType::TakeExposure(ExposureConfig::default())
    }

    fn node(id: &str, node_type: NodeType) -> NodeDefinition {
        NodeDefinition {
            id: id.into(),
            name: id.into(),
            enabled: true,
            node_type,
            children: vec![],
        }
    }

    fn plan(children: Vec<NodeDefinition>) -> SequenceDefinition {
        let mut sequence = SequenceDefinition::new("Night".into());
        sequence.root_node_id = Some("root".into());
        let mut root = node(
            "root",
            NodeType::Loop(LoopConfig {
                iterations: Some(1),
                condition: LoopCondition::Count,
                ..Default::default()
            }),
        );
        root.children = children.iter().map(|n| n.id.clone()).collect();
        sequence.nodes = std::iter::once(root).chain(children).collect();
        sequence
    }

    fn ids(steps: Vec<&NodeDefinition>) -> Vec<String> {
        steps.into_iter().map(|n| n.id.clone()).collect()
    }

    #[test]
    fn the_steps_after_the_last_target_are_the_shutdown() {
        let sequence = plan(vec![
            node("cool", NodeType::CoolCamera(Default::default())),
            node("target", light()),
            node("stop", NodeType::StopGuiding),
            node("home", NodeType::HomeMount),
            node("warm", NodeType::WarmCamera(WarmConfig::default())),
        ]);
        assert_eq!(
            ids(plan_shutdown_steps(&sequence)),
            vec!["stop", "home", "warm"]
        );
    }

    #[test]
    fn a_disabled_step_is_passed_over_and_an_imaging_step_ends_the_shutdown() {
        let mut disabled = node("park", NodeType::Park);
        disabled.enabled = false;
        let sequence = plan(vec![
            node("target", light()),
            node("warm-early", NodeType::WarmCamera(WarmConfig::default())),
            node("slew", NodeType::Unpark),
            node("stop", NodeType::StopGuiding),
            disabled,
            node("warm", NodeType::WarmCamera(WarmConfig::default())),
        ]);
        assert_eq!(ids(plan_shutdown_steps(&sequence)), vec!["stop", "warm"]);
    }

    #[test]
    fn a_plan_that_ends_on_its_target_has_no_shutdown() {
        let sequence = plan(vec![node("target", light())]);
        assert!(plan_shutdown_steps(&sequence).is_empty());
    }

    #[test]
    fn dawn_and_obstruction_end_the_night_and_weather_does_not() {
        assert!(ends_the_night("dawn_approaching"));
        assert!(ends_the_night(OBSTRUCTION_TRIGGER_ID));
        assert!(!ends_the_night("weather_unsafe"));
        assert!(!ends_the_night("guide_star_lost"));
    }
}
