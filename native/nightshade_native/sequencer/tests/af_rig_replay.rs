//! The 2026-09-09 rig sweep, replayed through the shipped fitter.
use nightshade_sequencer::autofocus::{
    AutofocusConfig, AutofocusMethod, FocusDataPoint, VCurveAutofocus,
};

fn pt(position: i32, hfr: f64) -> FocusDataPoint {
    FocusDataPoint {
        position,
        hfr,
        fwhm: None,
        star_count: 10,
    }
}

fn rig_sweep() -> Vec<FocusDataPoint> {
    vec![
        pt(2275, 7.69),
        pt(2350, 7.20),
        pt(2425, 4.47),
        pt(2500, 2.69),
        pt(2575, 5.70),
        pt(2650, 9.46),
        pt(2725, 14.14),
        pt(2800, 14.75),
        pt(2875, 14.43),
    ]
}

fn run(method: AutofocusMethod, points: Vec<FocusDataPoint>) -> (i32, f64) {
    let af = VCurveAutofocus::new(AutofocusConfig {
        method,
        step_size: 75,
        steps_out: 4,
        ..Default::default()
    });
    let r = af.find_best_focus(points).expect("fit");
    (r.best_position, r.curve_fit_quality)
}

#[test]
fn rig_sweep_lands_near_the_focus_the_operator_had_to_nudge_to() {
    // Ground truth, from the rig: the best sample was 2500 and a parabola
    // through its two neighbours puts the vertex at 2490. The operator landed
    // real focus at encoder 2441 — reached moving DOWN, so with that focuser's
    // ~50 steps of backlash the optics were at ~2490 in this sweep's
    // (approached-from-below) frame. The sweep chose 2471.
    for method in [
        AutofocusMethod::Hyperbolic,
        AutofocusMethod::VCurve,
        AutofocusMethod::Quadratic,
    ] {
        let (position, quality) = run(method, rig_sweep());
        println!("{:?} -> {} (R²={:.3})", method, position, quality);
        assert!(
            (2480..=2510).contains(&position),
            "{:?} put best focus at {}, outside the 2480-2510 the usable samples support",
            method,
            position
        );
        assert!(quality > 0.94, "{:?} fit quality {:.3}", method, quality);
    }
}

#[test]
fn a_clean_symmetric_sweep_is_left_alone() {
    // Nothing to narrow: a well-behaved V-curve must fit over every point it
    // sampled, or the rule is reshaping good data.
    let clean: Vec<_> = (-4..=4)
        .map(|k: i32| {
            let position = 5000 + k * 100;
            let hfr = 2.0 + 0.04 * (k * 100).abs() as f64;
            pt(position, hfr)
        })
        .collect();

    for method in [AutofocusMethod::VCurve, AutofocusMethod::Quadratic] {
        let (position, quality) = run(method, clean.clone());
        println!("clean {:?} -> {} (R²={:.3})", method, position, quality);
        assert!(
            (4980..=5020).contains(&position),
            "{:?} moved the vertex of a clean sweep to {}",
            method,
            position
        );
        assert!(quality > 0.9);
    }
}

/// The 2026-09-09 rig sweep that symmetric MAD clipping destroyed: all nine
/// points were sampled, the three nearest focus were cut, and autofocus
/// reported "best focus" at a wing with a best-HFR of 11.01 px.
fn clipped_rig_sweep() -> Vec<FocusDataPoint> {
    vec![
        pt(2201, 13.13),
        pt(2276, 12.62),
        pt(2351, 11.85),
        pt(2426, 5.94),
        pt(2501, 4.30),
        pt(2576, 4.66),
        pt(2651, 11.01),
        pt(2726, 12.88),
        pt(2801, 15.29),
    ]
}

#[test]
fn rejection_never_discards_the_focus_region() {
    for method in [
        AutofocusMethod::Hyperbolic,
        AutofocusMethod::VCurve,
        AutofocusMethod::Quadratic,
    ] {
        let af = VCurveAutofocus::new(AutofocusConfig {
            method,
            step_size: 75,
            steps_out: 4,
            ..Default::default()
        });
        let result = af.find_best_focus(clipped_rig_sweep()).expect("fit");

        // The minimum sample must survive rejection. Reporting a best-HFR of
        // 11.01 on a sweep that measured 4.30 is the shape of the bug.
        assert!(
            result.best_hfr < 5.0,
            "{:?} reported best HFR {:.2}; the sweep's own minimum was 4.30",
            method,
            result.best_hfr
        );
        assert!(
            (2450..=2560).contains(&result.best_position),
            "{:?} put focus at {}, away from the 2501 sample that measured 4.30",
            method,
            result.best_position
        );
    }
}

#[test]
fn a_genuine_high_outlier_is_still_rejected() {
    // One frame ruined by cloud in an otherwise clean sweep: it reads far
    // WORSE than its neighbours, and it must not drag the fit.
    let mut sweep: Vec<FocusDataPoint> = (-4..=4)
        .map(|k: i32| pt(5000 + k * 100, 2.0 + 0.05 * (k * 100).abs() as f64))
        .collect();
    sweep[6] = pt(5200, 40.0);

    let af = VCurveAutofocus::new(AutofocusConfig {
        method: AutofocusMethod::Quadratic,
        step_size: 100,
        steps_out: 4,
        ..Default::default()
    });
    let result = af.find_best_focus(sweep).expect("fit");
    assert!(
        !result.data_points.iter().any(|p| p.hfr > 30.0),
        "the cloud-ruined frame should have been rejected"
    );
    assert!(
        (4960..=5040).contains(&result.best_position),
        "focus moved to {} because of one bad frame",
        result.best_position
    );
}

/// The 2026-09-14 sweep, verbatim from the rig's log (23:54-23:56 UTC), every
/// point approached from below. Measured separately that night with the
/// app's own star crops: the from-below optimum was 6620 (HFR 2.99), with
/// 6520 and 6720 at 5.66 and 6.00.
fn rig_sweep_2026_09_14() -> Vec<FocusDataPoint> {
    vec![
        pt(6250, 14.50),
        pt(6325, 14.36),
        pt(6400, 11.86),
        pt(6475, 8.65),
        pt(6550, 5.27),
        pt(6625, 4.11),
        pt(6700, 5.71),
        pt(6775, 9.18),
        pt(6850, 13.50),
    ]
}

#[test]
fn the_2026_09_14_sweep_finds_the_from_below_optimum() {
    // The rig's own fit chose 6620 ("Final move 6850 -> 6620").
    for method in [AutofocusMethod::Hyperbolic, AutofocusMethod::Quadratic] {
        let (position, quality) = run(method, rig_sweep_2026_09_14());
        println!("{:?} -> {} (R²={:.3})", method, position, quality);
        assert!(
            (6600..=6640).contains(&position),
            "{:?} put best focus at {}; the from-below optimum measured on the rig is 6620",
            method,
            position
        );
        assert!(quality > 0.9, "{:?} fit quality {:.3}", method, quality);
    }
}
