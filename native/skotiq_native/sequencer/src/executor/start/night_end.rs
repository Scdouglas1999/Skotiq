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

/// Nodes that watch the run rather than do a step of it: recovery triggers
/// and the meridian flip. Plans place them anywhere, also after the shutdown.
fn is_watcher(node_type: &NodeType) -> bool {
    matches!(node_type, NodeType::Recovery(_) | NodeType::MeridianFlip(_))
}

/// The plan's shutdown steps: the enabled instructions at the end of the
/// root, after its last target, that only put the rig away. Disabled steps and
/// watchers are passed over; anything else ends the run of steps. A plan
/// wrapped in one container (a wizard plan is a target holding its whole
/// sequence) is read inside that container when nothing after it puts the rig
/// away.
pub(crate) fn plan_shutdown_steps(sequence: &SequenceDefinition) -> Vec<&NodeDefinition> {
    let node = |id: &String| sequence.nodes.iter().find(|n| &n.id == id);
    let Some(mut parent) = sequence.root_node_id.as_ref().and_then(node) else {
        return Vec::new();
    };
    let mut steps = Vec::new();
    loop {
        let mut descend_into = None;
        for id in parent.children.iter().rev() {
            let Some(child) = node(id) else {
                break;
            };
            if !child.enabled || (child.children.is_empty() && is_watcher(&child.node_type)) {
                continue;
            }
            if !child.children.is_empty() || !is_shutdown_step(&child.node_type) {
                if steps.is_empty() && !child.children.is_empty() {
                    descend_into = Some(child);
                }
                break;
            }
            steps.push(child);
        }
        match descend_into {
            Some(container) => parent = container,
            None => break,
        }
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
    run_steps(
        trigger_name,
        plan_shutdown_steps(sequence),
        sequence,
        base,
        device_ops,
        already,
    )
    .await
}

/// Run the plan's shutdown steps the tree never reached after the run
/// failed or a skip ended it early. A failure inside a target ends the tree
/// before Warm camera and Park mount, and a rig left cold and tracking is not
/// a safe end, attended or not. Steps that already ran are not run again.
pub(crate) async fn run_unreached_shutdown_steps(
    sequence: &SequenceDefinition,
    base: &ExecutionContext,
    device_ops: &SharedDeviceOps,
    statuses: &HashMap<NodeId, NodeStatus>,
) -> Vec<StepOutcome> {
    let steps = plan_shutdown_steps(sequence)
        .into_iter()
        .filter(|step| matches!(statuses.get(&step.id), None | Some(NodeStatus::Pending)))
        .collect();
    run_steps(
        "The run ended early",
        steps,
        sequence,
        base,
        device_ops,
        AlreadySafe::default(),
    )
    .await
}

async fn run_steps(
    trigger_name: &str,
    steps: Vec<&NodeDefinition>,
    sequence: &SequenceDefinition,
    base: &ExecutionContext,
    device_ops: &SharedDeviceOps,
    already: AlreadySafe,
) -> Vec<StepOutcome> {
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

    fn once() -> NodeType {
        NodeType::Loop(LoopConfig {
            iterations: Some(1),
            condition: LoopCondition::Count,
            ..Default::default()
        })
    }

    fn recovery(id: &str) -> NodeDefinition {
        node(id, NodeType::Recovery(Default::default()))
    }

    /// Smart Night ends its root with a weather-park recovery watcher after
    /// Park mount; the watcher must not hide the shutdown from dawn.
    #[test]
    fn a_trailing_recovery_watcher_does_not_hide_the_shutdown() {
        let mut darks = node("darks", once());
        darks.children = vec!["dark".into()];
        let mut sequence = plan(vec![
            node("target", light()),
            darks,
            node("warm", NodeType::WarmCamera(WarmConfig::default())),
            node("park", NodeType::Park),
            recovery("cloud-park"),
        ]);
        sequence.nodes.push(node("dark", light()));
        assert_eq!(ids(plan_shutdown_steps(&sequence)), vec!["warm", "park"]);
    }

    /// A Quick-Start wizard plan is one target holding a Sequence (with Warm
    /// Camera and Park Mount at its end) and the watchers after it.
    #[test]
    fn a_wizard_plan_wrapped_in_its_target_has_its_shutdown_inside() {
        let mut sequence = SequenceDefinition::new("M34".into());
        sequence.root_node_id = Some("m34".into());
        let mut target = node("m34", once());
        target.children = vec![
            "sequence".into(),
            "hfr".into(),
            "flip".into(),
            "weather".into(),
        ];
        let mut steps = node("sequence", once());
        steps.children = vec!["loop".into(), "stop".into(), "warm".into(), "park".into()];
        let mut capture = node("loop", NodeType::Loop(LoopConfig::default()));
        capture.children = vec!["l".into()];
        sequence.nodes = vec![
            target,
            steps,
            capture,
            node("l", light()),
            node("stop", NodeType::StopGuiding),
            node("warm", NodeType::WarmCamera(WarmConfig::default())),
            node("park", NodeType::Park),
            recovery("hfr"),
            node("flip", NodeType::MeridianFlip(Default::default())),
            recovery("weather"),
        ];
        assert_eq!(
            ids(plan_shutdown_steps(&sequence)),
            vec!["stop", "warm", "park"]
        );
    }

    /// The owner's plan: Park mount and Warm camera at the root after the
    /// target, the flip inside the target.
    #[test]
    fn the_owners_plan_shape_reads_its_root_shutdown() {
        let mut target = node("target", once());
        target.children = vec!["expose".into(), "flip".into()];
        let mut sequence = plan(vec![
            target,
            node("park", NodeType::Park),
            node("warm", NodeType::WarmCamera(WarmConfig::default())),
        ]);
        sequence.nodes.push(node("expose", light()));
        sequence
            .nodes
            .push(node("flip", NodeType::MeridianFlip(Default::default())));
        assert_eq!(ids(plan_shutdown_steps(&sequence)), vec!["park", "warm"]);
    }

    #[test]
    fn dawn_and_obstruction_end_the_night_and_weather_does_not() {
        assert!(ends_the_night("dawn_approaching"));
        assert!(ends_the_night(OBSTRUCTION_TRIGGER_ID));
        assert!(!ends_the_night("weather_unsafe"));
        assert!(!ends_the_night("guide_star_lost"));
    }
}
