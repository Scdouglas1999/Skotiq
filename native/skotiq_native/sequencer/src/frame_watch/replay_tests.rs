//! Replays of the rig night of 2026-10-23/24 (NGC 891, run 37, captured_images
//! rows 529-720), with each frame's measured HFR, star count, eccentricity,
//! pointing and the background plate solve the app logged for it.
//!
//! What happened that night, frame by frame: G_0089 (row 639) was exposing
//! when the mount stopped tracking and kept 868 stars against about 2,050 on
//! its neighbors; B_0086 (row 640), the first frame after the flip, trailed to
//! HFR 3.15 against about 2.0. After the flip every solved frame sat about
//! 31.6 arcmin from the target for two hours. From row 688 (alt 65.2, az 286)
//! the target set behind the trees east of the pier and the stars collapsed.

use super::fixture::{
    rows, rows_from, Row, FIELD_SHORT_SIDE_ARCMIN, TARGET_DEC_DEG, TARGET_RA_DEG,
};
use super::*;
use crate::quality::{
    filter_baseline_key, grade_frame_with_baselines, update_hfr_baseline, FilterBaseline,
    FrameMetrics, ImageQualityCheck, DEFAULT_STAR_COUNT_DROP_PERCENT,
};
use std::collections::{BTreeSet, HashMap};

/// The rig's grading settings that night (skotiq.log 2026-10-23 00:51:47):
/// HFR 3.5 px, HFR baseline +50%, eccentricity 0.8, at least 10 stars, which
/// arms the 50% star-count drop.
fn rig_check() -> ImageQualityCheck {
    ImageQualityCheck {
        hfr_threshold: Some(3.5),
        hfr_baseline_percent: Some(50.0),
        eccentricity_threshold: Some(0.8),
        star_count_min: Some(10),
        star_count_drop_percent: Some(DEFAULT_STAR_COUNT_DROP_PERCENT),
        max_consecutive_rejects: 3,
    }
}

/// Grade every row the way `expose.rs` does, returning (id, reject reason).
fn grade_night(rows: &[Row]) -> Vec<(u32, Option<String>)> {
    let check = rig_check();
    let mut baselines: HashMap<String, FilterBaseline> = HashMap::new();
    let (mut global_hfr, mut global_samples) = (None, Vec::new());
    rows.iter()
        .map(|row| {
            let key = filter_baseline_key(Some("NGC0891"), Some(&row.filter));
            let (filter_hfr, stars) = baselines
                .get(&key)
                .map(|b| (b.hfr(), b.star_count_at(Some(row.alt))))
                .unwrap_or((None, None));
            let metrics = FrameMetrics {
                hfr: row.hfr,
                eccentricity: row.ecc,
                star_count: row.stars,
                trail: None,
            };
            let grade =
                grade_frame_with_baselines(&check, &metrics, filter_hfr.or(global_hfr), stars);
            if grade.is_pass() {
                update_hfr_baseline(&mut global_hfr, &mut global_samples, row.hfr);
                baselines
                    .entry(key)
                    .or_default()
                    .record(row.stars, row.hfr, Some(row.alt));
            }
            (row.id, grade.reject_reason().map(str::to_string))
        })
        .collect()
}

#[test]
fn the_grader_rejects_the_untracked_and_trailed_frames_and_no_good_frame() {
    let rows = rows();
    assert_eq!(rows.len(), 192);
    let graded = grade_night(&rows);
    let reason = |id: u32| graded.iter().find(|(i, _)| *i == id).unwrap().1.clone();

    let row = |id: u32| rows.iter().find(|r| r.id == id).unwrap();
    assert!(
        row(639).db_accepted && row(640).db_accepted,
        "the night kept both"
    );
    let g_0089 = reason(639).expect("G_0089 is rejected");
    assert!(
        g_0089.starts_with("star count 868 is"),
        "G_0089 is judged against its neighbors, not the early 965: {g_0089}"
    );
    let b_0086 = reason(640).expect("B_0086 is rejected");
    assert!(
        b_0086.starts_with("HFR 3.15 px exceeds baseline"),
        "{b_0086}"
    );

    // Before the trees, the only other rejects are the frames the eccentricity
    // limit already rejected on the night.
    let eccentricity_rejects: BTreeSet<u32> = rows
        .iter()
        .filter(|r| r.id < 688 && r.db_reason.contains("eccentricity"))
        .map(|r| r.id)
        .collect();
    let new_rejects: BTreeSet<u32> = graded
        .iter()
        .filter(|(id, r)| *id < 688 && r.is_some())
        .map(|(id, _)| *id)
        .collect();
    let expected: BTreeSet<u32> = eccentricity_rejects
        .iter()
        .copied()
        .chain([639, 640])
        .collect();
    assert_eq!(new_rejects, expected);

    // The early low-altitude frames are not rejected against a baseline built
    // from them (G_0064, row 539, kept 687 stars at alt 42).
    assert!(reason(539).is_none());
    // The trees: from row 688 on every frame is rejected.
    for row in rows.iter().filter(|r| r.id >= 688) {
        assert!(reason(row.id).is_some(), "row {} passed", row.id);
    }
}

struct Replay {
    verdicts: Vec<(u32, FrameVerdict)>,
}

impl Replay {
    fn actions(&self) -> Vec<(u32, WatchAction)> {
        self.verdicts
            .iter()
            .flat_map(|(id, v)| v.actions.iter().cloned().map(move |a| (*id, a)))
            .collect()
    }

    fn verdict(&self, id: u32) -> &FrameVerdict {
        &self.verdicts.iter().find(|(i, _)| *i == id).unwrap().1
    }
}

/// Feed the night to a [`FrameWatch`]. A recenter is taken to finish one
/// minute after the frame that asked for it (on the night none ran, so the
/// mount stayed off target), and a probe higher in the sky finds stars when
/// `probe_finds_stars`.
fn replay(
    config: FrameWatchConfig,
    ids: std::ops::RangeInclusive<u32>,
    probe_finds_stars: bool,
) -> Replay {
    replay_rows(rows(), config, ids, probe_finds_stars)
}

fn replay_rows(
    rows: Vec<Row>,
    config: FrameWatchConfig,
    ids: std::ops::RangeInclusive<u32>,
    probe_finds_stars: bool,
) -> Replay {
    let graded = grade_night(&rows);
    let mut watch = FrameWatch::new(config);
    let mut verdicts = Vec::new();
    for row in rows.iter().filter(|r| ids.contains(&r.id)) {
        let reason = graded.iter().find(|(i, _)| *i == row.id).unwrap().1.clone();
        let obs = FrameObservation {
            save_path: format!("row-{}", row.id),
            target_name: Some("NGC0891".to_string()),
            filter: Some(row.filter.clone()),
            exposure_secs: row.exposure_secs,
            exposure_started_secs: row.captured_at - row.exposure_secs,
            accepted_by_grader: reason.is_none(),
            grader_reason: reason,
            star_count: row.stars,
            hfr: row.hfr,
            eccentricity: row.ecc,
            altitude_deg: Some(row.alt),
            azimuth_deg: Some(row.az),
            pier_side: Some(row.pier.clone()),
            solve: row.solve.clone(),
            target_ra_deg: Some(TARGET_RA_DEG),
            target_dec_deg: Some(TARGET_DEC_DEG),
            field_short_side_arcmin: Some(FIELD_SHORT_SIDE_ARCMIN),
            background_adu: None,
            guide_rms: None,
            guide_rms_samples: 0,
            guiding_lost: false,
            mount_not_tracking: false,
        };
        let mut verdict = watch.observe(&obs);
        let mut follow_ups = Vec::new();
        for action in &verdict.actions {
            match action {
                WatchAction::Recenter { .. } => watch.recentered(row.captured_at + 60.0),
                WatchAction::Probe { .. } => {
                    if let Some(found) = watch.probe_result(probe_finds_stars) {
                        follow_ups.push(found);
                    }
                }
                _ => {}
            }
        }
        verdict.actions.extend(follow_ups);
        verdicts.push((row.id, verdict));
    }
    Replay { verdicts }
}

#[test]
fn the_post_flip_offset_is_caught_on_the_first_solved_frame() {
    // Replay this historical night with its original field-relative threshold.
    let config = FrameWatchConfig {
        drift_limit_arcsec: None,
        ..Default::default()
    };
    let replay = replay(config, 529..=687, true);
    // Before the flip the solved centers sit within about 1 arcmin.
    for id in 529..=639 {
        let v = replay.verdict(id);
        assert!(!v.off_target, "row {id}: {:?}", v.offset_arcmin);
        assert!(
            v.offset_arcmin.unwrap() < 1.5,
            "row {id}: {:?}",
            v.offset_arcmin
        );
    }
    let recenters: Vec<u32> = replay
        .actions()
        .into_iter()
        .filter_map(|(id, a)| matches!(a, WatchAction::Recenter { .. }).then_some(id))
        .collect();
    assert_eq!(recenters.first(), Some(&641), "{recenters:?}");
    let first = replay.verdict(641);
    let offset = first.offset_arcmin.unwrap();
    assert!((offset - 31.6).abs() < 0.5, "{offset}");
    assert!((first.drift_limit_arcmin.unwrap() - 4.63).abs() < 0.05);
    assert!(first
        .exclusion_reason
        .as_deref()
        .unwrap()
        .starts_with(OFF_TARGET_PREFIX));
    // The frame after it was already exposing when the recenter ran: off
    // target, but it asks for nothing more.
    assert!(replay.verdict(642).off_target);
    assert!(!recenters.contains(&642));
    // Every solved post-flip frame is off target and none counts.
    for (id, v) in &replay.verdicts {
        if *id > 640 && v.offset_arcmin.is_some() {
            assert!(v.off_target && v.exclusion_reason.is_some(), "row {id}");
        }
    }
}

#[test]
fn the_trees_are_reported_at_their_altitude_and_azimuth_then_confirmed() {
    let replay = replay(FrameWatchConfig::default(), 529..=720, true);
    let obstruction_actions: Vec<(u32, WatchAction)> = replay
        .actions()
        .into_iter()
        .filter(|(_, a)| !matches!(a, WatchAction::Recenter { .. }))
        .collect();
    // Nothing on the good frames: G_0089's lone collapse is one frame.
    assert!(
        obstruction_actions.iter().all(|(id, _)| *id >= 688),
        "{obstruction_actions:?}"
    );
    let (told_at, told) = &obstruction_actions[0];
    assert_eq!(*told_at, 689);
    match told {
        WatchAction::PossibleObstructionOrCloud { at, frames } => {
            assert_eq!(*frames, 2);
            assert!((at.altitude_deg - 64.8).abs() < 0.1 && (at.azimuth_deg - 286.2).abs() < 0.2);
        }
        other => panic!("expected a possible-obstruction notice, got {other:?}"),
    }
    // Two failed solves (rows 690, 691) while the target sinks: probe at 691.
    let (probe_at, probe) = &obstruction_actions[1];
    assert_eq!(*probe_at, 691);
    let WatchAction::Probe { onset } = probe else {
        panic!("expected a probe, got {probe:?}");
    };
    assert!((onset.altitude_deg - 65.15).abs() < 0.05, "{onset:?}");
    assert!((onset.azimuth_deg - 286.22).abs() < 0.05, "{onset:?}");
    let (confirmed_at, confirmed) = &obstruction_actions[2];
    assert_eq!(*confirmed_at, 691);
    assert_eq!(
        confirmed,
        &WatchAction::Obstruction {
            onset: *onset,
            learned: false
        }
    );
    // Later collapsed frames count as obstructed and none as integration.
    for id in 692..=720 {
        let v = replay.verdict(id);
        if v.collapsed {
            assert!(v.obstructed, "row {id}");
            assert!(v
                .exclusion_reason
                .as_deref()
                .is_some_and(|r| r.starts_with(OBSTRUCTED_PREFIX)));
        }
    }
}

#[test]
fn a_learned_horizon_point_confirms_the_trees_on_the_second_frame_without_a_probe() {
    let config = FrameWatchConfig {
        learned_horizon: vec![HorizonPoint {
            azimuth_deg: 286.2,
            altitude_deg: 65.2,
        }],
        ..FrameWatchConfig::default()
    };
    let replay = replay(config, 600..=720, false);
    let actions: Vec<(u32, WatchAction)> = replay
        .actions()
        .into_iter()
        .filter(|(_, a)| !matches!(a, WatchAction::Recenter { .. }))
        .collect();
    assert!(matches!(
        actions.first(),
        Some((689, WatchAction::Obstruction { learned: true, .. }))
    ));
    assert!(!actions
        .iter()
        .any(|(_, a)| matches!(a, WatchAction::Probe { .. })));
}

#[test]
fn a_probe_that_finds_cloud_does_not_end_the_target_and_backs_off() {
    let replay = replay(FrameWatchConfig::default(), 529..=720, false);
    let actions = replay.actions();
    assert!(!actions
        .iter()
        .any(|(_, a)| matches!(a, WatchAction::Obstruction { .. })));
    let probes: Vec<u32> = actions
        .iter()
        .filter_map(|(id, a)| matches!(a, WatchAction::Probe { .. }).then_some(*id))
        .collect();
    assert_eq!(probes.first(), Some(&691));
    for pair in probes.windows(2) {
        assert!(pair[1] - pair[0] >= 8, "probes too close: {probes:?}");
    }
}

/// Clouds on a rising target: the stars collapse and come back. The operator
/// is told and then told the frames recovered; nothing is probed or ended.
#[test]
fn cloud_over_a_rising_target_is_reported_and_imaging_carries_on() {
    let mut watch = FrameWatch::new(FrameWatchConfig::default());
    let frame = |i: u32, stars: u32, solved: bool| FrameObservation {
        save_path: format!("f{i}"),
        target_name: Some("M 33".to_string()),
        filter: Some("L".to_string()),
        exposure_secs: 120.0,
        exposure_started_secs: f64::from(i) * 130.0,
        accepted_by_grader: stars > 1000,
        grader_reason: None,
        star_count: Some(stars),
        hfr: Some(2.0),
        eccentricity: Some(0.5),
        altitude_deg: Some(40.0 + f64::from(i) * 0.5),
        azimuth_deg: Some(110.0),
        pier_side: Some("West".to_string()),
        solve: if solved {
            SolveOutcome::Solved {
                ra_deg: 23.46,
                dec_deg: 30.66,
                pixel_scale_arcsec: 0.79,
                rotation_deg: 0.0,
            }
        } else {
            SolveOutcome::Failed
        },
        target_ra_deg: Some(23.46),
        target_dec_deg: Some(30.66),
        field_short_side_arcmin: Some(46.0),
        background_adu: None,
        guide_rms: None,
        guide_rms_samples: 0,
        guiding_lost: true,
        mount_not_tracking: false,
    };
    let mut actions = Vec::new();
    for i in 0..5 {
        actions.extend(watch.observe(&frame(i, 2000, true)).actions);
    }
    for i in 5..10 {
        let v = watch.observe(&frame(i, 300, false));
        assert!(v.collapsed && v.degraded.is_some() && !v.obstructed);
        assert_eq!(v.exclusion_reason, None, "cloud is graded, not excluded");
        actions.extend(v.actions);
    }
    // One clean frame could be a gap in the cloud; two in a row end the run.
    let first_clean = watch.observe(&frame(10, 2050, true));
    assert_eq!(first_clean.degraded, None);
    assert!(first_clean.actions.is_empty(), "{:?}", first_clean.actions);
    let recovered = watch.observe(&frame(11, 2040, true));
    actions.extend(recovered.actions);
    assert_eq!(actions.len(), 2, "{actions:?}");
    assert!(matches!(
        actions[0],
        WatchAction::PossibleObstructionOrCloud { frames: 2, .. }
    ));
    assert_eq!(actions[1], WatchAction::Recovered { frames: 5 });
}

fn watch_actions(replay: &Replay) -> Vec<(u32, WatchAction)> {
    replay
        .actions()
        .into_iter()
        .filter(|(_, a)| !matches!(a, WatchAction::Recenter { .. }))
        .collect()
}

/// 10-22: the target sank into the same trees. G_0035 (row 334) kept 0.64 of
/// its stars between frames that kept under half, and the operator was told
/// "Stars are back" while the target sank further in. A partly blocked frame
/// does not end the run of collapsed frames.
#[test]
fn a_partly_blocked_frame_does_not_report_the_stars_back() {
    let rows = rows_from(include_str!("fixtures/ngc891_2026_10_22_trees.csv"));
    let replay = replay_rows(rows, FrameWatchConfig::default(), 315..=335, true);
    let actions = watch_actions(&replay);
    assert!(
        !actions
            .iter()
            .any(|(_, a)| matches!(a, WatchAction::Recovered { .. })),
        "{actions:?}"
    );
    assert!(matches!(
        actions.first(),
        Some((
            333,
            WatchAction::PossibleObstructionOrCloud { frames: 2, .. }
        ))
    ));
    let partial = replay.verdict(334);
    assert!(!partial.collapsed, "{partial:?}");
    assert!(replay.verdict(335).collapsed);
}

/// 10-23: the mount stopped tracking at alt 83. B_0058 (row 525) lost half its
/// stars; the next three frames, 91 min later, were trails. That was reported
/// as "Possible obstruction or cloud" from "the last 2 frames". Frames an hour
/// apart are not one run, and trails are not an obstruction.
#[test]
fn trails_and_frames_an_hour_apart_are_not_an_obstruction() {
    let rows = rows_from(include_str!("fixtures/ngc891_2026_10_23_untracked.csv"));
    let replay = replay_rows(rows, FrameWatchConfig::default(), 505..=528, true);
    let actions = watch_actions(&replay);
    assert!(actions.is_empty(), "{actions:?}");
    assert!(replay.verdict(525).collapsed);
    for id in 526..=528 {
        let v = replay.verdict(id);
        assert!(v.trailed, "row {id}: {v:?}");
        assert_eq!(
            v.degraded.as_deref(),
            Some("the last frame lost most of its stars"),
            "row {id}: autofocus is held on it"
        );
    }
}

/// The same frames without the trails, an hour apart: the pause alone starts
/// a new run.
#[test]
fn a_long_pause_starts_a_new_run_of_collapsed_frames() {
    let mut watch = FrameWatch::new(FrameWatchConfig::default());
    let frame = |i: u32, start: f64, stars: u32| FrameObservation {
        save_path: format!("f{i}"),
        target_name: Some("NGC0891".to_string()),
        filter: Some("L".to_string()),
        exposure_secs: 120.0,
        exposure_started_secs: start,
        accepted_by_grader: stars > 1000,
        grader_reason: None,
        star_count: Some(stars),
        hfr: Some(2.0),
        eccentricity: Some(0.5),
        altitude_deg: Some(60.0),
        azimuth_deg: Some(280.0),
        pier_side: Some("East".to_string()),
        solve: SolveOutcome::NotAttempted,
        target_ra_deg: None,
        target_dec_deg: None,
        field_short_side_arcmin: None,
        background_adu: None,
        guide_rms: None,
        guide_rms_samples: 0,
        guiding_lost: false,
        mount_not_tracking: false,
    };
    for i in 0..5 {
        assert!(watch
            .observe(&frame(i, f64::from(i) * 130.0, 2000))
            .actions
            .is_empty());
    }
    assert!(watch.observe(&frame(5, 650.0, 400)).actions.is_empty());
    let later = watch.observe(&frame(6, 650.0 + 91.0 * 60.0, 400));
    assert!(later.actions.is_empty(), "{:?}", later.actions);
    let next = watch.observe(&frame(7, 650.0 + 93.0 * 60.0, 400));
    assert!(matches!(
        next.actions.as_slice(),
        [WatchAction::PossibleObstructionOrCloud { frames: 2, .. }]
    ));
}

/// The night ends on an obstruction only after a second confirmation: the
/// first probe that finds stars above starless frames, with nothing else in
/// the plan up, starts a new watch.
#[test]
fn an_obstruction_that_would_end_the_night_is_confirmed_twice() {
    let rows = rows();
    let graded = grade_night(&rows);
    let mut watch = FrameWatch::new(FrameWatchConfig::default());
    let mut confirmations = Vec::new();
    for row in rows.iter().filter(|r| r.id >= 529) {
        let reason = graded.iter().find(|(i, _)| *i == row.id).unwrap().1.clone();
        let obs = FrameObservation {
            save_path: format!("row-{}", row.id),
            target_name: Some("NGC0891".to_string()),
            filter: Some(row.filter.clone()),
            exposure_secs: row.exposure_secs,
            exposure_started_secs: row.captured_at - row.exposure_secs,
            accepted_by_grader: reason.is_none(),
            grader_reason: reason,
            star_count: row.stars,
            hfr: row.hfr,
            eccentricity: row.ecc,
            altitude_deg: Some(row.alt),
            azimuth_deg: Some(row.az),
            pier_side: Some(row.pier.clone()),
            solve: row.solve.clone(),
            target_ra_deg: None,
            target_dec_deg: None,
            field_short_side_arcmin: None,
            background_adu: None,
            guide_rms: None,
            guide_rms_samples: 0,
            guiding_lost: false,
            mount_not_tracking: false,
        };
        let verdict = watch.observe(&obs);
        for action in verdict.actions {
            if let WatchAction::Probe { .. } = action {
                if let Some(WatchAction::Obstruction { .. }) = watch.probe_result(true) {
                    confirmations.push((row.id, watch.confirm_before_ending()));
                }
            }
        }
    }
    assert_eq!(
        confirmations.first(),
        Some(&(691, false)),
        "{confirmations:?}"
    );
    let ends = confirmations.iter().find(|(_, end)| *end);
    assert!(
        ends.is_some_and(|(id, _)| *id > 693),
        "the second confirmation needs a new run of frames: {confirmations:?}"
    );
}

#[test]
fn two_arcminutes_of_drift_requests_a_recenter_with_default_settings() {
    let mut row = rows().remove(0);
    row.solve = SolveOutcome::Solved {
        ra_deg: TARGET_RA_DEG,
        dec_deg: TARGET_DEC_DEG + 2.0 / 60.0,
        pixel_scale_arcsec: 0.79,
        rotation_deg: 0.0,
    };
    let id = row.id;
    let replay = replay_rows(vec![row], FrameWatchConfig::default(), id..=id, true);
    assert!(
        replay.verdict(id).off_target,
        "two arcminutes must not pass the default drift limit"
    );
    assert!(matches!(
        replay.actions().as_slice(),
        [(_, WatchAction::Recenter { .. })]
    ));
}

#[test]
fn angular_limit_distinguishes_small_drift_and_respects_disable() {
    for (offset_arcsec, limit_arcsec, expected) in [
        (30.0, 60.0, false),
        (61.0, 60.0, true),
        (120.0, 180.0, false),
        (120.0, 0.0, false),
    ] {
        let mut row = rows().remove(0);
        row.solve = SolveOutcome::Solved {
            ra_deg: TARGET_RA_DEG,
            dec_deg: TARGET_DEC_DEG + offset_arcsec / 3600.0,
            pixel_scale_arcsec: 0.79,
            rotation_deg: 0.0,
        };
        let id = row.id;
        let config = FrameWatchConfig {
            drift_limit_arcsec: Some(limit_arcsec),
            ..Default::default()
        };
        let replay = replay_rows(vec![row], config, id..=id, true);
        assert_eq!(
            replay.verdict(id).off_target,
            expected,
            "offset {offset_arcsec}, limit {limit_arcsec}"
        );
        assert_eq!(
            replay
                .actions()
                .iter()
                .any(|(_, a)| matches!(a, WatchAction::Recenter { .. })),
            expected
        );
    }
}
