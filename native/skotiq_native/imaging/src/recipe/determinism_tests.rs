//! The determinism contract, exercised over synthetic images.
//!
//! Every case renders the same recipe cold twice, warm twice, and with the cache
//! switched off, and asserts the results are byte-identical. A property sweep
//! covers a spread of geometries, channel counts and seeds so a defect that only
//! shows on an odd width or a colour master is not hidden by one lucky size.

use std::sync::Arc;

use serde_json::json;

use super::testkit::{
    assert_deterministic, assert_pixels_identical, fixed_catalog, scale_params,
    synthetic_star_field, test_registry, ScaleOp,
};
use super::*;

fn recipe_of(steps: Vec<RecipeStep>) -> Recipe {
    let mut recipe = Recipe::new("rec", "master-1", RecipeAuthor::User);
    recipe.steps = steps;
    recipe
}

fn full_stack() -> Recipe {
    recipe_of(vec![
        RecipeStep::new("test_scale", 1).with_params(scale_params(1.5)),
        RecipeStep::new("test_catalog", 1),
        RecipeStep::new("test_crop", 1).with_params(json!({"margin": 2})),
        RecipeStep::new("test_scale", 1)
            .with_params(scale_params(9.0))
            .with_enabled(false),
        RecipeStep::new("test_stretch", 1).with_params(json!({"gamma": 0.45, "pivot": 12000.0})),
        RecipeStep::new("test_curves", 1).with_params(json!({"lift": 0.02})),
    ])
}

#[test]
fn a_full_stack_renders_identically_cold_warm_and_uncached() {
    let base = Arc::new(synthetic_star_field(64, 48, 1, 21));
    assert_deterministic(
        &full_stack(),
        &base,
        &test_registry(),
        &OpContext::new().with_catalog(fixed_catalog()),
        RenderOptions::full(),
    )
    .expect("the stack renders");
}

#[test]
fn a_stack_with_a_skipped_step_renders_identically() {
    let base = Arc::new(synthetic_star_field(64, 48, 1, 22));
    let out = assert_deterministic(
        &full_stack(),
        &base,
        &test_registry(),
        &OpContext::new(),
        RenderOptions::full(),
    )
    .expect("the stack renders");
    assert!(
        out.report.has_skips(),
        "no catalog is attached, so the catalog step must record a skip"
    );
}

#[test]
fn a_stack_carrying_a_disabled_step_this_build_cannot_run_renders_identically() {
    let base = Arc::new(synthetic_star_field(64, 48, 1, 23));
    let registry = test_registry();
    let ctx = OpContext::new().with_catalog(fixed_catalog());
    let mut carrying = full_stack();
    carrying
        .steps
        .insert(2, RecipeStep::new("no_such_op", 4).with_enabled(false));

    let carried = assert_deterministic(&carrying, &base, &registry, &ctx, RenderOptions::full())
        .expect("a step this build cannot run is disabled, so the stack still renders");
    let plain = assert_deterministic(&full_stack(), &base, &registry, &ctx, RenderOptions::full())
        .expect("the same stack without it renders");
    assert_pixels_identical(&carried.image, &plain.image, "disabled unregistered step");
}

#[test]
fn every_geometry_and_channel_count_renders_identically() {
    let registry = test_registry();
    let ctx = OpContext::new().with_catalog(fixed_catalog());
    for (width, height, channels, seed) in [
        (17_u32, 13_u32, 1_u32, 1_u64),
        (32, 32, 1, 2),
        (33, 31, 1, 3),
        (48, 32, 3, 4),
        (31, 47, 3, 5),
        (64, 16, 3, 6),
    ] {
        let base = Arc::new(synthetic_star_field(width, height, channels, seed));
        assert_deterministic(&full_stack(), &base, &registry, &ctx, RenderOptions::full())
            .unwrap_or_else(|e| panic!("{width}x{height}x{channels} seed {seed} failed: {e}"));
    }
}

#[test]
fn every_stage_boundary_renders_identically() {
    let base = Arc::new(synthetic_star_field(48, 40, 1, 31));
    let recipe = full_stack();
    let registry = test_registry();
    let ctx = OpContext::new().with_catalog(fixed_catalog());
    for index in 0..recipe.steps.len() {
        assert_deterministic(
            &recipe,
            &base,
            &registry,
            &ctx,
            RenderOptions::full().stopping_after(index),
        )
        .unwrap_or_else(|e| panic!("stage {index} failed: {e}"));
    }
}

#[test]
fn every_pyramid_level_renders_identically() {
    let base = Arc::new(synthetic_star_field(96, 64, 1, 41));
    let pyramid =
        ImagePyramid::build_with_min_dimension(Arc::clone(&base), 8).expect("the pyramid builds");
    let recipe = full_stack();
    let registry = test_registry();
    let ctx = OpContext::new().with_catalog(fixed_catalog());
    for level in 0..pyramid.level_count() {
        let level_base = pyramid.level(level).expect("the level exists");
        assert_deterministic(
            &recipe,
            level_base,
            &registry,
            &ctx,
            RenderOptions::full().at_level(level),
        )
        .unwrap_or_else(|e| panic!("level {level} failed: {e}"));
    }
}

#[test]
fn a_stage_render_matches_the_prefix_of_the_full_render() {
    let base = Arc::new(synthetic_star_field(48, 40, 1, 51));
    let registry = test_registry();
    let ctx = OpContext::new().with_catalog(fixed_catalog());
    let mut recipe = full_stack();
    recipe.steps.truncate(2);

    let mut cache = RenderCache::unbounded();
    let staged = render(
        &recipe,
        &base,
        &registry,
        &mut cache,
        &ctx,
        RenderOptions::full().stopping_after(1),
    )
    .expect("the staged render runs");

    let mut prefix = recipe.clone();
    prefix.steps.truncate(2);
    let mut fresh = RenderCache::unbounded();
    let whole =
        render_full(&prefix, &base, &registry, &mut fresh, &ctx).expect("the prefix render runs");
    assert_pixels_identical(&staged.image, &whole.image, "stage vs prefix");
}

#[test]
fn an_old_operation_version_keeps_rendering_what_it_always_did() {
    let base = Arc::new(synthetic_star_field(32, 32, 1, 61));
    let registry = test_registry();
    let ctx = OpContext::new();

    let v1 = recipe_of(vec![
        RecipeStep::new("test_scale", 1).with_params(scale_params(2.0))
    ]);
    let v2 = recipe_of(vec![
        RecipeStep::new("test_scale", 2).with_params(scale_params(2.0))
    ]);

    let mut cache = RenderCache::unbounded();
    let out_v1 = render_full(&v1, &base, &registry, &mut cache, &ctx).expect("v1 renders");
    let out_v2 = render_full(&v2, &base, &registry, &mut cache, &ctx).expect("v2 renders");

    assert_eq!(out_v1.image.data()[0], base.data()[0] * 2.0);
    assert_eq!(
        out_v2.image.data()[0],
        base.data()[0] * 4.0,
        "version 2 renders differently, and version 1 still renders the old pixels"
    );

    let mut cold = RenderCache::unbounded();
    let again = render_full(&v1, &base, &registry, &mut cold, &ctx).expect("v1 renders again");
    assert_pixels_identical(&out_v1.image, &again.image, "version 1 replay");
}

#[test]
fn a_cache_hit_and_a_cache_miss_agree_after_an_edit() {
    let base = Arc::new(synthetic_star_field(48, 48, 1, 71));
    let registry = test_registry();
    let ctx = OpContext::new().with_catalog(fixed_catalog());
    let mut warm = RenderCache::unbounded();

    let mut recipe = full_stack();
    render_full(&recipe, &base, &registry, &mut warm, &ctx).expect("the first render runs");

    for factor in [2.0_f64, 3.5, 0.25, 7.0] {
        recipe.steps[0].params = scale_params(factor);
        let from_cache =
            render_full(&recipe, &base, &registry, &mut warm, &ctx).expect("the warm render runs");
        let mut cold = RenderCache::unbounded();
        let from_scratch =
            render_full(&recipe, &base, &registry, &mut cold, &ctx).expect("the cold render runs");
        assert_pixels_identical(
            &from_cache.image,
            &from_scratch.image,
            "edited step, warm vs cold",
        );
        assert_eq!(from_cache.report.steps, from_scratch.report.steps);
    }
}

#[test]
fn toggling_a_step_off_and_on_returns_the_original_pixels() {
    let base = Arc::new(synthetic_star_field(40, 40, 1, 81));
    let registry = test_registry();
    let ctx = OpContext::new().with_catalog(fixed_catalog());
    let mut cache = RenderCache::unbounded();
    let mut recipe = full_stack();

    let before = render_full(&recipe, &base, &registry, &mut cache, &ctx).expect("first render");
    recipe.steps[0].enabled = false;
    render_full(&recipe, &base, &registry, &mut cache, &ctx).expect("toggled off");
    recipe.steps[0].enabled = true;
    let after = render_full(&recipe, &base, &registry, &mut cache, &ctx).expect("toggled back on");
    assert_pixels_identical(&before.image, &after.image, "toggle round trip");
}

#[test]
fn reordering_two_linear_steps_changes_nothing_that_should_not_change() {
    let base = Arc::new(synthetic_star_field(32, 32, 1, 91));
    let registry = test_registry();
    let ctx = OpContext::new();
    let mut cache = RenderCache::unbounded();

    let forward = recipe_of(vec![
        RecipeStep::new("test_scale", 1).with_params(scale_params(2.0)),
        RecipeStep::new("test_crop", 1).with_params(json!({"margin": 3})),
    ]);
    let reversed = recipe_of(vec![
        RecipeStep::new("test_crop", 1).with_params(json!({"margin": 3})),
        RecipeStep::new("test_scale", 1).with_params(scale_params(2.0)),
    ]);
    let a = render_full(&forward, &base, &registry, &mut cache, &ctx).expect("forward renders");
    let b = render_full(&reversed, &base, &registry, &mut cache, &ctx).expect("reversed renders");
    assert_pixels_identical(&a.image, &b.image, "scale and crop commute");
    assert_eq!(
        a.image.header().get_float("CRPIX1"),
        b.image.header().get_float("CRPIX1")
    );
}

#[test]
fn a_recipe_survives_a_json_round_trip_and_renders_the_same() {
    let base = Arc::new(synthetic_star_field(40, 32, 3, 101));
    let registry = test_registry();
    let ctx = OpContext::new().with_catalog(fixed_catalog());
    let recipe = full_stack();

    let mut cache = RenderCache::unbounded();
    let direct = render_full(&recipe, &base, &registry, &mut cache, &ctx).expect("direct render");

    let json = recipe.to_json().expect("the recipe encodes");
    let decoded = Recipe::from_json(&json).expect("the recipe decodes");
    let mut fresh = RenderCache::unbounded();
    let replayed =
        render_full(&decoded, &base, &registry, &mut fresh, &ctx).expect("replayed render");

    assert_pixels_identical(&direct.image, &replayed.image, "json round trip");
    assert_eq!(direct.report.steps, replayed.report.steps);
}

#[test]
fn the_builtin_registry_renders_an_empty_recipe_and_refuses_an_unregistered_operation() {
    let base = Arc::new(synthetic_star_field(16, 16, 1, 111));
    let registry = OpRegistry::builtin().expect("the builtin list registers cleanly");
    let empty = Recipe::new("rec", "master-1", RecipeAuthor::Autopilot);
    assert_deterministic(
        &empty,
        &base,
        &registry,
        &OpContext::new(),
        RenderOptions::full(),
    )
    .expect("an empty recipe renders against the builtin registry");

    let with_step = recipe_of(vec![RecipeStep::new("background_extract", 99)]);
    let mut cache = RenderCache::unbounded();
    assert!(matches!(
        render_full(&with_step, &base, &registry, &mut cache, &OpContext::new()),
        Err(RecipeError::UnknownOp { .. })
    ));
}

#[test]
fn the_operation_ordering_rule_holds_for_every_pair_of_stages() {
    let registry = test_registry();
    let linear = RecipeStep::new("test_scale", 1).with_params(scale_params(2.0));
    let stretched = RecipeStep::new("test_stretch", 1);
    assert_eq!(
        validate(
            &recipe_of(vec![linear.clone(), stretched.clone()]),
            &registry
        ),
        Ok(())
    );
    assert_eq!(
        validate(&recipe_of(vec![linear.clone(), linear.clone()]), &registry),
        Ok(())
    );
    assert_eq!(
        validate(
            &recipe_of(vec![stretched.clone(), stretched.clone()]),
            &registry
        ),
        Ok(())
    );
    assert!(matches!(
        validate(&recipe_of(vec![stretched, linear]), &registry),
        Err(RecipeError::StageOrder { .. })
    ));
}

#[test]
fn a_registered_operation_that_never_runs_costs_nothing() {
    let base = Arc::new(synthetic_star_field(24, 24, 1, 121));
    let applications = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let mut registry = OpRegistry::new();
    registry
        .register(Arc::new(ScaleOp {
            version: 1,
            applications: Arc::clone(&applications),
        }))
        .expect("test_scale@1 registers");
    let recipe = recipe_of(vec![RecipeStep::new("test_scale", 1)
        .with_params(scale_params(2.0))
        .with_enabled(false)]);
    let mut cache = RenderCache::unbounded();
    let out = render_full(&recipe, &base, &registry, &mut cache, &OpContext::new())
        .expect("the recipe renders");
    assert_eq!(
        applications.load(std::sync::atomic::Ordering::Relaxed),
        0,
        "a disabled step never reaches the operation"
    );
    assert_pixels_identical(&out.image, &base, "all steps disabled");
}
