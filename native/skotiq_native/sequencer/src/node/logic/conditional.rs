//! Conditional logic node.

use crate::node::context::ExecutionContext;
use crate::node::logic::sequential::execute_children_sequential;
use crate::node::runtime::RuntimeNode;
use crate::ExecutorEvent;
use crate::{ConditionalCheck, ConditionalConfig, NodeStatus, SafetyFailMode};

fn safety_poll_error_condition_result(
    fail_mode: SafetyFailMode,
    previous_safe: Option<bool>,
) -> bool {
    match fail_mode {
        SafetyFailMode::FailOpen => true,
        SafetyFailMode::FailClosed => false,
        SafetyFailMode::WarnOnly => previous_safe.unwrap_or(false),
    }
}

async fn previous_weather_safe(context: &ExecutionContext) -> Option<bool> {
    let trigger_state = context.run.trigger_state.as_ref()?;
    Some(trigger_state.read().await.telemetry.weather_safe)
}

async fn evaluate_safety_condition(
    label: &str,
    context: &ExecutionContext,
    safety_id: Option<&str>,
) -> bool {
    match context.run.device_ops.safety_is_safe(safety_id).await {
        Ok(is_safe) => {
            if !is_safe {
                tracing::warn!(
                    "{} check failed - conditions unsafe (target safety_id={:?})",
                    label,
                    safety_id
                );
            }
            is_safe
        }
        Err(e) => {
            let previous_safe = previous_weather_safe(context).await;
            let result =
                safety_poll_error_condition_result(*context.safety_fail_mode.read(), previous_safe);
            match *context.safety_fail_mode.read() {
                SafetyFailMode::FailOpen => {
                    tracing::warn!(
                        "{} check error (target safety_id={:?}): {} - treating as safe (fail-open)",
                        label,
                        safety_id,
                        e
                    );
                }
                SafetyFailMode::FailClosed => {
                    tracing::warn!(
                        "{} check error (target safety_id={:?}): {} - treating as unsafe (fail-closed)",
                        label,
                        safety_id,
                        e
                    );
                }
                SafetyFailMode::WarnOnly => {
                    tracing::warn!(
                        "{} check error (target safety_id={:?}): {} - preserving previous safety state {:?} (warn-only)",
                        label,
                        safety_id,
                        e,
                        previous_safe
                    );
                    if let Some(tx) = &context.run.event_tx {
                        let last_known = match previous_safe {
                            Some(true) => "safe",
                            Some(false) => "unsafe",
                            None => "not known, so taken as unsafe",
                        };
                        let _ = tx.send(ExecutorEvent::StepProblem {
                            message: format!(
                                "{label} could not be checked: {e}. The step went by the \
                                 last known state ({last_known})."
                            ),
                        });
                    }
                }
            }
            result
        }
    }
}

pub async fn execute_conditional(
    node: &mut RuntimeNode,
    config: ConditionalConfig,
    context: &mut ExecutionContext,
) -> NodeStatus {
    let condition_met = match &config.condition {
        ConditionalCheck::Always => true,
        ConditionalCheck::AltitudeAbove(min_alt) => {
            let Some(current_alt) = context.calculate_altitude() else {
                tracing::error!(
                    "Conditional AltitudeAbove requires target coordinates and observer location"
                );
                return NodeStatus::Failure;
            };
            current_alt > *min_alt
        }
        ConditionalCheck::TimeAfter(after) => context.clock.now_timestamp() > *after,
        ConditionalCheck::GuidingRmsBelow(threshold) => {
            match context.run.device_ops.guider_get_status().await {
                Ok(status) => status.rms_total < *threshold,
                Err(e) => {
                    tracing::warn!(
                        "Guiding RMS condition check failed (threshold {:.2}): {}",
                        threshold,
                        e
                    );
                    false
                }
            }
        }
        ConditionalCheck::HfrBelow(threshold) => {
            let current_hfr = if let Some(trigger_state_lock) = &context.run.trigger_state {
                let trigger_state = trigger_state_lock.read().await;
                trigger_state.latches.current_hfr
            } else {
                None
            };

            match current_hfr {
                Some(hfr) => hfr < *threshold,
                None => {
                    tracing::warn!(
                        "HFR condition check requested but no current HFR sample is available"
                    );
                    false
                }
            }
        }
        ConditionalCheck::WeatherSafe => {
            // WeatherSafe is the legacy "aggregated" check; it
            // never names a specific monitor. Always route with `None`.
            evaluate_safety_condition("Weather safety", context, None).await
        }
        ConditionalCheck::MoonSeparationAbove(degrees) => {
            let Some(separation) = context.calculate_moon_separation() else {
                tracing::error!("Conditional MoonSeparationAbove requires target coordinates");
                return NodeStatus::Failure;
            };
            separation > *degrees
        }
        ConditionalCheck::SafetyMonitorSafe => {
            // Multi-safety-monitor targeting. When the user
            // configured `safety_monitor_id` on the ConditionalConfig, we
            // pass it through to `safety_is_safe`; otherwise the dispatch
            // falls back to the aggregated / profile-default monitor.
            evaluate_safety_condition(
                "Safety monitor",
                context,
                config.safety_monitor_id.as_deref(),
            )
            .await
        }
    };

    if condition_met {
        execute_children_sequential(node, context).await
    } else {
        tracing::info!("Conditional check failed, skipping children");
        NodeStatus::Skipped
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::device_ops::SafetyOps;
    use crate::device_ops::{DeviceResult, NullDeviceOps, SharedDeviceOps};
    use crate::node::context::ExecutionContext;
    use crate::NodeId;
    use async_trait::async_trait;
    use std::sync::{Arc, Mutex};

    /// Test helper that records the `safety_id` passed to `safety_is_safe`
    /// and delegates everything else to `NullDeviceOps`. Lets the audit-C2
    /// dispatch test assert the safety_monitor_id flows from
    /// `ConditionalConfig` all the way down to the DeviceOps boundary.
    struct SafetyRecordingOps {
        inner: Arc<NullDeviceOps>,
        /// Captured `safety_id` argument of the last `safety_is_safe` call.
        /// `Some(None)` means "called with None"; `Some(Some(_))` means
        /// "called with a concrete id"; `None` means "never called".
        last_safety_id: Arc<Mutex<Option<Option<String>>>>,
        /// Whether `safety_is_safe` should return Ok(true). Tests flip this
        /// to false if they want to exercise the unsafe branch.
        safe_result: bool,
    }

    /// Recorded `safety_is_safe` argument: outer `Option` distinguishes
    /// "never called" (`None`) from "called" (`Some(_)`); inner `Option`
    /// captures the `safety_id` arg passed (`Some(Some(_))` = concrete id,
    /// `Some(None)` = called with `None`).
    type LastSafetyIdSlot = Arc<Mutex<Option<Option<String>>>>;

    impl SafetyRecordingOps {
        fn new(safe_result: bool) -> (Arc<Self>, LastSafetyIdSlot) {
            let last = Arc::new(Mutex::new(None));
            (
                Arc::new(Self {
                    inner: Arc::new(NullDeviceOps),
                    last_safety_id: last.clone(),
                    safe_result,
                }),
                last,
            )
        }
    }

    #[async_trait]
    impl SafetyOps for SafetyRecordingOps {
        // Override under test — capture the argument and short-circuit.
        async fn safety_is_safe(&self, safety_id: Option<&str>) -> DeviceResult<bool> {
            *self
                .last_safety_id
                .lock()
                .expect("safety_id mutex poisoned") = Some(safety_id.map(|s| s.to_string()));
            Ok(self.safe_result)
        }
    }

    crate::forward_device_ops!(SafetyRecordingOps => inner: MountOps, CameraOps, FocuserOps, FilterWheelOps, RotatorOps, GuiderOps, DomeOps, CoverCalibratorOps, PlateSolveOps, FrameStoreOps, OperatorNotifyOps, ConnectionOps, SiteOps);

    fn make_test_context(ops: SharedDeviceOps) -> ExecutionContext {
        ExecutionContext::new(NodeId::from("cond-test"), ops)
            .with_safety_fail_mode(SafetyFailMode::FailClosed)
    }

    #[test]
    fn safety_poll_error_contract_matches_fail_modes() {
        assert!(!safety_poll_error_condition_result(
            SafetyFailMode::FailClosed,
            Some(true)
        ));
        assert!(safety_poll_error_condition_result(
            SafetyFailMode::FailOpen,
            Some(false)
        ));
        assert!(safety_poll_error_condition_result(
            SafetyFailMode::WarnOnly,
            Some(true)
        ));
        assert!(!safety_poll_error_condition_result(
            SafetyFailMode::WarnOnly,
            Some(false)
        ));
        assert!(!safety_poll_error_condition_result(
            SafetyFailMode::WarnOnly,
            None
        ));
    }

    // ============================================================
    // Multi-safety-monitor targeting dispatch.

    /// When `safety_monitor_id` is `None`, the dispatch must call
    /// `safety_is_safe(None)` — that's the pre-C2 aggregated behaviour and
    /// every existing single-monitor sequence depends on it.
    #[tokio::test]
    async fn dispatch_passes_none_when_safety_monitor_id_absent() {
        let (ops, recorded) = SafetyRecordingOps::new(true);
        let context = make_test_context(ops.clone() as SharedDeviceOps);
        let result = evaluate_safety_condition("test", &context, None).await;
        assert!(result, "Ok(true) should propagate as 'safe'");
        let seen = recorded
            .lock()
            .expect("safety_id mutex poisoned")
            .clone()
            .expect("safety_is_safe was never invoked");
        assert!(
            seen.is_none(),
            "expected None safety_id, captured Some({:?})",
            seen
        );
    }

    /// When `safety_monitor_id` is `Some("safety-2")`, the dispatch must
    /// forward that exact id to `safety_is_safe` so a multi-monitor
    /// configuration can wire the conditional branch to one specific
    /// device.
    #[tokio::test]
    async fn dispatch_forwards_specific_safety_monitor_id() {
        let (ops, recorded) = SafetyRecordingOps::new(true);
        let context = make_test_context(ops.clone() as SharedDeviceOps);
        let result = evaluate_safety_condition("test", &context, Some("safety-2")).await;
        assert!(result);
        let seen = recorded
            .lock()
            .expect("safety_id mutex poisoned")
            .clone()
            .expect("safety_is_safe was never invoked");
        assert_eq!(
            seen.as_deref(),
            Some("safety-2"),
            "dispatch must forward the user-targeted safety monitor id"
        );
    }

    /// Wiring test: `execute_conditional` reads `safety_monitor_id` off the
    /// `ConditionalConfig` and propagates it through
    /// `evaluate_safety_condition` rather than hard-coding `None`.
    #[tokio::test]
    async fn execute_conditional_propagates_safety_monitor_id() {
        use crate::node::runtime::RuntimeNode;
        use crate::{ConditionalCheck, ConditionalConfig, NodeDefinition, NodeType};

        let (ops, recorded) = SafetyRecordingOps::new(true);
        let mut context = make_test_context(ops.clone() as SharedDeviceOps);

        let config = ConditionalConfig {
            condition: ConditionalCheck::SafetyMonitorSafe,
            safety_monitor_id: Some("rooftop-rain-sensor".to_string()),
        };

        let mut node = RuntimeNode::from_definition(NodeDefinition {
            id: NodeId::from("conditional-root"),
            name: "Conditional".to_string(),
            node_type: NodeType::Conditional(config.clone()),
            enabled: true,
            children: Vec::new(),
        });

        // execute_conditional returns Success when the safety check passes
        // and there are no children (sequential executor on an empty child
        // list returns Success). We don't care about the return value here
        // — only that the dispatch reached safety_is_safe with the right
        // id.
        let _ = execute_conditional(&mut node, config, &mut context).await;

        let seen = recorded
            .lock()
            .expect("safety_id mutex poisoned")
            .clone()
            .expect("execute_conditional did not invoke safety_is_safe");
        assert_eq!(
            seen.as_deref(),
            Some("rooftop-rain-sensor"),
            "ConditionalConfig.safety_monitor_id must flow into the DeviceOps call"
        );
    }

    /// When no `safety_monitor_id` is supplied (a single-monitor sequence),
    /// `execute_conditional` must still pass `None` so the
    /// aggregated/profile-default check fires.
    #[tokio::test]
    async fn execute_conditional_defaults_to_none_safety_id() {
        use crate::node::runtime::RuntimeNode;
        use crate::{ConditionalCheck, ConditionalConfig, NodeDefinition, NodeType};

        let (ops, recorded) = SafetyRecordingOps::new(true);
        let mut context = make_test_context(ops.clone() as SharedDeviceOps);

        let config = ConditionalConfig {
            condition: ConditionalCheck::SafetyMonitorSafe,
            safety_monitor_id: None,
        };

        let mut node = RuntimeNode::from_definition(NodeDefinition {
            id: NodeId::from("conditional-root"),
            name: "Conditional".to_string(),
            node_type: NodeType::Conditional(config.clone()),
            enabled: true,
            children: Vec::new(),
        });

        let _ = execute_conditional(&mut node, config, &mut context).await;

        let seen = recorded
            .lock()
            .expect("safety_id mutex poisoned")
            .clone()
            .expect("execute_conditional did not invoke safety_is_safe");
        assert!(
            seen.is_none(),
            "legacy ConditionalConfig (no safety_monitor_id) must dispatch with None, got {:?}",
            seen
        );
    }

    /// Serde compatibility: a sequence JSON without a `safety_monitor_id`
    /// key must still deserialize into a `ConditionalConfig` whose
    /// `safety_monitor_id` defaults to `None`. `#[serde(default)]` makes
    /// the field optional on the wire; this test pins that contract so
    /// future field reorganisations don't silently break saved sequences.
    ///
    /// Uses the canonical `{"type": "..."}` shape that matches
    /// the Dart serialiser (`#[serde(tag = "type", content = "value")]`
    /// on `ConditionalCheck`).
    #[test]
    fn conditional_config_deserializes_json_without_safety_id() {
        use crate::{ConditionalCheck, ConditionalConfig};

        let json = r#"{"condition":{"type":"SafetyMonitorSafe"}}"#;
        let parsed: ConditionalConfig = serde_json::from_str(json).expect("JSON must deserialize");
        assert!(matches!(
            parsed.condition,
            ConditionalCheck::SafetyMonitorSafe
        ));
        assert!(parsed.safety_monitor_id.is_none());
    }

    // ============================================================
    // ConditionalCheck Dart↔Rust serde handshake
    //
    // The Dart sequence executor emits each conditional condition as
    // `{"type": "<Variant>", "value": <data>}`. Under the externally-tagged
    // serde default, non-`Always` variants silently fail to deserialise —
    // every HfrBelow / GuidingRmsBelow / AltitudeAbove /
    // MoonSeparationAbove / TimeAfter conditional broken at the FFI
    // boundary. `ConditionalCheck` therefore pins
    // `#[serde(tag = "type", content = "value")]` to match the Dart wire
    // format.
    //
    // These tests are the guard: every variant round-trips through
    // serde_json, and the JSON shape produced is explicitly asserted
    // against the Dart-emitted format. If either side drifts the tests fail
    // loudly at `cargo test` time instead of waiting for an
    // HFR-conditional to misfire on a real imaging run.

    /// Round-trip every variant through serde_json. Encoding + decoding
    /// must yield a value `matches!()`-equivalent to the original — this
    /// catches missing variants and accidental representation changes.
    #[test]
    fn conditional_check_roundtrips_every_variant() {
        use crate::ConditionalCheck;

        let cases: Vec<ConditionalCheck> = vec![
            ConditionalCheck::Always,
            ConditionalCheck::AltitudeAbove(42.5),
            ConditionalCheck::TimeAfter(1_700_000_000),
            ConditionalCheck::GuidingRmsBelow(0.75),
            ConditionalCheck::HfrBelow(2.5),
            ConditionalCheck::WeatherSafe,
            ConditionalCheck::MoonSeparationAbove(30.0),
            ConditionalCheck::SafetyMonitorSafe,
        ];

        for original in cases {
            let json = serde_json::to_string(&original).expect("ConditionalCheck must serialize");
            let parsed: ConditionalCheck = serde_json::from_str(&json).unwrap_or_else(|e| {
                panic!("failed to round-trip {:?}: {} (json={})", original, e, json)
            });
            match (&original, &parsed) {
                (ConditionalCheck::Always, ConditionalCheck::Always) => {}
                (ConditionalCheck::WeatherSafe, ConditionalCheck::WeatherSafe) => {}
                (ConditionalCheck::SafetyMonitorSafe, ConditionalCheck::SafetyMonitorSafe) => {}
                (ConditionalCheck::AltitudeAbove(a), ConditionalCheck::AltitudeAbove(b))
                | (ConditionalCheck::GuidingRmsBelow(a), ConditionalCheck::GuidingRmsBelow(b))
                | (ConditionalCheck::HfrBelow(a), ConditionalCheck::HfrBelow(b))
                | (
                    ConditionalCheck::MoonSeparationAbove(a),
                    ConditionalCheck::MoonSeparationAbove(b),
                ) => {
                    assert!(
                        (a - b).abs() < 1e-9,
                        "f64 payload must round-trip exactly: {} != {}",
                        a,
                        b
                    );
                }
                (ConditionalCheck::TimeAfter(a), ConditionalCheck::TimeAfter(b)) => {
                    assert_eq!(a, b, "i64 payload must round-trip exactly");
                }
                _ => panic!(
                    "variant mismatch after round-trip: {:?} -> {:?}",
                    original, parsed
                ),
            }
        }
    }

    /// Pin the on-wire shape for a unit variant. Dart emits
    /// `{"type":"Always","value":null}`; serde with `tag/content`
    /// happily accepts that AND emits the shorter `{"type":"Always"}`
    /// form. Both must deserialise identically.
    #[test]
    fn conditional_check_unit_variant_wire_shape() {
        use crate::ConditionalCheck;

        // Rust → JSON. With `tag/content` on a unit variant, serde
        // omits the content field entirely.
        let json = serde_json::to_string(&ConditionalCheck::WeatherSafe).unwrap();
        assert_eq!(json, r#"{"type":"WeatherSafe"}"#);

        // Dart-emitted shape (explicit value:null) must still parse.
        let dart_shape = r#"{"type":"WeatherSafe","value":null}"#;
        let parsed: ConditionalCheck =
            serde_json::from_str(dart_shape).expect("Dart-emitted unit shape must deserialise");
        assert!(matches!(parsed, ConditionalCheck::WeatherSafe));
    }

    /// Pin the on-wire shape for a tuple variant. This is the case the
    /// previous default-serde representation broke at the FFI boundary
    /// — Dart sent `{"type":"HfrBelow","value":1.5}` and Rust expected
    /// `{"HfrBelow":1.5}`.
    #[test]
    fn conditional_check_tuple_variant_wire_shape() {
        use crate::ConditionalCheck;

        let json = serde_json::to_string(&ConditionalCheck::HfrBelow(2.5)).unwrap();
        assert_eq!(json, r#"{"type":"HfrBelow","value":2.5}"#);

        // Dart-emitted shape must round-trip back to the same value.
        let dart_shape = r#"{"type":"HfrBelow","value":2.5}"#;
        let parsed: ConditionalCheck =
            serde_json::from_str(dart_shape).expect("Dart-emitted tuple shape must deserialise");
        match parsed {
            ConditionalCheck::HfrBelow(v) => assert!((v - 2.5).abs() < 1e-9),
            other => panic!("expected HfrBelow(2.5), got {:?}", other),
        }
    }

    /// `TimeAfter` carries an `i64` (unix-millis or unix-seconds, the
    /// caller decides). Pin that the wire-shape uses the same payload
    /// the Dart side emits — `n.thresholdTime?.millisecondsSinceEpoch`
    /// for `ConditionalType.timeAfter`.
    #[test]
    fn conditional_check_time_after_wire_shape() {
        use crate::ConditionalCheck;

        let dart_shape = r#"{"type":"TimeAfter","value":1_700_000_000}"#;
        // JSON does not allow underscores in numbers — use the canonical form.
        let canonical = r#"{"type":"TimeAfter","value":1700000000}"#;
        let _ = dart_shape; // documentation reminder; the canonical shape is what we test.
        let parsed: ConditionalCheck =
            serde_json::from_str(canonical).expect("TimeAfter wire shape must deserialise");
        match parsed {
            ConditionalCheck::TimeAfter(t) => assert_eq!(t, 1_700_000_000),
            other => panic!("expected TimeAfter, got {:?}", other),
        }
    }

    /// The externally-tagged shape that a default-serde representation produces
    /// must NOT deserialise: a refactor that drops the `tag/content` attribute
    /// has to fail loudly here.
    #[test]
    fn conditional_check_rejects_externally_tagged_shape() {
        use crate::ConditionalCheck;

        let externally_tagged = r#"{"HfrBelow":2.5}"#;
        let result: Result<ConditionalCheck, _> = serde_json::from_str(externally_tagged);
        assert!(
            result.is_err(),
            "with #[serde(tag=type, content=value)] the legacy externally-tagged \
             shape MUST fail to deserialise; if it parses, the attribute is gone \
             and Dart-emitted conditionals are broken at the FFI boundary"
        );
    }
}
