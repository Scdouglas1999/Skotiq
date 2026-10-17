//! Cache keying and eviction.

use std::sync::Arc;

use serde_json::json;

use super::*;
use crate::recipe::model::{OpContext, RecipeAuthor, RecipeStep};
use crate::recipe::render::{StepOutcome, StepReport};
use crate::recipe::testkit::{fixed_catalog, fixed_stars, synthetic_star_field, FixedCatalog};

/// The master a render read, in the shape the bridge supplies: the path plus the
/// modification time and length of the bytes it opened.
const MASTER_READ: &str = "/masters/master-1.fits|1788203315655000000|8297280";

/// A second master, of the same geometry as the first and read at the same
/// instant, so only the path separates the two identities.
const OTHER_MASTER_READ: &str = "/masters/master-2.fits|1788203315655000000|8297280";

fn recipe_of(steps: Vec<RecipeStep>) -> Recipe {
    let mut recipe = Recipe::new("rec", "master-1", RecipeAuthor::User);
    recipe.steps = steps;
    recipe
}

fn three_step_recipe() -> Recipe {
    recipe_of(vec![
        RecipeStep::new("test_scale", 1).with_params(json!({"factor": 2.0})),
        RecipeStep::new("test_scale", 1).with_params(json!({"factor": 3.0})),
        RecipeStep::new("test_scale", 1).with_params(json!({"factor": 5.0})),
    ])
}

fn report(index: usize) -> Arc<Vec<StepReport>> {
    Arc::new(
        (0..=index)
            .map(|i| StepReport {
                index: i,
                op_id: "test_scale".to_string(),
                op_version: 1,
                outcome: StepOutcome::Applied,
                measurement: None,
            })
            .collect(),
    )
}

#[test]
fn a_key_is_stable_for_the_same_prefix() {
    let base = synthetic_star_field(8, 8, 1, 1);
    let ctx = OpContext::new();
    let recipe = three_step_recipe();
    assert_eq!(
        CacheKey::for_prefix(&recipe, MASTER_READ, &base, &ctx, 1),
        CacheKey::for_prefix(&recipe, MASTER_READ, &base, &ctx, 1)
    );
}

#[test]
fn editing_a_step_changes_that_boundary_and_the_ones_above_it() {
    let base = synthetic_star_field(8, 8, 1, 1);
    let ctx = OpContext::new();
    let before = three_step_recipe();
    let mut after = three_step_recipe();
    after.steps[1].params = json!({"factor": 4.0});

    assert_eq!(
        CacheKey::for_prefix(&before, MASTER_READ, &base, &ctx, 0),
        CacheKey::for_prefix(&after, MASTER_READ, &base, &ctx, 0),
        "the boundary below the edit is untouched"
    );
    assert_ne!(
        CacheKey::for_prefix(&before, MASTER_READ, &base, &ctx, 1),
        CacheKey::for_prefix(&after, MASTER_READ, &base, &ctx, 1)
    );
    assert_ne!(
        CacheKey::for_prefix(&before, MASTER_READ, &base, &ctx, 2),
        CacheKey::for_prefix(&after, MASTER_READ, &base, &ctx, 2)
    );
}

#[test]
fn disabling_a_step_returns_to_the_key_below_it() {
    let base = synthetic_star_field(8, 8, 1, 1);
    let ctx = OpContext::new();
    let mut recipe = three_step_recipe();
    recipe.steps[2].enabled = false;
    assert_eq!(
        CacheKey::for_prefix(&recipe, MASTER_READ, &base, &ctx, 2),
        CacheKey::for_prefix(&recipe, MASTER_READ, &base, &ctx, 1)
    );
}

#[test]
fn a_disabled_step_this_build_cannot_run_is_absent_from_the_key() {
    let base = synthetic_star_field(8, 8, 1, 1);
    let ctx = OpContext::new();
    let plain = three_step_recipe();
    let mut carrying = three_step_recipe();
    carrying
        .steps
        .insert(1, RecipeStep::new("no_such_op", 4).with_enabled(false));
    assert_eq!(
        CacheKey::for_prefix(&plain, MASTER_READ, &base, &ctx, 0),
        CacheKey::for_prefix(&carrying, MASTER_READ, &base, &ctx, 1),
        "the key names the enabled prefix, and an operation this build lacks contributes no text to it"
    );
    assert_eq!(
        CacheKey::for_prefix(&plain, MASTER_READ, &base, &ctx, 2),
        CacheKey::for_prefix(&carrying, MASTER_READ, &base, &ctx, 3)
    );
}

#[test]
fn one_recipe_over_two_masters_is_two_keys() {
    // The recipe is byte-identical — same id, same `baseMasterRef`, same steps —
    // and the two masters share a geometry, so every other component of the key
    // matches. Only the master actually read differs. Keyed on `baseMasterRef`
    // alone the second render hits the first master's boundary and is handed the
    // first master's pixels under its own path.
    let base = synthetic_star_field(8, 8, 1, 1);
    let ctx = OpContext::new();
    let recipe = three_step_recipe();

    assert_ne!(
        CacheKey::for_prefix(&recipe, MASTER_READ, &base, &ctx, 1),
        CacheKey::for_prefix(&recipe, OTHER_MASTER_READ, &base, &ctx, 1),
        "two masters must not share a step boundary"
    );
}

#[test]
fn the_same_master_rewritten_is_a_different_key() {
    // The bridge's identity carries the modification time and the length, so a
    // path whose bytes were replaced keys differently even though the path did
    // not move.
    let base = synthetic_star_field(8, 8, 1, 1);
    let ctx = OpContext::new();
    let recipe = three_step_recipe();
    let rewritten = "/masters/master-1.fits|1788203315999000000|8297280";

    assert_ne!(
        CacheKey::for_prefix(&recipe, MASTER_READ, &base, &ctx, 0),
        CacheKey::for_prefix(&recipe, rewritten, &base, &ctx, 0),
        "rewriting a master must not leave its old boundaries reachable"
    );
}

#[test]
fn a_different_pyramid_level_is_a_different_key() {
    let base = synthetic_star_field(8, 8, 1, 1);
    let recipe = three_step_recipe();
    assert_ne!(
        CacheKey::for_prefix(&recipe, MASTER_READ, &base, &OpContext::new(), 0),
        CacheKey::for_prefix(
            &recipe,
            MASTER_READ,
            &base,
            &OpContext::new().at_level(1),
            0
        )
    );
}

#[test]
fn attaching_a_catalog_is_a_different_key() {
    let base = synthetic_star_field(8, 8, 1, 1);
    let recipe = three_step_recipe();
    assert_ne!(
        CacheKey::for_prefix(&recipe, MASTER_READ, &base, &OpContext::new(), 0),
        CacheKey::for_prefix(
            &recipe,
            MASTER_READ,
            &base,
            &OpContext::new().with_catalog(fixed_catalog()),
            0
        )
    );
}

#[test]
fn two_catalogs_holding_different_stars_are_different_keys() {
    // The boundary after a colour calibration is the catalogue's answer made
    // pixels. Keying on the star list is what stops the second render of a
    // field whose photometry was refreshed being served the first one's
    // colours — the engine's own guarantee, so no caller has to clear the cache.
    let base = synthetic_star_field(8, 8, 1, 1);
    let recipe = three_step_recipe();
    let first = OpContext::new().with_catalog(fixed_catalog());
    let mut revised = fixed_stars();
    revised[1].v_mag += 0.25;
    let refreshed = OpContext::new().with_catalog(Arc::new(FixedCatalog { stars: revised }));

    assert_ne!(
        CacheKey::for_prefix(&recipe, MASTER_READ, &base, &first, 0),
        CacheKey::for_prefix(&recipe, MASTER_READ, &base, &refreshed, 0)
    );
    assert_eq!(
        CacheKey::for_prefix(&recipe, MASTER_READ, &base, &first, 0),
        CacheKey::for_prefix(
            &recipe,
            MASTER_READ,
            &base,
            &OpContext::new().with_catalog(Arc::new(FixedCatalog {
                stars: fixed_stars()
            })),
            0
        ),
        "the same stars behind a fresh handle must still hit the boundary they produced"
    );
}

#[test]
fn a_different_base_geometry_is_a_different_key() {
    let recipe = three_step_recipe();
    let ctx = OpContext::new();
    assert_ne!(
        CacheKey::for_prefix(
            &recipe,
            MASTER_READ,
            &synthetic_star_field(8, 8, 1, 1),
            &ctx,
            0
        ),
        CacheKey::for_prefix(
            &recipe,
            MASTER_READ,
            &synthetic_star_field(16, 8, 1, 1),
            &ctx,
            0
        )
    );
}

#[test]
fn a_different_base_master_ref_is_a_different_key() {
    let base = synthetic_star_field(8, 8, 1, 1);
    let ctx = OpContext::new();
    let mut other = three_step_recipe();
    other.base_master_ref = "master-2".to_string();
    assert_ne!(
        CacheKey::for_prefix(&three_step_recipe(), MASTER_READ, &base, &ctx, 0),
        CacheKey::for_prefix(&other, MASTER_READ, &base, &ctx, 0)
    );
}

#[test]
fn a_key_fingerprint_is_thirty_two_hex_digits() {
    let base = synthetic_star_field(8, 8, 1, 1);
    let key = CacheKey::for_prefix(
        &three_step_recipe(),
        MASTER_READ,
        &base,
        &OpContext::new(),
        0,
    );
    let fingerprint = key.fingerprint();
    assert_eq!(fingerprint.len(), 32);
    assert!(fingerprint.chars().all(|c| c.is_ascii_hexdigit()));
    assert!(key.as_str().contains("master-1"));
}

#[test]
fn a_stored_boundary_comes_back_with_its_reports() {
    let base = synthetic_star_field(8, 8, 1, 1);
    let key = CacheKey::for_prefix(
        &three_step_recipe(),
        MASTER_READ,
        &base,
        &OpContext::new(),
        0,
    );
    let mut cache = RenderCache::unbounded();
    cache.insert(key.clone(), Arc::new(base.clone()), report(0));
    assert!(cache.contains(&key));
    let (image, reports) = cache.get(&key).expect("the boundary is stored");
    assert_eq!(image.len(), base.len());
    assert_eq!(reports.len(), 1);
    assert_eq!(cache.hits(), 1);
    assert_eq!(cache.misses(), 0);
}

#[test]
fn a_missing_boundary_counts_a_miss() {
    let base = synthetic_star_field(8, 8, 1, 1);
    let key = CacheKey::for_prefix(
        &three_step_recipe(),
        MASTER_READ,
        &base,
        &OpContext::new(),
        0,
    );
    let mut cache = RenderCache::unbounded();
    assert!(cache.get(&key).is_none());
    assert_eq!(cache.misses(), 1);
    cache.reset_stats();
    assert_eq!(cache.misses(), 0);
}

#[test]
fn a_disabled_cache_stores_nothing() {
    let base = synthetic_star_field(8, 8, 1, 1);
    let key = CacheKey::for_prefix(
        &three_step_recipe(),
        MASTER_READ,
        &base,
        &OpContext::new(),
        0,
    );
    let mut cache = RenderCache::disabled();
    cache.insert(key.clone(), Arc::new(base), report(0));
    assert!(cache.is_empty());
    assert!(cache.get(&key).is_none());
}

#[test]
fn the_least_recently_used_boundary_is_evicted_first() {
    let base = synthetic_star_field(8, 8, 1, 1);
    let bytes = base.byte_size();
    let recipe = three_step_recipe();
    let ctx = OpContext::new();
    let keys: Vec<CacheKey> = (0..3)
        .map(|i| CacheKey::for_prefix(&recipe, MASTER_READ, &base, &ctx, i))
        .collect();

    let mut cache = RenderCache::new(bytes * 2);
    let image = Arc::new(base);
    cache.insert(keys[0].clone(), Arc::clone(&image), report(0));
    cache.insert(keys[1].clone(), Arc::clone(&image), report(1));
    // Touch the oldest so the middle one becomes least recently used.
    assert!(cache.get(&keys[0]).is_some());
    cache.insert(keys[2].clone(), Arc::clone(&image), report(2));

    assert_eq!(cache.len(), 2);
    assert!(cache.contains(&keys[0]));
    assert!(!cache.contains(&keys[1]));
    assert!(cache.contains(&keys[2]));
    assert_eq!(cache.used_bytes(), bytes * 2);
}

#[test]
fn a_boundary_larger_than_the_whole_budget_is_not_stored() {
    let base = synthetic_star_field(8, 8, 1, 1);
    let key = CacheKey::for_prefix(
        &three_step_recipe(),
        MASTER_READ,
        &base,
        &OpContext::new(),
        0,
    );
    let mut cache = RenderCache::new(base.byte_size() - 1);
    cache.insert(key.clone(), Arc::new(base), report(0));
    assert!(cache.is_empty());
    assert_eq!(cache.used_bytes(), 0);
}

#[test]
fn re_inserting_a_key_does_not_double_count_its_bytes() {
    let base = synthetic_star_field(8, 8, 1, 1);
    let bytes = base.byte_size();
    let key = CacheKey::for_prefix(
        &three_step_recipe(),
        MASTER_READ,
        &base,
        &OpContext::new(),
        0,
    );
    let mut cache = RenderCache::unbounded();
    let image = Arc::new(base);
    cache.insert(key.clone(), Arc::clone(&image), report(0));
    cache.insert(key, Arc::clone(&image), report(0));
    assert_eq!(cache.len(), 1);
    assert_eq!(cache.used_bytes(), bytes);
}

#[test]
fn clearing_drops_every_boundary_and_keeps_the_counters() {
    let base = synthetic_star_field(8, 8, 1, 1);
    let key = CacheKey::for_prefix(
        &three_step_recipe(),
        MASTER_READ,
        &base,
        &OpContext::new(),
        0,
    );
    let mut cache = RenderCache::unbounded();
    cache.insert(key.clone(), Arc::new(base), report(0));
    assert!(cache.get(&key).is_some());
    cache.clear();
    assert!(cache.is_empty());
    assert_eq!(cache.used_bytes(), 0);
    assert_eq!(cache.hits(), 1);
}

#[test]
fn the_default_cache_carries_the_documented_budget() {
    assert_eq!(
        RenderCache::default().capacity_bytes(),
        DEFAULT_CACHE_CAPACITY_BYTES
    );
}
