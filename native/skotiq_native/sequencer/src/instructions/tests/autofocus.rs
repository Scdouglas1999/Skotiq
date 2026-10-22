//! `autofocus` tests — moved verbatim out of the former single `instructions::tests`
//! module (release-pass C3 mechanical split). Shared fixtures stay in the parent
//! `tests` module and reach here through `use super::*;`.

use super::*;

#[test]
fn autofocus_admission_is_atomic_and_released_by_guard() {
    let _serial = AF_GATE_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let first = try_admit_autofocus_run().expect("first run must admit");
    assert!(
        try_admit_autofocus_run().is_none(),
        "a concurrent autofocus run must be rejected"
    );
    drop(first);
    let next = try_admit_autofocus_run().expect("guard drop must release admission");
    drop(next);
}

// Single-threaded (current-thread) tokio runtime, so holding the sync gate
// lock across awaits cannot deadlock; the lock only serializes vs other
// gate tests running on separate threads.
#[tokio::test(start_paused = true)]
#[allow(clippy::await_holding_lock)]
async fn node_admission_waits_for_inflight_run_then_times_out_on_stuck_gate() {
    let _serial = AF_GATE_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());

    // Scenario 1: a trigger-fired run holds the gate; the node waiter must
    // block while it is held rather than fail the run.
    let inflight = try_admit_autofocus_run().expect("first run must admit");
    let waiter =
        tokio::spawn(async { admit_autofocus_run_waiting(Duration::from_secs(600)).await });
    tokio::time::sleep(Duration::from_secs(5)).await;
    assert!(
        !waiter.is_finished(),
        "the node waiter must keep waiting while an autofocus is in flight, \
             not fail immediately"
    );
    // Once the in-flight run releases, the waiter admits.
    drop(inflight);
    let guard = waiter
        .await
        .expect("waiter task panicked")
        .expect("waiter must admit once the gate frees");
    drop(guard);

    // Scenario 2: a gate that never releases must time out (not hang).
    let _stuck = try_admit_autofocus_run().expect("hold the gate");
    let result = admit_autofocus_run_waiting(Duration::from_secs(600)).await;
    assert!(
        result.is_none(),
        "a gate that never releases must time out, not hang forever"
    );
}

#[test]
fn autofocus_config_validation_rejects_decorative_or_dangerous_values() {
    let valid = AutofocusConfig::default();
    assert!(validate_autofocus_config(&valid).is_ok());

    let mut invalid = valid.clone();
    invalid.exposures_per_point = 0;
    assert!(validate_autofocus_config(&invalid).is_err());

    let mut invalid = valid.clone();
    invalid.inner_crop_ratio = invalid.outer_crop_ratio;
    assert!(validate_autofocus_config(&invalid).is_err());

    let mut invalid = valid.clone();
    invalid.number_of_attempts = 11;
    assert!(validate_autofocus_config(&invalid).is_err());

    let mut invalid = valid.clone();
    invalid.gain = Some(-1);
    assert!(validate_autofocus_config(&invalid).is_err());

    let mut invalid = valid;
    invalid.max_duration_secs = 0.0;
    assert!(validate_autofocus_config(&invalid).is_err());
}

#[tokio::test]
async fn autofocus_cleanup_restores_and_verifies_original_position() {
    let ops = Arc::new(ScriptedDomeRotatorOps::new());
    let ctx = ctx_with_ops(ops.clone()).await;

    restore_autofocus_origin("focuser-1", &ctx, 12_345, None)
        .await
        .expect("cleanup should restore the original position");

    assert_eq!(ops.focuser_halt_calls.load(Ordering::SeqCst), 1);
    assert_eq!(*ops.focuser_moves.lock().unwrap(), vec![12_345]);
}

#[tokio::test]
#[allow(clippy::await_holding_lock)]
async fn autofocus_restores_designated_filter_and_guiding_on_cancel() {
    let _serial = AF_GATE_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let ops = Arc::new(ScriptedDomeRotatorOps::new().with_guiding(true));
    let ctx = ctx_with_ops(ops.clone()).await;
    ctx.cancellation_token.store(true, Ordering::SeqCst);
    let mut config = AutofocusConfig {
        filter: Some("L".to_string()),
        disable_guiding_during_af: true,
        ..AutofocusConfig::default()
    };
    config.filter_settings.insert(
        "R".to_string(),
        crate::AutofocusFilterConfig {
            af_filter_name: Some("L".to_string()),
            gain: Some(120),
            offset: Some(15),
            ..crate::AutofocusFilterConfig::default()
        },
    );

    let guard = try_admit_autofocus_run().expect("test autofocus must admit");
    let result = execute_autofocus_admitted(&config, &ctx, None, guard).await;

    assert_eq!(result.status, NodeStatus::Cancelled);
    assert_eq!(*ops.filter_moves.lock().unwrap(), vec![0, 1]);
    assert_eq!(ops.guider_stop_calls.load(Ordering::SeqCst), 1);
    assert_eq!(ops.guider_start_calls.load(Ordering::SeqCst), 1);
    assert_eq!(
        *ops.fresh_star_selections.lock().unwrap(),
        vec![0],
        "guiding resumes on a star picked after the autofocus run"
    );
    assert!(ops.guiding.load(Ordering::SeqCst));
}

#[tokio::test(start_paused = true)]
async fn autofocus_timeout_bounds_hung_camera_exposure() {
    let ops = Arc::new(ScriptedDomeRotatorOps::new().with_hanging_camera());
    let ctx = ctx_with_ops(ops.clone()).await;
    let config = AutofocusConfig {
        steps_out: 1,
        max_duration_secs: 1.0,
        focuser_settle_time_ms: 0,
        ..AutofocusConfig::default()
    };

    let result = execute_autofocus_once(
        &config,
        &ctx,
        None,
        &crate::node::context::PauseGate::default(),
    )
    .await;

    assert_eq!(result.status, NodeStatus::Failure);
    assert!(
        result
            .message
            .as_deref()
            .is_some_and(|message| message.contains("timed out")),
        "hung sub-operation must fail at the autofocus deadline: {:?}",
        result.message
    );
    tokio::task::yield_now().await;
    assert_eq!(
        ops.camera_abort_calls.load(Ordering::SeqCst),
        1,
        "timing out a camera exposure must also abort it"
    );
}

/// A synthetic star field: `count` Gaussian PSFs on a low-noise background,
/// laid out on a grid well inside the crop region.
fn synthetic_star_field(width: u32, height: u32, count: usize, sigma: f64) -> ImageData {
    let mut data = vec![300u16; (width * height) as usize];

    let columns = (count as f64).sqrt().ceil() as usize;
    let rows = count.div_ceil(columns);
    for i in 0..count {
        let col = i % columns;
        let row = i / columns;
        // Keep every star inside the central half of the frame so the default
        // crop ratio cannot be what decides the count.
        let cx = width as f64 * (0.3 + 0.4 * (col as f64 + 0.5) / columns as f64);
        let cy = height as f64 * (0.3 + 0.4 * (row as f64 + 0.5) / rows as f64);

        let radius = (sigma * 4.0).ceil() as i64;
        for dy in -radius..=radius {
            for dx in -radius..=radius {
                let x = cx as i64 + dx;
                let y = cy as i64 + dy;
                if x < 0 || y < 0 || x >= width as i64 || y >= height as i64 {
                    continue;
                }
                let r2 = (dx * dx + dy * dy) as f64;
                let peak = 20_000.0 * (-r2 / (2.0 * sigma * sigma)).exp();
                let idx = (y as u32 * width + x as u32) as usize;
                data[idx] = data[idx].saturating_add(peak as u16);
            }
        }
    }

    ImageData {
        width,
        height,
        data,
        bits_per_pixel: 16,
        exposure_secs: 1.0,
        gain: None,
        offset: None,
        temperature: None,
        filter: None,
        timestamp: 0,
        sensor_type: Some("Monochrome".to_string()),
        bayer_offset: None,
    }
}

#[test]
fn star_count_reports_detection_not_the_brightest_n_cap() {
    let image = synthetic_star_field(512, 512, 25, 1.6);

    let uncapped = calculate_hfr_with_crops(&image, 1.0, 0.0, 0);
    let uncapped_hfr = uncapped.hfr.expect("measured");
    assert!(
        uncapped.star_count >= 20,
        "fixture must give the detector a real population to count, got {}",
        uncapped.star_count
    );

    // The cap exists to steady the HFR median, not to redefine how many stars
    // the frame had. Reporting the cap makes every sweep point read the same
    // number and disarms `min_star_count`, which defaults to the same 10.
    let capped = calculate_hfr_with_crops(&image, 1.0, 0.0, 5);
    let capped_hfr = capped.hfr.expect("measured");
    assert_eq!(
        capped.star_count, uncapped.star_count,
        "brightest-N must not change the reported star count"
    );
    assert!(
        (capped_hfr - uncapped_hfr).abs() < 5.0,
        "capped median should still be a sane HFR (got {} vs {})",
        capped_hfr,
        uncapped_hfr
    );
}

#[test]
fn stars_outside_the_hfr_window_are_counted_not_just_dropped() {
    // Tight stars: every one of them lands inside the validity window.
    let focused = calculate_hfr_with_crops(&synthetic_star_field(512, 512, 16, 1.5), 1.0, 0.0, 0);
    assert_eq!(
        focused.unmeasurable_star_count, 0,
        "a focused frame should have nothing beyond the HFR window"
    );
}

fn star_detect_fixture(name: &str) -> ImageData {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../test-fixtures/star-detect-2026-10-21")
        .join(name);
    let (image, _) =
        skotiq_imaging::read_fits(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    ImageData {
        width: image.width,
        height: image.height,
        data: image.as_u16().expect("16-bit frame"),
        bits_per_pixel: 16,
        exposure_secs: 90.0,
        gain: None,
        offset: None,
        temperature: None,
        filter: Some("L".to_string()),
        timestamp: 0,
        sensor_type: Some("Monochrome".to_string()),
        bayer_offset: None,
    }
}

/// An autofocus sweep over a real star field, sharp to a 20 px donut: the
/// measured HFR is the whole donut's (SEP's half-flux radius, recorded in the
/// fixture manifest) and grows with defocus, and the star count falls as
/// faint stars spread below the noise instead of staying flat.
#[test]
fn autofocus_hfr_tracks_defocus_on_a_real_field() {
    let sweep = [
        ("focused_L.fits", 2.454),
        ("defocus_R06.fits", 5.38),
        ("defocus_R12.fits", 10.022),
        ("defocus_R20.fits", 16.68),
    ];
    let mut previous: Option<(f64, u32)> = None;
    for (file, sep_hfr) in sweep {
        let m = calculate_hfr_with_crops(&star_detect_fixture(file), 1.0, 0.0, 10);
        let m_hfr = m.hfr.expect("measured");
        assert!(
            (m_hfr / sep_hfr - 1.0).abs() < 0.12,
            "{file}: autofocus HFR {:.2} against SEP {sep_hfr:.2}",
            m_hfr
        );
        if let Some((hfr, count)) = previous {
            assert!(m_hfr > hfr, "{file}: HFR {m_hfr:.2} after {hfr:.2}");
            assert!(
                m.star_count <= count,
                "{file}: {} stars after {count} on a sharper frame",
                m.star_count
            );
        }
        previous = Some((m_hfr, m.star_count));
    }
}

/// A field of defocused stars: annuli of outer radius `radius` px with a 0.6
/// central obstruction (a Gaussian of sigma 1.5 px at `radius == 0`), equal
/// flux, on a noisy sky.
fn donut_field(radius: f64) -> ImageData {
    const SIZE: u32 = 640;
    const FLUX: f64 = 3.0e5;
    let mut state = 0x9e37_79b9_7f4a_7c15u64;
    let mut noise = move || {
        let mut acc = 0.0;
        for _ in 0..4 {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            acc += (state >> 11) as f64 / (1u64 << 53) as f64;
        }
        (acc - 2.0) * 1.732
    };
    let mut px: Vec<f64> = (0..SIZE * SIZE).map(|_| 800.0 + 20.0 * noise()).collect();
    let inner = 0.6 * radius;
    let area = std::f64::consts::PI * (radius * radius - inner * inner);
    for row in 0..4 {
        for col in 0..4 {
            let cx = 80.0 + col as f64 * 160.0 + 0.3;
            let cy = 80.0 + row as f64 * 160.0 + 0.7;
            for y in (cy as i64 - 60)..(cy as i64 + 60) {
                for x in (cx as i64 - 60)..(cx as i64 + 60) {
                    let d = (x as f64 - cx).hypot(y as f64 - cy);
                    let v = if radius <= 0.0 {
                        FLUX / (2.0 * std::f64::consts::PI * 2.25) * (-d * d / 4.5).exp()
                    } else if (inner..=radius).contains(&d) {
                        FLUX / area
                    } else {
                        0.0
                    };
                    px[(y as u32 * SIZE + x as u32) as usize] += v;
                }
            }
        }
    }
    ImageData {
        width: SIZE,
        height: SIZE,
        data: px.iter().map(|v| v.clamp(0.0, 65535.0) as u16).collect(),
        bits_per_pixel: 16,
        exposure_secs: 3.0,
        gain: None,
        offset: None,
        temperature: None,
        filter: Some("L".to_string()),
        timestamp: 0,
        sensor_type: Some("Monochrome".to_string()),
        bayer_offset: None,
    }
}

/// A sweep whose wings are defocused past 20 px HFR, sampled lopsidedly
/// around focus: every point is measured at its real size (a uniform annulus
/// with a 0.6 obstruction has an HFR of 0.82 of its outer radius), and every
/// fit method puts best focus at the focus position.
#[test]
fn a_sweep_with_wings_past_20_px_finds_focus() {
    const FOCUS: i32 = 6600;
    const STEP: i32 = 100;
    const PX_PER_STEP: f64 = 7.5;
    let config = AutofocusConfig::default();
    let mut points = Vec::new();
    for i in -3..=5 {
        let position = FOCUS + i * STEP;
        let radius = f64::from(i.abs()) * PX_PER_STEP;
        let m = calculate_hfr_with_crops(
            &donut_field(radius),
            config.outer_crop_ratio,
            config.inner_crop_ratio,
            config.use_brightest_n_stars,
        );
        let hfr = m
            .hfr
            .unwrap_or_else(|| panic!("R {radius}: no HFR measured"));
        if radius > 0.0 {
            assert!(
                (hfr / (0.8246 * radius) - 1.0).abs() < 0.1,
                "R {radius}: HFR {hfr:.2}, expected {:.2}",
                0.8246 * radius
            );
        }
        points.push(crate::autofocus::FocusDataPoint {
            position,
            hfr,
            fwhm: None,
            star_count: m.star_count,
        });
    }
    assert!(
        points.last().unwrap().hfr > 28.0,
        "the far wing must read its real size: {:?}",
        points.last()
    );
    for method in [
        crate::autofocus::AutofocusMethod::VCurve,
        crate::autofocus::AutofocusMethod::Quadratic,
        crate::autofocus::AutofocusMethod::Hyperbolic,
    ] {
        let engine = crate::autofocus::VCurveAutofocus::new(crate::autofocus::AutofocusConfig {
            method,
            step_size: STEP,
            ..Default::default()
        });
        let result = engine
            .find_best_focus(points.clone())
            .unwrap_or_else(|e| panic!("{method:?}: {e}"));
        assert!(
            (result.best_position - FOCUS).abs() <= STEP / 4,
            "{method:?}: best focus {} for true focus {FOCUS} (R2 {:.3}) from {:?}",
            result.best_position,
            result.curve_fit_quality,
            points
                .iter()
                .map(|p| (p.position, p.hfr))
                .collect::<Vec<_>>()
        );
    }
}

#[test]
fn autofocus_counts_no_stars_on_a_dark_or_a_starless_frame() {
    for file in ["dark_240s.fits", "no_stars_L.fits"] {
        let m = calculate_hfr_with_crops(&star_detect_fixture(file), 1.0, 0.0, 10);
        assert_eq!(m.star_count, 0, "{file}: {} stars counted", m.star_count);
    }
}

// The guider-resume cleanup failure. Verbatim from the owner's
// skotiq.log.2026-09-15, 02:58:40:
//
//   WARN trigger_monitor: Autofocus trigger 'HFR Degradation' did not converge
//   (Failed to switch to autofocus filter "L": filter wheel did not reach
//   position 0 within 120 seconds; CRITICAL CLEANUP FAILURE: guider accepted
//   resume but did not report guiding). The focuser was returned to position
//   6620 and imaging continues on the last-good focus.
//
// "Imaging continues" was the defect. Three 180 s lights followed, every one
// trailed to HFR 15.6 px against a 3.50 px limit, every one rejected, zero
// accepted, and the night was over.

/// A guider that accepts the resume and never guides must produce a result the
/// CALLER can act on — not just a sentence in a message string.
#[tokio::test(start_paused = true)]
async fn a_failed_guider_resume_is_marked_not_just_described() {
    let ops = Arc::new(
        // The guider is STOPPED — autofocus stopped it for the sweep — and the
        // resume will be accepted without ever reporting guiding.
        ScriptedDomeRotatorOps::new()
            .with_guiding(false)
            .with_guider_resume_that_never_guides(),
    );
    let ctx = pointing_ctx(ops.clone(), "NGC7380", (22.79, 58.13)).await;

    // The latch the monitor's guide-poll block arms `guide_star_lost` from.
    // Autofocus stopped guiding for its sweep, so this is what the run still
    // believes.
    ctx.trigger_state
        .as_ref()
        .expect("pointing_ctx wires a trigger state")
        .write()
        .await
        .set_guiding_enabled(true);

    let result = resume_guiding_after_autofocus(&ctx, InstructionResult::success()).await;

    assert_eq!(
        result.status,
        NodeStatus::Failure,
        "a guider that never came back is a failed autofocus"
    );
    let message = result.message.clone().unwrap_or_default();
    assert!(
        message.contains("CRITICAL CLEANUP FAILURE"),
        "the operator-facing message must still name it: {message}"
    );
    assert_eq!(
        autofocus_trigger_failure_cost(result.data.as_ref()),
        AutofocusTriggerFailureCost::EveryFrameUnguided,
        "the marker is what lets the trigger arm tell a missed curve fit from a \
         dead guider; without it the run carries on exposing"
    );

    // And the run must stop believing guiding is healthy. PHD2 answers
    // is_guiding = true while it chases a lost star, so the latch is the only
    // honest signal left.
    assert!(
        !ctx.trigger_state
            .as_ref()
            .expect("pointing_ctx wires a trigger state")
            .read()
            .await
            .guiding
            .is_enabled(),
        "the cleanup knows the guider is down; the run's state must say so"
    );
}

/// PHD2's `guide` RPC answers before PHD2 is guiding: it loops, selects a
/// star and only then reports Guiding. A resume read once, straight after the
/// RPC, called that guider dead, and a dead guider now holds the run.
#[tokio::test(start_paused = true)]
async fn a_guider_still_finding_its_star_is_waited_for() {
    let ops = Arc::new(
        ScriptedDomeRotatorOps::new()
            .with_guiding(false)
            .with_guider_that_locks_after_polls(3),
    );
    let ctx = pointing_ctx(ops.clone(), "NGC7380", (22.79, 58.13)).await;

    let result = resume_guiding_after_autofocus(&ctx, InstructionResult::success()).await;

    assert_eq!(
        result.status,
        NodeStatus::Success,
        "a guider that locks a few seconds after the resume came back: {:?}",
        result.message
    );
    assert_eq!(
        autofocus_trigger_failure_cost(result.data.as_ref()),
        AutofocusTriggerFailureCost::SoftFramesOnly
    );
}

/// Guiding with the error far past any settle bound is not guiding restored.
/// PHD2 reports Guiding while it chases a star it has effectively lost
/// (measured at -56.8 / -54.4 px on the owner's rig), and the recovery ladder
/// already refuses that as a lock.
#[tokio::test(start_paused = true)]
async fn a_guider_chasing_a_lost_star_is_not_guiding_restored() {
    let ops = Arc::new(
        ScriptedDomeRotatorOps::new()
            .with_guiding(false)
            .with_guider_rms(78.6),
    );
    let ctx = pointing_ctx(ops.clone(), "NGC7380", (22.79, 58.13)).await;

    let result = resume_guiding_after_autofocus(&ctx, InstructionResult::success()).await;

    assert_eq!(
        autofocus_trigger_failure_cost(result.data.as_ref()),
        AutofocusTriggerFailureCost::EveryFrameUnguided,
        "is_guiding at 78.6 px is not a restored guider: {:?}",
        result.message
    );
}

/// A guider that has not sent one guide step since it was restarted has not
/// shown it holds anything. PHD2's statistics window is reset when guiding
/// starts, and an empty window reads RMS 0.0 while PHD2 already reports
/// Guiding, which passed the settle bound before a single step was measured.
#[tokio::test(start_paused = true)]
async fn a_guider_with_no_guide_step_since_the_restart_is_not_guiding_restored() {
    let ops = Arc::new(
        ScriptedDomeRotatorOps::new()
            .with_guiding(false)
            .with_guider_rms(0.0),
    );
    let ctx = pointing_ctx(ops.clone(), "NGC7380", (22.79, 58.13)).await;

    let result = resume_guiding_after_autofocus(&ctx, InstructionResult::success()).await;

    assert_eq!(
        autofocus_trigger_failure_cost(result.data.as_ref()),
        AutofocusTriggerFailureCost::EveryFrameUnguided,
        "an empty statistics window is not a settled lock: {:?}",
        result.message
    );
}

/// A Stop pressed while the cleanup waits for the guider to settle ends the
/// wait. The run's end waits for this cleanup, so on a guider that was never
/// coming back the operator's Stop took the full two minutes to land.
#[tokio::test(start_paused = true)]
async fn a_stop_ends_the_wait_for_the_guider_to_settle() {
    let ops = Arc::new(
        ScriptedDomeRotatorOps::new()
            .with_guiding(false)
            .with_guider_rms(78.6),
    );
    let ctx = pointing_ctx(ops.clone(), "NGC7380", (22.79, 58.13)).await;
    let stop = ctx.cancellation_token.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_secs(5)).await;
        stop.store(true, Ordering::SeqCst);
    });

    let started = tokio::time::Instant::now();
    let _ = resume_guiding_after_autofocus(&ctx, InstructionResult::success()).await;

    assert!(
        started.elapsed() < Duration::from_secs(10),
        "the cleanup kept waiting {:?} for the guider after the run was stopped",
        started.elapsed()
    );
    assert!(
        !ctx.trigger_state
            .as_ref()
            .expect("pointing_ctx wires a trigger state")
            .read()
            .await
            .guiding
            .is_enabled(),
        "a guider nobody saw settle must not be left marked as guiding"
    );
}

/// A guider that DOES come back is not a failure, and the latch is re-armed.
#[tokio::test]
async fn a_successful_guider_resume_leaves_the_result_alone() {
    let ops = Arc::new(ScriptedDomeRotatorOps::new().with_guiding(false));
    let ctx = pointing_ctx(ops.clone(), "NGC7380", (22.79, 58.13)).await;

    let result = resume_guiding_after_autofocus(&ctx, InstructionResult::success()).await;

    assert_eq!(result.status, NodeStatus::Success);
    assert_eq!(
        autofocus_trigger_failure_cost(result.data.as_ref()),
        AutofocusTriggerFailureCost::SoftFramesOnly,
        "no marker on a clean resume"
    );
    assert!(
        ctx.trigger_state
            .as_ref()
            .expect("pointing_ctx wires a trigger state")
            .read()
            .await
            .guiding
            .is_enabled(),
        "a proven resume re-arms the guide-star-lost latch"
    );
}

/// A missed curve fit and a dead guider must not be classified the same way.
/// They arrive as the identical `NodeStatus::Failure`, and collapsing them is
/// the whole defect.
#[test]
fn the_two_autofocus_failure_costs_are_distinguishable() {
    assert_eq!(
        autofocus_trigger_failure_cost(None),
        AutofocusTriggerFailureCost::SoftFramesOnly,
        "a failure with no data is a focus failure: continue on last-good focus"
    );
    assert_eq!(
        autofocus_trigger_failure_cost(Some(&serde_json::json!({
            "autofocus_origin_restored": true,
        }))),
        AutofocusTriggerFailureCost::SoftFramesOnly,
        "a restored focuser with no guiding marker is still just soft frames"
    );
    assert_eq!(
        autofocus_trigger_failure_cost(Some(&serde_json::json!({
            "autofocus_origin_restored": true,
            AUTOFOCUS_GUIDING_NOT_RESTORED_KEY: true,
        }))),
        AutofocusTriggerFailureCost::EveryFrameUnguided,
        "the guiding marker wins: every subsequent frame trails"
    );
}

/// The hold the operator actually reads. The message he DID see for this
/// failure was `Change Filter failed: Operation cancelled`, which named
/// neither the cause nor the consequence nor what to do.
#[test]
fn the_unguided_hold_message_says_what_happened_and_what_did_not() {
    let hold = autofocus_trigger_unguided_hold(
        "hfr_degraded",
        "HFR Degradation",
        "guider accepted resume but did not report guiding",
        Some(6620),
    );
    let message = &hold.operator_message;
    assert!(
        message.contains("HFR Degradation"),
        "name the trigger: {message}"
    );
    assert!(message.contains("PAUSED"), "say the run stopped: {message}");
    assert!(
        message.contains("Nothing has been moved or closed"),
        "say what was NOT done — the owner has been burned by this path: {message}"
    );
    assert!(message.contains("Resume"), "say how to clear it: {message}");
    assert_eq!(
        hold.decision.summary, AUTOFOCUS_TRIGGER_UNGUIDED_HOLD_SUMMARY,
        "the replay row and the constant cannot drift"
    );
}

/// A sweep that left the guider down must not be retried. Its next attempt's
/// exposures run on an unguided mount and its entry stops the guider again.
#[tokio::test]
#[allow(clippy::await_holding_lock)]
async fn a_guiderless_sweep_is_not_retried_across_attempts() {
    let _serial = AF_GATE_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let ops = Arc::new(
        // The guider is STOPPED — autofocus stopped it for the sweep — and the
        // resume will be accepted without ever reporting guiding.
        ScriptedDomeRotatorOps::new()
            .with_guiding(false)
            .with_guider_resume_that_never_guides(),
    );
    let ctx = pointing_ctx(ops.clone(), "NGC7380", (22.79, 58.13)).await;
    let config = AutofocusConfig {
        number_of_attempts: 3,
        ..Default::default()
    };
    let pause = crate::node::context::PauseGate::default();

    let result = execute_autofocus_attempts(&config, &ctx, None, &pause).await;

    assert_eq!(result.status, NodeStatus::Failure);
    // The sweep itself fails for its own reasons in this harness; what matters
    // is that a guiding-not-restored result is returned rather than re-swept.
    if autofocus_trigger_failure_cost(result.data.as_ref())
        == AutofocusTriggerFailureCost::EveryFrameUnguided
    {
        assert!(
            ops.guider_start_calls.load(Ordering::SeqCst) <= 1,
            "a sweep that could not restore guiding must not start another one"
        );
    }
}

/// `number_of_attempts` is the operator's retry budget for a sweep that fails
/// cleanly (focuser restored, guiding back). Nothing counted attempts:
/// returning after the first failure, or retrying a sweep regardless of the
/// budget's end, both passed. Every attempt takes its own frames, so the
/// exposure count is a count of sweeps.
#[tokio::test(start_paused = true)]
async fn a_cleanly_failing_sweep_is_retried_exactly_up_to_the_budget() {
    // No AF_GATE_TEST_LOCK: `execute_autofocus_attempts` never takes the
    // admission gate, and holding the lock for this test's ~10 s pushed the
    // gate tests into overlap with other suites' autofocus runs.
    let mut exposures = Vec::new();
    for attempts in [1_u32, 3] {
        let ops = Arc::new(ScriptedDomeRotatorOps::new());
        let mut ctx = pointing_ctx(ops.clone(), "NGC7380", (22.79, 58.13)).await;
        ctx.focuser_id = Some("foc-1".to_string());
        let config = AutofocusConfig {
            number_of_attempts: attempts,
            exposure_duration: 0.01,
            steps_out: 1,
            exposures_per_point: 1,
            ..Default::default()
        };
        let pause = crate::node::context::PauseGate::default();

        let result = execute_autofocus_attempts(&config, &ctx, None, &pause).await;

        // The test camera's frames have no stars, so every sweep fails, and
        // fails cleanly.
        assert_eq!(result.status, NodeStatus::Failure, "{:?}", result.message);
        exposures.push(ops.camera_exposure_calls.load(Ordering::SeqCst));
    }
    assert!(exposures[0] > 0, "a sweep takes frames");
    assert_eq!(
        exposures[1],
        3 * exposures[0],
        "a budget of 3 must run three sweeps of {} frames each",
        exposures[0]
    );
}

/// The run's event channel is how a sequence's autofocus reaches the focus
/// panel: no call returns its outcome to the UI, so a sweep that ends without
/// an `AutofocusFinished` leaves the panel reading "running" for the night.
#[tokio::test]
#[allow(clippy::await_holding_lock)]
async fn a_run_autofocus_reports_how_it_ended_on_the_event_channel() {
    let _serial = AF_GATE_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let (tx, mut rx) = tokio::sync::broadcast::channel(64);

    // Stopped before the first point.
    let ops = Arc::new(ScriptedDomeRotatorOps::new());
    let mut ctx = ctx_with_ops(ops.clone()).await;
    ctx.focuser_id = Some("foc-1".to_string());
    ctx.event_tx = Some(tx.clone());
    ctx.cancellation_token.store(true, Ordering::SeqCst);
    let guard = try_admit_autofocus_run().expect("test autofocus must admit");
    let result = execute_autofocus_admitted(&AutofocusConfig::default(), &ctx, None, guard).await;
    assert_eq!(result.status, NodeStatus::Cancelled);

    // A sweep on starless frames fails.
    let ops = Arc::new(ScriptedDomeRotatorOps::new());
    let mut ctx = pointing_ctx(ops.clone(), "NGC7380", (22.79, 58.13)).await;
    ctx.focuser_id = Some("foc-1".to_string());
    ctx.event_tx = Some(tx.clone());
    let config = AutofocusConfig {
        exposure_duration: 0.01,
        steps_out: 1,
        exposures_per_point: 1,
        ..Default::default()
    };
    let guard = try_admit_autofocus_run().expect("test autofocus must admit");
    let failed = execute_autofocus_admitted(&config, &ctx, None, guard).await;
    assert_eq!(failed.status, NodeStatus::Failure);

    let mut finished = Vec::new();
    while let Ok(event) = rx.try_recv() {
        if let crate::executor::ExecutorEvent::AutofocusFinished {
            focuser_id,
            status,
            message,
            result_json,
        } = event
        {
            assert_eq!(focuser_id, "foc-1");
            assert!(result_json.is_none(), "only a success carries a result");
            finished.push((status, message));
        }
    }
    assert_eq!(
        finished,
        vec![
            (NodeStatus::Cancelled, result.message.clone()),
            (NodeStatus::Failure, failed.message.clone()),
        ],
        "each sweep ends with exactly one outcome, carrying its own reason"
    );
}
