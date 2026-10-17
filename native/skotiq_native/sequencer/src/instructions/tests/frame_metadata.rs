//! `frame_metadata` tests — moved verbatim out of the former single `instructions::tests`
//! module (release-pass C3 mechanical split). Shared fixtures stay in the parent
//! `tests` module and reach here through `use super::*;`.

use super::*;

/// The frame event that makes Dart write the `captured_images` row must
/// carry the same `FrameContext` the FITS writer stamped the header from.
/// An event carrying only node id, grading metrics and a save path lands the
/// row with NULL gain, offset, sensor temperature, cooler power, pointing,
/// pier side, focuser position and rotator angle while the file on disk has
/// every one of them.
#[tokio::test]
async fn frame_event_carries_the_fits_writers_own_capture_context() {
    let sun_alt = live_sun_alt();
    let ctx = expose_ctx(Arc::new(NullDeviceOps), None, sun_alt - 30.0).await;
    let (event_tx, mut event_rx) = tokio::sync::broadcast::channel(16);
    let ctx = InstructionContext {
        event_tx: Some(event_tx),
        ..ctx
    };

    let mut frame_ctx = crate::scheduling::FrameContext::new_light("sess-evt", 2, 2, 120.0, 7);
    frame_ctx.frame_type = "Dark".to_string();
    frame_ctx.target_id = Some("tgt-evt".to_string());
    frame_ctx.gain = Some(139);
    frame_ctx.offset = Some(21);
    frame_ctx.sensor_temp_c = Some(-9.5);
    frame_ctx.cooler_power_percent = Some(63.5);
    frame_ctx.mount_ra_hours = Some(5.5);
    frame_ctx.mount_dec_degrees = Some(-5.25);
    frame_ctx.mount_altitude_deg = Some(48.5);
    frame_ctx.mount_azimuth_deg = Some(171.25);
    frame_ctx.pier_side = Some("West".to_string());
    frame_ctx.focuser_position = Some(31_705);
    frame_ctx.focuser_temperature_c = Some(4.25);
    frame_ctx.rotator_angle_deg = Some(212.5);

    emit_grade_progress(
        &ctx,
        crate::quality::FrameGrade::Pass,
        &crate::quality::FrameMetrics::default(),
        false,
        7,
        10,
        std::path::Path::new("/captures/evt_0007.fits"),
        &frame_ctx,
        &Arc::new(AtomicU32::new(0)),
        &Arc::new(AtomicU32::new(0)),
        &Arc::new(AtomicU32::new(0)),
        u32::MAX,
    )
    .await;

    let mut emitted = None;
    while let Ok(event) = event_rx.try_recv() {
        if let crate::executor::ExecutorEvent::NodeProgress {
            structured_detail: Some(detail),
            ..
        } = event
        {
            if let crate::node::ProgressDetail::FrameAccepted { capture, .. } = *detail {
                emitted = Some(capture);
            }
        }
    }

    let emitted = emitted.expect("a saved frame must emit FrameAccepted");
    assert_eq!(
        emitted,
        crate::scheduling::FrameCaptureMetadata::from(&frame_ctx),
        "the row's payload and the header's source must be the same struct"
    );
}

/// A frame has to say which camera took it, even on a rig with no
/// equipment profile.
///
/// `INSTRUME` was built only from `ExecutionContext::camera_make/model`,
/// which come from the observer profile — a cross-product of app settings
/// and the ACTIVE EQUIPMENT PROFILE. A headless rig that never had a
/// profile created has neither, so every frame it wrote carried no
/// `INSTRUME` at all. Reproduced on the live rig: a real run wrote
/// `Polaris_1_0001.fits` with `PIXSIZE 2.4` as the only clue to which of
/// the two attached ZWO cameras took it, and reproduced again against the
/// Linux simulator build, whose frames were identically silent.
///
/// `expose_node_execution_ctx` sets no `camera_make`/`camera_model`, so
/// this is exactly that rig. The camera is connected and the driver knows
/// its name; the file must carry it.
#[tokio::test]
async fn frame_names_the_camera_when_no_equipment_profile_does() {
    let scratch = scratch_dir("instrume-fallback");
    let ops = Arc::new(ScriptedDomeRotatorOps::new());
    let mut ec = expose_node_execution_ctx(ops.clone(), scratch.0.clone()).await;
    assert!(
        ec.camera_make.is_none() && ec.camera_model.is_none(),
        "precondition: this rig has no equipment profile naming a camera"
    );

    let status = run_expose_node(one_dark_no_filter(), &mut ec).await;
    assert_eq!(status, NodeStatus::Success, "burst should complete");

    let saved = ops.saved_frame_contexts();
    assert_eq!(saved.len(), 1, "one frame should have reached the writer");
    assert_eq!(
        saved[0].camera_model.as_deref(),
        Some("ZWO ASI1600MM-Cool (1600-A1B2)"),
        "INSTRUME must fall back to the camera the driver reports"
    );
}

/// The operator's own answer outranks the driver's.
///
/// Guards the fallback against becoming an override: someone who has named
/// their camera in an equipment profile has said what they want in their
/// archive, and a generic driver string must not displace it.
#[tokio::test]
async fn equipment_profile_camera_name_beats_the_driver_string() {
    let scratch = scratch_dir("instrume-profile");
    let ops = Arc::new(ScriptedDomeRotatorOps::new());
    let mut ec = expose_node_execution_ctx(ops.clone(), scratch.0.clone()).await;
    ec.camera_make = Some("ZWO".to_string());
    ec.camera_model = Some("ASI178MM".to_string());

    let status = run_expose_node(one_dark_no_filter(), &mut ec).await;
    assert_eq!(status, NodeStatus::Success, "burst should complete");

    let saved = ops.saved_frame_contexts();
    assert_eq!(
        saved[0].camera_model.as_deref(),
        Some("ASI178MM"),
        "a profile-named camera must survive the driver fallback"
    );
    assert_eq!(saved[0].camera_make.as_deref(), Some("ZWO"));
}

/// Asserted at the REAL call site: the frame event that makes Dart write the
/// `captured_images` row is stamped from the very `FrameContext` instance
/// `save_fits` was handed for that frame.
///
/// Every other test on this path calls `emit_grade_progress` directly with a
/// hand-made context and then derives both sides of the comparison from that
/// same literal — proving only that a function stamps from its own argument,
/// never that the argument is the right one. So this test runs
/// `execute_exposure` for real against a device layer that RECORDS what the
/// FITS writer received, and compares that recording against what the event
/// carried. Hand `emit_grade_progress` anything other than `frame_ctx` and
/// this fails; nothing else in the suite does.
#[tokio::test]
async fn frame_event_is_stamped_from_the_context_save_fits_received() {
    let scratch = scratch_dir("frame-ctx-agreement");
    let ops = Arc::new(
        ScriptedDomeRotatorOps::new()
            .with_capture_telemetry()
            .with_rotator_angles(vec![212.5]),
    );
    let (event_tx, mut event_rx) = tokio::sync::broadcast::channel(64);
    let ctx = saving_expose_ctx(ops.clone(), scratch.0.clone(), event_tx).await;

    let result = execute_exposure(&one_dark(2), &ctx, |_, _, _| {}).await;
    assert_eq!(
        result.status,
        NodeStatus::Success,
        "burst should complete: {:?}",
        result.message
    );

    let saved = ops.saved_frame_contexts();
    assert_eq!(
        saved.len(),
        2,
        "both frames must have reached the FITS writer"
    );

    let emitted = drain_frame_captures(&mut event_rx);
    assert_eq!(
        emitted.len(),
        saved.len(),
        "every saved frame must emit exactly one frame event"
    );

    for (index, (written, sent)) in saved.iter().zip(emitted.iter()).enumerate() {
        assert_eq!(
            *sent,
            crate::scheduling::FrameCaptureMetadata::from(written),
            "frame {} event carries a different capture than the FITS writer got",
            index + 1
        );
    }

    // Guard the guard: an all-default context would satisfy the equality
    // above if BOTH hops were severed together, so pin the telemetry the
    // scripted rig reported. These are the values that reach
    // `captured_images`.
    let first = &emitted[0];
    assert_eq!(first.gain, Some(139));
    assert_eq!(first.offset, Some(21));
    assert_eq!(first.sensor_temp_c, Some(-9.5));
    assert_eq!(first.cooler_power_percent, Some(63.5));
    assert_eq!(first.mount_ra_hours, Some(5.5));
    assert_eq!(first.mount_dec_degrees, Some(-5.25));
    assert!(
        first.mount_altitude_deg.is_some() && first.mount_azimuth_deg.is_some(),
        "a sited rig must derive alt/az from its own pointing"
    );
    assert_eq!(first.pier_side.as_deref(), Some("West"));
    assert_eq!(first.focuser_position, Some(31_705));
    assert_eq!(first.focuser_temperature_c, Some(4.25));
    assert_eq!(first.rotator_angle_deg, Some(212.5));
    assert_eq!(first.frame_type, "Dark");
    assert_eq!((first.bin_x, first.bin_y), (2, 2));
}

/// The alt/az stamped on a frame belongs to the light it integrated.
///
/// This block runs after readout, so deriving the horizon frame from
/// `Utc::now()` dated it by the whole exposure plus download — and this is
/// the ONE derivation that feeds both the FITS `OBJCTALT`/`AIRMASS` cards
/// and the `captured_images.mount_altitude` column the AAVSO exporter reads
/// its AMASS from, so the error lands in a published photometry submission.
///
/// Deliberately clock-independent: the mount is pointed at whatever is
/// culminating at the instant the test starts, so the save-time answer is
/// the target's maximum altitude and the midpoint — an hour later — is
/// measurably lower, whatever time of day the suite runs. Tokio's clock is
/// paused so the two-hour exposure costs no wall time while the CHRONO
/// timestamps stay real.
#[tokio::test(start_paused = true)]
async fn frame_altitude_is_derived_at_the_exposure_midpoint() {
    let now = chrono::Utc::now();
    let ra_hours =
        crate::meridian::local_sidereal_time(crate::meridian::julian_day(&now), TEST_LON)
            .rem_euclid(24.0);
    let dec_degrees = 20.0;

    let scratch = scratch_dir("frame-ctx-midpoint");
    let ops = Arc::new(
        ScriptedDomeRotatorOps::new()
            .with_capture_telemetry()
            .with_scripted_mount_coordinates(ra_hours, dec_degrees),
    );
    let (event_tx, _event_rx) = tokio::sync::broadcast::channel(64);
    let mut ctx = saving_expose_ctx(ops.clone(), scratch.0.clone(), event_tx).await;

    // Opt out of the daylight gate, RELATIVE to the live Sun.
    //
    // This test is about where the altitude is sampled, not about whether
    // the Sun is up. Left on the default -12 deg threshold it passed at
    // night and failed in daylight — it was failing here with
    // "Sun altitude -2.4 deg is above the maximum -12.0 deg". Seeding the
    // threshold above the CURRENT Sun altitude keeps the gate wired
    // (the resolution path is still exercised) while making the outcome
    // independent of the hour the suite happens to run.
    let mut ts = crate::triggers::TriggerState::new();
    ts.set_max_sun_altitude_degrees(live_sun_alt() + 5.0);
    ctx.trigger_state = Some(std::sync::Arc::new(tokio::sync::RwLock::new(ts)));

    let config = ExposureConfig {
        duration_secs: 7200.0,
        count: 1,
        frame_type: "Light".to_string(),
        ..ExposureConfig::default()
    };
    let result = execute_exposure(&config, &ctx, |_, _, _| {}).await;
    assert_eq!(
        result.status,
        NodeStatus::Success,
        "burst should complete: {:?}",
        result.message
    );

    let saved = ops.saved_frame_contexts();
    let frame = saved.first().expect("one frame reached the FITS writer");
    let started = frame
        .exposure_started_at
        .expect("the shutter-open instant is recorded");
    let recorded = frame
        .mount_altitude_deg
        .expect("a sited rig derives an altitude from its own pointing");

    let (at_midpoint, _) = crate::meridian::calculate_alt_az(
        ra_hours,
        dec_degrees,
        TEST_LAT,
        TEST_LON,
        started + chrono::Duration::seconds(3600),
    );
    let (at_shutter_open, _) =
        crate::meridian::calculate_alt_az(ra_hours, dec_degrees, TEST_LAT, TEST_LON, started);
    assert!(
        (at_shutter_open - at_midpoint).abs() > 0.5,
        "test rig is not discriminating: shutter-open {at_shutter_open:.4} deg \
             vs midpoint {at_midpoint:.4} deg"
    );
    assert!(
        (recorded - at_midpoint).abs() < 0.05,
        "mount_altitude_deg was {recorded:.4} deg; the exposure midpoint is \
             {at_midpoint:.4} deg and the shutter-open instant is \
             {at_shutter_open:.4} deg"
    );
}

/// A sequenced sub must reach the FITS writer carrying the sensor's own
/// pixel pitch.
///
/// `FitsWriteHeaderRich::from_frame_context` hardcoded `pixel_size_x: None`
/// and nothing upstream ever asked the camera, so every frame a real run
/// produced landed on disk with FOCALLEN and APTDIA but no XPIXSZ/YPIXSZ —
/// ASTAP, PixInsight and AstroBin cannot derive the plate scale from such a
/// file. The manual-snapshot path was fixed to write the pitch, which left
/// two frames off one rig disagreeing about one sensor.
///
/// Asserted at the real call site rather than on a hand-built context:
/// `execute_exposure` runs, and what is checked is the `FrameContext` the
/// FITS writer was actually HANDED.
#[tokio::test]
async fn sequenced_frames_carry_the_sensor_pixel_pitch() {
    let scratch = scratch_dir("frame-ctx-pixel-pitch");
    let ops = Arc::new(ScriptedDomeRotatorOps::new().with_capture_telemetry());
    let (event_tx, _event_rx) = tokio::sync::broadcast::channel(16);
    let ctx = saving_expose_ctx(ops.clone(), scratch.0.clone(), event_tx).await;

    let result = execute_exposure(&one_dark(1), &ctx, |_, _, _| {}).await;
    assert_eq!(result.status, NodeStatus::Success, "{:?}", result.message);

    let saved = ops.saved_frame_contexts();
    assert_eq!(
        saved.len(),
        1,
        "the frame must have reached the FITS writer"
    );
    assert_eq!(
        (
            saved[0].camera_pixel_size_x_um,
            saved[0].camera_pixel_size_y_um
        ),
        (Some(3.76), Some(3.76)),
        "the pitch the camera reported has to be on the context the header \
             is built from, or the sub is written without XPIXSZ/YPIXSZ"
    );
}

/// ...and a camera that will not report a pitch leaves the keywords off
/// rather than stamping a plausible-looking default a solver would trust.
#[tokio::test]
async fn a_camera_that_reports_no_pitch_leaves_the_keywords_absent() {
    let scratch = scratch_dir("frame-ctx-no-pixel-pitch");
    // No `with_capture_telemetry`, so the scripted rig has no pitch to give.
    let ops = Arc::new(ScriptedDomeRotatorOps::new());
    let (event_tx, _event_rx) = tokio::sync::broadcast::channel(16);
    let ctx = saving_expose_ctx(ops.clone(), scratch.0.clone(), event_tx).await;

    let result = execute_exposure(&one_dark(1), &ctx, |_, _, _| {}).await;
    assert_eq!(result.status, NodeStatus::Success, "{:?}", result.message);

    let saved = ops.saved_frame_contexts();
    assert_eq!(saved.len(), 1);
    assert_eq!(
        (
            saved[0].camera_pixel_size_x_um,
            saved[0].camera_pixel_size_y_um
        ),
        (None, None),
    );
}

/// A camera that reports a slightly different exposure than the one
/// commanded is reporting a real measurement (shutter latency, a coarse
/// exposure clock), and that measurement is what `EXPTIME` means. It must
/// reach both the header and the row.
#[tokio::test]
async fn plausible_driver_exposure_report_wins_over_the_commanded_value() {
    let scratch = scratch_dir("exposure-report-honest");
    let ops = Arc::new(
        ScriptedDomeRotatorOps::new()
            // Commanded 60s, shutter actually open 60.4s.
            .with_reported_exposure_secs(60.4),
    );
    let (event_tx, mut event_rx) = tokio::sync::broadcast::channel(16);
    let ctx = saving_expose_ctx(ops.clone(), scratch.0.clone(), event_tx).await;

    let config = ExposureConfig {
        duration_secs: 60.0,
        ..one_dark(1)
    };
    let result = execute_exposure(&config, &ctx, |_, _, _| {}).await;
    assert_eq!(result.status, NodeStatus::Success, "{:?}", result.message);

    let saved = ops.saved_frame_contexts();
    assert_eq!(saved[0].duration_secs, 60.4);
    assert_eq!(drain_frame_captures(&mut event_rx)[0].exposure_secs, 60.4);
}

/// ...but that trust is bounded. `captured_images.exposure_duration` is
/// summed into every integration total in the app, so a driver reporting an
/// impossible exposure — longer than the sequencer ever waited — must not be
/// able to inflate a night's reported integration. Here a 60-second sub is
/// reported as an hour; the recorded value has to stay 60.
///
/// This is the one direction where the driver is provably wrong rather than
/// merely surprising: nothing kept the shutter open past the command.
#[tokio::test]
async fn nonsense_driver_exposure_report_cannot_inflate_integration_totals() {
    let scratch = scratch_dir("exposure-report-nonsense");
    let ops = Arc::new(
        ScriptedDomeRotatorOps::new()
            // 60x the commanded exposure: an entire night's integration in
            // one sub, if this were believed.
            .with_reported_exposure_secs(3600.0),
    );
    let (event_tx, mut event_rx) = tokio::sync::broadcast::channel(16);
    let ctx = saving_expose_ctx(ops.clone(), scratch.0.clone(), event_tx).await;

    let config = ExposureConfig {
        duration_secs: 60.0,
        ..one_dark(1)
    };
    let result = execute_exposure(&config, &ctx, |_, _, _| {}).await;
    assert_eq!(result.status, NodeStatus::Success, "{:?}", result.message);

    let saved = ops.saved_frame_contexts();
    assert_eq!(
        saved[0].duration_secs, 60.0,
        "an impossible exposure report must not reach the FITS header"
    );
    assert_eq!(
        drain_frame_captures(&mut event_rx)[0].exposure_secs,
        60.0,
        "nor the captured_images row every integration total sums"
    );
}

/// The per-frame progress callback reports the seconds the frame was RECORDED
/// as, so every integration total in the app sums the same number the FITS
/// header and the `captured_images` row were written from.
///
/// Crediting the node's PLANNED duration instead makes the surfaces that sum
/// rows disagree with the surfaces that multiply: 5 + 15 + 15 + 15 s across
/// four frames reads as `50s` on the Session Report and `1m 0s` on the
/// Dashboard, the Execution History row and the Recover Sequence dialog.
#[tokio::test]
async fn the_frame_callback_reports_recorded_seconds_not_planned_ones() {
    let scratch = scratch_dir("exposure-callback-recorded");
    let ops = Arc::new(
        ScriptedDomeRotatorOps::new()
            // Commanded 15 s; the shutter was actually open 5 s — the shape a
            // meridian-flip solve leaves when it restarts the camera under the
            // burst.
            .with_reported_exposure_secs(5.0),
    );
    let (event_tx, _event_rx) = tokio::sync::broadcast::channel(16);
    let ctx = saving_expose_ctx(ops.clone(), scratch.0.clone(), event_tx).await;

    let config = ExposureConfig {
        duration_secs: 15.0,
        ..one_dark(1)
    };

    let reported = Arc::new(Mutex::new(Vec::<f64>::new()));
    let sink = reported.clone();
    let result = execute_exposure(&config, &ctx, move |_frame, _total, recorded_secs| {
        sink.lock().unwrap().push(recorded_secs);
    })
    .await;
    assert_eq!(result.status, NodeStatus::Success, "{:?}", result.message);

    let saved = ops.saved_frame_contexts();
    assert_eq!(
        saved[0].duration_secs, 5.0,
        "the row and the header record what the camera exposed"
    );
    assert_eq!(
        reported.lock().unwrap().as_slice(),
        &[5.0],
        "the run's integration credit must sum the SAME number the row does, \
         not the 15.0 s the node planned"
    );
}

/// The bound the recorded value carries is the one the FITS writer already
/// enforced, so a lying driver cannot inflate a night through this new path
/// either.
#[test]
fn recorded_exposure_secs_keeps_the_command_when_the_report_is_impossible() {
    // Believable: shutter latency, coarse exposure clocks.
    assert_eq!(recorded_exposure_secs(60.0, 60.4), 60.4);
    // Physically possible under-report: an aborted or truncated exposure.
    assert_eq!(recorded_exposure_secs(15.0, 5.0), 5.0);
    // Impossible: nothing kept the shutter open past the command.
    assert_eq!(recorded_exposure_secs(60.0, 3600.0), 60.0);
    // A driver that reports nothing at all leaves the command standing.
    assert_eq!(recorded_exposure_secs(30.0, 0.0), 30.0);
}

/// The consecutive-reject limit tells the operator that frames keep failing
/// grading; it never pauses, stops or parks the run (owner decision
/// 2026-10-06: "this limit should never stop a sequence or end a night. Again,
/// just notify users of these issues"). It used to hand the storm to the
/// recovery driver, which paused the run (or parked it under the opt-in
/// give-up policy), and repeated an Error banner on every further reject.
mod consecutive_reject_limit {
    use super::*;

    struct Storm {
        ctx: InstructionContext,
        requests: tokio::sync::mpsc::Receiver<crate::recovery::RecoveryCause>,
        events: tokio::sync::broadcast::Receiver<crate::executor::ExecutorEvent>,
        decisions: tokio::sync::broadcast::Receiver<crate::decision::DecisionEvent>,
        accepted: Arc<AtomicU32>,
        rejected: Arc<AtomicU32>,
        consecutive: Arc<AtomicU32>,
    }

    /// What grading one frame produced.
    #[derive(Debug, Default, PartialEq)]
    struct Seen {
        /// Requests to the recovery driver, which freezes the node tree.
        recovery_requests: usize,
        /// Sequencer Errors: every one is a "Sequence failed" notification.
        errors: usize,
        /// The streak notice in the run's warnings.
        streak_warnings: usize,
        /// The decision row the app raises its notification from.
        streak_notices: usize,
    }

    const NOTICE: Seen = Seen {
        recovery_requests: 0,
        errors: 0,
        streak_warnings: 1,
        streak_notices: 1,
    };
    const QUIET: Seen = Seen {
        recovery_requests: 0,
        errors: 0,
        streak_warnings: 0,
        streak_notices: 0,
    };

    async fn storm() -> Storm {
        let ctx = expose_ctx(Arc::new(NullDeviceOps), None, live_sun_alt() - 30.0).await;
        let (event_tx, events) = tokio::sync::broadcast::channel(256);
        let (request_tx, requests) = tokio::sync::mpsc::channel(16);
        let (decision_tx, decisions) = tokio::sync::broadcast::channel(256);
        Storm {
            ctx: InstructionContext {
                event_tx: Some(event_tx),
                recovery_request_tx: Some(request_tx),
                decision_tx: Some(decision_tx),
                ..ctx
            },
            requests,
            events,
            decisions,
            accepted: Arc::new(AtomicU32::new(0)),
            rejected: Arc::new(AtomicU32::new(0)),
            consecutive: Arc::new(AtomicU32::new(0)),
        }
    }

    impl Storm {
        /// Grade one frame and report what that frame alone produced.
        async fn frame(&mut self, frame: u32, pass: bool, max: u32) -> Seen {
            let grade = if pass {
                crate::quality::FrameGrade::Pass
            } else {
                crate::quality::FrameGrade::Reject {
                    reason: "star count 3 below minimum 20".to_string(),
                    hfr: None,
                    eccentricity: None,
                    star_count: Some(3),
                }
            };
            let frame_ctx = crate::scheduling::FrameContext::new_light("sess", 1, 1, 60.0, frame);
            emit_grade_progress(
                &self.ctx,
                grade,
                &crate::quality::FrameMetrics::default(),
                true,
                frame,
                20,
                std::path::Path::new("/captures/storm.fits"),
                &frame_ctx,
                &self.accepted,
                &self.rejected,
                &self.consecutive,
                max,
            )
            .await;
            let mut seen = Seen::default();
            while self.requests.try_recv().is_ok() {
                seen.recovery_requests += 1;
            }
            while let Ok(event) = self.events.try_recv() {
                match event {
                    crate::executor::ExecutorEvent::Error { .. } => seen.errors += 1,
                    crate::executor::ExecutorEvent::Warning { message } => {
                        assert!(
                            message.contains("in a row") && message.contains("The run continues"),
                            "{message}"
                        );
                        seen.streak_warnings += 1;
                    }
                    _ => {}
                }
            }
            while let Ok(decision) = self.decisions.try_recv() {
                if decision.summary == crate::instructions::IMAGE_GRADING_REJECT_STREAK_SUMMARY {
                    assert_eq!(decision.details["consecutive_rejects"], max);
                    assert_eq!(decision.details["reason"], "star count 3 below minimum 20");
                    seen.streak_notices += 1;
                }
            }
            seen
        }
    }

    #[tokio::test]
    async fn a_reject_streak_notifies_once_and_never_holds_the_run() {
        let mut s = storm().await;
        assert_eq!(s.frame(1, false, 3).await, QUIET);
        assert_eq!(s.frame(2, false, 3).await, QUIET);
        // The limit: one notice, and nothing asked to freeze the run.
        assert_eq!(s.frame(3, false, 3).await, NOTICE);
        // Still rejecting: no repeat, so a cloudy hour is one notice, not sixty.
        assert_eq!(s.frame(4, false, 3).await, QUIET);
        assert_eq!(s.frame(5, false, 3).await, QUIET);
        // One good frame ends the streak; a later streak is told about again.
        assert_eq!(s.frame(6, true, 3).await, QUIET);
        assert_eq!(s.frame(7, false, 3).await, QUIET);
        assert_eq!(s.frame(8, false, 3).await, QUIET);
        assert_eq!(s.frame(9, false, 3).await, NOTICE);
        // The rejects are still graded and counted.
        assert_eq!(s.accepted.load(Ordering::Relaxed), 1);
        assert_eq!(s.rejected.load(Ordering::Relaxed), 8);
    }

    /// The app raises its notifications by matching these summaries
    /// verbatim, so a reworded summary here would silently stop the operator
    /// being told.
    #[test]
    fn the_app_matches_the_summaries_it_notifies_on() {
        let classifier = std::fs::read_to_string(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../packages/skotiq_core/lib/src/services/notification/event_classifier.dart"
        ))
        .expect("the app's notification classifier is in the repository");
        for summary in [
            crate::instructions::IMAGE_GRADING_REJECT_STREAK_SUMMARY,
            crate::executor::AUTOFOCUS_TRIGGER_CONTINUED_SUMMARY,
        ] {
            assert!(
                classifier.contains(&format!("'{summary}'")),
                "event_classifier.dart does not match {summary:?}"
            );
        }
    }

    #[tokio::test]
    async fn a_limit_of_zero_never_notifies() {
        let mut s = storm().await;
        for frame in 1..=5 {
            assert_eq!(s.frame(frame, false, 0).await, QUIET);
        }
    }
}
