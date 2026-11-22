//! What a run that ended early still owes the rig.
//!
//! A trigger that ends the run (dawn, an obstruction, unsafe weather), a
//! failure, or a stop the system asked for cancels the node tree, so the
//! plan's own end steps after its targets never run. They are run here
//! instead, once the tree has stopped and the rig is parked or left, on a
//! context of their own so the run's cancellation does not cancel them. The
//! operator's own Stop is the one end that leaves the rig as it is.

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

pub(crate) use crate::triggers::ends_the_night;

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

/// The `metadata` key by which the app asks for the plan's closing warm-up to
/// wait for end-of-night calibration.
pub const DEFER_SHUTDOWN_WARM_UP_METADATA_KEY: &str = "defer_shutdown_warm_up";

/// With end-of-night calibration to follow (the app sets
/// [`DEFER_SHUTDOWN_WARM_UP_METADATA_KEY`] to `"true"`), the Warm Camera steps
/// among the plan's shutdown steps are left to calibration, so the camera
/// stays at its set-point for the darks. Calibration warms the camera however
/// it ends.
pub(crate) fn defer_shutdown_warm_up(sequence: &mut SequenceDefinition) {
    let wanted = sequence
        .metadata
        .get(DEFER_SHUTDOWN_WARM_UP_METADATA_KEY)
        .is_some_and(|value| value == "true");
    if !wanted {
        return;
    }
    let warm_ups: Vec<NodeId> = plan_shutdown_steps(sequence)
        .into_iter()
        .filter(|step| matches!(step.node_type, NodeType::WarmCamera(_)))
        .map(|step| step.id.clone())
        .collect();
    for node in &mut sequence.nodes {
        if let NodeType::WarmCamera(config) = &mut node.node_type {
            if warm_ups.contains(&node.id) {
                config.defer_to_calibration = true;
            }
        }
    }
}

/// What the end-of-night sweep already did before the plan's steps run.
#[derive(Default, Clone, Copy)]
pub(crate) struct AlreadySafe {
    pub guiding_stopped: bool,
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

/// The one rule on how a run ends (owner, 2026-11-17): a run that did not
/// walk through its plan's end steps still runs the ones it did not reach,
/// whatever ended it (a trigger, a failure, a skip past its targets, a stop
/// the system asked for), except the operator's own Stop, after which the rig
/// is theirs. Warm camera runs, and the mount is parked only when the plan
/// parks it. Steps that already ran are not run again, and `already` says
/// what a trigger's park sweep has put away.
///
/// `base` is the run's context. The steps get fresh cancel, pause and skip
/// flags: the run's own are already set by whatever ended it.
pub(crate) async fn run_owed_end_steps(
    label: &str,
    sequence: &SequenceDefinition,
    base: &ExecutionContext,
    device_ops: &SharedDeviceOps,
    state: &RunCell,
    already: AlreadySafe,
) -> Vec<StepOutcome> {
    if state.stopped_by_operator() {
        tracing::info!("Run end: stopped by the operator, so the plan's end steps are not run");
        return Vec::new();
    }
    let statuses = state.read_progress(|progress| progress.node_statuses.clone());
    let steps = plan_shutdown_steps(sequence)
        .into_iter()
        .filter(|step| matches!(statuses.get(&step.id), None | Some(NodeStatus::Pending)))
        .collect();
    run_steps(label, steps, sequence, base, device_ops, already).await
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

    fn deferred(sequence: &SequenceDefinition) -> Vec<String> {
        sequence
            .nodes
            .iter()
            .filter(|n| matches!(&n.node_type, NodeType::WarmCamera(c) if c.defer_to_calibration))
            .map(|n| n.id.clone())
            .collect()
    }

    fn wanting_deferral(mut sequence: SequenceDefinition) -> SequenceDefinition {
        sequence.metadata.insert(
            DEFER_SHUTDOWN_WARM_UP_METADATA_KEY.to_string(),
            "true".to_string(),
        );
        defer_shutdown_warm_up(&mut sequence);
        sequence
    }

    /// Only the warm-up among the closing steps waits for calibration.
    #[test]
    fn the_closing_warm_up_is_left_to_calibration() {
        let sequence = wanting_deferral(plan(vec![
            node("early-warm", NodeType::WarmCamera(WarmConfig::default())),
            node("target", light()),
            node("stop", NodeType::StopGuiding),
            node("warm", NodeType::WarmCamera(WarmConfig::default())),
        ]));
        assert_eq!(deferred(&sequence), vec!["warm"]);
    }

    /// A wizard plan holds its warm-up inside its one target, with a flip
    /// and recovery watchers after it.
    #[test]
    fn a_wizard_plans_warm_up_is_left_to_calibration() {
        let mut target = node("m34", once());
        target.children = vec!["l".into(), "warm".into()];
        let mut sequence = plan(vec![
            target,
            node("flip", NodeType::MeridianFlip(Default::default())),
            recovery("weather"),
        ]);
        sequence.nodes.push(node("l", light()));
        sequence
            .nodes
            .push(node("warm", NodeType::WarmCamera(WarmConfig::default())));
        assert_eq!(deferred(&wanting_deferral(sequence)), vec!["warm"]);
    }

    /// The app's wish travels in the loaded plan's metadata.
    #[test]
    fn a_loaded_plan_that_asks_has_its_warm_up_deferred() {
        let mut sequence = plan(vec![
            node("target", light()),
            node("warm", NodeType::WarmCamera(WarmConfig::default())),
            node("flip", NodeType::MeridianFlip(Default::default())),
        ]);
        sequence.metadata.insert(
            DEFER_SHUTDOWN_WARM_UP_METADATA_KEY.to_string(),
            "true".to_string(),
        );
        let mut executor = SequenceExecutor::new();
        executor.load_sequence(sequence).unwrap();
        assert_eq!(deferred(executor.sequence.as_ref().unwrap()), vec!["warm"]);
    }

    #[test]
    fn without_calibration_to_follow_nothing_is_deferred() {
        let mut sequence = plan(vec![
            node("target", light()),
            node("warm", NodeType::WarmCamera(WarmConfig::default())),
        ]);
        defer_shutdown_warm_up(&mut sequence);
        assert!(deferred(&sequence).is_empty());
        let sequence = wanting_deferral(plan(vec![node("target", light())]));
        assert!(deferred(&sequence).is_empty());
    }

    #[test]
    fn dawn_and_obstruction_end_the_night_and_weather_does_not() {
        assert!(ends_the_night("dawn_approaching"));
        assert!(ends_the_night(OBSTRUCTION_TRIGGER_ID));
        assert!(!ends_the_night("weather_unsafe"));
        assert!(!ends_the_night("guide_star_lost"));
    }
}
