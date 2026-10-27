//! The frame watch inside a running trigger monitor, fed the rig night of
//! 2026-10-23/24 frame by frame: the frame events the capture loop sent, the
//! plate solves the app logged, and the simulator rig acting on what the
//! watch decides.

use super::dispatch::Dispatcher;
use super::frame_watch::{
    FrameWatchStage, Measurer, OBSTRUCTION_TRIGGER_ID, TARGET_DRIFT_TRIGGER_ID,
};
use super::*;
use crate::executor::scenario_sim_tests::ScriptedDeviceOps;
use crate::frame_watch::assess::MeasuredFrame;
use crate::frame_watch::fixture::{
    rows, Row, FIELD_SHORT_SIDE_ARCMIN, TARGET_DEC_DEG, TARGET_RA_DEG,
};
use crate::frame_watch::{FrameAssessed, FrameWatchEvent, HorizonObstructionReport};

const SITE_LAT: f64 = 39.9719;
const SITE_LON: f64 = -75.3576;

fn plan() -> SequenceDefinition {
    let header: crate::TargetHeaderConfig = serde_json::from_value(serde_json::json!({
        "target_name": "NGC0891", "ra_hours": TARGET_RA_DEG / 15.0,
        "dec_degrees": TARGET_DEC_DEG, "rotation": null, "priority": 0,
        "min_altitude": 30.0, "max_altitude": null
    }))
    .expect("target header");
    serde_json::from_value(serde_json::json!({
        "id": "plan",
        "name": "NGC0891 Plan",
        "root_node_id": "root",
        "nodes": [
            {
                "id": "root", "name": "root", "enabled": true, "children": ["ngc891"],
                "node_type": serde_json::to_value(crate::NodeType::Loop(crate::LoopConfig::default())).unwrap(),
            },
            {
                "id": "ngc891", "name": "NGC0891", "enabled": true, "children": [],
                "node_type": serde_json::to_value(crate::NodeType::TargetHeader(header)).unwrap(),
            }
        ],
        "metadata": {}
    }))
    .expect("plan")
}

struct Harness {
    dispatcher: Dispatcher,
    stage: FrameWatchStage,
    events: broadcast::Sender<ExecutorEvent>,
    seen: broadcast::Receiver<ExecutorEvent>,
    ops: Arc<ScriptedDeviceOps>,
    /// The target id the capture loop stamps on each frame.
    target_id: Option<String>,
}

impl Harness {
    async fn new() -> Self {
        Self::with_plan_and_rows(plan(), rows()).await
    }

    async fn with_plan_and_rows(plan: SequenceDefinition, frames: Vec<Row>) -> Self {
        let ops = Arc::new(ScriptedDeviceOps::new());
        *ops.pointing.lock().unwrap() = Some((TARGET_RA_DEG / 15.0, TARGET_DEC_DEG));
        let mut manager = TriggerManager::new();
        manager.create_standard_triggers();
        {
            let lock = manager.state();
            let mut s = lock.write().await;
            s.set_target(TARGET_RA_DEG, TARGET_DEC_DEG);
            s.current_target_name = Some("NGC0891".to_string());
            s.weather_safe = true;
        }
        let (events, seen) = broadcast::channel(4096);
        let (decisions, _) = broadcast::channel(4096);
        let (requests, _recovery) = mpsc::channel(4);
        let (done, _) = watch::channel(false);
        let (_, quiesced) = watch::channel(true);
        let (heartbeat, _) = watch::channel(0);
        let runtime_config = RuntimeConfig {
            latitude: Some(SITE_LAT),
            longitude: Some(SITE_LON),
            ..RuntimeConfig::default()
        };
        // Each frame is "measured" from the night's logged solve.
        let solves: HashMap<String, Row> = frames
            .into_iter()
            .map(|r| (format!("row-{}.fits", r.id), r))
            .collect();
        let measurer: Measurer = Arc::new(move |path: String, _, _| {
            let row = solves.get(&path).cloned();
            Box::pin(async move {
                let row = row.ok_or_else(|| format!("no such frame {path}"))?;
                let solved = matches!(row.solve, crate::frame_watch::SolveOutcome::Solved { .. });
                Ok(MeasuredFrame {
                    width: 4656,
                    height: 3520,
                    background_adu: None,
                    solve: row.solve,
                    field_short_side_arcmin: solved.then_some(FIELD_SHORT_SIDE_ARCMIN),
                })
            })
        });
        let stage =
            FrameWatchStage::with_measurer(events.subscribe(), measurer, Some(plan.clone()));
        let dispatcher = Dispatcher::new(TriggerMonitorArgs {
            active_run_id_for_decisions: Arc::new(StdRwLock::new(None)),
            cloud_motion_for_recovery: Arc::new(RwLock::new(CloudMotionSnapshot::default())),
            custom_recovery_branches_for_triggers: Arc::new(HashMap::new()),
            custom_recovery_context_for_triggers: ExecutionContext::new("root".into(), ops.clone()),
            decision_tx_for_lifecycle: decisions,
            device_ops_for_triggers: ops.clone(),
            event_tx_clone2: events.clone(),
            execution_quiesced_for_triggers: quiesced,
            heartbeat_tx: heartbeat,
            is_cancelled_clone: Arc::new(AtomicBool::new(false)),
            is_paused_for_triggers: Arc::new(AtomicBool::new(false)),
            meridian_flip_failed_for_triggers: Arc::new(AtomicBool::new(false)),
            meridian_flip_failure_for_triggers: Arc::new(StdRwLock::new(None)),
            park_and_abort_done_for_triggers: done,
            park_and_abort_for_triggers: Arc::new(AtomicBool::new(false)),
            progress_for_triggers: Arc::new(StdRwLock::new(SequenceProgress::default())),
            recovery_request_tx: requests,
            runtime_config: Arc::new(StdRwLock::new(runtime_config)),
            sequence_for_custom_recovery_triggers: Some(plan),
            skip_to_next_target_for_triggers: Arc::new(AtomicBool::new(false)),
            skip_to_node_for_recovery: Arc::new(StdRwLock::new(None)),
            state_clone: Arc::new(RwLock::new(ExecutorState::Running)),
            transparency_backup_for_recovery: Arc::new(RwLock::new(None)),
            trigger_action_context: TriggerActionContext {
                mount_id: Some("mount".into()),
                camera_id: Some("camera".into()),
                latitude: Some(SITE_LAT),
                longitude: Some(SITE_LON),
                ..Default::default()
            },
            trigger_action_in_flight_for_triggers: Arc::new(AtomicBool::new(false)),
            trigger_manager: Arc::new(RwLock::new(manager)),
            triggers_enabled: true,
        })
        .await;
        Self {
            dispatcher,
            stage,
            events,
            seen,
            ops,
            target_id: None,
        }
    }

    /// Send the frame event the capture loop sent for `row`, with the
    /// grader's verdict of that night.
    async fn save(&mut self, row: &Row) {
        self.dispatcher
            .rig
            .trigger_state
            .write()
            .await
            .set_filter(row.filter.clone());
        let capture = crate::scheduling::FrameCaptureMetadata {
            mount_altitude_deg: Some(row.alt),
            mount_azimuth_deg: Some(row.az),
            pier_side: Some(row.pier.clone()),
            exposure_secs: row.exposure_secs,
            bin_x: 1,
            bin_y: 1,
            frame_type: "Light".to_string(),
            target_id: self.target_id.clone(),
            ..Default::default()
        };
        let path = format!("row-{}.fits", row.id);
        let detail = if row.db_accepted {
            ProgressDetail::FrameAccepted {
                frame: 1,
                total: 1,
                hfr: row.hfr,
                eccentricity: row.ecc,
                star_count: row.stars,
                accepted_total: 0,
                rejected_total: 0,
                save_path: Some(path),
                capture,
            }
        } else {
            ProgressDetail::FrameRejected {
                frame: 1,
                total: 1,
                reason: row.db_reason.clone(),
                hfr: row.hfr,
                eccentricity: row.ecc,
                star_count: row.stars,
                reject_path: path,
                consecutive_rejects: 1,
                accepted_total: 0,
                rejected_total: 0,
                likely_cause: None,
                evidence: Vec::new(),
                sky_brightness_at_capture: None,
                cloud_cover_at_capture: None,
                wind_at_capture: None,
                guide_rms_at_capture: None,
                sensor_temp_at_capture: None,
                capture,
            }
        };
        let _ = self.events.send(ExecutorEvent::NodeProgress {
            node_id: "lights".to_string(),
            instruction: "Exposure".to_string(),
            progress_percent: 100.0,
            detail: String::new(),
            structured_detail: Some(Box::new(detail)),
        });
    }

    /// Tick until the frame watch has reported `path` (or the run ended).
    async fn tick_until_reported(
        &mut self,
        path: &str,
        log: &mut Vec<ExecutorEvent>,
    ) -> Option<Vec<(String, RecoveryAction)>> {
        for _ in 0..200 {
            if let Some(end) = self
                .stage
                .tick(&mut self.dispatcher, RunMode::Running)
                .await
            {
                self.drain(log);
                return Some(end);
            }
            let before = log.len();
            self.drain(log);
            if log[before..]
                .iter()
                .any(|e| assessed(e).is_some_and(|a| a.save_path == path))
            {
                return None;
            }
            tokio::time::sleep(std::time::Duration::from_millis(5)).await;
        }
        panic!("{path} was never reported");
    }

    fn drain(&mut self, log: &mut Vec<ExecutorEvent>) {
        while let Ok(event) = self.seen.try_recv() {
            log.push(event);
        }
    }
}

fn assessed(event: &ExecutorEvent) -> Option<&FrameAssessed> {
    match event {
        ExecutorEvent::FrameWatch(e) => match e.as_ref() {
            FrameWatchEvent::FrameAssessed(a) => Some(a),
            _ => None,
        },
        _ => None,
    }
}

fn obstruction(event: &ExecutorEvent) -> Option<&HorizonObstructionReport> {
    match event {
        ExecutorEvent::FrameWatch(e) => match e.as_ref() {
            FrameWatchEvent::HorizonObstruction(h) => Some(h),
            _ => None,
        },
        _ => None,
    }
}

fn fired(log: &[ExecutorEvent], id: &str) -> usize {
    log.iter()
        .filter(|e| matches!(e, ExecutorEvent::TriggerFired { trigger_id, .. } if trigger_id == id))
        .count()
}

fn warnings(log: &[ExecutorEvent]) -> Vec<&str> {
    log.iter()
        .filter_map(|e| match e {
            ExecutorEvent::Warning { message } => Some(message.as_str()),
            _ => None,
        })
        .collect()
}

#[tokio::test(start_paused = true)]
async fn the_night_replayed_recenters_after_the_flip_and_ends_at_the_trees() {
    // Keep the original night's threshold for this historical replay.
    let mut legacy_plan = plan();
    legacy_plan.metadata.insert(
        "frame_watch".into(),
        r#"{"drift_limit_fraction":0.10}"#.into(),
    );
    let mut h = Harness::with_plan_and_rows(legacy_plan, rows()).await;
    let mut log = Vec::new();
    let mut ended = None;
    let mut drift_fired_after = None;
    let mut hold_seen_at = None;
    for row in rows().iter().filter(|r| (620..=720).contains(&r.id)) {
        // The frame's own exposure and download.
        tokio::time::sleep(std::time::Duration::from_secs_f64(row.exposure_secs + 8.0)).await;
        h.save(row).await;
        let before = fired(&log, TARGET_DRIFT_TRIGGER_ID);
        if let Some(end) = h
            .tick_until_reported(&format!("row-{}.fits", row.id), &mut log)
            .await
        {
            ended = Some((row.id, end));
            break;
        }
        if drift_fired_after.is_none() && fired(&log, TARGET_DRIFT_TRIGGER_ID) > before {
            drift_fired_after = Some(row.id);
        }
        if hold_seen_at.is_none()
            && h.dispatcher
                .rig
                .trigger_state
                .read()
                .await
                .autofocus_hold
                .is_some()
        {
            hold_seen_at = Some(row.id);
        }
    }

    // Every frame is recorded with its solve; pre-flip frames sit on target.
    let records: Vec<&FrameAssessed> = log.iter().filter_map(assessed).collect();
    let record = |id: u32| {
        records
            .iter()
            .find(|a| a.save_path == format!("row-{id}.fits"))
            .copied()
            .unwrap()
    };
    assert!(record(630).plate_solved && !record(630).off_target);
    assert!(record(630).offset_arcmin.unwrap() < 1.5);
    assert!((record(630).altitude_deg.unwrap() - 79.27).abs() < 0.01);
    assert!(!record(640).plate_solved && record(640).solve_attempted);

    // The first solved frame after the flip asks for one recenter, which the
    // simulator rig runs before the next frame.
    assert_eq!(drift_fired_after, Some(641));
    assert!(record(641).off_target);
    assert!(record(641)
        .exclusion_reason
        .as_deref()
        .unwrap()
        .starts_with("Off target: center 31.6 arcmin"));
    assert!(h.ops.calls().iter().any(|c| c.starts_with("plate_solve")));
    assert!(warnings(&log)
        .iter()
        .any(|w| w.contains("31.6 arcmin from the target (limit 4.6 arcmin)")));
    // On the night the mount never came back, so recenters stop after three.
    assert_eq!(
        fired(&log, TARGET_DRIFT_TRIGGER_ID),
        3,
        "{:?}",
        warnings(&log)
    );
    assert!(warnings(&log)
        .iter()
        .any(|w| w.contains("No more recenters are tried")));

    // The trees: noticed at their altitude and azimuth, probed, confirmed.
    let w = warnings(&log);
    let notice = w
        .iter()
        .position(|w| w.starts_with("Possible obstruction or cloud at alt 64.8°, az 286.2°"))
        .expect("possible-obstruction notice");
    assert!(!w[notice].contains("likely cloud"));
    assert!(w
        .iter()
        .any(|w| w.starts_with("Checking the sky higher up")));
    // The first confirmation (row 691) would end the night, so it is checked
    // once more before anything ends or is saved to the horizon.
    let deferred = w
        .iter()
        .position(|w| {
            w.starts_with("Possible obstruction: NGC0891 looks blocked from alt 65.2°, az 286.2°")
        })
        .unwrap_or_else(|| panic!("no deferral notice: {w:?}"));
    let report = log
        .iter()
        .find_map(obstruction)
        .unwrap_or_else(|| panic!("no obstruction report: {:?}", warnings(&log)));
    assert!(
        w.iter()
            .position(|x| x.starts_with("Obstruction:"))
            .unwrap()
            > deferred,
        "{w:?}"
    );
    assert!(report.altitude_deg < 65.15, "{report:?}");
    assert!((report.azimuth_deg - 286.5).abs() < 2.0, "{report:?}");
    assert_eq!(report.action, "end_of_night");
    assert_eq!(report.latitude, Some(SITE_LAT));
    // Single-target plan: on the second confirmation the night ends through
    // the end-of-night trigger, and that run of frames is marked obstructed.
    let (ended_at, end) = ended.expect("the run ended");
    assert!(ended_at > 693, "ended at {ended_at}");
    assert!(end.iter().any(|(id, action)| id == OBSTRUCTION_TRIGGER_ID
        && matches!(action, RecoveryAction::ParkAndAbort)));
    assert!(
        log.iter()
            .filter_map(assessed)
            .any(|a| a.save_path == format!("row-{ended_at}.fits") && a.obstructed),
        "row {ended_at}"
    );
    // Autofocus was held once the frames went bad.
    assert!(hold_seen_at.is_some());
}

#[tokio::test(start_paused = true)]
async fn autofocus_is_held_on_trailed_and_starless_frames_and_runs_once_they_recover() {
    let mut h = Harness::new().await;
    let mut log = Vec::new();
    // An interval autofocus is due on every frame.
    {
        let mut manager = h.dispatcher.trigger_manager.write().await;
        manager.add_trigger(
            crate::triggers::Trigger::new(
                "autofocus_interval",
                "Autofocus Interval",
                crate::TriggerType::AutofocusInterval { every_n_frames: 1 },
                RecoveryAction::Autofocus,
            )
            .with_cooldown(0),
        );
        let state = manager.state();
        state.write().await.increment_exposure_count();
    }
    let all = rows();
    let row = |id: u32| all.iter().find(|r| r.id == id).unwrap().clone();
    let due = |h: &Harness| {
        let manager = h.dispatcher.trigger_manager.clone();
        async move {
            let mut manager = manager.write().await;
            manager
                .check_all()
                .await
                .iter()
                .any(|f| f.trigger_id() == "autofocus_interval")
        }
    };

    // R_0079 (row 594) was rejected at eccentricity 0.85: trailed.
    h.save(&row(594)).await;
    h.tick_until_reported("row-594.fits", &mut log).await;
    assert!(!due(&h).await, "autofocus waits on trailed stars");
    let _ = h.stage.tick(&mut h.dispatcher, RunMode::Running).await;
    h.drain(&mut log);
    assert!(
        warnings(&log)
            .iter()
            .any(|w| w
                .starts_with("Autofocus is due but waits: the last frame's stars were trailed")),
        "{:?}",
        warnings(&log)
    );

    // A clean frame on target releases it.
    h.save(&row(596)).await;
    h.tick_until_reported("row-596.fits", &mut log).await;
    assert!(due(&h).await, "autofocus runs once frames recover");
    assert!(warnings(&log)
        .iter()
        .any(|w| w.starts_with("Frames have recovered; the autofocus that was waiting runs now")));
}

/// The rig at 08:55 on 2026-10-26: NGC 891's last frame (one star, behind the
/// trees) was reported after the run had moved on to M67. Judged as an M67
/// frame it had no baseline, so it read as clean, released the autofocus hold
/// and a focus sweep ran on a starless sky. A frame is judged against the
/// target it was taken on, and a frame with too few stars to measure holds
/// autofocus whatever the baseline.
#[tokio::test(start_paused = true)]
async fn the_last_frame_of_a_target_holds_autofocus_after_the_run_moves_on() {
    let mut h = Harness::new().await;
    h.target_id = Some("ngc891".to_string());
    let mut log = Vec::new();
    let all = rows();
    let row = |id: u32| all.iter().find(|r| r.id == id).unwrap().clone();
    for id in 620..=630 {
        h.save(&row(id)).await;
        h.tick_until_reported(&format!("row-{id}.fits"), &mut log)
            .await;
    }
    assert!(h
        .dispatcher
        .rig
        .trigger_state
        .read()
        .await
        .autofocus_hold
        .is_none());

    // The run moves on to M67 before NGC 891's last frame is reported.
    {
        let mut state = h.dispatcher.rig.trigger_state.write().await;
        state.set_target(8.8567 * 15.0, 11.8);
        state.current_target_name = Some("M67".to_string());
    }
    let mut last = row(706);
    assert_eq!(last.stars, Some(1));
    last.filter = "G".to_string();
    h.save(&last).await;
    h.tick_until_reported("row-706.fits", &mut log).await;

    let hold = h
        .dispatcher
        .rig
        .trigger_state
        .read()
        .await
        .autofocus_hold
        .clone();
    assert_eq!(
        hold.as_deref(),
        Some("the last frame lost most of its stars")
    );
}

#[tokio::test(start_paused = true)]
async fn two_arcminutes_of_drift_runs_centering_with_the_default_limit() {
    let mut row = rows().remove(0);
    row.solve = crate::frame_watch::SolveOutcome::Solved {
        ra_deg: TARGET_RA_DEG,
        dec_deg: TARGET_DEC_DEG + 2.0 / 60.0,
        pixel_scale_arcsec: 0.79,
        rotation_deg: 0.0,
    };
    let mut h = Harness::with_plan_and_rows(plan(), vec![row.clone()]).await;
    let mut log = Vec::new();
    h.save(&row).await;
    assert!(h
        .tick_until_reported(&format!("row-{}.fits", row.id), &mut log)
        .await
        .is_none());
    let frame = log.iter().find_map(assessed).expect("saved frame assessed");
    assert!(frame.off_target);
    assert_eq!(fired(&log, TARGET_DRIFT_TRIGGER_ID), 1);
    assert!(
        h.ops.calls().iter().any(|c| c.starts_with("plate_solve")),
        "centering must run, not merely emit a trigger"
    );
    assert!(warnings(&log)
        .iter()
        .any(|w| w.contains("2.0 arcmin from the target (limit 1.0 arcmin)")));
}
