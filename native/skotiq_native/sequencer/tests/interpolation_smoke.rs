//! Integration test for the interpolation engine.
//!
//! Lives in `tests/` (not under `src/`) so it compiles against the library's
//! public API but does NOT pull in the in-tree `#[cfg(test)]` modules of
//! sibling agents that are currently in-flight. That keeps the
//! interpolation suite runnable end-to-end while those parallel changes
//! settle.

use skotiq_sequencer::{
    expressions::EvaluationFrame, interpolate, ExecutionContext, InterpolationError,
};

fn ctx_with_target() -> ExecutionContext {
    let mut ctx = ExecutionContext::new(
        "root".to_string(),
        std::sync::Arc::new(skotiq_sequencer::NullDeviceOps),
    );
    ctx.target_name = Some("M42".to_string());
    ctx.target_id = Some("tgt-42".to_string());
    ctx.target_ra = Some(5.59);
    ctx.target_dec = Some(-5.39);
    ctx.target_rotation = Some(45.0);
    ctx.current_filter = Some("Ha".to_string());
    ctx.current_filter_index = Some(3);
    ctx.latitude = Some(40.7);
    ctx.longitude = Some(-74.0);
    ctx.observer_name = Some("Alice".to_string());
    ctx.site_elevation_m = Some(150.0);
    ctx.camera_make = Some("ZWO".to_string());
    ctx.camera_model = Some("ASI2600MM".to_string());
    ctx.telescope_name = Some("TS APO".to_string());
    ctx.telescope_focal_length_mm = Some(910.0);
    ctx.telescope_aperture_mm = Some(130.0);
    ctx.set_temp_c = Some(-10.0);
    ctx
}

fn frame_with_burst() -> EvaluationFrame {
    use chrono::TimeZone;
    EvaluationFrame {
        frame: Some(8),
        frame_total: Some(30),
        exposure_duration_secs: Some(180.0),
        exposure_gain: Some(100),
        exposure_offset: Some(10),
        exposure_binning: Some("1x1".to_string()),
        filter_position: Some(3),
        session_start: Some(
            chrono::Utc
                .with_ymd_and_hms(2026, 1, 15, 22, 14, 33)
                .single()
                .unwrap(),
        ),
        now_override: Some(
            chrono::Utc
                .with_ymd_and_hms(2026, 1, 15, 22, 47, 12)
                .single()
                .unwrap(),
        ),
        moon_phase: Some(0.42),
        weather_temp_c: Some(12.4),
        weather_humidity: Some(67.0),
        sqm: Some(21.2),
    }
}

#[test]
fn save_path_template_renders_hierarchical_directories() {
    let ctx = ctx_with_target();
    let frame = frame_with_burst();
    let rendered = interpolate(
        "${session.date}/${target.name}/${filter}/sub_${frame:04}_${exposure.duration:.0f}s.fits",
        &ctx,
        &frame,
    )
    .expect("template must render");
    assert_eq!(rendered, "2026-01-15/M42/Ha/sub_0008_180s.fits");
}

#[test]
fn notification_template_renders_message() {
    let ctx = ctx_with_target();
    let frame = frame_with_burst();
    let rendered = interpolate(
        "${target.name} done. Took ${frame} frames at ${exposure.duration}s = ${exposure.total:.1f}m total.",
        &ctx,
        &frame,
    )
    .expect("must render");
    assert_eq!(rendered, "M42 done. Took 8 frames at 180s = 90.0m total.");
}

#[test]
fn run_script_argument_renders_session_id() {
    let mut ctx = ctx_with_target();
    ctx.session_id = "test-session-123".to_string();
    let frame = frame_with_burst();
    let rendered = interpolate("--input=${session.id}", &ctx, &frame).expect("must render");
    assert_eq!(rendered, "--input=test-session-123");
}

#[test]
fn unknown_variable_returns_error_not_empty() {
    let ctx = ctx_with_target();
    let frame = frame_with_burst();
    let err = interpolate("${target.naem}", &ctx, &frame).expect_err("must error on typo");
    match err {
        InterpolationError::UnknownVariable { name, .. } => assert_eq!(name, "target.naem"),
        other => panic!("expected UnknownVariable, got {other:?}"),
    }
}

#[test]
fn missing_data_returns_unresolvable_not_empty() {
    // Load-bearing target data (join keys and coordinates) must still fail
    // loudly rather than render as empty. `target.ra` stands in for the class.
    let mut ctx = ctx_with_target();
    ctx.target_ra = None;
    let frame = frame_with_burst();
    let err = interpolate("${target.ra}", &ctx, &frame).expect_err("must error");
    match err {
        InterpolationError::Unresolvable { name, .. } => assert_eq!(name, "target.ra"),
        other => panic!("expected Unresolvable, got {other:?}"),
    }
}

/// `${target.name}` is the ONE deliberate exception to the rule above.
///
/// Leaving it unresolvable aborts the exposure *after the shutter has already
/// opened* on any untargeted run — every calibration sequence — discarding
/// real photons and finishing the run with zero frames. It renders the
/// explicit `untargeted` label instead, matching what the non-template
/// filename path writes. Note this still honours the
/// spirit of the test above: the result is a stated fact, never an empty
/// string. Pinned here as well as in the resolver's own unit tests so the
/// exception cannot be quietly widened to the strict fields.
#[test]
fn missing_target_name_renders_untargeted_rather_than_aborting() {
    let mut ctx = ctx_with_target();
    ctx.target_name = None;
    let frame = frame_with_burst();
    let rendered =
        interpolate("${target.name}", &ctx, &frame).expect("an untargeted run must still render");
    assert_eq!(rendered, "untargeted");
    assert!(!rendered.is_empty(), "must never render as empty");

    // The strict fields are unaffected by that exception.
    for strict in ["${target.id}", "${target.ra}", "${target.dec}"] {
        let mut bare = ExecutionContext::new(
            "root".to_string(),
            std::sync::Arc::new(skotiq_sequencer::NullDeviceOps),
        );
        bare.target_name = None;
        let frame = frame_with_burst();
        interpolate(strict, &bare, &frame).expect_err(&format!(
            "{strict} must stay strict when there is no target"
        ));
    }
}

#[test]
fn templates_without_placeholders_pass_through() {
    let ctx = ctx_with_target();
    let frame = frame_with_burst();
    let rendered = interpolate("plain literal — no $ here", &ctx, &frame).expect("must render");
    assert_eq!(rendered, "plain literal — no $ here");
}

#[test]
fn doubled_dollar_escapes_interpolation() {
    let ctx = ctx_with_target();
    let frame = frame_with_burst();
    let rendered =
        interpolate("price tag is $${500} (literal)", &ctx, &frame).expect("must render");
    assert_eq!(rendered, "price tag is ${500} (literal)");
}

#[test]
fn concurrent_filter_changes_resolve_to_current_value() {
    // Simulates a multi-filter run where the same ExecutionContext is
    // mutated between bursts. The resolver always reads the current
    // value from ctx.current_filter — no stale captures.
    let mut ctx = ctx_with_target();
    let frame = frame_with_burst();

    ctx.current_filter = Some("L".to_string());
    let l_render = interpolate("${filter}", &ctx, &frame).unwrap();
    assert_eq!(l_render, "L");

    ctx.current_filter = Some("Ha".to_string());
    let ha_render = interpolate("${filter}", &ctx, &frame).unwrap();
    assert_eq!(ha_render, "Ha");

    ctx.current_filter = Some("OIII".to_string());
    let oiii_render = interpolate("${filter}", &ctx, &frame).unwrap();
    assert_eq!(oiii_render, "OIII");
}

#[test]
fn frame_counter_isolated_to_evaluation_frame() {
    // Each frame in a burst gets a fresh EvaluationFrame; the resolver
    // reads `frame.frame`, not a shared atomic. Two frames evaluated in
    // sequence must produce the right counter for each.
    let ctx = ctx_with_target();
    let mut frame = frame_with_burst();

    frame.frame = Some(1);
    let rendered_1 = interpolate("${frame:04}", &ctx, &frame).unwrap();
    assert_eq!(rendered_1, "0001");

    frame.frame = Some(15);
    let rendered_15 = interpolate("${frame:04}", &ctx, &frame).unwrap();
    assert_eq!(rendered_15, "0015");
}

#[test]
fn round_trip_template_is_not_pre_rendered() {
    // A saved template string must survive a parse → re-encode round-trip
    // unchanged so persistence keeps the user's authored syntax intact.
    use skotiq_sequencer::expressions::parse_template;
    use skotiq_sequencer::TemplatePart;

    let original = "${session.date}/${target.name}/${filter}/sub_${frame:04}.fits";
    let parts = parse_template(original).expect("parse");
    let mut rebuilt = String::new();
    for part in &parts {
        match part {
            TemplatePart::Literal(s) => rebuilt.push_str(s),
            TemplatePart::Variable {
                name, format_spec, ..
            } => {
                rebuilt.push_str("${");
                rebuilt.push_str(name);
                if let Some(spec) = format_spec {
                    rebuilt.push(':');
                    rebuilt.push_str(spec);
                }
                rebuilt.push('}');
            }
        }
    }
    assert_eq!(rebuilt, original);
}

#[test]
fn catalog_dump_is_valid_json_array() {
    let json = skotiq_sequencer::expressions::catalog::catalog_json();
    assert!(json.starts_with('['), "expected JSON array");
    assert!(json.ends_with(']'), "expected JSON array");
    // Spot-check that a known variable appears in the dump.
    assert!(json.contains("\"target.name\""));
    assert!(json.contains("\"frame\""));
    assert!(json.contains("\"session.date\""));
}
