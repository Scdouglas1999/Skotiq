//! Per-target integration budget accounting.
//!
//! The TargetHeader runtime (`node::logic::target_header`) installs one
//! [`BudgetState`] per target on the executor's [`BudgetRegistry`] when
//! entering a target with `TargetHeaderConfig::integration_budget()` set.
//!
//! The exposure instruction (`node::instructions::expose`) calls
//! [`BudgetRegistry::record_exposure`] after every successful burst,
//! crediting the burst's wall-clock seconds to the active target and
//! active filter. The next time the TargetHeader checks the budget — at
//! each child boundary — [`BudgetState::is_met`] becomes true and the
//! target completes Success without imaging the remaining children.
//!
//! State is cheap (one `HashMap<String, f64>` per target plus a flag).
//! Lookups are O(1); the registry is keyed by `target_id` (the
//! TargetHeader node id) so the registry survives across multiple
//! TargetHeader entries in the same sequence (e.g. a Loop wrapping a
//! TargetHeader resumes the existing state).

use crate::IntegrationBudget;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;

/// Per-target live integration accounting.
///
/// Cheap to clone (every meaningful field is owned). Serialized into the
/// session checkpoint so pause/resume preserves completed-per-filter time.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct BudgetState {
    /// The TargetHeader node id this state belongs to. Persisted so a
    /// future checkpoint format can audit registry contents.
    pub target_id: String,
    /// Completed integration time per filter, in seconds. Keys are the
    /// `current_filter` strings observed when each exposure burst landed.
    /// Frames captured with no filter (mono camera, OSD) credit to the
    /// empty string `""`.
    pub completed_by_filter: HashMap<String, f64>,
    /// Sum of `completed_by_filter` values, refreshed on every credit. A
    /// derived field, but persisting it avoids a re-scan on every
    /// budget check during a long imaging run.
    pub completed_total_secs: f64,
    /// Sticky flag — once the budget is met, the next TargetHeader
    /// boundary check returns Skipped without re-evaluating. Without
    /// this, a quick burst right at the budget edge would set the flag
    /// at frame N, then a sibling-skip pass would clear the
    /// per-filter cap from the snapshot mid-evaluation and we'd
    /// flip-flop.
    pub budget_met: bool,
    /// The TargetHeader run id the state was last credited under. Used
    /// to detect "the TargetHeader is being re-entered fresh" vs
    /// "TargetHeader is being re-entered after pause/resume on the
    /// same run".
    pub run_id: u64,
}

impl BudgetState {
    pub fn new(target_id: impl Into<String>) -> Self {
        Self {
            target_id: target_id.into(),
            completed_by_filter: HashMap::new(),
            completed_total_secs: 0.0,
            budget_met: false,
            run_id: 0,
        }
    }

    /// Credit `secs` of exposure to `filter` (`None` is stored under `""`).
    /// Refreshes the total. Idempotent only across distinct exposures —
    /// callers must NOT credit the same burst twice.
    pub fn credit(&mut self, filter: Option<&str>, secs: f64) {
        if secs <= 0.0 || !secs.is_finite() {
            return;
        }
        let key = filter.unwrap_or("").to_string();
        let entry = self.completed_by_filter.entry(key).or_insert(0.0);
        *entry += secs;
        self.completed_total_secs += secs;
    }

    /// Evaluate the budget against the current accumulated state.
    ///
    /// Returns the [`BudgetEvaluation`] explaining which constraint
    /// triggered (or None if the budget is not yet met).
    pub fn evaluate(&self, budget: &IntegrationBudget) -> BudgetEvaluation {
        // Total cap fires first — it's the strictest interpretation
        // when both are set ("total = 8h" must hold even if individual
        // filter ratios haven't all filled).
        if budget.total_secs > 0.0 && self.completed_total_secs >= budget.total_secs {
            return BudgetEvaluation::Met {
                reason: BudgetMetReason::TotalReached,
                completed_total: self.completed_total_secs,
                budget_total: budget.total_secs,
            };
        }

        // Per-filter caps. Track which filters have hit their cap so
        // the UI can surface "Ha complete" while OIII still runs.
        let caps = budget.resolved_caps();
        if !caps.is_empty() {
            let mut filters_met = Vec::new();
            let mut all_met = true;
            for (filter, cap) in &caps {
                let done = self.completed_by_filter.get(filter).copied().unwrap_or(0.0);
                if done >= *cap {
                    filters_met.push(filter.clone());
                } else {
                    all_met = false;
                }
            }
            // If every filter with a cap has reached it, the budget is
            // met — there is nothing more for the runtime to do.
            if all_met && !caps.is_empty() {
                return BudgetEvaluation::Met {
                    reason: BudgetMetReason::AllFiltersComplete,
                    completed_total: self.completed_total_secs,
                    budget_total: budget.total_secs,
                };
            }
            return BudgetEvaluation::Open {
                filters_complete: filters_met,
                caps,
            };
        }

        BudgetEvaluation::Open {
            filters_complete: Vec::new(),
            caps: HashMap::new(),
        }
    }

    /// Convenience — true iff [`evaluate`] returned [`BudgetEvaluation::Met`].
    pub fn is_met(&self, budget: &IntegrationBudget) -> bool {
        matches!(self.evaluate(budget), BudgetEvaluation::Met { .. })
    }

    /// Accepted-frame count completed for `filter`, derived from the
    /// accumulated accepted-seconds and the configured per-sub length.
    ///
    /// The budget registry credits ACCEPTED-frame exposure time only
    /// (rejected subs are subtracted upstream in the expose instruction), so
    /// `floor(accepted_secs / sub_secs)` recovers the number of accepted subs
    /// exactly when `sub_secs` matches the exposure's per-frame duration.
    /// Returns `0` for a non-positive `sub_secs` (a misconfigured Count
    /// entry) — fail closed rather than divide by zero.
    pub fn accepted_frames(&self, filter: &str, sub_secs: f64) -> u32 {
        if sub_secs <= 0.0 || !sub_secs.is_finite() {
            return 0;
        }
        let done = self.completed_by_filter.get(filter).copied().unwrap_or(0.0);
        // A tiny epsilon guards against IEEE-754 drift leaving e.g.
        // 60 * 300.0 at 17999.9999997 after repeated additions.
        ((done + 1e-6) / sub_secs).floor().max(0.0) as u32
    }

    /// Per-filter accepted-frame progress for every [`FilterBudgetEntry::Count`]
    /// entry in `budget`, as `(filter, accepted_so_far, desired)`.
    ///
    /// Surfaced so the dashboard can render "Ha 47/60 accepted" rows. Filters
    /// configured with the time-based [`FilterBudgetEntry::Absolute`] /
    /// [`FilterBudgetEntry::Ratio`] variants are omitted (they have no
    /// count target).
    pub fn count_progress(&self, budget: &IntegrationBudget) -> Vec<(String, u32, u32)> {
        let mut rows = Vec::new();
        for (filter, entry) in &budget.per_filter {
            if let crate::FilterBudgetEntry::Count {
                desired_accepted,
                sub_secs,
            } = entry
            {
                rows.push((
                    filter.clone(),
                    self.accepted_frames(filter, *sub_secs),
                    *desired_accepted,
                ));
            }
        }
        rows.sort_by(|a, b| a.0.cmp(&b.0));
        rows
    }
}

/// Why the budget was considered met. Surfaced to the dashboard so the
/// user can tell "we ran out of time on M31's total" from "Ha filled,
/// OIII filled, SII filled — target complete".
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BudgetMetReason {
    /// The wall-clock total cap was hit.
    TotalReached,
    /// Every filter listed in `per_filter` reached its cap.
    AllFiltersComplete,
}

/// Result of [`BudgetState::evaluate`].
#[derive(Debug, Clone)]
pub enum BudgetEvaluation {
    /// Budget is met — TargetHeader should mark remaining children
    /// Skipped and return Success.
    Met {
        reason: BudgetMetReason,
        completed_total: f64,
        /// `0.0` when no total cap was set.
        budget_total: f64,
    },
    /// Budget is open — keep imaging. `filters_complete` lists any
    /// filters that have already hit their per-filter cap (the UI
    /// uses this to colour-flag rows green even before the whole
    /// target is done).
    Open {
        filters_complete: Vec<String>,
        caps: HashMap<String, f64>,
    },
}

impl BudgetEvaluation {
    pub fn is_met(&self) -> bool {
        matches!(self, BudgetEvaluation::Met { .. })
    }
}

/// Shared, async-safe registry of [`BudgetState`] keyed by TargetHeader
/// node id. Lives on the [`crate::node::context::ExecutionContext`] for
/// the duration of a run; persisted into the session checkpoint between
/// pause/resume cycles.
///
/// The registry holds an `Arc<RwLock<HashMap<...>>>` so `ExecutionContext`
/// stays `Clone` (parallel branches share a single registry instance).
#[derive(Debug, Clone, Default)]
pub struct BudgetRegistry {
    inner: Arc<RwLock<BudgetRegistryInner>>,
}

#[derive(Debug, Default)]
struct BudgetRegistryInner {
    by_target: HashMap<String, BudgetState>,
    /// The currently-active TargetHeader. Set by `enter_target` and
    /// cleared by `leave_target`. The exposure instruction reads this
    /// to know which target to credit a burst against.
    active_target: Option<String>,
    /// Active target's budget config (cloned at enter time). `None`
    /// when the active target has no budget configured. The exposure
    /// instruction reads this to resolve per-filter caps when emitting
    /// the structured IntegrationBudget progress event.
    active_budget: Option<IntegrationBudget>,
}

impl BudgetRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    /// Replace the registry contents from a snapshot (used by
    /// checkpoint resume). Active target is cleared — it will be re-set
    /// the next time a TargetHeader is entered.
    pub async fn restore_snapshot(&self, snapshot: BudgetRegistrySnapshot) {
        let mut guard = self.inner.write().await;
        guard.by_target = snapshot
            .states
            .into_iter()
            .map(|s| (s.target_id.clone(), s))
            .collect();
        guard.active_target = None;
    }

    /// Snapshot the registry for checkpoint serialization.
    pub async fn snapshot(&self) -> BudgetRegistrySnapshot {
        let guard = self.inner.read().await;
        BudgetRegistrySnapshot {
            states: guard.by_target.values().cloned().collect(),
        }
    }

    /// Called by [`crate::node::logic::target_header`] on entry. Returns
    /// the freshly-installed (or existing) [`BudgetState`] clone so the
    /// runtime can evaluate it without acquiring a second lock.
    ///
    /// `budget` is the per-target config (cloned into the registry). Pass
    /// `None` when the target has no budget; the registry will still
    /// track exposure time (useful for the UI) but `active_budget()`
    /// will return None so the exposure instruction skips the
    /// IntegrationBudget progress emission.
    pub async fn enter_target(
        &self,
        target_id: &str,
        budget: Option<IntegrationBudget>,
    ) -> BudgetState {
        let mut guard = self.inner.write().await;
        guard.active_target = Some(target_id.to_string());
        guard.active_budget = budget;
        guard
            .by_target
            .entry(target_id.to_string())
            .or_insert_with(|| BudgetState::new(target_id))
            .clone()
    }

    /// Called by the TargetHeader runtime on exit. Clearing
    /// `active_target` prevents any stray late exposure (e.g. a
    /// background recovery action between targets) from being
    /// credited to a target that has already terminated.
    pub async fn leave_target(&self) {
        let mut guard = self.inner.write().await;
        guard.active_target = None;
        guard.active_budget = None;
    }

    /// Read-only snapshot of the active target's budget config (cloned).
    /// Used by the exposure instruction to resolve per-filter caps
    /// before emitting the structured IntegrationBudget progress event.
    pub async fn active_budget(&self) -> Option<IntegrationBudget> {
        self.inner.read().await.active_budget.clone()
    }

    /// Crediting hook for [`crate::node::instructions::expose`]. Returns
    /// the post-credit clone of the active target's state, or `None`
    /// when no TargetHeader is currently active (sequence imaged
    /// without a target — credit nothing, no budget to enforce).
    pub async fn record_exposure(&self, filter: Option<&str>, secs: f64) -> Option<BudgetState> {
        let mut guard = self.inner.write().await;
        let active = guard.active_target.clone()?;
        let entry = guard
            .by_target
            .entry(active.clone())
            .or_insert_with(|| BudgetState::new(active));
        entry.credit(filter, secs);
        Some(entry.clone())
    }

    /// pre-seed per-target / per-filter carry-over from
    /// prior sessions so the IntegrationBudget tracker treats those
    /// frames as already-counted toward the configured budget.
    ///
    /// Called by the Dart `SequenceExecutor.start()` right after the
    /// sequence JSON is loaded, when the operator has chosen "Resume"
    /// in the session-handoff pre-flight dialog. The per-filter map
    /// reflects the captured-image history for the target (the
    /// `SessionHandoffService.detectCarryOver` result, summed per
    /// filter); `total_secs` is the sum and is also persisted as the
    /// `completed_total_secs` field so the very first budget evaluation
    /// honours the prior integration without waiting for the first
    /// credit of the new run.
    ///
    /// Behaviour:
    ///   * `Resume`  → supply the prior per-filter totals (this method).
    ///   * `Restart` → supply an empty map (zeroes the per-target state).
    ///   * `ContinueNew` → caller does NOT call this method; per-target
    ///     state stays at the registry's default (`completed_*_secs = 0`).
    ///
    /// The method is idempotent — re-seeding a target replaces its
    /// per-filter map outright. `run_id` is reset to 0 so the next
    /// `TargetHeader::enter` round assigns a fresh run id rather than
    /// inheriting one from an unrelated prior session checkpoint.
    pub async fn seed_carry_over(&self, target_id: &str, per_filter_secs: HashMap<String, f64>) {
        // Sanitize: drop non-finite or negative entries up front so the total
        // never accumulates NaN / -inf from a malformed Dart payload. The Dart
        // side already validates; this is defence in depth at the bridge
        // boundary, coercing to a clean state rather than aborting sequence start
        // over a single garbage entry.
        let mut cleaned: HashMap<String, f64> = HashMap::new();
        let mut total = 0.0_f64;
        for (k, v) in per_filter_secs.into_iter() {
            if v.is_finite() && v > 0.0 {
                total += v;
                cleaned.insert(k, v);
            }
        }
        let mut guard = self.inner.write().await;
        let entry = guard
            .by_target
            .entry(target_id.to_string())
            .or_insert_with(|| BudgetState::new(target_id));
        entry.completed_by_filter = cleaned;
        entry.completed_total_secs = total;
        entry.budget_met = false;
        entry.run_id = 0;
    }

    /// Read-only snapshot of one target's state (for dashboard /
    /// progress payloads). Returns `None` when the target has not been
    /// entered yet.
    pub async fn state_for(&self, target_id: &str) -> Option<BudgetState> {
        let guard = self.inner.read().await;
        guard.by_target.get(target_id).cloned()
    }

    /// Read-only snapshot of every known target state (used by the
    /// executor's checkpoint streaming task).
    pub async fn all_states(&self) -> Vec<BudgetState> {
        let guard = self.inner.read().await;
        guard.by_target.values().cloned().collect()
    }
}

/// Serializable snapshot of [`BudgetRegistry`] — written into
/// [`crate::checkpoint::SessionCheckpoint`] so pause/resume preserves
/// per-filter completed time.
///
/// Backwards-compat: old checkpoints without `budget_states` deserialize
/// with `default` (empty vec), which is "start fresh" — the
/// documented behaviour for pre-budget checkpoints.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct BudgetRegistrySnapshot {
    #[serde(default)]
    pub states: Vec<BudgetState>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::FilterBudgetEntry;

    fn ratio_budget(total: f64, ratios: &[(&str, f64)]) -> IntegrationBudget {
        IntegrationBudget {
            total_secs: total,
            per_filter: ratios
                .iter()
                .map(|(f, r)| ((*f).to_string(), FilterBudgetEntry::Ratio(*r)))
                .collect(),
            stop_on_budget_met: true,
        }
    }

    #[test]
    fn resolved_filter_cap_normalises_ratios() {
        let b = ratio_budget(
            8.0 * 3600.0,
            &[("L", 4.0), ("R", 1.0), ("G", 1.0), ("B", 1.0)],
        );
        // 8h split 4:1:1:1 → L gets 4/7 of 28800, R/G/B each get 1/7.
        let l = b.resolved_filter_cap("L").expect("L cap");
        assert!((l - (4.0 / 7.0) * 28_800.0).abs() < 1.0, "L={l}");
        let r = b.resolved_filter_cap("R").expect("R cap");
        assert!((r - (1.0 / 7.0) * 28_800.0).abs() < 1.0, "R={r}");
    }

    #[test]
    fn resolved_filter_cap_uses_absolute_directly() {
        let b = IntegrationBudget {
            total_secs: 0.0,
            per_filter: [("Ha".to_string(), FilterBudgetEntry::Absolute(6.0 * 3600.0))]
                .into_iter()
                .collect(),
            stop_on_budget_met: true,
        };
        assert_eq!(b.resolved_filter_cap("Ha"), Some(6.0 * 3600.0));
        assert_eq!(b.resolved_filter_cap("OIII"), None);
    }

    #[test]
    fn ratio_without_total_yields_no_cap() {
        let b = ratio_budget(0.0, &[("L", 4.0), ("R", 1.0)]);
        assert_eq!(b.resolved_filter_cap("L"), None);
        assert_eq!(b.resolved_filter_cap("R"), None);
        // is_active still true — there's a non-zero ratio entry; the
        // validator surfaces "ratios without total" as an error.
        assert!(b.is_active());
    }

    #[test]
    fn is_active_false_for_all_zero_budget() {
        let b = IntegrationBudget::default();
        assert!(!b.is_active());
    }

    #[test]
    fn credit_accumulates_per_filter_and_total() {
        let mut s = BudgetState::new("target1");
        s.credit(Some("L"), 60.0);
        s.credit(Some("L"), 60.0);
        s.credit(Some("R"), 30.0);
        s.credit(None, 10.0);
        assert_eq!(s.completed_by_filter.get("L").copied(), Some(120.0));
        assert_eq!(s.completed_by_filter.get("R").copied(), Some(30.0));
        assert_eq!(s.completed_by_filter.get("").copied(), Some(10.0));
        assert!((s.completed_total_secs - 160.0).abs() < f64::EPSILON);
    }

    #[test]
    fn credit_rejects_non_finite_and_non_positive() {
        let mut s = BudgetState::new("t");
        s.credit(Some("L"), 0.0);
        s.credit(Some("L"), -10.0);
        s.credit(Some("L"), f64::NAN);
        s.credit(Some("L"), f64::INFINITY);
        assert!(s.completed_by_filter.is_empty());
        assert_eq!(s.completed_total_secs, 0.0);
    }

    #[test]
    fn evaluate_total_cap_fires_first() {
        let b = IntegrationBudget {
            total_secs: 100.0,
            per_filter: [("L".to_string(), FilterBudgetEntry::Absolute(80.0))]
                .into_iter()
                .collect(),
            stop_on_budget_met: true,
        };
        let mut s = BudgetState::new("t");
        s.credit(Some("L"), 50.0);
        s.credit(Some("R"), 60.0); // total 110 -> total cap hit
        let eval = s.evaluate(&b);
        assert!(matches!(
            eval,
            BudgetEvaluation::Met {
                reason: BudgetMetReason::TotalReached,
                ..
            }
        ));
    }

    #[test]
    fn evaluate_all_filters_complete_fires() {
        let b = IntegrationBudget {
            total_secs: 0.0,
            per_filter: [
                ("L".to_string(), FilterBudgetEntry::Absolute(60.0)),
                ("R".to_string(), FilterBudgetEntry::Absolute(60.0)),
            ]
            .into_iter()
            .collect(),
            stop_on_budget_met: true,
        };
        let mut s = BudgetState::new("t");
        s.credit(Some("L"), 60.0);
        s.credit(Some("R"), 60.0);
        let eval = s.evaluate(&b);
        assert!(matches!(
            eval,
            BudgetEvaluation::Met {
                reason: BudgetMetReason::AllFiltersComplete,
                ..
            }
        ));
    }

    #[test]
    fn evaluate_open_lists_filters_complete() {
        let b = IntegrationBudget {
            total_secs: 0.0,
            per_filter: [
                ("L".to_string(), FilterBudgetEntry::Absolute(60.0)),
                ("R".to_string(), FilterBudgetEntry::Absolute(60.0)),
            ]
            .into_iter()
            .collect(),
            stop_on_budget_met: true,
        };
        let mut s = BudgetState::new("t");
        s.credit(Some("L"), 60.0);
        s.credit(Some("R"), 30.0);
        let eval = s.evaluate(&b);
        match eval {
            BudgetEvaluation::Open {
                filters_complete,
                caps,
            } => {
                assert_eq!(filters_complete, vec!["L".to_string()]);
                assert_eq!(caps.get("L").copied(), Some(60.0));
                assert_eq!(caps.get("R").copied(), Some(60.0));
            }
            BudgetEvaluation::Met { .. } => panic!("budget should still be open"),
        }
    }

    #[tokio::test]
    async fn registry_records_exposure_against_active_target() {
        let reg = BudgetRegistry::new();
        reg.enter_target("t1", None).await;
        let s = reg
            .record_exposure(Some("L"), 30.0)
            .await
            .expect("active target");
        assert_eq!(s.completed_by_filter.get("L").copied(), Some(30.0));
        let s = reg
            .record_exposure(Some("L"), 30.0)
            .await
            .expect("active target");
        assert_eq!(s.completed_by_filter.get("L").copied(), Some(60.0));
        assert!((s.completed_total_secs - 60.0).abs() < f64::EPSILON);
    }

    #[tokio::test]
    async fn registry_drops_exposure_without_active_target() {
        let reg = BudgetRegistry::new();
        assert!(reg.record_exposure(Some("L"), 30.0).await.is_none());
    }

    #[tokio::test]
    async fn registry_leave_target_blocks_late_credits() {
        let reg = BudgetRegistry::new();
        reg.enter_target("t1", None).await;
        reg.leave_target().await;
        assert!(reg.record_exposure(Some("L"), 30.0).await.is_none());
        // The state for t1 is still queryable.
        let s = reg.state_for("t1").await.expect("state retained");
        assert!(s.completed_by_filter.is_empty());
    }

    #[tokio::test]
    async fn registry_snapshot_roundtrips_through_serde() {
        let reg = BudgetRegistry::new();
        reg.enter_target("t1", None).await;
        reg.record_exposure(Some("L"), 30.0).await;
        reg.record_exposure(Some("R"), 15.0).await;
        let snap = reg.snapshot().await;
        let json = serde_json::to_string(&snap).expect("ser");
        let back: BudgetRegistrySnapshot = serde_json::from_str(&json).expect("de");
        let restored = BudgetRegistry::new();
        restored.restore_snapshot(back).await;
        let s = restored.state_for("t1").await.expect("state");
        assert_eq!(s.completed_by_filter.get("L").copied(), Some(30.0));
        assert_eq!(s.completed_by_filter.get("R").copied(), Some(15.0));
        assert!((s.completed_total_secs - 45.0).abs() < f64::EPSILON);
    }

    #[tokio::test]
    async fn registry_resume_credits_continue_to_accumulate() {
        // Simulate: target ran, paused at L=120, resumed, credit another 60s of L.
        let reg = BudgetRegistry::new();
        let mut state = BudgetState::new("t1");
        state.credit(Some("L"), 120.0);
        let snap = BudgetRegistrySnapshot {
            states: vec![state],
        };
        reg.restore_snapshot(snap).await;
        reg.enter_target("t1", None).await;
        let s = reg.record_exposure(Some("L"), 60.0).await.expect("active");
        assert_eq!(s.completed_by_filter.get("L").copied(), Some(180.0));
    }

    // session-handoff carry-over seeding

    #[tokio::test]
    async fn seed_carry_over_populates_per_filter_totals() {
        // Operator chose Resume in the pre-flight dialog: the Dart side
        // pushed the prior session's per-filter totals (Lum: 4h, Red: 2h)
        // and the next budget evaluation must see those credits before
        // any new exposure lands.
        let reg = BudgetRegistry::new();
        let mut per_filter = HashMap::new();
        per_filter.insert("L".to_string(), 14_400.0); // 4h
        per_filter.insert("R".to_string(), 7_200.0); //  2h
        reg.seed_carry_over("m31-header", per_filter).await;
        let s = reg.state_for("m31-header").await.expect("seeded");
        assert_eq!(s.completed_by_filter.get("L").copied(), Some(14_400.0));
        assert_eq!(s.completed_by_filter.get("R").copied(), Some(7_200.0));
        assert!((s.completed_total_secs - 21_600.0).abs() < f64::EPSILON);
        assert!(!s.budget_met);
    }

    #[tokio::test]
    async fn seed_carry_over_with_empty_map_zeroes_state() {
        // Operator chose Restart: the Dart side pushes an empty inner
        // map so a stale checkpoint carry-over is overwritten with
        // zeros. Verifies the Restart branch.
        let reg = BudgetRegistry::new();
        let mut state = BudgetState::new("m42-header");
        state.credit(Some("Ha"), 3_600.0);
        let snap = BudgetRegistrySnapshot {
            states: vec![state],
        };
        reg.restore_snapshot(snap).await;
        // Confirm the snapshot took effect before seeding.
        let pre = reg.state_for("m42-header").await.expect("restored");
        assert_eq!(pre.completed_total_secs, 3_600.0);
        // Now Restart-equivalent: seed with an empty map.
        reg.seed_carry_over("m42-header", HashMap::new()).await;
        let post = reg.state_for("m42-header").await.expect("seeded");
        assert!(post.completed_by_filter.is_empty());
        assert_eq!(post.completed_total_secs, 0.0);
        assert!(!post.budget_met);
    }

    #[tokio::test]
    async fn seed_carry_over_filters_out_non_finite_and_negative() {
        // Defence in depth: a malformed Dart payload (NaN / negative)
        // must not corrupt the running total. The Dart side already
        // validates, but the Rust boundary still coerces to clean state.
        let reg = BudgetRegistry::new();
        let mut per_filter = HashMap::new();
        per_filter.insert("L".to_string(), 1_800.0);
        per_filter.insert("Bad-NaN".to_string(), f64::NAN);
        per_filter.insert("Bad-Inf".to_string(), f64::INFINITY);
        per_filter.insert("Bad-Neg".to_string(), -42.0);
        reg.seed_carry_over("ic1396", per_filter).await;
        let s = reg.state_for("ic1396").await.expect("seeded");
        // Only the well-formed 1800s Lum entry survived.
        assert_eq!(s.completed_by_filter.len(), 1);
        assert_eq!(s.completed_by_filter.get("L").copied(), Some(1_800.0));
        assert!((s.completed_total_secs - 1_800.0).abs() < f64::EPSILON);
    }

    #[tokio::test]
    async fn seeded_carry_over_continues_to_accumulate_on_record_exposure() {
        // End-to-end: Resume seeds 4h Lum → enter target → record
        // another 600s exposure → completed_secs reflects the sum.
        let reg = BudgetRegistry::new();
        let mut per_filter = HashMap::new();
        per_filter.insert("L".to_string(), 14_400.0);
        reg.seed_carry_over("m31", per_filter).await;
        reg.enter_target("m31", None).await;
        let s = reg.record_exposure(Some("L"), 600.0).await.expect("active");
        assert_eq!(s.completed_by_filter.get("L").copied(), Some(15_000.0));
        assert!((s.completed_total_secs - 15_000.0).abs() < f64::EPSILON);
    }

    // Count-based completion ("N accepted frames per filter")

    fn count_budget(entries: &[(&str, u32, f64)]) -> IntegrationBudget {
        IntegrationBudget {
            total_secs: 0.0,
            per_filter: entries
                .iter()
                .map(|(f, n, secs)| {
                    (
                        (*f).to_string(),
                        FilterBudgetEntry::Count {
                            desired_accepted: *n,
                            sub_secs: *secs,
                        },
                    )
                })
                .collect(),
            stop_on_budget_met: true,
        }
    }

    #[test]
    fn count_resolves_to_n_times_sub_secs_cap() {
        // 60 x Ha 300s → cap = 18000s.
        let b = count_budget(&[("Ha", 60, 300.0)]);
        assert_eq!(b.resolved_filter_cap("Ha"), Some(18_000.0));
        assert!(b.is_active());
    }

    #[test]
    fn count_zero_frames_or_zero_secs_yields_no_cap() {
        assert_eq!(
            count_budget(&[("Ha", 0, 300.0)]).resolved_filter_cap("Ha"),
            None
        );
        assert_eq!(
            count_budget(&[("Ha", 60, 0.0)]).resolved_filter_cap("Ha"),
            None
        );
        // Both-zero → not active at all.
        assert!(!count_budget(&[("Ha", 0, 0.0)]).is_active());
    }

    #[test]
    fn count_is_met_after_n_accepted_subs() {
        // 5 x Ha 300s. Credit accepted-frame seconds one sub at a time; the
        // budget must report met exactly at the 5th accepted sub, not the 4th.
        let b = count_budget(&[("Ha", 5, 300.0)]);
        let mut s = BudgetState::new("t");
        for i in 1..=4 {
            s.credit(Some("Ha"), 300.0);
            assert!(!s.is_met(&b), "should not be met after {i} accepted subs");
            assert_eq!(s.accepted_frames("Ha", 300.0), i);
        }
        s.credit(Some("Ha"), 300.0);
        assert_eq!(s.accepted_frames("Ha", 300.0), 5);
        assert!(s.is_met(&b), "must be met after the 5th accepted sub");
        match s.evaluate(&b) {
            BudgetEvaluation::Met { reason, .. } => {
                assert_eq!(reason, BudgetMetReason::AllFiltersComplete)
            }
            BudgetEvaluation::Open { .. } => panic!("count budget should be met"),
        }
    }

    #[test]
    fn count_rejected_subs_do_not_advance_completion() {
        // The expose instruction credits accepted-frame seconds only. Simulate
        // a burst of 3 with one rejected: only 2 subs' worth of seconds land.
        // After two such bursts, accepted = 4, not 6 — so a 5-sub Count budget
        // is NOT met until a 5th accepted sub is credited.
        let b = count_budget(&[("Ha", 5, 300.0)]);
        let mut s = BudgetState::new("t");
        s.credit(Some("Ha"), 2.0 * 300.0); // burst 1: 2 accepted
        s.credit(Some("Ha"), 2.0 * 300.0); // burst 2: 2 accepted
        assert_eq!(s.accepted_frames("Ha", 300.0), 4);
        assert!(!s.is_met(&b));
        s.credit(Some("Ha"), 300.0); // burst 3: 1 accepted → 5 total
        assert_eq!(s.accepted_frames("Ha", 300.0), 5);
        assert!(s.is_met(&b));
    }

    #[test]
    fn count_multi_filter_all_must_complete() {
        // 3 x Ha 300s AND 2 x OIII 600s — target completes only when BOTH
        // filters reach their accepted-sub counts.
        let b = count_budget(&[("Ha", 3, 300.0), ("OIII", 2, 600.0)]);
        let mut s = BudgetState::new("t");
        s.credit(Some("Ha"), 3.0 * 300.0); // Ha done
        assert!(!s.is_met(&b), "OIII still open");
        match s.evaluate(&b) {
            BudgetEvaluation::Open {
                filters_complete, ..
            } => assert_eq!(filters_complete, vec!["Ha".to_string()]),
            BudgetEvaluation::Met { .. } => panic!("not all filters complete yet"),
        }
        s.credit(Some("OIII"), 600.0); // 1 of 2
        assert!(!s.is_met(&b));
        s.credit(Some("OIII"), 600.0); // 2 of 2 → both complete
        assert!(s.is_met(&b));
    }

    #[test]
    fn count_progress_reports_accepted_over_desired() {
        let b = count_budget(&[("Ha", 60, 300.0), ("OIII", 30, 600.0)]);
        let mut s = BudgetState::new("t");
        s.credit(Some("Ha"), 47.0 * 300.0);
        s.credit(Some("OIII"), 5.0 * 600.0);
        let rows = s.count_progress(&b);
        assert_eq!(
            rows,
            vec![("Ha".to_string(), 47, 60), ("OIII".to_string(), 5, 30),]
        );
    }

    #[test]
    fn count_accepted_frames_tolerates_float_drift() {
        // Accumulating 60 credits of 300.0 should still floor to 60, not 59,
        // despite IEEE-754 round-off.
        let mut s = BudgetState::new("t");
        for _ in 0..60 {
            s.credit(Some("Ha"), 300.0);
        }
        assert_eq!(s.accepted_frames("Ha", 300.0), 60);
    }

    #[test]
    fn count_total_cap_still_fires_first_when_combined() {
        // A total cap combined with Count entries: the total wins when it is
        // reached first (documented "strictest interpretation" behaviour).
        let mut b = count_budget(&[("Ha", 100, 300.0)]);
        b.total_secs = 600.0; // 2 subs worth
        let mut s = BudgetState::new("t");
        s.credit(Some("Ha"), 300.0);
        s.credit(Some("Ha"), 300.0); // total 600 → total cap hit
        match s.evaluate(&b) {
            BudgetEvaluation::Met { reason, .. } => {
                assert_eq!(reason, BudgetMetReason::TotalReached)
            }
            BudgetEvaluation::Open { .. } => panic!("total cap should fire first"),
        }
    }

    #[test]
    fn count_serde_roundtrips_through_wire_format() {
        // Wire shape must match the externally-tagged enum the Dart side
        // would emit: {"kind":"Count","value":{"desired_accepted":60,"sub_secs":300.0}}.
        let entry = FilterBudgetEntry::Count {
            desired_accepted: 60,
            sub_secs: 300.0,
        };
        let json = serde_json::to_string(&entry).expect("ser");
        assert!(json.contains("\"kind\":\"Count\""), "json: {json}");
        assert!(json.contains("\"desired_accepted\":60"), "json: {json}");
        let back: FilterBudgetEntry = serde_json::from_str(&json).expect("de");
        assert_eq!(back, entry);
    }

    #[tokio::test]
    async fn count_completion_works_end_to_end_through_record_exposure() {
        // End-to-end through the registry credit hook the expose instruction
        // uses: enter a target with a 3 x L 120s Count budget, record three
        // accepted-frame bursts, and confirm is_met flips on the third.
        let budget = count_budget(&[("L", 3, 120.0)]);
        let reg = BudgetRegistry::new();
        reg.enter_target("t1", Some(budget.clone())).await;
        for i in 1..=2 {
            let s = reg.record_exposure(Some("L"), 120.0).await.expect("active");
            assert!(!s.is_met(&budget), "not met after {i} subs");
        }
        let s = reg.record_exposure(Some("L"), 120.0).await.expect("active");
        assert!(s.is_met(&budget), "met after the 3rd accepted sub");
        assert_eq!(s.accepted_frames("L", 120.0), 3);
    }
}
