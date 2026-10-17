//! Recipe validation and replay.
//!
//! A render walks the step list in order over a base image, consulting the
//! step-boundary cache for the deepest prefix already computed and applying only
//! the steps above it. The result carries a report naming every step and what
//! happened to it, so a caller can state what ran without inspecting pixels.
//!
//! # Stage ordering
//!
//! One rule is enforced at validation time: no linear-stage operation may sit
//! after a stretched-stage one. The rule reads the whole step list, enabled or
//! not, because a disabled step keeps its place in the order and re-enabling it
//! must not turn a valid recipe invalid. The one step it cannot read is a
//! disabled one naming an operation this build does not carry: an unregistered
//! operation has no stage here, so it orders nothing and blocks nothing until it
//! is enabled.
//!
//! # Cancellation
//!
//! The cancel flag is polled before each step and after the last. Operations
//! poll it inside their own loops (see [`CANCEL_POLL_PIXELS`]), so a long single
//! step aborts too.

use std::sync::Arc;

use serde_json::Value;

use super::cache::{CacheKey, RenderCache};
use super::model::{
    OpApplied, OpContext, OpError, OpImage, OpStage, Recipe, RecipeError, CANCEL_POLL_PIXELS,
};
use super::pyramid::ImagePyramid;
use super::registry::OpRegistry;

/// What happened to one step in a render.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StepOutcome {
    /// The operation ran and produced the image passed to the next step.
    Applied,
    /// The step is disabled; the image passed through untouched.
    Disabled,
    /// The operation reported a capability it needs as unavailable. The image
    /// passed through untouched and the reason is recorded — never a silent
    /// no-op.
    Skipped {
        /// Why the operation could not run, in the words the user reads.
        reason: String,
    },
}

impl StepOutcome {
    /// The `camelCase` wire token.
    pub fn as_wire(&self) -> &'static str {
        match self {
            StepOutcome::Applied => "applied",
            StepOutcome::Disabled => "disabled",
            StepOutcome::Skipped { .. } => "skipped",
        }
    }
}

/// One line of a render report.
#[derive(Debug, Clone, PartialEq)]
pub struct StepReport {
    /// Index of the step in the recipe.
    pub index: usize,
    /// Operation id.
    pub op_id: String,
    /// Operation version.
    pub op_version: u32,
    /// What happened.
    pub outcome: StepOutcome,
    /// What the operation solved while it ran (see [`OpApplied::measurement`]),
    /// or `None` when it measured nothing and for every outcome but
    /// [`StepOutcome::Applied`] — a step that did not run measured nothing.
    ///
    /// It travels into the boundary cache with the image, so a render served
    /// from the cache reports the same measurement the render that computed it
    /// did.
    pub measurement: Option<Value>,
}

/// What a render did, step by step.
#[derive(Debug, Clone, PartialEq)]
pub struct RenderReport {
    /// Pyramid level the render ran at; `0` is full resolution.
    pub level: u32,
    /// One entry per step the render covered, in order.
    pub steps: Vec<StepReport>,
    /// Index of the first step actually executed. Steps below it were served
    /// from the cache.
    pub resumed_at: usize,
    /// Boundary lookups served from the cache during this render.
    pub cache_hits: usize,
    /// Boundary lookups that had to be computed during this render.
    pub cache_misses: usize,
}

impl RenderReport {
    /// Steps the render recorded as explicitly skipped.
    pub fn skipped(&self) -> impl Iterator<Item = &StepReport> {
        self.steps
            .iter()
            .filter(|s| matches!(s.outcome, StepOutcome::Skipped { .. }))
    }

    /// Whether any step was recorded as explicitly skipped.
    pub fn has_skips(&self) -> bool {
        self.skipped().next().is_some()
    }
}

/// A rendered image and the report describing how it was produced.
#[derive(Debug, Clone)]
pub struct RenderOutput {
    /// The rendered image.
    pub image: Arc<OpImage>,
    /// What each step did.
    pub report: RenderReport,
}

/// What a render is asked for.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct RenderOptions {
    /// Pyramid level; `0` is full resolution.
    pub level: u32,
    /// Render only through this step index. `None` renders the whole stack.
    /// This is how a stage master ("after step N") is materialised without
    /// storing one.
    pub stop_after: Option<usize>,
    /// How the caller identifies the master these base pixels came from.
    ///
    /// The step-boundary key carries it, because `Recipe::base_master_ref` names
    /// the master a recipe was authored on rather than the one this render is
    /// reading. Without it, replaying one recipe over a second master of the
    /// same geometry hits the first master's boundaries and returns the first
    /// master's pixels. A caller with no master to name leaves it empty, which
    /// keys distinctly from every caller that names one.
    pub base_identity: String,
}

impl RenderOptions {
    /// Full resolution, whole stack, no master named.
    pub fn full() -> Self {
        Self::default()
    }

    /// The same options stopping after step `index`.
    pub fn stopping_after(mut self, index: usize) -> Self {
        self.stop_after = Some(index);
        self
    }

    /// The same options at pyramid level `level`.
    pub fn at_level(mut self, level: u32) -> Self {
        self.level = level;
        self
    }

    /// The same options naming the master the base pixels were read from.
    pub fn over_master(mut self, identity: impl Into<String>) -> Self {
        self.base_identity = identity.into();
        self
    }
}

/// Check a recipe without touching pixels.
///
/// Validates the schema version, the branch link, that every *enabled* step
/// names a registered operation, that every registered step's parameters pass
/// that operation's own validation, and the stage ordering rule.
///
/// A disabled step naming an operation this build does not carry is not a
/// blocker: the render never reaches it, so refusing the whole recipe would
/// strand every step below it. The step is still reported as unregistered by the
/// callers that list steps one by one — see `api_darkroom_validate` — and
/// enabling it puts the operation back on the render path, where it is
/// [`RecipeError::UnknownOp`] again.
pub fn validate(recipe: &Recipe, registry: &OpRegistry) -> Result<(), RecipeError> {
    if recipe.schema_version != super::model::RECIPE_SCHEMA_VERSION {
        return Err(RecipeError::UnsupportedSchemaVersion {
            found: recipe.schema_version,
        });
    }
    if let Some(parent) = &recipe.parent {
        if parent.recipe_id == recipe.id {
            return Err(RecipeError::InvalidParent {
                reason: format!("recipe '{}' lists itself as its parent", recipe.id),
            });
        }
        if parent.divergence_index > recipe.steps.len() {
            return Err(RecipeError::InvalidParent {
                reason: format!(
                    "divergence index {} is past the end of a {}-step recipe",
                    parent.divergence_index,
                    recipe.steps.len()
                ),
            });
        }
    }

    let mut first_stretched: Option<(usize, String)> = None;
    for (index, step) in recipe.steps.iter().enumerate() {
        let Some(op) = registry.get(&step.op_id, step.op_version) else {
            if step.enabled {
                return Err(RecipeError::UnknownOp {
                    index,
                    op_id: step.op_id.clone(),
                    op_version: step.op_version,
                });
            }
            // A disabled step this build cannot run keeps its place in the list
            // and contributes nothing to the stage rule: an operation the
            // registry does not carry has no stage here to order against.
            continue;
        };
        op.validate_params(&step.params)
            .map_err(|source| RecipeError::InvalidParams {
                index,
                op_id: step.op_id.clone(),
                op_version: step.op_version,
                source: Box::new(source),
            })?;
        match op.stage() {
            OpStage::Stretched => {
                if first_stretched.is_none() {
                    first_stretched = Some((index, step.op_id.clone()));
                }
            }
            OpStage::Linear => {
                if let Some((blocking_index, blocking_op_id)) = &first_stretched {
                    return Err(RecipeError::StageOrder {
                        index,
                        op_id: step.op_id.clone(),
                        op_version: step.op_version,
                        blocking_index: *blocking_index,
                        blocking_op_id: blocking_op_id.clone(),
                    });
                }
            }
        }
    }
    Ok(())
}

/// Replay `recipe` over `base`.
///
/// The base image is the pixels `recipe.base_master_ref` names, at the pyramid
/// level `opts.level` states. The cache is consulted for the deepest already
/// computed prefix and updated at every boundary the render crosses.
pub fn render(
    recipe: &Recipe,
    base: &Arc<OpImage>,
    registry: &OpRegistry,
    cache: &mut RenderCache,
    ctx: &OpContext,
    opts: RenderOptions,
) -> Result<RenderOutput, RecipeError> {
    validate(recipe, registry)?;
    if base.is_empty() {
        return Err(RecipeError::BaseImage {
            source: Box::new(OpError::EmptyImage),
        });
    }

    let step_count = recipe.steps.len();
    let last = match opts.stop_after {
        Some(index) if index >= step_count => {
            return Err(RecipeError::StepIndexOutOfRange { index, step_count })
        }
        Some(index) => Some(index),
        None => recipe.last_index(),
    };

    let ctx = ctx.clone().at_level(opts.level);
    ctx.check_cancel().map_err(|_| RecipeError::Cancelled)?;

    let Some(last) = last else {
        return Ok(RenderOutput {
            image: Arc::clone(base),
            report: RenderReport {
                level: opts.level,
                steps: Vec::new(),
                resumed_at: 0,
                cache_hits: 0,
                cache_misses: 0,
            },
        });
    };

    let mut hits = 0usize;
    let mut misses = 0usize;

    // The deepest cached boundary at or below `last` is the resume point. A
    // boundary is a resume point for step `index` only when its report covers
    // exactly steps `0..=index`: a run of disabled steps shares one key with the
    // boundary below it, and resuming at the wrong one would drop those steps
    // from the report.
    let mut image = Arc::clone(base);
    let mut reports: Vec<StepReport> = Vec::new();
    let mut resume_at = 0usize;
    for index in (0..=last).rev() {
        let key = CacheKey::for_prefix(recipe, &opts.base_identity, base, &ctx, index);
        match cache.get(&key) {
            Some((cached_image, cached_reports)) if cached_reports.len() == index + 1 => {
                hits += 1;
                image = cached_image;
                reports = (*cached_reports).clone();
                resume_at = index + 1;
                break;
            }
            Some(_) | None => misses += 1,
        }
    }

    for index in resume_at..=last {
        ctx.check_cancel().map_err(|_| RecipeError::Cancelled)?;
        let step = &recipe.steps[index];
        if !step.enabled {
            reports.push(StepReport {
                index,
                op_id: step.op_id.clone(),
                op_version: step.op_version,
                outcome: StepOutcome::Disabled,
                measurement: None,
            });
            continue;
        }
        let op =
            registry
                .get(&step.op_id, step.op_version)
                .ok_or_else(|| RecipeError::UnknownOp {
                    index,
                    op_id: step.op_id.clone(),
                    op_version: step.op_version,
                })?;
        match op.apply_measured(&image, &step.params, &ctx) {
            Ok(OpApplied {
                image: next,
                measurement,
            }) => {
                image = Arc::new(next);
                reports.push(StepReport {
                    index,
                    op_id: step.op_id.clone(),
                    op_version: step.op_version,
                    outcome: StepOutcome::Applied,
                    measurement,
                });
            }
            Err(OpError::Unavailable { reason, .. }) => {
                reports.push(StepReport {
                    index,
                    op_id: step.op_id.clone(),
                    op_version: step.op_version,
                    outcome: StepOutcome::Skipped { reason },
                    measurement: None,
                });
            }
            Err(OpError::Cancelled) => return Err(RecipeError::Cancelled),
            Err(source) => {
                return Err(RecipeError::Step {
                    index,
                    source: Box::new(source),
                })
            }
        }
        let key = CacheKey::for_prefix(recipe, &opts.base_identity, base, &ctx, index);
        cache.insert(key, Arc::clone(&image), Arc::new(reports.clone()));
    }

    ctx.check_cancel().map_err(|_| RecipeError::Cancelled)?;

    Ok(RenderOutput {
        image,
        report: RenderReport {
            level: opts.level,
            steps: reports,
            resumed_at: resume_at,
            cache_hits: hits,
            cache_misses: misses,
        },
    })
}

/// Replay the whole recipe at full resolution.
pub fn render_full(
    recipe: &Recipe,
    base: &Arc<OpImage>,
    registry: &OpRegistry,
    cache: &mut RenderCache,
    ctx: &OpContext,
) -> Result<RenderOutput, RecipeError> {
    render(recipe, base, registry, cache, ctx, RenderOptions::full())
}

/// Replay the whole recipe over one level of a pyramid built from the base
/// master.
///
/// The pyramid is built once per base image; a parameter drag re-renders over
/// the same level, so the downsample cost is paid once rather than per frame.
pub fn render_preview(
    recipe: &Recipe,
    pyramid: &ImagePyramid,
    level: u32,
    registry: &OpRegistry,
    cache: &mut RenderCache,
    ctx: &OpContext,
) -> Result<RenderOutput, RecipeError> {
    let base = pyramid.level(level).ok_or(RecipeError::LevelOutOfRange {
        level,
        level_count: pyramid.level_count(),
    })?;
    render(
        recipe,
        base,
        registry,
        cache,
        ctx,
        RenderOptions::full().at_level(level),
    )
}

/// The pixel budget between cancel polls, re-exported for operation authors.
pub const OP_CANCEL_POLL_PIXELS: usize = CANCEL_POLL_PIXELS;

#[cfg(test)]
#[path = "render_tests.rs"]
mod render_tests;
