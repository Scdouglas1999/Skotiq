//! The defocus-dropout screen against real sweeps from the owner's rig.
//!
//! `rig_2026_11_07.csv` holds every complete sweep of that night: the 100-step
//! narrowband run whose outer points found donut specks and turned the curve
//! into a W, and the clean 60-step and 100-step runs the screen must leave
//! alone.

use crate::autofocus::{
    screen_defocus_dropouts, AutofocusConfig, AutofocusMethod, FocusDataPoint, VCurveAutofocus,
};

fn rig_run(name: &str) -> Vec<FocusDataPoint> {
    let points: Vec<FocusDataPoint> = include_str!("autofocus_fixtures/rig_2026_11_07.csv")
        .lines()
        .filter(|line| !line.starts_with('#') && !line.starts_with("run,"))
        .filter_map(|line| {
            let cells: Vec<&str> = line.split(',').collect();
            (cells[0] == name).then(|| FocusDataPoint {
                position: cells[1].parse().unwrap(),
                hfr: cells[2].parse().unwrap(),
                fwhm: None,
                star_count: cells[3].parse().unwrap(),
            })
        })
        .collect();
    assert!(!points.is_empty(), "no run {name} in the fixture");
    points
}

fn rejected_positions(points: &[FocusDataPoint]) -> Vec<i32> {
    let (_, rejected) = screen_defocus_dropouts(points);
    rejected.iter().map(|r| r.position).collect()
}

fn engine() -> VCurveAutofocus {
    VCurveAutofocus::new(AutofocusConfig {
        method: AutofocusMethod::Hyperbolic,
        ..Default::default()
    })
}

#[test]
fn the_narrowband_w_sweep_loses_exactly_its_donut_points() {
    let run = rig_run("r0_ha_100x7");
    assert_eq!(
        rejected_positions(&run),
        vec![44707, 44907, 45007, 45807, 45907, 46007, 46107]
    );

    let (kept, rejected) = screen_defocus_dropouts(&run);
    assert_eq!(
        kept.iter().map(|p| p.position).collect::<Vec<_>>(),
        vec![45107, 45207, 45307, 45407, 45507, 45607, 45707],
        "kept points come back in measured order"
    );
    for r in &rejected {
        assert!(!r.reason.is_empty());
        assert!(
            r.reason.len() < 120,
            "reason too long for the table: {}",
            r.reason
        );
    }

    // What is left is a V the fit describes far better than the W.
    let screened = engine().find_best_focus(kept).unwrap();
    let raw = engine().find_best_focus(run).unwrap();
    assert!(
        screened.curve_fit_quality > 0.9,
        "R² {}",
        screened.curve_fit_quality
    );
    assert!(screened.curve_fit_quality > raw.curve_fit_quality);
    assert!(
        (45380..=45500).contains(&screened.best_position),
        "best focus {}",
        screened.best_position
    );
}

#[test]
fn clean_rig_sweeps_keep_every_point_and_their_answer() {
    for name in ["r1_100x7", "r4_60x6", "r5_60x6", "r8_api_60x6"] {
        let run = rig_run(name);
        assert_eq!(rejected_positions(&run), Vec::<i32>::new(), "{name}");
        let (kept, _) = screen_defocus_dropouts(&run);
        let before = engine().find_best_focus(run).unwrap();
        let after = engine().find_best_focus(kept).unwrap();
        assert_eq!(before.best_position, after.best_position, "{name}");
    }
}

#[test]
fn a_last_point_that_reads_low_on_few_stars_is_left_out() {
    // 45757 read 17.19 from 24 stars, then 45817 read 5.98 from 13.
    assert_eq!(rejected_positions(&rig_run("r6_60x6")), vec![45817]);
}

#[test]
fn a_frame_that_lost_most_of_its_stars_near_focus_is_left_out() {
    // 45408 found 27 stars between points that found 140 and 210.
    assert_eq!(rejected_positions(&rig_run("r7_60x6")), vec![45408]);
}

/// A 60-step, 13-point sweep shaped like the owner's report: after 45716
/// read 19.57 from 32 stars, 45776 read 8.88 from 15.
#[test]
fn the_reported_point_after_a_wing_of_19_px_is_left_out() {
    let samples = [
        (45056, 17.9, 41),
        (45116, 15.1, 52),
        (45176, 12.2, 70),
        (45236, 9.4, 95),
        (45296, 6.6, 120),
        (45356, 4.1, 160),
        (45416, 2.4, 240),
        (45476, 3.9, 170),
        (45536, 6.9, 125),
        (45596, 10.1, 98),
        (45656, 14.8, 61),
        (45716, 19.57, 32),
        (45776, 8.88, 15),
    ];
    let run: Vec<FocusDataPoint> = samples
        .iter()
        .map(|&(position, hfr, star_count)| FocusDataPoint {
            position,
            hfr,
            fwhm: None,
            star_count,
        })
        .collect();
    assert_eq!(rejected_positions(&run), vec![45776]);
}

/// A dropout far out can read lower than true focus. It must not pose as
/// the point the screen trusts first.
#[test]
fn a_dropout_lower_than_focus_cannot_anchor_the_screen() {
    let samples = [
        (1000, 1.2, 4),
        (1100, 9.0, 60),
        (1200, 6.0, 90),
        (1300, 3.5, 120),
        (1400, 2.0, 150),
        (1500, 3.4, 118),
        (1600, 6.1, 88),
        (1700, 9.2, 62),
    ];
    let run: Vec<FocusDataPoint> = samples
        .iter()
        .map(|&(position, hfr, star_count)| FocusDataPoint {
            position,
            hfr,
            fwhm: None,
            star_count,
        })
        .collect();
    assert_eq!(rejected_positions(&run), vec![1000]);
}

/// The failure an earlier symmetric MAD clip had: a clean sweep lost its
/// focus region. Noisy clean sweeps of every rig shape keep every point.
#[test]
fn noisy_clean_sweeps_never_lose_a_point() {
    let mut state: u64 = 0x5EED_AF00_1108_0001;
    let mut uniform = move || {
        state = state
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        // Why: the top 53 bits map exactly into an f64 in [0, 1).
        (state >> 11) as f64 / (1u64 << 53) as f64
    };
    for name in ["r1_100x7", "r4_60x6", "r5_60x6", "r8_api_60x6"] {
        let clean = rig_run(name);
        for trial in 0..500 {
            let noisy: Vec<FocusDataPoint> = clean
                .iter()
                .map(|p| FocusDataPoint {
                    position: p.position,
                    hfr: p.hfr * (0.9 + 0.2 * uniform()),
                    fwhm: None,
                    // Why: counts are at most a few thousand; the product is
                    // positive and far inside u32.
                    star_count: ((f64::from(p.star_count) * (0.7 + 0.6 * uniform())) as u32).max(1),
                })
                .collect();
            assert_eq!(
                rejected_positions(&noisy),
                Vec::<i32>::new(),
                "{name} trial {trial}: {noisy:?}"
            );
        }
    }
}

/// When most of a sweep looks bad the sweep is bad, not a few frames: the
/// screen keeps everything and lets the fit and its checks decide.
#[test]
fn a_screen_that_would_leave_too_few_points_keeps_the_sweep() {
    let samples = [
        (1000, 3.0, 5),
        (1100, 3.5, 6),
        (1200, 9.0, 80),
        (1300, 2.0, 150),
        (1400, 9.0, 80),
        (1500, 3.0, 5),
        (1600, 2.8, 4),
    ];
    let run: Vec<FocusDataPoint> = samples
        .iter()
        .map(|&(position, hfr, star_count)| FocusDataPoint {
            position,
            hfr,
            fwhm: None,
            star_count,
        })
        .collect();
    let (kept, rejected) = screen_defocus_dropouts(&run);
    assert!(rejected.is_empty());
    assert_eq!(kept.len(), run.len());
}

#[test]
fn find_best_focus_reports_the_points_its_outlier_clip_removed() {
    let mut run = rig_run("r5_60x6");
    // A cloud over one wing frame.
    run[1].hfr = 60.0;
    let result = engine().find_best_focus(run).unwrap();
    assert_eq!(result.rejected_points.len(), 1);
    assert_eq!(result.rejected_points[0].position, 45106);
    assert!(result.data_points.iter().all(|p| p.position != 45106));
}
