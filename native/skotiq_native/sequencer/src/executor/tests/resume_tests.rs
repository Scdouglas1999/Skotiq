//! A run stopped part-way and resumed from its checkpoint continues where it
//! stopped: finished bursts are not taken again, a burst it stopped in takes
//! only the frames it still owes, and the steps that prepare the rig (here a
//! wait standing in for unpark and slew) run again.

use super::*;
use crate::device_ops::NullDeviceOps;
use crate::{DelayConfig, LoopCondition, LoopConfig, NodeType, SequenceDefinition};

const FRAMES: u32 = 8;
const SUB_SECS: f64 = 0.3;

/// The shape the app builds: a Count loop at the root around the plan's
/// steps, here a setup group with a wait in it and one burst of darks.
fn app_built_plan(loop_passes: u32) -> SequenceDefinition {
    let mut sequence = SequenceDefinition::new("Stop and recover".to_string());
    sequence.nodes.push(crate::NodeDefinition {
        id: "root".to_string(),
        name: "Root".to_string(),
        node_type: NodeType::Loop(LoopConfig {
            iterations: Some(loop_passes),
            condition: LoopCondition::Count,
            condition_value: None,
            horizon_profile: None,
        }),
        enabled: true,
        children: vec!["setup".to_string(), "frames".to_string()],
    });
    // The app's instruction groups run as one-pass loops.
    sequence.nodes.push(crate::NodeDefinition {
        id: "setup".to_string(),
        name: "Setup".to_string(),
        node_type: NodeType::Loop(LoopConfig {
            iterations: Some(1),
            condition: LoopCondition::Count,
            condition_value: None,
            horizon_profile: None,
        }),
        enabled: true,
        children: vec![
            "wait".to_string(),
            "notify".to_string(),
            "script".to_string(),
        ],
    });
    sequence.nodes.push(crate::NodeDefinition {
        id: "notify".to_string(),
        name: "Tell me it started".to_string(),
        node_type: NodeType::Notification(crate::NotificationConfig {
            title: "Imaging started".to_string(),
            message: "The darks are running".to_string(),
            ..Default::default()
        }),
        enabled: true,
        children: vec![],
    });
    // Disabled, so no script runs in a test; what a resume does with it is
    // read from the tree in `a_resume_runs_a_finished_script_step_again`.
    sequence.nodes.push(crate::NodeDefinition {
        id: "script".to_string(),
        name: "Open the roof".to_string(),
        node_type: NodeType::RunScript(crate::ScriptConfig::default()),
        enabled: false,
        children: vec![],
    });
    sequence.nodes.push(crate::NodeDefinition {
        id: "wait".to_string(),
        name: "Wait".to_string(),
        node_type: NodeType::Delay(DelayConfig { seconds: 1.0 }),
        enabled: true,
        children: vec![],
    });
    sequence.nodes.push(crate::NodeDefinition {
        id: "frames".to_string(),
        name: "Darks".to_string(),
        node_type: NodeType::TakeExposure(crate::ExposureConfig {
            duration_secs: SUB_SECS,
            count: FRAMES,
            frame_type: crate::FrameType::Dark,
            ..Default::default()
        }),
        enabled: true,
        children: vec![],
    });
    sequence.root_node_id = Some("root".to_string());
    sequence
}

struct Leg {
    executor: SequenceExecutor,
    events: tokio::sync::broadcast::Receiver<ExecutorEvent>,
}

fn executor_for(dir: &std::path::Path) -> SequenceExecutor {
    let mut executor = SequenceExecutor::new();
    executor.set_checkpoint_dir(dir.join("checkpoint"));
    executor.set_device_ops(Arc::new(NullDeviceOps));
    executor.set_save_path(Some(dir.to_path_buf()));
    executor.set_devices(Some("cam-1".to_string()), None, None, None, None);
    executor
}

async fn start(mut executor: SequenceExecutor) -> Leg {
    let events = executor.subscribe();
    executor.start().await.expect("run starts");
    Leg { executor, events }
}

/// Where the first leg is stopped.
#[derive(Clone, Copy)]
enum StopAt {
    /// After this many frames.
    Frame(u32),
    /// When the wait step starts for this time.
    Wait(u32),
}

/// Count what the run did until it reached a terminal state: frames
/// completed, and how often the wait step started.
async fn drain(leg: &mut Leg, stop: Option<StopAt>) -> (u32, u32) {
    let (frames, waits, _) = drain_counting_notifications(leg, stop).await;
    (frames, waits)
}

/// [`drain`], with how often the notification step ran.
async fn drain_counting_notifications(leg: &mut Leg, stop: Option<StopAt>) -> (u32, u32, u32) {
    let mut notified = 0;
    let (frames, waits) = drain_inner(leg, stop, &mut notified).await;
    (frames, waits, notified)
}

async fn drain_inner(leg: &mut Leg, stop: Option<StopAt>, notified: &mut u32) -> (u32, u32) {
    let mut frames = 0;
    let mut waits = 0;
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(60);
    loop {
        let event = tokio::time::timeout_at(deadline, leg.events.recv())
            .await
            .expect("run ends in time");
        match event {
            Ok(ExecutorEvent::ExposureCompleted { .. }) => {
                frames += 1;
                if matches!(stop, Some(StopAt::Frame(at)) if at == frames) {
                    leg.executor.stop().await.expect("stop is accepted");
                }
            }
            Ok(ExecutorEvent::NodeStarted { id, .. }) if id == "notify" => *notified += 1,
            Ok(ExecutorEvent::NodeStarted { id, .. }) if id == "wait" => {
                waits += 1;
                if matches!(stop, Some(StopAt::Wait(at)) if at == waits) {
                    leg.executor.stop().await.expect("stop is accepted");
                }
            }
            Ok(ExecutorEvent::StateChanged(
                ExecutorState::Completed | ExecutorState::Failed | ExecutorState::Cancelled,
            )) => return (frames, waits),
            Ok(_) | Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {}
            Err(tokio::sync::broadcast::error::RecvError::Closed) => return (frames, waits),
        }
    }
}

async fn stop_and_resume(loop_passes: u32, stop: StopAt) -> ((u32, u32), (u32, u32)) {
    let dir = std::env::temp_dir().join(format!("sk-resume-continues-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();

    let mut first = executor_for(&dir);
    first
        .load_sequence(app_built_plan(loop_passes))
        .expect("sequence loads");
    let mut first = start(first).await;
    let before = drain(&mut first, Some(stop)).await;
    drop(first);

    let mut second = executor_for(&dir);
    second
        .resume_from_checkpoint()
        .await
        .expect("resume prepares");
    let mut second = start(second).await;
    let after = drain(&mut second, None).await;
    let progress = second.executor.get_progress();
    let _ = std::fs::remove_dir_all(&dir);
    assert_eq!(
        progress.completed_exposures,
        loop_passes * FRAMES,
        "the resumed run counts the plan's frames once"
    );
    (before, after)
}

/// An 8-frame plan stopped after its third frame takes the other five on
/// resume; the step before the burst prepares the rig again.
#[tokio::test]
async fn a_resumed_run_takes_only_the_frames_it_still_owes() {
    let ((frames_before, waits_before), (frames_after, waits_after)) =
        stop_and_resume(1, StopAt::Frame(3)).await;
    assert_eq!((frames_before, waits_before), (3, 1));
    assert_eq!(frames_after, FRAMES - 3, "frames taken after the resume");
    assert_eq!(waits_after, 1, "the rig is prepared again before the burst");
}

/// Stopped in the second pass of a two-pass loop, the resume finishes that
/// pass's burst and runs no third pass.
#[tokio::test]
async fn a_resumed_loop_continues_the_pass_it_stopped_in() {
    let ((frames_before, waits_before), (frames_after, waits_after)) =
        stop_and_resume(2, StopAt::Frame(FRAMES + 2)).await;
    assert_eq!((frames_before, waits_before), (FRAMES + 2, 2));
    assert_eq!(frames_after, FRAMES - 2);
    assert_eq!(waits_after, 1);
}

/// Stopped while the second pass's wait runs, the resume runs that wait again
/// and the whole second burst: the burst's status from the first pass is not
/// progress in the second.
#[tokio::test]
async fn a_status_from_an_earlier_pass_does_not_count_on_resume() {
    let ((frames_before, waits_before), (frames_after, waits_after)) =
        stop_and_resume(2, StopAt::Wait(2)).await;
    assert_eq!((frames_before, waits_before), (FRAMES, 2));
    assert_eq!(frames_after, FRAMES);
    assert_eq!(waits_after, 1);
}

/// A plan stopped in its burst had already sent its notification. The resume
/// prepared the rig again and sent "Imaging started" a second time.
#[tokio::test]
async fn a_resume_does_not_send_a_finished_notification_again() {
    let dir = std::env::temp_dir().join(format!("sk-resume-notify-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();

    let mut first = executor_for(&dir);
    first
        .load_sequence(app_built_plan(1))
        .expect("sequence loads");
    let mut first = start(first).await;
    let (_, _, sent_before) =
        drain_counting_notifications(&mut first, Some(StopAt::Frame(3))).await;
    drop(first);

    let mut second = executor_for(&dir);
    second
        .resume_from_checkpoint()
        .await
        .expect("resume prepares");
    let mut second = start(second).await;
    let (frames_after, waits_after, sent_after) =
        drain_counting_notifications(&mut second, None).await;
    let _ = std::fs::remove_dir_all(&dir);

    assert_eq!(sent_before, 1);
    assert_eq!(sent_after, 0, "the notification is not sent a second time");
    assert_eq!(waits_after, 1, "the rig is still prepared again");
    assert_eq!(frames_after, FRAMES - 3);
}

/// Stop, Restore progress and Start without closing the app: the executor is
/// still in its Cancelled state when the resume is prepared. The start then
/// recycled the executor and wiped what the resume had marked, so the whole
/// plan ran again (22 frames for an 18-frame plan on the simulator).
#[tokio::test]
async fn a_resume_in_the_same_launch_continues_too() {
    let dir = std::env::temp_dir().join(format!("sk-resume-same-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();

    let mut executor = executor_for(&dir);
    executor
        .load_sequence(app_built_plan(2))
        .expect("sequence loads");
    let mut leg = start(executor).await;
    let (frames_before, _, sent_before) =
        drain_counting_notifications(&mut leg, Some(StopAt::Frame(FRAMES + 2))).await;
    assert_eq!(leg.executor.get_state().await, ExecutorState::Cancelled);

    leg.executor
        .resume_from_checkpoint()
        .await
        .expect("resume prepares");
    leg.executor.start().await.expect("the resumed run starts");
    let (frames_after, waits_after, sent_after) =
        drain_counting_notifications(&mut leg, None).await;
    let _ = std::fs::remove_dir_all(&dir);

    assert_eq!(frames_before, FRAMES + 2);
    assert_eq!(frames_after, FRAMES - 2, "only the frames still owed");
    assert_eq!(waits_after, 1, "the rig is prepared again");
    assert_eq!((sent_before, sent_after), (2, 0));
}

/// A script may have opened the roof the stop closed, and the steps after it
/// move the mount, so a finished Run Script step is not kept by a resume.
#[test]
fn a_resume_runs_a_finished_script_step_again() {
    let mut executor = SequenceExecutor::new();
    executor
        .load_sequence(app_built_plan(1))
        .expect("sequence loads");
    let root = executor.root_node.as_ref().expect("the plan has a tree");
    let kept = crate::node::resume::kept_on_resume(root.as_ref());
    assert!(kept.contains("notify"));
    assert!(kept.contains("frames"));
    assert!(!kept.contains("script"));
    assert!(!kept.contains("wait"));
}

/// What the app reads to show a restored run's progress before and while it
/// continues: the frames each step already has over the whole plan, every
/// pass included. Restored from a two-pass plan stopped two frames into its
/// second pass, the app showed 0 of 16 and pre-flight estimated all 16.
#[tokio::test]
async fn a_checkpoint_tells_the_app_the_frames_each_step_has() {
    let dir = std::env::temp_dir().join(format!("sk-resume-frames-done-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();

    let mut first = executor_for(&dir);
    first
        .load_sequence(app_built_plan(2))
        .expect("sequence loads");
    let mut first = start(first).await;
    drain(&mut first, Some(StopAt::Frame(FRAMES + 2))).await;
    drop(first);

    let mut second = executor_for(&dir);
    let restored = second
        .get_checkpoint_info()
        .expect("the stopped run kept its checkpoint");
    assert_eq!(
        restored.frames_done_by_step.get("frames").copied(),
        Some(FRAMES + 2),
        "both passes' frames count for the step"
    );

    second
        .resume_from_checkpoint()
        .await
        .expect("resume prepares");
    let mut second = start(second).await;
    drain(&mut second, Some(StopAt::Frame(3))).await;
    let stopped_again = second
        .executor
        .get_checkpoint_info()
        .expect("the run stopped again keeps its checkpoint");
    let _ = std::fs::remove_dir_all(&dir);
    assert_eq!(
        stopped_again.frames_done_by_step.get("frames").copied(),
        Some(FRAMES + 2 + 3),
        "the continued run adds its frames to those it continued from"
    );
}

/// A checkpoint written before the per-step frames were recorded still loads,
/// with no per-step frames.
#[test]
fn a_checkpoint_without_per_step_frames_still_loads() {
    let mut checkpoint = crate::checkpoint::SessionCheckpoint::new(app_built_plan(1));
    checkpoint
        .exposure_frames_done
        .insert("frames".to_string(), 3);
    let mut json = serde_json::to_value(&checkpoint).expect("serializes");
    json.as_object_mut()
        .expect("an object")
        .remove("exposure_frames_done");
    let loaded: crate::checkpoint::SessionCheckpoint =
        serde_json::from_value(json).expect("an older checkpoint loads");
    assert!(loaded.exposure_frames_done.is_empty());
}
