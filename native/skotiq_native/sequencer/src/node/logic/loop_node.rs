//! Loop logic node.

use crate::node::context::ExecutionContext;
use crate::node::logic::sequential::execute_children_sequential;
use crate::node::progress::ProgressUpdate;
use crate::node::runtime::RuntimeNode;
use crate::node::Node;
use crate::scheduling::astronomy::object_alt_az;
use crate::scheduling::HorizonProfile;
use crate::{LoopCondition, LoopConfig, NodeStatus};

/// Current `(altitude_deg, azimuth_deg)` of the active target from the
/// execution context, or `None` when target coordinates or the observer
/// location are unset.
///
/// `ExecutionContext::calculate_altitude` only returns altitude; the
/// per-azimuth horizon mask needs azimuth too, so this consults
/// [`object_alt_az`] (the same astronomy used by the scheduler) for both.
/// `target_ra` is stored in **hours**, so it is converted to degrees (×15)
/// for `object_alt_az`, which — like the Dart `objectAltAz` — expects RA in
/// degrees.
fn current_alt_az(context: &ExecutionContext) -> Option<(f64, f64)> {
    let ra_hours = context.target_ra?;
    let dec_deg = context.target_dec?;
    let lat = context.latitude?;
    let lon = context.longitude?;
    let now = chrono::Utc::now();
    Some(object_alt_az(ra_hours * 15.0, dec_deg, &now, lat, lon))
}

/// Effective altitude floor for an altitude loop condition.
///
/// With no horizon profile this is just the flat `condition_value` floor
/// (the prior behaviour). With a profile, the obstruction altitude at the
/// target's current azimuth is folded in: the floor becomes the higher of
/// the user's flat floor and the local horizon, so the loop only releases
/// once the target has cleared BOTH the configured minimum AND the physical
/// obstruction (tree / roofline) at that azimuth.
fn effective_altitude_floor(
    flat_floor: f64,
    horizon: Option<&HorizonProfile>,
    azimuth_deg: f64,
) -> f64 {
    match horizon {
        Some(profile) => flat_floor.max(profile.min_altitude_at(azimuth_deg)),
        None => flat_floor,
    }
}

pub async fn execute_loop(
    node: &mut RuntimeNode,
    config: LoopConfig,
    context: &mut ExecutionContext,
) -> NodeStatus {
    // do NOT reset current_iteration here. A fresh run already has it at
    // 0 (from_definition / reset), and a nested re-run is preceded by the
    // parent's reset() — so the only time it's non-zero on entry is a RESUME,
    // where `resume_from_checkpoint` restored it via restore_loop_iterations.
    // Unconditionally zeroing it made a resumed Count loop restart at iteration
    // 1 and re-image every already-captured iteration.

    // Count-based loops have an explicit upper bound; condition-based loops
    // (UntilTime, AltitudeBelow, WhileDark, etc.) terminate via runtime
    // checks inside the loop body, so the bound stays effectively infinite.
    let max_iterations = match config.condition {
        // `iterations: Option<u32>` — semantically REQUIRED when condition
        // == Count, optional otherwise. UI builder enforces this; `unwrap_or(1)`
        // is a safety floor for a legacy/corrupt sequence file where Count
        // was selected without iterations. A single execution is the safest
        // interpretation of "Count with no count".
        LoopCondition::Count => config.iterations.unwrap_or(1),
        _ => u32::MAX,
    };

    // Iterations THIS execution ran. `node.current_iteration` cannot answer
    // that question: a resumed run restores it from the checkpoint before the
    // body has run once here.
    let mut iterations_run_here: u32 = 0;

    loop {
        if context.is_cancelled().await {
            return NodeStatus::Cancelled;
        }
        // A skip-to-next-target request stops the loop starting another
        // iteration. What it must not do is turn the work the loop already did
        // into a skip — the loop reports what IT did, and leaves the request
        // set for the TargetHeader that owns it. Reporting Skipped whatever had
        // happened is what put `message: "Skipped: Night root"` on the terminal
        // status of a night that captured every frame it planned and answered
        // `state: "completed"` on the same request.
        if context.is_skip_to_next_target_requested() {
            return if iterations_run_here == 0 {
                NodeStatus::Skipped
            } else {
                NodeStatus::Success
            };
        }

        let should_continue = match config.condition {
            LoopCondition::Count => node.current_iteration < max_iterations,
            LoopCondition::UntilTime => {
                if let Some(until) = config.condition_value {
                    // condition_value is f64 carrying a Unix timestamp; year
                    // 2038 is ~2.1e9 (< 2^31), still 1000x below f64 precision
                    // limit. f64 -> i64 saturates per Rust 1.45 spec.
                    chrono::Utc::now().timestamp() < (until as i64)
                } else {
                    false
                }
            }
            LoopCondition::AltitudeBelow => {
                // A bound exists when either a flat floor OR a horizon mask is
                // configured. Without either the condition can never fire, so
                // looping would be unbounded — fail closed (return false →
                // loop exits immediately) rather than spin forever.
                if config.condition_value.is_none() && config.horizon_profile.is_none() {
                    false
                } else {
                    let Some((current_alt, current_az)) = current_alt_az(context) else {
                        tracing::error!(
                            "Loop condition AltitudeBelow requires target coordinates and observer location"
                        );
                        return NodeStatus::Failure;
                    };
                    let floor = effective_altitude_floor(
                        config.condition_value.unwrap_or(0.0),
                        config.horizon_profile.as_ref(),
                        current_az,
                    );
                    // Continue while the target is still up and clear of the
                    // (flat + local-horizon) floor; stop once it drops below.
                    current_alt >= floor
                }
            }
            LoopCondition::AltitudeAbove => {
                if config.condition_value.is_none() && config.horizon_profile.is_none() {
                    false
                } else {
                    let Some((current_alt, current_az)) = current_alt_az(context) else {
                        tracing::error!(
                            "Loop condition AltitudeAbove requires target coordinates and observer location"
                        );
                        return NodeStatus::Failure;
                    };
                    let floor = effective_altitude_floor(
                        config.condition_value.unwrap_or(0.0),
                        config.horizon_profile.as_ref(),
                        current_az,
                    );
                    // Continue while the target is still below the
                    // (flat + local-horizon) floor; stop once it rises above —
                    // i.e. once it clears the tree/roofline at its azimuth.
                    current_alt <= floor
                }
            }
            LoopCondition::IntegrationTime => {
                if let Some(target_secs) = config.condition_value {
                    let integrated_secs = context.get_completed_integration_secs().await;
                    integrated_secs < target_secs
                } else {
                    false
                }
            }
            LoopCondition::Forever => true,
            LoopCondition::WhileDark => {
                let Some(is_dark) = context.is_dark() else {
                    tracing::error!(
                        "Loop condition WhileDark requires observer latitude/longitude"
                    );
                    return NodeStatus::Failure;
                };
                is_dark
            }
        };

        if !should_continue {
            break;
        }

        node.current_iteration += 1;
        iterations_run_here += 1;
        tracing::info!("=== LOOP ITERATION {} STARTING ===", node.current_iteration);
        tracing::info!("Loop has {} children", node.children.len());
        for (i, child) in node.children.iter().enumerate() {
            tracing::info!("  Child {}: '{}' (id={})", i, child.name(), child.id());
        }

        let total_children = match config.condition {
            // max_iterations is u32 -> usize widening (lossless on >=32-bit platforms).
            LoopCondition::Count => Some(max_iterations as usize),
            _ => None,
        };

        let mut update = ProgressUpdate::lifecycle(
            node.id().clone(),
            NodeStatus::Running,
            format!("Loop iteration {}", node.current_iteration),
        );
        // current_iteration is u32 -> usize widening (lossless).
        update.current_child = Some(node.current_iteration as usize);
        update.total_children = total_children;
        context.send_progress(update);

        // Children retain Success/Failure from the previous iteration and
        // would short-circuit on the next pass; resetting them per-iter is
        // what makes a Loop actually re-execute its body.
        tracing::info!(
            "Resetting {} children for iteration {}",
            node.children.len(),
            node.current_iteration
        );
        for child in &mut node.children {
            child.reset();
        }
        tracing::info!("Children reset complete");

        tracing::info!(
            "Starting execute_children_sequential for iteration {}",
            node.current_iteration
        );
        let result = execute_children_sequential(node, context).await;
        tracing::info!(
            "execute_children_sequential completed with result: {:?}",
            result
        );
        if result == NodeStatus::Skipped && context.is_skip_to_next_target_requested() {
            return NodeStatus::Skipped;
        }
        if result == NodeStatus::Failure || result == NodeStatus::Cancelled {
            return result;
        }
    }

    NodeStatus::Success
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::node::context::ExecutionContext;
    use crate::scheduling::HorizonSample;
    use crate::{LoopCondition, LoopConfig};

    fn ctx_with_target(ra_hours: f64, dec_deg: f64, lat: f64, lon: f64) -> ExecutionContext {
        let mut ctx = ExecutionContext::new_for_test("root".to_string());
        ctx.target_ra = Some(ra_hours);
        ctx.target_dec = Some(dec_deg);
        ctx.latitude = Some(lat);
        ctx.longitude = Some(lon);
        ctx
    }

    #[test]
    fn effective_floor_without_horizon_is_flat_floor() {
        // No profile => the flat condition_value floor is used unchanged.
        assert_eq!(effective_altitude_floor(20.0, None, 137.0), 20.0);
        assert_eq!(effective_altitude_floor(0.0, None, 0.0), 0.0);
    }

    #[test]
    fn effective_floor_takes_max_of_flat_and_horizon() {
        // Tree at 45 deg in the east; flat floor 10 deg. East target must clear
        // the tree (45), not just the flat floor.
        let h = HorizonProfile::new(vec![
            HorizonSample::new(0.0, 10.0),
            HorizonSample::new(90.0, 45.0),
        ])
        .unwrap();
        // At az 90 the horizon is 45 > flat 10 => 45 wins.
        assert!((effective_altitude_floor(10.0, Some(&h), 90.0) - 45.0).abs() < 1e-9);
        // At az 0 the horizon is 10 == flat 10 => 10.
        assert!((effective_altitude_floor(10.0, Some(&h), 0.0) - 10.0).abs() < 1e-9);
        // Flat floor higher than the horizon at this az wins.
        assert!((effective_altitude_floor(60.0, Some(&h), 90.0) - 60.0).abs() < 1e-9);
    }

    #[test]
    fn effective_floor_is_per_azimuth_not_flat() {
        // The whole point: the floor must vary with azimuth. A flat reading of
        // the profile (e.g. always using sample[0]) would make these equal.
        let h = HorizonProfile::new(vec![
            HorizonSample::new(0.0, 5.0),
            HorizonSample::new(180.0, 35.0),
        ])
        .unwrap();
        let north = effective_altitude_floor(0.0, Some(&h), 0.0);
        let south = effective_altitude_floor(0.0, Some(&h), 180.0);
        let east = effective_altitude_floor(0.0, Some(&h), 90.0);
        assert!((north - 5.0).abs() < 1e-9, "north {north}");
        assert!((south - 35.0).abs() < 1e-9, "south {south}");
        // East is the linear midpoint of the two samples (5 -> 35).
        assert!((east - 20.0).abs() < 1e-9, "east {east}");
        assert!(north < east && east < south);
    }

    #[test]
    fn current_alt_az_none_without_coords() {
        let ctx = ExecutionContext::new_for_test("root".to_string());
        assert!(current_alt_az(&ctx).is_none());

        // Missing observer location alone is still None.
        let mut partial = ExecutionContext::new_for_test("root".to_string());
        partial.target_ra = Some(5.59);
        partial.target_dec = Some(-5.39);
        assert!(current_alt_az(&partial).is_none());
    }

    #[test]
    fn current_alt_az_returns_finite_pair_with_coords() {
        let ctx = ctx_with_target(5.59, -5.39, 40.7, -74.0);
        let (alt, az) = current_alt_az(&ctx).expect("coords present");
        assert!(alt.is_finite() && (-90.0..=90.0).contains(&alt));
        assert!(az.is_finite() && (0.0..360.0).contains(&az));
    }

    #[test]
    fn current_alt_az_matches_context_altitude() {
        // The new alt/az path must agree with the existing flat-floor altitude
        // (ExecutionContext::calculate_altitude) so behaviour is unchanged when
        // no horizon profile is configured. They use the same sin(alt) formula;
        // any LST-source drift must stay sub-degree.
        let ctx = ctx_with_target(5.59, -5.39, 40.7, -74.0);
        let (alt, _az) = current_alt_az(&ctx).unwrap();
        let ctx_alt = ctx.calculate_altitude().unwrap();
        assert!(
            (alt - ctx_alt).abs() < 0.1,
            "alt {alt} vs ctx_alt {ctx_alt}"
        );
    }

    #[test]
    fn loop_config_deserializes_without_horizon_field_legacy() {
        // Legacy sequence JSON (no horizon_profile key) must still load, with
        // the field defaulting to None — preserving flat-floor-only behaviour.
        let json = r#"{"iterations":null,"condition":"AltitudeAbove","condition_value":20.0}"#;
        let cfg: LoopConfig = serde_json::from_str(json).expect("legacy config loads");
        assert!(cfg.horizon_profile.is_none());
        assert_eq!(cfg.condition_value, Some(20.0));
        assert!(matches!(cfg.condition, LoopCondition::AltitudeAbove));
    }

    #[test]
    fn loop_config_horizon_profile_round_trips() {
        let cfg = LoopConfig {
            iterations: None,
            condition: LoopCondition::AltitudeAbove,
            condition_value: Some(10.0),
            horizon_profile: HorizonProfile::new(vec![
                HorizonSample::new(0.0, 10.0),
                HorizonSample::new(90.0, 45.0),
            ]),
        };
        let json = serde_json::to_string(&cfg).unwrap();
        // Samples serialize with the Dart-compatible {"az","alt"} shape.
        assert!(json.contains("\"az\""));
        assert!(json.contains("\"alt\""));
        let back: LoopConfig = serde_json::from_str(&json).unwrap();
        let profile = back.horizon_profile.expect("profile round-trips");
        assert!((profile.min_altitude_at(90.0) - 45.0).abs() < 1e-9);
    }

    #[tokio::test]
    async fn altitude_above_unbounded_without_floor_or_horizon_exits_immediately() {
        // No condition_value and no horizon => no bound. Fail closed: the loop
        // body must not execute (should_continue == false on entry).
        let mut node = RuntimeNode::from_definition(crate::NodeDefinition {
            id: "loop".to_string(),
            name: "loop".to_string(),
            node_type: crate::NodeType::Loop(LoopConfig {
                iterations: None,
                condition: LoopCondition::AltitudeAbove,
                condition_value: None,
                horizon_profile: None,
            }),
            enabled: true,
            children: vec![],
        });
        let mut ctx = ctx_with_target(5.59, -5.39, 40.7, -74.0);
        let cfg = LoopConfig {
            iterations: None,
            condition: LoopCondition::AltitudeAbove,
            condition_value: None,
            horizon_profile: None,
        };
        let status = execute_loop(&mut node, cfg, &mut ctx).await;
        assert_eq!(status, NodeStatus::Success);
        assert_eq!(node.current_iteration, 0, "body must not run");
    }

    /// A loop whose body ran and then met a skip-to-next-target request reports
    /// what it did, not the request.
    ///
    /// Returning Skipped for a loop that had already executed its body is what
    /// put `message: "Skipped: Night root"` on the terminal status of a night
    /// that captured all 8 frames it planned and answered `state: "completed"`
    /// — the run's own verdict and the sentence describing it disagreed. The
    /// request stays set: the TargetHeader that owns it consumes it at its own
    /// boundary.
    #[tokio::test]
    async fn skip_request_after_an_executed_iteration_reports_the_work_done() {
        let mut node = RuntimeNode::from_definition(crate::NodeDefinition {
            id: "loop".to_string(),
            name: "Night root".to_string(),
            node_type: crate::NodeType::Loop(LoopConfig {
                iterations: None,
                condition: LoopCondition::Forever,
                condition_value: None,
                horizon_profile: None,
            }),
            enabled: true,
            children: vec![],
        });
        node.add_child(Box::new(SkipRequestingChild::new("expose")));

        let mut ctx = ExecutionContext::new_for_test("root".to_string());
        let cfg = LoopConfig {
            iterations: None,
            condition: LoopCondition::Forever,
            condition_value: None,
            horizon_profile: None,
        };
        let status = execute_loop(&mut node, cfg, &mut ctx).await;

        assert_eq!(
            status,
            NodeStatus::Success,
            "the loop ran its body once and then yielded to the request"
        );
        assert_eq!(node.current_iteration, 1, "exactly one iteration ran");
        assert!(
            ctx.is_skip_to_next_target_requested(),
            "the loop leaves the request for the TargetHeader that owns it"
        );
    }

    /// A request that arrives before the body has run once is a skip: the loop
    /// did nothing.
    #[tokio::test]
    async fn skip_request_before_the_first_iteration_reports_skipped() {
        let mut node = RuntimeNode::from_definition(crate::NodeDefinition {
            id: "loop".to_string(),
            name: "Night root".to_string(),
            node_type: crate::NodeType::Loop(LoopConfig {
                iterations: Some(1),
                condition: LoopCondition::Count,
                condition_value: None,
                horizon_profile: None,
            }),
            enabled: true,
            children: vec![],
        });
        node.add_child(Box::new(SkipRequestingChild::new("expose")));

        let mut ctx = ExecutionContext::new_for_test("root".to_string());
        ctx.request_skip_to_next_target();
        let cfg = LoopConfig {
            iterations: Some(1),
            condition: LoopCondition::Count,
            condition_value: None,
            horizon_profile: None,
        };
        let status = execute_loop(&mut node, cfg, &mut ctx).await;

        assert_eq!(status, NodeStatus::Skipped);
        assert_eq!(node.current_iteration, 0, "the body never ran");
    }

    /// A child that asks to move on to the next target while it runs, and then
    /// finishes its own work — the exposure-burst shape.
    struct SkipRequestingChild {
        id: crate::NodeId,
        name: String,
        node_type: crate::NodeType,
        children: Vec<Box<dyn Node>>,
    }

    impl SkipRequestingChild {
        fn new(id: &str) -> Self {
            Self {
                id: id.to_string(),
                name: id.to_string(),
                node_type: crate::NodeType::Delay(crate::DelayConfig { seconds: 0.0 }),
                children: Vec::new(),
            }
        }
    }

    #[async_trait::async_trait]
    impl Node for SkipRequestingChild {
        fn id(&self) -> &crate::NodeId {
            &self.id
        }

        fn name(&self) -> &str {
            &self.name
        }

        fn node_type(&self) -> &crate::NodeType {
            &self.node_type
        }

        fn is_enabled(&self) -> bool {
            true
        }

        async fn execute(&mut self, context: &mut ExecutionContext) -> NodeStatus {
            context.request_skip_to_next_target();
            NodeStatus::Success
        }

        fn reset(&mut self) {}

        async fn abort(&mut self) {}

        fn children(&self) -> &[Box<dyn Node>] {
            &self.children
        }

        fn children_mut(&mut self) -> &mut Vec<Box<dyn Node>> {
            &mut self.children
        }

        fn mark_completed(&mut self, _node_id: &crate::NodeId) {}
    }
}
