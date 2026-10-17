//! DepthLock's foothold in the executor.
//!
//! A Smart Exposure plan may be bound to one revision of a persistent
//! DepthLock goal. The goal itself — its sky region, measurement definition,
//! evidence and verdicts — lives in the host's goal store; this crate only
//! carries the binding and asks the store for a verdict at each batch
//! boundary through [`DepthGoalOps`]. The executor stays the sole acquisition
//! authority: an achieved verdict retires that plan's remaining count, nothing
//! more. Count, time, visibility, pause, safety and cancellation limits are
//! untouched, and the check happens between batches so an in-flight exposure
//! is never aborted for a depth result.

use serde::{Deserialize, Serialize};
use std::sync::Arc;

/// A plan's link to one revision of a DepthLock goal. Serialized in the
/// sequence document under `FilterPlan.depth_goal`.
///
/// The revision is part of the binding on purpose: editing a goal's region
/// or definition produces a new revision with fresh evidence, and a plan
/// authored against the old one must not complete on the new one's verdict
/// (or vice versa).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DepthGoalBinding {
    pub goal_id: String,
    pub revision: u64,
}

/// The evidence behind an achieved verdict, carried on the completion event
/// so the run history can say exactly what finished the plan.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DepthGoalCompletion {
    pub goal_id: String,
    pub revision: u64,
    /// Independent post-selection exposures the verdict rests on.
    pub evidence_frames: u32,
    /// Exposures acquired after the provisional candidate that confirmed it.
    pub confirmation_frames: u32,
    /// Lower-quartile depth score of the accumulated evidence (dimensionless).
    pub score: f64,
    /// The goal's user threshold the conservative score met.
    pub threshold: f64,
}

/// What the goal store answers when the executor asks about a binding.
#[derive(Debug, Clone, PartialEq)]
pub enum DepthGoalVerdict {
    /// Automatic completion is enabled for the goal and its committed
    /// analysis — for exactly this revision, over exactly its current
    /// evidence — is achieved. The plan may finish at this boundary.
    Achieved(DepthGoalCompletion),
    /// Keep running the bounded plan: still collecting, unreliable data,
    /// automation switched off, or advisory-only. `reason` is the store's
    /// own explanation and is only logged.
    Continue { reason: String },
    /// The binding cannot be honored: the goal is gone, its revision moved
    /// on, or the store is unavailable. The executor warns once per plan per
    /// run and continues the bounded plan.
    Unavailable { reason: String },
}

/// Verdict source installed on the executor by the host. Implementations
/// must be cheap and non-blocking: the call sits between exposure batches.
pub trait DepthGoalOps: Send + Sync {
    fn verdict(&self, binding: &DepthGoalBinding) -> DepthGoalVerdict;
}

pub type SharedDepthGoalOps = Arc<dyn DepthGoalOps>;
