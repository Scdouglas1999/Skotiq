//! Scenario sims for the ways a run ends at the end of the night: the plan's
//! shutdown steps after its targets must still run when a trigger ends the
//! night by cancelling the node tree.

use super::scenario_sim_tests::{
    bring_dawn_near, drain_fired_and_errors, start_run_in_guide_star_recovery, wait_for_monitor,
    wait_for_state, ScriptedDeviceOps, DAWN_OFF,
};
use crate::device_ops::SharedDeviceOps;
use crate::{
    DelayConfig, LoopCondition, LoopConfig, NodeDefinition, NodeType, SequenceDefinition,
    WarmConfig,
};
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::Duration;

fn node(id: &str, name: &str, node_type: NodeType) -> NodeDefinition {
    NodeDefinition {
        id: id.into(),
        name: name.into(),
        enabled: true,
        node_type,
        children: vec![],
    }
}

/// A plan shaped like the owner's Smart Night plans: one long imaging step,
/// then Stop Guiding, `put_away` and Warm Camera.
fn night_plan(put_away: NodeDefinition) -> SequenceDefinition {
    let steps = vec![
        node(
            "imaging",
            "Imaging",
            NodeType::Delay(DelayConfig { seconds: 600.0 }),
        ),
        node("stop-guiding", "Stop Guiding", NodeType::StopGuiding),
        put_away,
        node(
            "warm",
            "Warm camera",
            NodeType::WarmCamera(WarmConfig::default()),
        ),
    ];
    let mut root = node(
        "root",
        "Night",
        NodeType::Loop(LoopConfig {
            iterations: Some(1),
            condition: LoopCondition::Count,
            ..Default::default()
        }),
    );
    root.children = steps.iter().map(|n| n.id.clone()).collect();
    let mut sequence = SequenceDefinition::new("Night".into());
    sequence.root_node_id = Some("root".into());
    sequence.nodes = std::iter::once(root).chain(steps).collect();
    sequence
}

async fn start_night(
    mut executor: super::SequenceExecutor,
    ops: Arc<ScriptedDeviceOps>,
    plan: SequenceDefinition,
) -> super::SequenceExecutor {
    ops.cooler_idle.store(true, Ordering::SeqCst);
    executor.set_devices(
        Some("cam-1".to_string()),
        Some("mount-1".to_string()),
        None,
        None,
        None,
    );
    executor.set_device_ops(ops as SharedDeviceOps);
    executor.load_sequence(plan).expect("sequence loads");
    executor.start().await.expect("executor starts");
    executor
}

async fn wait_until_finished(executor: &super::SequenceExecutor) -> super::ExecutorState {
    wait_for_state(executor, Duration::from_secs(20), |s| {
        matches!(
            s,
            super::ExecutorState::Cancelled
                | super::ExecutorState::Completed
                | super::ExecutorState::Failed
        )
    })
    .await
}

fn notified(calls: &[String], text: &str) -> bool {
    calls
        .iter()
        .any(|c| c.starts_with("notify:") && c.contains(text))
}

/// The dawn park ends the run and the plan's own shutdown still runs:
/// guiding stopped, the mount left parked rather than sent home from the park
/// position, and the camera warmed. Every step is told to the operator.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn dawn_park_still_runs_the_plans_shutdown_steps() {
    let ops = Arc::new(ScriptedDeviceOps::new());
    let plan = night_plan(node("home", "Home mount", NodeType::HomeMount));
    let mut executor = start_night(super::SequenceExecutor::new(), ops.clone(), plan).await;
    wait_for_monitor(&ops).await;

    bring_dawn_near(&executor).await;
    let state = wait_until_finished(&executor).await;
    let calls = ops.calls();
    let _ = executor.stop().await;

    assert_eq!(state, super::ExecutorState::Cancelled, "calls={calls:?}");
    let park = calls.iter().position(|c| c == "mount_park:mount-1");
    let warm = calls
        .iter()
        .position(|c| c == "camera_set_cooler:cam-1:false");
    assert!(park.is_some(), "dawn must park; calls={calls:?}");
    assert!(
        warm.is_some_and(|w| w > park.unwrap()),
        "the plan's Warm camera must run after the park; calls={calls:?}"
    );
    assert_eq!(
        calls.iter().filter(|c| *c == "guider_stop").count(),
        1,
        "guiding is stopped once, by the park; calls={calls:?}"
    );
    assert!(
        !calls.iter().any(|c| c.starts_with("mount_find_home")),
        "a parked mount is not sent home; calls={calls:?}"
    );
    assert!(notified(&calls, "Home mount: not run"), "calls={calls:?}");
    assert!(notified(&calls, "Warm camera: done"), "calls={calls:?}");
}

/// With Park before dawn off, the plan's own Park step is what puts the mount
/// away, and the operator is told so rather than that it may still track.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn dawn_without_parking_runs_the_plans_own_park_and_warm() {
    let ops = Arc::new(ScriptedDeviceOps::new());
    let mut executor = super::SequenceExecutor::new();
    let mut events = executor.subscribe();
    executor.set_park_policy(DAWN_OFF).await;
    let plan = night_plan(node("park", "Park mount", NodeType::Park));
    let mut executor = start_night(executor, ops.clone(), plan).await;
    wait_for_monitor(&ops).await;

    bring_dawn_near(&executor).await;
    let state = wait_until_finished(&executor).await;
    let calls = ops.calls();
    let _ = executor.stop().await;
    let (_, errors) = drain_fired_and_errors(&mut events);

    assert_eq!(state, super::ExecutorState::Cancelled, "calls={calls:?}");
    assert!(calls.iter().any(|c| c == "guider_stop"), "calls={calls:?}");
    assert!(
        calls.iter().any(|c| c == "mount_park:mount-1"),
        "the plan's Park step must run; calls={calls:?}"
    );
    assert!(
        calls.iter().any(|c| c == "camera_set_cooler:cam-1:false"),
        "calls={calls:?}"
    );
    assert!(
        errors
            .iter()
            .any(|m| m.contains("plan's own shutdown steps")),
        "errors={errors:?}"
    );
}

/// A weather park in the middle of the night does not end the night: the
/// camera stays cold for when the sky clears.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_weather_park_does_not_run_the_end_of_night_steps() {
    let ops = Arc::new(ScriptedDeviceOps::new());
    let plan = night_plan(node("home", "Home mount", NodeType::HomeMount));
    let mut executor = start_night(super::SequenceExecutor::new(), ops.clone(), plan).await;
    wait_for_monitor(&ops).await;

    executor.update_weather_verdict(Some(true)).await;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    while ops.call_count("mount_park") == 0 && tokio::time::Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    tokio::time::sleep(Duration::from_secs(2)).await;
    let calls = ops.calls();
    let _ = executor.stop().await;

    assert!(
        calls.iter().any(|c| c == "mount_park:mount-1"),
        "calls={calls:?}"
    );
    assert!(
        !calls.iter().any(|c| c.starts_with("camera_set_cooler")),
        "calls={calls:?}"
    );
}

fn target_plan(end_when: crate::scheduling::TargetTrigger) -> SequenceDefinition {
    let config: crate::TargetHeaderConfig = serde_json::from_value(serde_json::json!({
        "target_name": "NGC0891",
        "ra_hours": 2.376,
        "dec_degrees": 42.35,
        "rotation": null,
        "priority": 0,
        "min_altitude": null,
        "max_altitude": null,
    }))
    .unwrap();
    let mut target = node(
        "target",
        "Target — NGC0891",
        NodeType::TargetHeader(crate::TargetHeaderConfig {
            end_when: Some(end_when),
            ..config
        }),
    );
    target.children = vec!["imaging".into()];
    let imaging = node(
        "imaging",
        "Imaging",
        NodeType::Delay(DelayConfig { seconds: 600.0 }),
    );
    let warm = node(
        "warm",
        "Warm camera",
        NodeType::WarmCamera(WarmConfig::default()),
    );
    let mut root = node(
        "root",
        "Night",
        NodeType::Loop(LoopConfig {
            iterations: Some(1),
            condition: LoopCondition::Count,
            ..Default::default()
        }),
    );
    root.children = vec!["target".into(), "warm".into()];
    let mut sequence = SequenceDefinition::new("Night".into());
    sequence.root_node_id = Some("root".into());
    sequence.nodes = vec![root, target, imaging, warm];
    sequence
}

/// The rig on 2026-10-26: a plan whose target stops at 06:00 owns its end, so
/// the Dawn Approaching trigger stood down, and the run was paused at 05:25.
/// Paused, the target's stop time is never reached, so the run sat paused and
/// tracking until a human came. A held run cannot reach its own end: dawn
/// ends the night, parks, and runs the plan's shutdown steps.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn dawn_ends_a_paused_plan_that_owns_its_end_time() {
    use crate::scheduling::TargetTrigger;
    let ops = Arc::new(ScriptedDeviceOps::new());
    let in_two_hours = chrono::Utc::now().timestamp() + 2 * 3600;
    let plan = target_plan(TargetTrigger::TimeAfter(in_two_hours));
    let mut executor = start_night(super::SequenceExecutor::new(), ops.clone(), plan).await;
    wait_for_monitor(&ops).await;
    executor.pause().await.expect("pause");
    let paused = wait_for_state(&executor, Duration::from_secs(5), |s| {
        s == super::ExecutorState::Paused
    })
    .await;
    assert_eq!(paused, super::ExecutorState::Paused);

    bring_dawn_near(&executor).await;
    let state = wait_until_finished(&executor).await;
    let calls = ops.calls();
    let _ = executor.stop().await;

    assert_eq!(state, super::ExecutorState::Cancelled, "calls={calls:?}");
    assert!(
        calls.iter().any(|c| c == "mount_park:mount-1"),
        "calls={calls:?}"
    );
    assert!(
        calls.iter().any(|c| c == "camera_set_cooler:cam-1:false"),
        "the plan's Warm camera must run; calls={calls:?}"
    );
}

/// Running, the same plan keeps its own end: dawn does not cut it short.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn dawn_leaves_a_running_plan_that_owns_its_end_time() {
    use crate::scheduling::TargetTrigger;
    let ops = Arc::new(ScriptedDeviceOps::new());
    let in_two_hours = chrono::Utc::now().timestamp() + 2 * 3600;
    let plan = target_plan(TargetTrigger::TimeAfter(in_two_hours));
    let mut executor = start_night(super::SequenceExecutor::new(), ops.clone(), plan).await;
    wait_for_monitor(&ops).await;

    bring_dawn_near(&executor).await;
    tokio::time::sleep(Duration::from_secs(3)).await;
    let state = executor.get_state().await;
    let calls = ops.calls();
    let _ = executor.stop().await;

    assert_eq!(state, super::ExecutorState::Running, "calls={calls:?}");
    assert!(
        !calls.iter().any(|c| c.starts_with("mount_park")),
        "calls={calls:?}"
    );
}

/// A plan that kept last night's absolute stop time images tonight: the time
/// is moved to tonight and the operator is told, instead of the target being
/// skipped and the camera warmed at dusk.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn last_nights_stop_time_is_rolled_to_tonight_and_the_target_images() {
    use crate::scheduling::TargetTrigger;
    let ops = Arc::new(ScriptedDeviceOps::new());
    let executor = super::SequenceExecutor::new();
    let mut events = executor.subscribe();
    let yesterday_morning = chrono::Utc::now().timestamp() - 15 * 3600;
    let plan = target_plan(TargetTrigger::TimeAfter(yesterday_morning));
    let mut executor = start_night(executor, ops.clone(), plan).await;
    tokio::time::sleep(Duration::from_secs(2)).await;
    let state = executor.get_state().await;
    let calls = ops.calls();
    let _ = executor.stop().await;

    let mut warnings = Vec::new();
    let mut skipped = false;
    while let Ok(event) = events.try_recv() {
        match event {
            super::ExecutorEvent::Warning { message } => warnings.push(message),
            super::ExecutorEvent::TriggerFired { trigger_id, .. }
                if trigger_id == crate::node::logic::target_header::TARGET_END_WHEN_TRIGGER_ID =>
            {
                skipped = true
            }
            _ => {}
        }
    }
    assert_eq!(state, super::ExecutorState::Running, "calls={calls:?}");
    assert!(!skipped, "the target must not be skipped");
    assert!(
        warnings
            .iter()
            .any(|m| m.contains("earlier night") && m.contains("NGC0891")),
        "warnings={warnings:?}"
    );
    assert!(
        !calls.iter().any(|c| c.starts_with("camera_set_cooler")),
        "the camera must not be warmed at dusk; calls={calls:?}"
    );
}

/// A plan whose only target's end time passed earlier tonight refuses to
/// start with a clear message: no shutdown steps run and no 0-frame run is
/// recorded as completed.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_plan_with_nothing_left_to_image_refuses_to_start() {
    use crate::scheduling::TargetTrigger;
    let ops = Arc::new(ScriptedDeviceOps::new());
    ops.cooler_idle.store(true, Ordering::SeqCst);
    let mut executor = super::SequenceExecutor::new();
    executor.set_devices(
        Some("cam-1".to_string()),
        Some("mount-1".to_string()),
        None,
        None,
        None,
    );
    executor.set_device_ops(ops.clone() as SharedDeviceOps);
    let an_hour_ago = chrono::Utc::now().timestamp() - 3600;
    executor
        .load_sequence(target_plan(TargetTrigger::TimeAfter(an_hour_ago)))
        .expect("sequence loads");
    let refusal = executor.start().await.expect_err("start is refused");
    assert!(refusal.contains("Nothing to image"), "{refusal}");
    assert_eq!(executor.get_state().await, super::ExecutorState::Idle);
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(ops.calls().is_empty(), "calls={:?}", ops.calls());
}

/// A run that dawn ends in the middle of a guide-star recovery takes the
/// recovery with it: the status API stops reporting one, so no banner is left
/// on screen after the night.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn dawn_during_a_recovery_ends_the_recovery_with_the_run() {
    let ops = Arc::new(ScriptedDeviceOps::new());
    let mut executor = start_run_in_guide_star_recovery(ops.clone(), 30.0).await;
    assert!(executor.current_recovery().is_some());

    bring_dawn_near(&executor).await;
    let state = wait_until_finished(&executor).await;
    let recovery = executor.current_recovery();
    let calls = ops.calls();
    let _ = executor.stop().await;

    assert_eq!(state, super::ExecutorState::Cancelled, "calls={calls:?}");
    assert!(recovery.is_none(), "recovery={recovery:?}");
}

/// With end-of-night calibration to follow, the plan's Warm Camera step is
/// deferred: the camera stays at its set-point for the darks.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn dawn_park_leaves_a_deferred_warm_up_to_calibration() {
    let ops = Arc::new(ScriptedDeviceOps::new());
    let mut plan = night_plan(node("home", "Home mount", NodeType::HomeMount));
    for n in &mut plan.nodes {
        if let NodeType::WarmCamera(config) = &mut n.node_type {
            config.defer_to_calibration = true;
        }
    }
    let mut executor = start_night(super::SequenceExecutor::new(), ops.clone(), plan).await;
    wait_for_monitor(&ops).await;

    bring_dawn_near(&executor).await;
    let state = wait_until_finished(&executor).await;
    let calls = ops.calls();
    let _ = executor.stop().await;

    assert_eq!(state, super::ExecutorState::Cancelled, "calls={calls:?}");
    assert!(
        calls.iter().any(|c| c == "mount_park:mount-1"),
        "calls={calls:?}"
    );
    assert!(
        !calls.iter().any(|c| c.starts_with("camera_set_cooler")),
        "the cooler must stay at its set-point; calls={calls:?}"
    );
    assert!(
        notified(&calls, "Warm camera: not run, end-of-night calibration"),
        "calls={calls:?}"
    );
}

const SITE: (f64, f64) = (45.0, -75.0);

/// A right ascension `hours` past the meridian at [`SITE`] now.
fn ra_past_meridian(hours: f64) -> f64 {
    let lst = crate::meridian::local_sidereal_time(
        crate::meridian::julian_day(&chrono::Utc::now()),
        SITE.1,
    );
    (lst - hours).rem_euclid(24.0)
}

fn target(id: &str, ra_hours: f64, children: Vec<String>) -> NodeDefinition {
    let config: crate::TargetHeaderConfig = serde_json::from_value(serde_json::json!({
        "target_name": "M34",
        "ra_hours": ra_hours,
        "dec_degrees": 42.75,
        "rotation": null,
        "priority": 0,
        "min_altitude": null,
        "max_altitude": null,
    }))
    .unwrap();
    let mut node = node(id, "M34", NodeType::TargetHeader(config));
    node.children = children;
    node
}

fn once(id: &str, name: &str, children: Vec<String>) -> NodeDefinition {
    let mut node = node(
        id,
        name,
        NodeType::Loop(LoopConfig {
            iterations: Some(1),
            condition: LoopCondition::Count,
            ..Default::default()
        }),
    );
    node.children = children;
    node
}

fn flip_step() -> NodeDefinition {
    node(
        "flip",
        "Meridian Flip",
        NodeType::MeridianFlip(crate::MeridianFlipConfig {
            pause_guiding: false,
            auto_center: false,
            refocus_after: false,
            resume_guiding: false,
            settle_time: 0.0,
            max_retries: 0,
            retry_delays_secs: Vec::new(),
            ..Default::default()
        }),
    )
}

fn weather_watcher() -> NodeDefinition {
    node(
        "weather",
        "Weather Safety",
        NodeType::Recovery(crate::RecoveryConfig {
            trigger: Some(crate::TriggerType::WeatherUnsafe),
            recovery_action: crate::RecoveryAction::ParkAndAbort,
            max_retries: 1,
        }),
    )
}

/// The Quick-Start wizard's plan: one target holding the Sequence (imaging,
/// Warm Camera, Park Mount) with the meridian flip and a watcher after it.
fn wizard_plan(imaging_secs: f64) -> SequenceDefinition {
    let mut sequence = SequenceDefinition::new("M34 Sequence".into());
    sequence.root_node_id = Some("m34".into());
    sequence.nodes = vec![
        target(
            "m34",
            ra_past_meridian(4.0),
            vec!["sequence".into(), "flip".into(), "weather".into()],
        ),
        once(
            "sequence",
            "Sequence",
            vec!["imaging".into(), "warm".into(), "park".into()],
        ),
        node(
            "imaging",
            "Imaging",
            NodeType::Delay(DelayConfig {
                seconds: imaging_secs,
            }),
        ),
        node(
            "warm",
            "Warm Camera",
            NodeType::WarmCamera(WarmConfig::default()),
        ),
        node("park", "Park Mount", NodeType::Park),
        flip_step(),
        weather_watcher(),
    ];
    sequence
}

/// The owner's plan: the target holds imaging and then the meridian flip;
/// Park mount and Warm camera follow at the root.
fn owners_plan(imaging_secs: f64) -> SequenceDefinition {
    let mut sequence = SequenceDefinition::new("Night".into());
    sequence.root_node_id = Some("root".into());
    sequence.nodes = vec![
        once(
            "root",
            "Night",
            vec!["target".into(), "park".into(), "warm".into()],
        ),
        target(
            "target",
            ra_past_meridian(4.0),
            vec!["imaging".into(), "flip".into()],
        ),
        node(
            "imaging",
            "Smart Exposure",
            NodeType::Delay(DelayConfig {
                seconds: imaging_secs,
            }),
        ),
        flip_step(),
        node("park", "Park mount", NodeType::Park),
        node(
            "warm",
            "Warm camera",
            NodeType::WarmCamera(WarmConfig::default()),
        ),
    ];
    sequence
}

fn rig_at_site() -> Arc<ScriptedDeviceOps> {
    let ops = Arc::new(ScriptedDeviceOps::new());
    *ops.observer_location.lock().unwrap() = Some(SITE);
    // Pier side follows the flip. The run's own trigger already flipped the
    // mount for this target, west of the meridian, so it is on pier East.
    ops.flip_on_slew.store(true, Ordering::SeqCst);
    ops.flipped.store(true, Ordering::SeqCst);
    ops
}

fn moved_after_park(calls: &[String]) -> Vec<String> {
    let Some(park) = calls.iter().position(|c| c == "mount_park:mount-1") else {
        return Vec::new();
    };
    calls[park..]
        .iter()
        .filter(|c| {
            c.starts_with("mount_slew")
                || c.ends_with(":true") && c.starts_with("mount_set_tracking")
        })
        .cloned()
        .collect()
}

/// The wizard placed its Meridian Flip after the Sequence, so it ran as a
/// step after Park Mount: tracking on, slews of the parked mount, and a run
/// that ended Failed with the mount unparked. The plan's park is final.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_flip_step_after_the_plans_park_leaves_the_mount_parked() {
    let ops = rig_at_site();
    let executor = start_night(
        super::SequenceExecutor::new(),
        ops.clone(),
        wizard_plan(0.5),
    )
    .await;
    let state = wait_until_finished(&executor).await;
    let calls = ops.calls();

    assert_eq!(state, super::ExecutorState::Completed, "calls={calls:?}");
    assert!(
        calls.iter().any(|c| c == "mount_park:mount-1"),
        "calls={calls:?}"
    );
    assert_eq!(
        moved_after_park(&calls),
        Vec::<String>::new(),
        "calls={calls:?}"
    );
}

/// Dawn ends a wizard plan: its shutdown lives inside the target, behind the
/// watchers, and still runs (Warm Camera after the dawn park).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn dawn_runs_the_shutdown_inside_a_wizard_plan() {
    let ops = rig_at_site();
    let mut executor = start_night(
        super::SequenceExecutor::new(),
        ops.clone(),
        wizard_plan(600.0),
    )
    .await;
    wait_for_monitor(&ops).await;

    bring_dawn_near(&executor).await;
    let state = wait_until_finished(&executor).await;
    let calls = ops.calls();
    let _ = executor.stop().await;

    assert_eq!(state, super::ExecutorState::Cancelled, "calls={calls:?}");
    assert!(
        calls.iter().any(|c| c == "mount_park:mount-1"),
        "calls={calls:?}"
    );
    assert!(
        calls.iter().any(|c| c == "camera_set_cooler:cam-1:false"),
        "Warm Camera must run at dawn; calls={calls:?}"
    );
    assert_eq!(
        moved_after_park(&calls),
        Vec::<String>::new(),
        "calls={calls:?}"
    );
}

/// Smart Night ends its root with a weather watcher after Park mount. Dawn
/// still warms the camera.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn dawn_runs_the_shutdown_of_a_plan_that_ends_with_a_watcher() {
    let ops = Arc::new(ScriptedDeviceOps::new());
    let mut plan = night_plan(node("park", "Park mount", NodeType::Park));
    plan.nodes.push(weather_watcher());
    plan.nodes[0].children.push("weather".into());
    let mut executor = start_night(super::SequenceExecutor::new(), ops.clone(), plan).await;
    wait_for_monitor(&ops).await;

    bring_dawn_near(&executor).await;
    let state = wait_until_finished(&executor).await;
    let calls = ops.calls();
    let _ = executor.stop().await;

    assert_eq!(state, super::ExecutorState::Cancelled, "calls={calls:?}");
    assert!(
        calls.iter().any(|c| c == "camera_set_cooler:cam-1:false"),
        "Warm camera must run at dawn; calls={calls:?}"
    );
}

/// The owner's plan at the end of its target: the trigger already flipped
/// the mount (pier East), so the flip step leaves it, and Park mount and Warm
/// camera run. The run completes.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_owners_plan_ends_its_target_without_a_second_flip() {
    let ops = rig_at_site();
    let executor = start_night(
        super::SequenceExecutor::new(),
        ops.clone(),
        owners_plan(0.5),
    )
    .await;
    let state = wait_until_finished(&executor).await;
    let calls = ops.calls();

    assert_eq!(state, super::ExecutorState::Completed, "calls={calls:?}");
    assert!(
        !calls.iter().any(|c| c.starts_with("mount_slew")),
        "calls={calls:?}"
    );
    let park = calls.iter().position(|c| c == "mount_park:mount-1");
    let warm = calls
        .iter()
        .position(|c| c == "camera_set_cooler:cam-1:false");
    assert!(
        park.is_some() && warm.is_some_and(|w| w > park.unwrap()),
        "calls={calls:?}"
    );
}

/// The owner's plan at dawn: parked, then Warm camera; the flip step never
/// runs on the parked mount.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_owners_plan_at_dawn_parks_and_warms() {
    let ops = rig_at_site();
    let mut executor = start_night(
        super::SequenceExecutor::new(),
        ops.clone(),
        owners_plan(600.0),
    )
    .await;
    wait_for_monitor(&ops).await;

    bring_dawn_near(&executor).await;
    let state = wait_until_finished(&executor).await;
    let calls = ops.calls();
    let _ = executor.stop().await;

    assert_eq!(state, super::ExecutorState::Cancelled, "calls={calls:?}");
    assert!(
        calls.iter().any(|c| c == "camera_set_cooler:cam-1:false"),
        "calls={calls:?}"
    );
    assert_eq!(
        moved_after_park(&calls),
        Vec::<String>::new(),
        "calls={calls:?}"
    );
}

/// A run that fails inside its imaging still runs the plan's shutdown:
/// guiding stopped, mount parked, camera warmed. The run stays Failed.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_failed_run_still_runs_the_plans_shutdown_steps() {
    let ops = Arc::new(ScriptedDeviceOps::new());
    let mut plan = night_plan(node("park", "Park mount", NodeType::Park));
    // A flip step outside any target has no target to flip for and fails.
    for n in &mut plan.nodes {
        if n.id == "imaging" {
            *n = flip_step();
            n.id = "imaging".into();
        }
    }
    let executor = start_night(super::SequenceExecutor::new(), ops.clone(), plan).await;
    let state = wait_until_finished(&executor).await;
    let calls = ops.calls();

    assert_eq!(state, super::ExecutorState::Failed, "calls={calls:?}");
    let park = calls.iter().position(|c| c == "mount_park:mount-1");
    let warm = calls
        .iter()
        .position(|c| c == "camera_set_cooler:cam-1:false");
    assert!(
        park.is_some(),
        "the plan's Park mount must run; calls={calls:?}"
    );
    assert!(
        warm.is_some_and(|w| w > park.unwrap()),
        "the plan's Warm camera must run; calls={calls:?}"
    );
    assert!(notified(&calls, "Warm camera: done"), "calls={calls:?}");
}

/// Skip step ends the step that is running and the run goes on: the next
/// step and the plan's shutdown still run. It used to skip the whole target,
/// which in a wizard plan (one target holding everything) ended the run as
/// Completed with no shutdown at all.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn skip_step_skips_only_the_running_step() {
    let ops = rig_at_site();
    let mut plan = wizard_plan(600.0);
    // A second step after the long one, before the shutdown.
    plan.nodes.push(node(
        "second",
        "R",
        NodeType::Delay(DelayConfig { seconds: 0.2 }),
    ));
    for n in &mut plan.nodes {
        if n.id == "sequence" {
            n.children.insert(1, "second".into());
        }
    }
    let executor = start_night(super::SequenceExecutor::new(), ops.clone(), plan).await;
    wait_for_state(&executor, Duration::from_secs(5), |s| {
        s == super::ExecutorState::Running
    })
    .await;
    tokio::time::sleep(Duration::from_millis(500)).await;

    executor.skip().await.expect("skip");
    let state = wait_until_finished(&executor).await;
    let progress = executor.get_progress();
    let calls = ops.calls();

    assert_eq!(state, super::ExecutorState::Completed, "calls={calls:?}");
    assert_eq!(
        progress.node_statuses.get("imaging"),
        Some(&crate::NodeStatus::Skipped)
    );
    assert_eq!(
        progress.node_statuses.get("second"),
        Some(&crate::NodeStatus::Success)
    );
    assert!(
        calls.iter().any(|c| c == "camera_set_cooler:cam-1:false"),
        "calls={calls:?}"
    );
    assert!(
        calls.iter().any(|c| c == "mount_park:mount-1"),
        "calls={calls:?}"
    );
}

/// A new run does not read the previous run's tracking as its own: the
/// mount the last run parked, unparked for this one and not yet tracking, is
/// not a lost track on the first poll.
#[test]
fn a_new_run_does_not_inherit_the_last_runs_tracking_baseline() {
    let mut state = crate::triggers::TriggerState::new();
    assert!(!super::monitoring::apply_mount_tracking_poll(
        &mut state, true
    ));
    state.telemetry.mount_is_tracking = Some(true);
    state.reset_for_new_run();
    assert!(
        !super::monitoring::apply_mount_tracking_poll(&mut state, false),
        "the first poll of a new run is not a loss"
    );
}
