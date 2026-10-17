//! Validation, replay, reporting, cancellation and cache resume.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use serde_json::json;

use super::*;
use crate::recipe::cache::RenderCache;
use crate::recipe::model::{OpError, RecipeAuthor, RecipeParent, RecipeStep};
use crate::recipe::pyramid::ImagePyramid;
use crate::recipe::registry::OpRegistry;
use crate::recipe::testkit::{
    assert_pixels_identical, assert_wcs_identical, fixed_catalog, scale_params,
    synthetic_star_field, test_registry, ScaleOp,
};

fn recipe_of(steps: Vec<RecipeStep>) -> Recipe {
    let mut recipe = Recipe::new("rec", "master-1", RecipeAuthor::User);
    recipe.steps = steps;
    recipe
}

fn base_image() -> Arc<OpImage> {
    Arc::new(synthetic_star_field(48, 32, 1, 42))
}

fn scale_step(factor: f64) -> RecipeStep {
    RecipeStep::new("test_scale", 1).with_params(scale_params(factor))
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

#[test]
fn an_empty_recipe_validates_against_an_empty_registry() {
    let recipe = Recipe::new("rec", "master-1", RecipeAuthor::Autopilot);
    assert_eq!(validate(&recipe, &OpRegistry::new()), Ok(()));
}

#[test]
fn an_unknown_operation_is_named_with_its_step_index() {
    let recipe = recipe_of(vec![scale_step(2.0), RecipeStep::new("no_such_op", 4)]);
    assert_eq!(
        validate(&recipe, &test_registry()),
        Err(RecipeError::UnknownOp {
            index: 1,
            op_id: "no_such_op".to_string(),
            op_version: 4,
        })
    );
}

#[test]
fn an_unregistered_version_of_a_known_operation_is_unknown() {
    let recipe = recipe_of(vec![RecipeStep::new("test_scale", 9)]);
    assert!(matches!(
        validate(&recipe, &test_registry()),
        Err(RecipeError::UnknownOp { op_version: 9, .. })
    ));
}

#[test]
fn invalid_parameters_carry_the_operations_own_error() {
    let recipe = recipe_of(vec![
        RecipeStep::new("test_scale", 1).with_params(json!({"factor": "fast"}))
    ]);
    let err = validate(&recipe, &test_registry()).expect_err("the payload is rejected");
    match err {
        RecipeError::InvalidParams { index, source, .. } => {
            assert_eq!(index, 0);
            assert!(matches!(*source, OpError::ParamType { .. }));
        }
        other => panic!("expected InvalidParams, got {other:?}"),
    }
}

#[test]
fn a_linear_operation_may_not_follow_a_stretched_one() {
    let recipe = recipe_of(vec![
        scale_step(2.0),
        RecipeStep::new("test_stretch", 1),
        scale_step(3.0),
    ]);
    assert_eq!(
        validate(&recipe, &test_registry()),
        Err(RecipeError::StageOrder {
            index: 2,
            op_id: "test_scale".to_string(),
            op_version: 1,
            blocking_index: 1,
            blocking_op_id: "test_stretch".to_string(),
        })
    );
}

#[test]
fn a_stretched_operation_may_follow_a_stretched_one() {
    let recipe = recipe_of(vec![
        scale_step(2.0),
        RecipeStep::new("test_stretch", 1),
        RecipeStep::new("test_curves", 1),
    ]);
    assert_eq!(validate(&recipe, &test_registry()), Ok(()));
}

#[test]
fn the_stage_rule_reads_disabled_steps_too() {
    let recipe = recipe_of(vec![
        RecipeStep::new("test_stretch", 1),
        scale_step(3.0).with_enabled(false),
    ]);
    assert!(
        matches!(
            validate(&recipe, &test_registry()),
            Err(RecipeError::StageOrder { .. })
        ),
        "a disabled step keeps its place in the order, so re-enabling it cannot break a valid recipe"
    );
}

#[test]
fn a_disabled_step_this_build_cannot_run_blocks_nothing_until_it_is_enabled() {
    let mut recipe = recipe_of(vec![
        scale_step(2.0),
        RecipeStep::new("no_such_op", 4).with_enabled(false),
    ]);
    assert_eq!(
        validate(&recipe, &test_registry()),
        Ok(()),
        "a step that will not run needs no operation to run it"
    );

    recipe.steps[1].enabled = true;
    assert_eq!(
        validate(&recipe, &test_registry()),
        Err(RecipeError::UnknownOp {
            index: 1,
            op_id: "no_such_op".to_string(),
            op_version: 4,
        }),
        "enabling it puts the operation this build lacks back on the render path"
    );
}

#[test]
fn the_stage_rule_reads_past_a_disabled_step_this_build_cannot_place() {
    let recipe = recipe_of(vec![
        RecipeStep::new("test_stretch", 1),
        RecipeStep::new("no_such_op", 4).with_enabled(false),
        scale_step(3.0),
    ]);
    assert!(
        matches!(
            validate(&recipe, &test_registry()),
            Err(RecipeError::StageOrder { index: 2, .. })
        ),
        "a step with no stage in this build hides neither the stretch below it nor the linear step above it"
    );
}

#[test]
fn a_recipe_that_parents_itself_is_rejected() {
    let mut recipe = recipe_of(vec![scale_step(2.0)]);
    recipe.parent = Some(RecipeParent {
        recipe_id: "rec".to_string(),
        divergence_index: 0,
    });
    assert!(matches!(
        validate(&recipe, &test_registry()),
        Err(RecipeError::InvalidParent { .. })
    ));
}

#[test]
fn a_divergence_index_past_the_end_is_rejected() {
    let mut recipe = recipe_of(vec![scale_step(2.0)]);
    recipe.parent = Some(RecipeParent {
        recipe_id: "rec-0".to_string(),
        divergence_index: 2,
    });
    assert!(matches!(
        validate(&recipe, &test_registry()),
        Err(RecipeError::InvalidParent { .. })
    ));
}

#[test]
fn a_divergence_index_at_the_end_is_a_pure_extension() {
    let mut recipe = recipe_of(vec![scale_step(2.0)]);
    recipe.parent = Some(RecipeParent {
        recipe_id: "rec-0".to_string(),
        divergence_index: 1,
    });
    assert_eq!(validate(&recipe, &test_registry()), Ok(()));
}

#[test]
fn an_unsupported_schema_version_is_rejected_before_the_steps_are_read() {
    let mut recipe = recipe_of(vec![RecipeStep::new("no_such_op", 1)]);
    recipe.schema_version = 2;
    assert_eq!(
        validate(&recipe, &test_registry()),
        Err(RecipeError::UnsupportedSchemaVersion { found: 2 })
    );
}

// ---------------------------------------------------------------------------
// Replay
// ---------------------------------------------------------------------------

#[test]
fn an_empty_recipe_renders_the_base_unchanged() {
    let base = base_image();
    let recipe = Recipe::new("rec", "master-1", RecipeAuthor::Autopilot);
    let mut cache = RenderCache::unbounded();
    let out = render_full(
        &recipe,
        &base,
        &OpRegistry::new(),
        &mut cache,
        &OpContext::new(),
    )
    .expect("an empty recipe renders");
    assert_pixels_identical(&out.image, &base, "empty recipe");
    assert!(out.report.steps.is_empty());
    assert!(!out.report.has_skips());
}

#[test]
fn steps_apply_in_order() {
    let base = base_image();
    let recipe = recipe_of(vec![scale_step(2.0), scale_step(3.0)]);
    let mut cache = RenderCache::unbounded();
    let out = render_full(
        &recipe,
        &base,
        &test_registry(),
        &mut cache,
        &OpContext::new(),
    )
    .expect("the recipe renders");
    for (index, value) in out.image.data().iter().enumerate() {
        assert_eq!(*value, base.data()[index] * 6.0);
    }
    assert_eq!(
        out.report
            .steps
            .iter()
            .map(|s| &s.outcome)
            .collect::<Vec<_>>(),
        vec![&StepOutcome::Applied, &StepOutcome::Applied]
    );
}

#[test]
fn a_disabled_step_passes_the_image_through_and_is_reported() {
    let base = base_image();
    let recipe = recipe_of(vec![scale_step(2.0), scale_step(3.0).with_enabled(false)]);
    let mut cache = RenderCache::unbounded();
    let out = render_full(
        &recipe,
        &base,
        &test_registry(),
        &mut cache,
        &OpContext::new(),
    )
    .expect("the recipe renders");
    assert_eq!(out.image.data()[0], base.data()[0] * 2.0);
    assert_eq!(out.report.steps[1].outcome, StepOutcome::Disabled);
    assert_eq!(out.report.steps.len(), 2);
}

#[test]
fn a_disabled_step_this_build_cannot_run_renders_as_disabled() {
    let base = base_image();
    let recipe = recipe_of(vec![
        scale_step(2.0),
        RecipeStep::new("no_such_op", 4).with_enabled(false),
        scale_step(3.0),
    ]);
    let mut cache = RenderCache::unbounded();
    let out = render_full(
        &recipe,
        &base,
        &test_registry(),
        &mut cache,
        &OpContext::new(),
    )
    .expect("the enabled steps render over a step this build cannot run");
    assert_eq!(out.image.data()[0], base.data()[0] * 6.0);
    assert_eq!(out.report.steps.len(), 3);
    assert_eq!(out.report.steps[1].op_id, "no_such_op");
    assert_eq!(out.report.steps[1].outcome, StepOutcome::Disabled);
}

#[test]
fn a_leading_disabled_step_still_appears_in_the_report() {
    let base = base_image();
    let recipe = recipe_of(vec![scale_step(2.0).with_enabled(false), scale_step(3.0)]);
    let mut cache = RenderCache::unbounded();
    let out = render_full(
        &recipe,
        &base,
        &test_registry(),
        &mut cache,
        &OpContext::new(),
    )
    .expect("the recipe renders");
    assert_eq!(out.report.steps[0].outcome, StepOutcome::Disabled);
    assert_eq!(out.image.data()[0], base.data()[0] * 3.0);
}

#[test]
fn an_unavailable_capability_is_recorded_as_an_explicit_skip() {
    let base = base_image();
    let recipe = recipe_of(vec![RecipeStep::new("test_catalog", 1), scale_step(2.0)]);
    let mut cache = RenderCache::unbounded();
    let out = render_full(
        &recipe,
        &base,
        &test_registry(),
        &mut cache,
        &OpContext::new(),
    )
    .expect("a skipped step does not abort the render");
    assert_eq!(
        out.report.steps[0].outcome,
        StepOutcome::Skipped {
            reason: "no photometric catalog is installed".to_string()
        }
    );
    assert!(out.report.has_skips());
    assert_eq!(out.report.skipped().count(), 1);
    assert_eq!(out.image.data()[0], base.data()[0] * 2.0);
}

#[test]
fn the_same_step_applies_once_the_capability_is_present() {
    let base = base_image();
    let recipe = recipe_of(vec![RecipeStep::new("test_catalog", 1)]);
    let mut cache = RenderCache::unbounded();
    let ctx = OpContext::new().with_catalog(fixed_catalog());
    let out = render_full(&recipe, &base, &test_registry(), &mut cache, &ctx)
        .expect("the recipe renders");
    assert_eq!(out.report.steps[0].outcome, StepOutcome::Applied);
    assert_eq!(out.image.data()[0], base.data()[0] * 1.03);
    assert!(!out.report.has_skips());
}

#[test]
fn an_operation_failure_aborts_the_render_with_its_step_index() {
    let base = base_image();
    let recipe = recipe_of(vec![scale_step(2.0), RecipeStep::new("test_failing", 1)]);
    let mut cache = RenderCache::unbounded();
    let err = render_full(
        &recipe,
        &base,
        &test_registry(),
        &mut cache,
        &OpContext::new(),
    )
    .expect_err("a failing operation aborts");
    match err {
        RecipeError::Step { index, source } => {
            assert_eq!(index, 1);
            assert!(matches!(*source, OpError::Failed { .. }));
        }
        other => panic!("expected Step, got {other:?}"),
    }
}

#[test]
fn the_wcs_survives_the_whole_stack() {
    let base = base_image();
    let recipe = recipe_of(vec![
        scale_step(2.0),
        RecipeStep::new("test_stretch", 1),
        RecipeStep::new("test_curves", 1),
    ]);
    let mut cache = RenderCache::unbounded();
    let out = render_full(
        &recipe,
        &base,
        &test_registry(),
        &mut cache,
        &OpContext::new(),
    )
    .expect("the recipe renders");
    assert_wcs_identical(&out.image, &base, "three-step stack");
    assert_eq!(out.image.header().get_string("OBJECT"), Some("M31"));
    assert_eq!(out.image.header().get_float("EXPTIME"), Some(300.0));
    assert_eq!(
        out.image.header().get_string("DATE-OBS"),
        Some("2026-08-16T02:11:04")
    );
}

#[test]
fn a_crop_moves_the_reference_pixel_with_the_image() {
    let base = base_image();
    let recipe = recipe_of(vec![
        RecipeStep::new("test_crop", 1).with_params(json!({"margin": 4}))
    ]);
    let mut cache = RenderCache::unbounded();
    let out = render_full(
        &recipe,
        &base,
        &test_registry(),
        &mut cache,
        &OpContext::new(),
    )
    .expect("the recipe renders");
    assert_eq!(out.image.width(), base.width() - 8);
    assert_eq!(out.image.height(), base.height() - 8);
    assert_eq!(out.image.header().get_int("NAXIS1"), Some(40));
    assert_eq!(
        out.image.header().get_float("CRPIX1"),
        base.header().get_float("CRPIX1").map(|v| v - 4.0)
    );
}

// ---------------------------------------------------------------------------
// Stage materialisation
// ---------------------------------------------------------------------------

#[test]
fn stopping_after_a_step_materialises_that_stage() {
    let base = base_image();
    let recipe = recipe_of(vec![scale_step(2.0), scale_step(3.0), scale_step(5.0)]);
    let mut cache = RenderCache::unbounded();
    let out = render(
        &recipe,
        &base,
        &test_registry(),
        &mut cache,
        &OpContext::new(),
        RenderOptions::full().stopping_after(1),
    )
    .expect("the recipe renders");
    assert_eq!(out.image.data()[0], base.data()[0] * 6.0);
    assert_eq!(out.report.steps.len(), 2);
}

#[test]
fn stopping_after_a_step_the_recipe_does_not_have_is_rejected() {
    let base = base_image();
    let recipe = recipe_of(vec![scale_step(2.0)]);
    let mut cache = RenderCache::unbounded();
    let err = render(
        &recipe,
        &base,
        &test_registry(),
        &mut cache,
        &OpContext::new(),
        RenderOptions::full().stopping_after(3),
    )
    .expect_err("the step index is out of range");
    assert_eq!(
        err,
        RecipeError::StepIndexOutOfRange {
            index: 3,
            step_count: 1
        }
    );
}

// ---------------------------------------------------------------------------
// Cancellation
// ---------------------------------------------------------------------------

#[test]
fn a_cancel_raised_before_the_render_stops_it_immediately() {
    let base = base_image();
    let recipe = recipe_of(vec![scale_step(2.0)]);
    let mut cache = RenderCache::unbounded();
    let ctx = OpContext::new();
    ctx.request_cancel();
    assert_eq!(
        render_full(&recipe, &base, &test_registry(), &mut cache, &ctx)
            .expect_err("the render is cancelled"),
        RecipeError::Cancelled
    );
}

#[test]
fn a_cancel_raised_inside_an_operation_surfaces_as_cancelled() {
    let base = base_image();
    let recipe = recipe_of(vec![RecipeStep::new("test_self_cancel", 1)]);
    let mut cache = RenderCache::unbounded();
    assert_eq!(
        render_full(
            &recipe,
            &base,
            &test_registry(),
            &mut cache,
            &OpContext::new()
        )
        .expect_err("the render is cancelled"),
        RecipeError::Cancelled
    );
}

#[test]
fn a_cancel_between_steps_stops_the_remaining_ones() {
    let base = base_image();
    let recipe = recipe_of(vec![
        RecipeStep::new("test_self_cancel", 1),
        scale_step(2.0),
    ]);
    let mut cache = RenderCache::unbounded();
    let applications = Arc::new(AtomicUsize::new(0));
    let mut registry = OpRegistry::new();
    let scale = ScaleOp {
        version: 1,
        applications: Arc::clone(&applications),
    };
    registry
        .register(Arc::new(scale))
        .expect("test_scale@1 registers");
    registry
        .register(Arc::new(crate::recipe::testkit::SelfCancellingOp))
        .expect("test_self_cancel@1 registers");
    assert_eq!(
        render_full(&recipe, &base, &registry, &mut cache, &OpContext::new())
            .expect_err("the render is cancelled"),
        RecipeError::Cancelled
    );
    assert_eq!(applications.load(Ordering::Relaxed), 0);
}

// ---------------------------------------------------------------------------
// Cache resume
// ---------------------------------------------------------------------------

fn counting_registry() -> (OpRegistry, Arc<AtomicUsize>) {
    let applications = Arc::new(AtomicUsize::new(0));
    let mut registry = OpRegistry::new();
    registry
        .register(Arc::new(ScaleOp {
            version: 1,
            applications: Arc::clone(&applications),
        }))
        .expect("test_scale@1 registers");
    (registry, applications)
}

#[test]
fn editing_a_step_replays_only_that_step_and_the_ones_above_it() {
    let base = base_image();
    let (registry, applications) = counting_registry();
    let mut cache = RenderCache::unbounded();
    let ctx = OpContext::new();

    let mut recipe = recipe_of(vec![scale_step(2.0), scale_step(3.0), scale_step(5.0)]);
    render_full(&recipe, &base, &registry, &mut cache, &ctx).expect("first render");
    assert_eq!(applications.load(Ordering::Relaxed), 3);

    recipe.steps[2].params = scale_params(7.0);
    render_full(&recipe, &base, &registry, &mut cache, &ctx).expect("edit the top step");
    assert_eq!(applications.load(Ordering::Relaxed), 4);

    recipe.steps[0].params = scale_params(11.0);
    render_full(&recipe, &base, &registry, &mut cache, &ctx).expect("edit the bottom step");
    assert_eq!(applications.load(Ordering::Relaxed), 7);
}

#[test]
fn an_unchanged_recipe_replays_nothing() {
    let base = base_image();
    let (registry, applications) = counting_registry();
    let mut cache = RenderCache::unbounded();
    let ctx = OpContext::new();
    let recipe = recipe_of(vec![scale_step(2.0), scale_step(3.0)]);

    let first = render_full(&recipe, &base, &registry, &mut cache, &ctx).expect("first render");
    let second = render_full(&recipe, &base, &registry, &mut cache, &ctx).expect("second render");
    assert_eq!(applications.load(Ordering::Relaxed), 2);
    assert_eq!(second.report.resumed_at, 2);
    assert_eq!(second.report.cache_hits, 1);
    assert_pixels_identical(&first.image, &second.image, "warm replay");
    assert_eq!(first.report.steps, second.report.steps);
}

#[test]
fn a_cache_hit_reports_the_steps_it_did_not_run() {
    let base = base_image();
    let (registry, _) = counting_registry();
    let mut cache = RenderCache::unbounded();
    let ctx = OpContext::new();
    let recipe = recipe_of(vec![scale_step(2.0), scale_step(3.0)]);
    render_full(&recipe, &base, &registry, &mut cache, &ctx).expect("first render");
    let warm = render_full(&recipe, &base, &registry, &mut cache, &ctx).expect("warm render");
    assert_eq!(warm.report.steps.len(), 2);
    assert!(warm
        .report
        .steps
        .iter()
        .all(|s| s.outcome == StepOutcome::Applied));
}

#[test]
fn a_disabled_step_above_a_cached_boundary_still_reports() {
    let base = base_image();
    let (registry, applications) = counting_registry();
    let mut cache = RenderCache::unbounded();
    let ctx = OpContext::new();

    let mut recipe = recipe_of(vec![scale_step(2.0), scale_step(3.0)]);
    render_full(&recipe, &base, &registry, &mut cache, &ctx).expect("first render");
    assert_eq!(applications.load(Ordering::Relaxed), 2);

    recipe.steps[1].enabled = false;
    let out = render_full(&recipe, &base, &registry, &mut cache, &ctx).expect("toggled render");
    assert_eq!(
        applications.load(Ordering::Relaxed),
        2,
        "disabling the top step replays nothing"
    );
    assert_eq!(out.report.steps.len(), 2);
    assert_eq!(out.report.steps[0].outcome, StepOutcome::Applied);
    assert_eq!(out.report.steps[1].outcome, StepOutcome::Disabled);
    assert_eq!(out.image.data()[0], base.data()[0] * 2.0);
}

#[test]
fn a_run_of_disabled_steps_does_not_collapse_the_report() {
    let base = base_image();
    let (registry, _) = counting_registry();
    let mut cache = RenderCache::unbounded();
    let ctx = OpContext::new();
    let recipe = recipe_of(vec![
        scale_step(2.0),
        scale_step(3.0).with_enabled(false),
        scale_step(5.0).with_enabled(false),
        scale_step(7.0),
    ]);
    render_full(&recipe, &base, &registry, &mut cache, &ctx).expect("first render");
    let warm = render_full(&recipe, &base, &registry, &mut cache, &ctx).expect("warm render");
    assert_eq!(
        warm.report
            .steps
            .iter()
            .map(|s| s.index)
            .collect::<Vec<_>>(),
        vec![0, 1, 2, 3]
    );
    assert_eq!(warm.report.steps[1].outcome, StepOutcome::Disabled);
    assert_eq!(warm.report.steps[2].outcome, StepOutcome::Disabled);
}

// ---------------------------------------------------------------------------
// Preview
// ---------------------------------------------------------------------------

#[test]
fn a_preview_renders_over_the_requested_level() {
    let base = base_image();
    let pyramid =
        ImagePyramid::build_with_min_dimension(Arc::clone(&base), 4).expect("the pyramid builds");
    let recipe = recipe_of(vec![scale_step(2.0)]);
    let mut cache = RenderCache::unbounded();
    let out = render_preview(
        &recipe,
        &pyramid,
        1,
        &test_registry(),
        &mut cache,
        &OpContext::new(),
    )
    .expect("the preview renders");
    assert_eq!(out.report.level, 1);
    assert_eq!(out.image.width(), base.width() / 2);
    assert_eq!(out.image.height(), base.height() / 2);
}

#[test]
fn a_preview_level_the_pyramid_does_not_have_is_rejected() {
    let base = base_image();
    let pyramid =
        ImagePyramid::build_with_min_dimension(Arc::clone(&base), 4).expect("the pyramid builds");
    let recipe = recipe_of(vec![scale_step(2.0)]);
    let mut cache = RenderCache::unbounded();
    let err = render_preview(
        &recipe,
        &pyramid,
        99,
        &test_registry(),
        &mut cache,
        &OpContext::new(),
    )
    .expect_err("the level is out of range");
    assert_eq!(
        err,
        RecipeError::LevelOutOfRange {
            level: 99,
            level_count: pyramid.level_count(),
        }
    );
}

#[test]
fn a_preview_and_a_full_render_do_not_share_a_cache_entry() {
    let base = base_image();
    let pyramid =
        ImagePyramid::build_with_min_dimension(Arc::clone(&base), 4).expect("the pyramid builds");
    let (registry, applications) = counting_registry();
    let recipe = recipe_of(vec![scale_step(2.0)]);
    let mut cache = RenderCache::unbounded();
    render_full(&recipe, &base, &registry, &mut cache, &OpContext::new())
        .expect("the full render runs");
    render_preview(
        &recipe,
        &pyramid,
        1,
        &registry,
        &mut cache,
        &OpContext::new(),
    )
    .expect("the preview runs");
    assert_eq!(applications.load(Ordering::Relaxed), 2);
}

#[test]
fn the_step_outcome_wire_tokens_are_stable() {
    assert_eq!(StepOutcome::Applied.as_wire(), "applied");
    assert_eq!(StepOutcome::Disabled.as_wire(), "disabled");
    assert_eq!(
        StepOutcome::Skipped {
            reason: "x".to_string()
        }
        .as_wire(),
        "skipped"
    );
}

#[test]
fn the_cancel_poll_budget_is_re_exported_for_operation_authors() {
    assert_eq!(OP_CANCEL_POLL_PIXELS, crate::recipe::CANCEL_POLL_PIXELS);
}
