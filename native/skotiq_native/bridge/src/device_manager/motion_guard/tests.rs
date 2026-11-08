use super::detector::*;
use super::ledger::{CommandKind, CommandLedger};

const RUN: Context = Context {
    watch_position: true,
    home_dec_deg: 90.0,
};
const IDLE: Context = Context {
    watch_position: false,
    home_dec_deg: 90.0,
};

/// A tracking mount at a fixed RA/Dec.
fn at(t: f64, ra_hours: f64, dec_deg: f64) -> Sample {
    Sample {
        t,
        ra_hours,
        dec_deg,
        altitude_deg: Some(40.0),
        slewing: false,
        tracking: true,
        parked: false,
        at_home: Some(false),
    }
}

struct Rig {
    detector: Detector,
    ledger: CommandLedger,
    ctx: Context,
    fault_recorded: bool,
}

impl Rig {
    fn new(ctx: Context) -> Self {
        Self {
            detector: Detector::default(),
            ledger: CommandLedger::default(),
            ctx,
            fault_recorded: false,
        }
    }

    fn feed(&mut self, sample: Sample) -> Vec<Finding> {
        let findings =
            self.detector
                .observe(sample, &mut self.ledger, self.ctx, self.fault_recorded);
        if findings.iter().any(|f| matches!(f, Finding::Motion { .. })) {
            self.fault_recorded = true;
        }
        findings
    }

    fn feed_all(&mut self, samples: impl IntoIterator<Item = Sample>) -> Vec<Finding> {
        samples.into_iter().flat_map(|s| self.feed(s)).collect()
    }
}

fn motion_kinds(findings: &[Finding]) -> Vec<MotionKind> {
    findings
        .iter()
        .filter_map(|f| match f {
            Finding::Motion { kind, .. } => Some(*kind),
            _ => None,
        })
        .collect()
}

fn lost(findings: &[Finding]) -> Vec<LostReason> {
    findings
        .iter()
        .filter_map(|f| match f {
            Finding::PositionLost(reason) => Some(reason.clone()),
            _ => None,
        })
        .collect()
}

/// The NYX-101 signature: the Dec axis alone at 4.7 deg/s with nothing
/// commanded, read once a second during a run.
#[test]
fn a_dec_runaway_is_caught_within_three_readings() {
    let mut rig = Rig::new(RUN);
    let mut findings = rig.feed_all((0..10).map(|i| at(i as f64, 3.0, 40.0)));
    assert!(findings.is_empty(), "a tracking mount raised {findings:?}");
    for i in 0..3 {
        findings.extend(rig.feed(at(10.0 + i as f64, 3.0, 40.0 + 4.7 * (i + 1) as f64)));
    }
    let kinds = motion_kinds(&findings);
    assert_eq!(kinds, vec![MotionKind::Runaway], "{findings:?}");
    match &findings[0] {
        Finding::Motion {
            rate_deg_per_sec, ..
        } => assert!(
            (rate_deg_per_sec - 4.7).abs() < 0.1,
            "rate {rate_deg_per_sec}"
        ),
        other => panic!("{other:?}"),
    }
    assert!(rig.detector.fault_moving());
}

/// Idle readings come every five seconds; the run is still caught.
#[test]
fn a_runaway_is_caught_at_the_idle_cadence() {
    let mut rig = Rig::new(IDLE);
    rig.feed_all((0..4).map(|i| at(i as f64 * 5.0, 3.0, 10.0)));
    let findings =
        rig.feed_all((1..=2).map(|i| at(15.0 + i as f64 * 5.0, 3.0, 10.0 + 23.5 * i as f64)));
    assert_eq!(motion_kinds(&findings), vec![MotionKind::Runaway]);
}

/// The Dec reading sweeps through the pole: Dec turns back and RA jumps
/// 12 hours. The axis kept turning at the same speed.
#[test]
fn a_runaway_through_the_pole_reads_as_one_motion() {
    let mut rig = Rig::new(RUN);
    rig.feed_all([at(-1.0, 3.0, 88.0), at(0.0, 3.0, 88.0)]);
    let findings = rig.feed_all([at(1.0, 15.0, 87.3), at(2.0, 15.0, 82.6)]);
    assert_eq!(motion_kinds(&findings), vec![MotionKind::Runaway]);
}

#[test]
fn a_commanded_slew_is_not_a_fault() {
    let mut rig = Rig::new(RUN);
    rig.feed_all((0..3).map(|i| at(i as f64, 3.0, 10.0)));
    rig.ledger.record(3.0, CommandKind::Slew);
    let mut findings = Vec::new();
    for i in 0..10 {
        let mut s = at(4.0 + i as f64, 3.0, 10.0 + 5.0 * i as f64);
        s.slewing = true;
        findings.extend(rig.feed(s));
    }
    // Arrived and settled.
    findings.extend(rig.feed_all((0..8).map(|i| at(14.0 + i as f64, 3.0, 55.0))));
    assert!(findings.is_empty(), "a commanded slew raised {findings:?}");
    // The window closed: a runaway now is caught.
    let findings = rig.feed_all((1..=3).map(|i| at(22.0 + i as f64, 3.0, 55.0 + 4.7 * i as f64)));
    assert_eq!(motion_kinds(&findings), vec![MotionKind::Runaway]);
}

#[test]
fn a_single_bad_reading_is_not_a_fault() {
    let mut rig = Rig::new(RUN);
    rig.feed_all((0..5).map(|i| at(i as f64, 3.0, 40.0)));
    let findings = rig.feed_all([at(5.0, 9.0, -20.0), at(6.0, 3.0, 40.0), at(7.0, 3.0, 40.0)]);
    assert!(findings.is_empty(), "{findings:?}");
}

/// Guide pulses and dithers move arcseconds, and a mount that is not tracking
/// drifts in RA with the sky; neither is motion.
#[test]
fn guiding_dithers_and_an_untracked_mount_are_not_faults() {
    let mut rig = Rig::new(RUN);
    // Tracking, with 2.5 s guide pulses at 0.5x sidereal plus a dither.
    let findings = rig.feed_all((0..30).map(|i| {
        let wobble = if i % 7 == 0 { 0.003 } else { 0.0 };
        at(i as f64, 3.0 + wobble / 15.0, 40.0 + wobble)
    }));
    assert!(findings.is_empty(), "{findings:?}");
    // Not tracking: RA advances with sidereal time.
    let sidereal_h_per_s = 1.002_737_909_35 / 3600.0;
    let findings = rig.feed_all((0..30).map(|i| {
        let mut s = at(100.0 + i as f64, 3.0 + i as f64 * sidereal_h_per_s, 40.0);
        s.tracking = false;
        s
    }));
    assert!(findings.is_empty(), "{findings:?}");
}

#[test]
fn a_jog_with_move_axis_is_explained_until_it_stops() {
    let mut rig = Rig::new(RUN);
    rig.feed(at(0.0, 3.0, 40.0));
    rig.ledger
        .record(0.5, CommandKind::MoveAxis { axis: 1, rate: 1.0 });
    let findings = rig.feed_all((1..=5).map(|i| at(i as f64, 3.0, 40.0 + i as f64)));
    assert!(findings.is_empty(), "{findings:?}");
    rig.ledger
        .record(5.5, CommandKind::MoveAxis { axis: 1, rate: 0.0 });
    let findings = rig.feed_all((6..=12).map(|i| at(i as f64, 3.0, 45.5)));
    assert!(findings.is_empty(), "{findings:?}");
    let findings = rig.feed_all((13..=15).map(|i| at(i as f64, 3.0, 45.5 + 4.7 * (i - 12) as f64)));
    assert_eq!(motion_kinds(&findings), vec![MotionKind::Runaway]);
}

#[test]
fn slewing_with_no_slew_commanded_is_a_fault() {
    let mut rig = Rig::new(RUN);
    rig.feed_all((0..3).map(|i| at(i as f64, 3.0, 40.0)));
    let findings = rig.feed_all((3..7).map(|i| {
        let mut s = at(i as f64, 3.0, 40.0);
        s.slewing = true;
        s
    }));
    assert_eq!(motion_kinds(&findings), vec![MotionKind::Slewing]);
}

#[test]
fn a_fast_dive_below_the_horizon_is_a_fault() {
    let mut rig = Rig::new(RUN);
    let mut a = at(0.0, 3.0, 40.0);
    a.altitude_deg = Some(1.0);
    let mut b = at(5.0, 3.0, 40.3);
    b.altitude_deg = Some(-0.5);
    let mut c = at(10.0, 3.0, 40.6);
    c.altitude_deg = Some(-2.0);
    let findings = rig.feed_all([a, b, c]);
    assert_eq!(motion_kinds(&findings), vec![MotionKind::BelowHorizon]);
}

#[test]
fn a_target_setting_slowly_is_not_a_dive() {
    let mut rig = Rig::new(RUN);
    let findings = rig.feed_all((0..20).map(|i| {
        let mut s = at(i as f64, 3.0, 10.0);
        s.altitude_deg = Some(0.02 - 0.004 * i as f64);
        s
    }));
    assert!(findings.is_empty(), "{findings:?}");
}

#[test]
fn the_fault_ends_when_the_mount_reads_still() {
    let mut rig = Rig::new(RUN);
    rig.feed_all((0..3).map(|i| at(i as f64, 3.0, 10.0)));
    rig.feed_all((1..=3).map(|i| at(2.0 + i as f64, 3.0, 10.0 + 4.7 * i as f64)));
    assert!(rig.detector.fault_moving());
    let findings = rig.feed_all((0..8).map(|i| at(6.0 + i as f64, 3.0, 24.1 + 4.7)));
    assert!(findings.contains(&Finding::Stopped), "{findings:?}");
    assert!(!rig.detector.fault_moving());
}

/// 11-08: the mount ran, went silent for about 30 s, and came back reporting
/// home. During the fault every way back counts as a lost position.
#[test]
fn silence_during_a_runaway_then_an_answer_is_a_lost_position() {
    let mut rig = Rig::new(RUN);
    rig.feed_all((0..3).map(|i| at(i as f64, 3.0, 10.0)));
    rig.feed_all((1..=3).map(|i| at(2.0 + i as f64, 3.0, 10.0 + 4.7 * i as f64)));
    for i in 0..30 {
        rig.detector.observe_failure(6.0 + i as f64);
    }
    let mut home = at(36.0, 0.0, 90.0);
    home.at_home = Some(true);
    let findings = rig.feed(home);
    assert_eq!(
        lost(&findings),
        vec![LostReason::CameBackAfterFault { silent_secs: 30.0 }]
    );
}

#[test]
fn coming_back_at_home_after_silence_during_a_run_is_a_lost_position() {
    let mut rig = Rig::new(RUN);
    rig.feed_all((0..3).map(|i| at(i as f64, 3.0, 40.0)));
    for i in 0..15 {
        rig.detector.observe_failure(3.0 + i as f64);
    }
    let mut home = at(18.0, 0.0, 90.0);
    home.at_home = Some(true);
    assert_eq!(
        lost(&rig.feed(home)),
        vec![LostReason::CameBackAtHome { silent_secs: 15.0 }]
    );
}

#[test]
fn a_short_blip_is_not_a_lost_position() {
    let mut rig = Rig::new(RUN);
    rig.feed_all((0..3).map(|i| at(i as f64, 3.0, 40.0)));
    rig.detector.observe_failure(3.0);
    rig.detector.observe_failure(4.0);
    let findings = rig.feed(at(5.0, 3.0, 40.0));
    assert!(findings.is_empty(), "{findings:?}");
}

#[test]
fn at_home_with_no_home_command_during_a_run_is_a_lost_position() {
    let mut rig = Rig::new(RUN);
    rig.feed_all((0..3).map(|i| at(i as f64, 3.0, 40.0)));
    let mut home = at(3.0, 3.0, 40.0);
    home.at_home = Some(true);
    assert_eq!(
        lost(&rig.feed(home)),
        vec![LostReason::AtHomeWithoutCommand]
    );

    // A commanded home explains the same edge.
    let mut rig = Rig::new(RUN);
    rig.feed_all((0..3).map(|i| at(i as f64, 3.0, 40.0)));
    rig.ledger.record(3.0, CommandKind::FindHome);
    let mut s = at(4.0, 3.0, 40.0);
    s.at_home = Some(true);
    assert!(lost(&rig.feed(s)).is_empty());

    // So does an idle mount: homing it from Unity is the operator's business.
    let mut rig = Rig::new(IDLE);
    rig.feed_all((0..3).map(|i| at(i as f64, 3.0, 40.0)));
    let mut s = at(3.0, 3.0, 40.0);
    s.at_home = Some(true);
    assert!(lost(&rig.feed(s)).is_empty());
}

#[test]
fn a_snap_to_home_is_a_lost_position_and_a_sync_jump_is_not() {
    let mut rig = Rig::new(RUN);
    rig.feed_all((0..3).map(|i| at(i as f64, 3.0, 40.0)));
    let findings = rig.feed_all([at(3.0, 0.0, 90.0), at(4.0, 0.0, 90.0)]);
    assert_eq!(
        lost(&findings),
        vec![LostReason::JumpedToHome { degrees: 50.0 }]
    );
    assert!(motion_kinds(&findings).is_empty(), "{findings:?}");

    let mut rig = Rig::new(RUN);
    rig.feed_all((0..3).map(|i| at(i as f64, 3.0, 40.0)));
    rig.ledger.record(2.5, CommandKind::Sync);
    let findings = rig.feed_all([at(3.0, 4.0, 30.0), at(4.0, 4.0, 30.0)]);
    assert!(findings.is_empty(), "{findings:?}");
}

/// A runaway that ends in a snap to home (the controller restarted between
/// two readings) is a lost position too.
#[test]
fn a_runaway_that_ends_at_home_is_a_lost_position() {
    let mut rig = Rig::new(RUN);
    rig.feed_all((0..3).map(|i| at(i as f64, 3.0, 10.0)));
    rig.feed_all((1..=3).map(|i| at(2.0 + i as f64, 3.0, 10.0 + 4.7 * i as f64)));
    let mut home = at(6.0, 0.0, 90.0);
    home.at_home = Some(true);
    let mut home2 = home;
    home2.t = 7.0;
    let findings = rig.feed_all([home, home2]);
    let reasons = lost(&findings);
    assert!(
        reasons.contains(&LostReason::AtHomeWithoutCommand)
            && reasons
                .iter()
                .any(|r| matches!(r, LostReason::JumpedToHome { .. })),
        "{findings:?}"
    );
}

/// The live path through the device manager: the simulated NYX runaway is
/// detected, the stop commands are sent and recorded, slews are refused, the
/// restart that follows marks the position unknown, and the operator's
/// confirmation clears it.
#[tokio::test]
async fn the_simulated_runaway_is_caught_and_recovered_end_to_end() {
    use crate::api::devices::simulation::{get_sim_mount, sim_singleton_test_lock, SimulatedMount};
    use crate::api::get_device_manager;
    use crate::device::{DeviceInfo, DeviceType, DriverType};
    use crate::device_manager::ops::{sim_faults, sim_runaway};

    let _serialized = sim_singleton_test_lock().lock().await;
    super::reset_for_tests();
    super::set_config(super::GuardConfig::default());
    sim_faults::clear_all();
    sim_runaway::reset();
    let device_id = "sim_mount_runaway_guard";
    get_device_manager()
        .register_device(
            DeviceInfo {
                id: device_id.to_string(),
                name: "Simulated Mount".to_string(),
                device_type: DeviceType::Mount,
                driver_type: DriverType::Simulator,
                description: "Simulated mount".to_string(),
                driver_version: "1.0".to_string(),
                serial_number: None,
                unique_id: None,
                display_name: "Simulated Mount".to_string(),
            },
            false,
        )
        .await;
    crate::api::devices::simulation::cancel_sim_slew().await;
    {
        let mut mount = get_sim_mount().write().await;
        *mount = SimulatedMount::default();
        mount.status.connected = true;
        mount.status.parked = false;
        mount.status.tracking = true;
        mount.status.right_ascension = 3.0;
        mount.status.declination = 40.0;
    }
    // Idle, so the position rules only start once the fault is recorded.
    sim_faults::arm(
        "mount.runaway",
        sim_faults::FaultSpec::new(
            sim_faults::Trigger::Times(1),
            sim_faults::Effect::Runaway {
                deg_per_sec: 4.7,
                run_secs: 3.0,
                blackout_secs: 1.5,
                delay_secs: 0.6,
            },
        ),
    );
    let mgr = get_device_manager();
    let mut caught = false;
    for _ in 0..40 {
        let _ = mgr.mount_get_status(device_id).await;
        if super::block_reason(device_id).is_some() {
            caught = true;
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(400)).await;
    }
    assert!(caught, "the runaway was never flagged");
    let refused = mgr.mount_slew(device_id, 5.0, 20.0).await;
    assert!(
        refused.is_err(),
        "a slew was sent to a mount that is running away"
    );

    // Let the stop round run, the runaway finish, the blackout pass and the
    // mount come back at home.
    let mut lost_flagged = false;
    for _ in 0..40 {
        tokio::time::sleep(std::time::Duration::from_millis(400)).await;
        let _ = mgr.mount_get_status(device_id).await;
        if super::with_registry(|r| r.mounts.get(device_id).is_some_and(|e| e.lost.is_some())) {
            lost_flagged = true;
            break;
        }
    }
    let fault = super::with_registry(|r| r.mounts.get(device_id).and_then(|e| e.fault.clone()))
        .expect("the fault is kept for the operator");
    assert!(
        fault.stop_attempts.iter().any(|a| a.contains("Abort slew")),
        "no stop was attempted: {:?}",
        fault.stop_attempts
    );
    assert!(
        lost_flagged,
        "the restart at home did not mark the position unknown"
    );
    assert!(
        crate::api::sequencer::api_sequencer_resume().await.is_err(),
        "a run could be resumed while the mount's position is unknown"
    );

    super::response::confirm_rehomed(device_id).expect("the operator can confirm");
    assert!(super::block_reason(device_id).is_none());
    sim_faults::clear_all();
    sim_runaway::reset();
    super::reset_for_tests();
}
