use super::*;

/// a flip moves the mount from one pier side to the other,
/// `mark_flip_performed` records the *origin* side, and a subsequent
/// observed return to the origin side must clear `has_flipped_this_target`
/// so a second flip is allowed for the same long-running target.
#[tokio::test]
async fn audit_1_9_pier_side_return_clears_flipped_flag() {
    let mut state = TriggerState::new();
    state.set_meridian_target("M101".to_string());

    // Pre-flip: mount on West side.
    state.update_pier_side(PierSide::West);
    assert!(!state.has_flipped_this_target);

    // Flip happens — pier side now reads East. The executor publishes
    // pier-side first, then calls mark_flip_performed (this is the live
    // sequence in `meridian_flip_executor::execute`'s success path).
    state.update_pier_side(PierSide::East);
    state.mark_flip_performed();
    assert!(state.has_flipped_this_target);
    assert_eq!(state.flip_origin_pier_side, Some(PierSide::West));

    // Some time later the mount returns to the original (West) side.
    // The return-to-origin invariant clears the flag so the trigger can fire again.
    state.update_pier_side(PierSide::West);
    assert!(
        !state.has_flipped_this_target,
        "has_flipped_this_target must clear when the mount returns to the pre-flip side"
    );
    assert_eq!(state.flip_origin_pier_side, None);
}

/// pier side `Unknown` must NOT clear the flag (it is not
/// authoritative evidence of a return-to-origin).
#[tokio::test]
async fn audit_1_9_unknown_pier_side_does_not_clear_flipped_flag() {
    let mut state = TriggerState::new();
    state.set_meridian_target("NGC 6888".to_string());
    state.update_pier_side(PierSide::West);
    state.update_pier_side(PierSide::East);
    state.mark_flip_performed();
    assert!(state.has_flipped_this_target);

    state.update_pier_side(PierSide::Unknown);
    assert!(
        state.has_flipped_this_target,
        "Unknown pier side must keep the flag latched until a real reading arrives"
    );
}

/// DriftLimit fires when accumulated plate-solve drift
/// exceeds the configured pixel budget. With a 30 px budget and a
/// (40, 30) drift the quadrature sum is 50 px and the trigger must fire.
#[tokio::test]
async fn audit_1_11_drift_limit_fires_when_drift_exceeds_threshold() {
    let mut trigger = Trigger::new(
        "test_drift",
        "Test Drift",
        TriggerType::DriftLimit { max_pixels: 30.0 },
        RecoveryAction::Recenter,
    );
    let mut state = TriggerState::new();
    // Target at RA=0deg, Dec=0deg — keeps the cos(dec) factor predictable.
    state.set_target(0.0, 0.0);
    // Pixel scale 1 arcsec/pixel so RA drift in arcsec equals pixels.
    // RA = 40/3600 deg drift, Dec = 30/3600 deg drift -> 40 px / 30 px.
    state.update_plate_solve(40.0 / 3600.0, 30.0 / 3600.0, 1.0);
    let drift = state.calculate_drift_pixels().expect("drift available");
    // Verify the helper math before exercising the trigger.
    assert!((drift.0 - 40.0).abs() < 0.001);
    assert!((drift.1 - 30.0).abs() < 0.001);
    assert!(trigger.check(&state).await, "drift 50 px must exceed 30 px");
}

/// DriftLimit must NOT fire below the budget (3 px drift
/// against a 30 px budget — quadrature sum stays well under).
#[tokio::test]
async fn audit_1_11_drift_limit_does_not_fire_below_threshold() {
    let mut trigger = Trigger::new(
        "test_drift",
        "Test Drift",
        TriggerType::DriftLimit { max_pixels: 30.0 },
        RecoveryAction::Recenter,
    );
    let mut state = TriggerState::new();
    state.set_target(0.0, 0.0);
    state.update_plate_solve(2.0 / 3600.0, 2.0 / 3600.0, 1.0);
    assert!(!trigger.check(&state).await);
}

/// with no plate-solve recorded the trigger evaluator
/// returns false (not error / not silent fire).
#[tokio::test]
async fn audit_1_11_drift_limit_inactive_without_plate_solve() {
    let mut trigger = Trigger::new(
        "test_drift",
        "Test Drift",
        TriggerType::DriftLimit { max_pixels: 30.0 },
        RecoveryAction::Recenter,
    );
    let state = TriggerState::new();
    assert!(!trigger.check(&state).await);
}

/// The standard-trigger builder creates a `DitherInterval` trigger so
/// periodic dithering is honoured even when the sequence does not contain an
/// explicit Dither node. The standard `DriftLimit` trigger is registered
/// alongside it.
#[tokio::test]
async fn audit_1_5_and_1_11_standard_triggers_include_new_audit_triggers() {
    let mut manager = TriggerManager::new();
    manager.create_standard_triggers();
    let names: Vec<String> = manager.triggers().iter().map(|t| t.id.clone()).collect();
    assert!(
        names.contains(&"dither_interval".to_string()),
        "DitherInterval standard trigger missing — regression. ids: {:?}",
        names
    );
    assert!(
        names.contains(&"drift_limit".to_string()),
        "DriftLimit standard trigger missing — regression. ids: {:?}",
        names
    );
}

/// The operator's meridian-flip settings must reach BOTH the trigger's own
/// config (which decides when to fire) and the recovery action's config
/// (which decides how the flip runs).
///
/// The standard trigger is seeded with `MeridianFlipConfig::default()`, so a
/// path that never replaces it leaves the whole Settings → Meridian Flip
/// panel inert — a run with `recenterAfterFlip: false` still executes
/// "Step 6/8: Plate solving and centering". The Rust defaults equal the panel
/// defaults, so only an operator who changed a value is silently ignored.
#[tokio::test]
async fn meridian_flip_settings_reach_both_trigger_and_recovery_action() {
    let mut manager = TriggerManager::new();
    manager.create_standard_triggers();

    // Sanity: the seeded trigger really carries the default config.
    let seeded = manager.get_trigger("meridian_flip").expect("trigger");
    match &seeded.trigger_type {
        TriggerType::MeridianFlip { config } => {
            assert!(config.auto_center, "default seeds auto_center = true");
            assert_eq!(config.minutes_past_meridian, 5.0);
        }
        other => panic!("expected a MeridianFlip trigger, got {:?}", other),
    }

    let user = crate::MeridianFlipConfig {
        minutes_past_meridian: 17.0,
        auto_center: false,
        refocus_after: true,
        pause_guiding: false,
        max_retries: 1,
        retry_delays_secs: vec![5.0],
        failure_action: crate::FlipFailureAction::AbortAndPark,
        ..Default::default()
    };
    assert!(
        manager.set_meridian_flip_config(user.clone()),
        "the standard meridian_flip trigger must be found"
    );

    let updated = manager.get_trigger("meridian_flip").expect("trigger");
    match &updated.trigger_type {
        TriggerType::MeridianFlip { config } => {
            assert_eq!(
                config.minutes_past_meridian, 17.0,
                "the FIRE threshold must follow the user's setting"
            );
        }
        other => panic!("expected a MeridianFlip trigger, got {:?}", other),
    }
    match &updated.recovery_action {
        RecoveryAction::MeridianFlip(config) => {
            assert!(
                !config.auto_center,
                "recenterAfterFlip=false must actually disable the \
                 post-flip plate-solve step"
            );
            assert!(config.refocus_after);
            assert!(!config.pause_guiding);
            assert_eq!(config.max_retries, 1);
            assert_eq!(config.retry_delays_secs, vec![5.0]);
            assert_eq!(
                config.failure_action,
                crate::FlipFailureAction::AbortAndPark
            );
        }
        other => panic!("expected a MeridianFlip action, got {:?}", other),
    }
}

/// A manager with no standard triggers must report that the push did not
/// land, so the caller can warn instead of silently running on defaults.
#[tokio::test]
async fn meridian_flip_settings_push_reports_missing_trigger() {
    let mut manager = TriggerManager::new();
    assert!(
        !manager.set_meridian_flip_config(crate::MeridianFlipConfig::default()),
        "pushing settings with no meridian_flip trigger registered must \
         report failure rather than silently succeeding"
    );
}

/// AutofocusInterval is part of the standard trigger set so periodic refocus
/// fires in sequences that lack an explicit Autofocus node. Symmetric with
/// the DitherInterval test.
#[tokio::test]
async fn trust_patch_3_standard_triggers_include_autofocus_interval() {
    let mut manager = TriggerManager::new();
    manager.create_standard_triggers();
    let names: Vec<String> = manager.triggers().iter().map(|t| t.id.clone()).collect();
    assert!(
        names.contains(&"autofocus_interval".to_string()),
        "AutofocusInterval standard trigger missing — trust-patch §3 regression. ids: {:?}",
        names
    );
}

/// HumidityThreshold trigger fires when state.current_humidity
/// exceeds the configured threshold and stays inactive when below.
#[tokio::test]
async fn trust_patch_2_humidity_threshold_fires_above_max_percent() {
    let mut trigger = Trigger::new(
        "humidity",
        "Humidity Threshold",
        TriggerType::HumidityThreshold { max_percent: 85.0 },
        RecoveryAction::Pause,
    );
    let mut state = TriggerState::new();

    // No humidity reading -> trigger stays inactive
    assert!(!trigger.check(&state).await);

    // Below threshold -> inactive
    state.update_humidity(70.0);
    assert!(!trigger.check(&state).await);

    // Above threshold -> fires
    state.update_humidity(90.0);
    assert!(trigger.check(&state).await);
}

/// FocusDrift trigger uses VecDeque so trimming is O(1)
/// and the window stays bounded.
#[tokio::test]
async fn trust_patch_6_focus_drift_window_uses_vecdeque_and_is_bounded() {
    let mut trigger = Trigger::new(
        "focus_drift",
        "Focus Drift",
        TriggerType::FocusDrift {
            window_size: 5,
            min_increasing_count: 3,
            min_total_increase: 0.3,
        },
        RecoveryAction::Autofocus,
    );

    let mut state = TriggerState::new();
    // Feed monotonically increasing HFR values to force a trip:
    // window will hold the last 5 of these.
    for hfr in [1.0_f64, 1.2, 1.4, 1.6, 1.9, 2.3, 2.7] {
        state.current_hfr = Some(hfr);
        // No assertion on intermediate state — the trigger may or may
        // not have fired by now; what matters is the window cap.
        let _ = trigger.check(&state).await;
    }

    // Window must not exceed configured size.
    assert!(
        trigger.focus_drift_hfr_window.len() <= 5,
        "FocusDrift window {} exceeded configured size 5",
        trigger.focus_drift_hfr_window.len()
    );
}

/// `Trigger::new_focus_drift_checked` rejects oversize
/// windows up-front (instead of silently clamping the way `new` does
/// for stored sequences).
#[test]
fn trust_patch_6_focus_drift_checked_rejects_oversize_windows() {
    let err = Trigger::new_focus_drift_checked(
        "fd",
        "FD",
        FOCUS_DRIFT_WINDOW_MAX + 1,
        5,
        0.5,
        RecoveryAction::Autofocus,
    )
    .expect_err("oversize window must be rejected");
    assert!(err.contains("exceeds maximum"), "error message: {}", err);
}

/// `Trigger::new` clamps oversize windows silently with
/// a tracing warning so a checkpoint-restored sequence with a stale
/// window still loads.
#[test]
fn trust_patch_6_focus_drift_new_clamps_oversize_windows() {
    let trigger = Trigger::new(
        "fd",
        "FD",
        TriggerType::FocusDrift {
            window_size: FOCUS_DRIFT_WINDOW_MAX * 2,
            min_increasing_count: 5,
            min_total_increase: 0.5,
        },
        RecoveryAction::Autofocus,
    );
    match trigger.trigger_type {
        TriggerType::FocusDrift { window_size, .. } => {
            assert_eq!(
                window_size, FOCUS_DRIFT_WINDOW_MAX,
                "Trigger::new must clamp oversize FocusDrift windows to FOCUS_DRIFT_WINDOW_MAX"
            );
        }
        _ => panic!("expected FocusDrift trigger_type after construction"),
    }
    // clamp must also populate the visible diagnostic so
    // the executor can surface it on start (ExecutorEvent::Error).
    let warning = trigger
        .clamp_warning
        .as_ref()
        .expect("clamp_warning must be populated when window was clamped");
    assert_eq!(warning.field, "FocusDrift.window_size");
    assert_eq!(warning.original, FOCUS_DRIFT_WINDOW_MAX * 2);
    assert_eq!(warning.clamped_to, FOCUS_DRIFT_WINDOW_MAX);
}

/// when no clamping occurs, `clamp_warning` must be None
/// so the executor doesn't emit spurious clamp errors for healthy
/// configurations.
#[test]
fn wave_1_5_focus_drift_below_cap_has_no_clamp_warning() {
    let trigger = Trigger::new(
        "fd",
        "FD",
        TriggerType::FocusDrift {
            window_size: 5,
            min_increasing_count: 3,
            min_total_increase: 0.5,
        },
        RecoveryAction::Autofocus,
    );
    assert!(
        trigger.clamp_warning.is_none(),
        "clamp_warning must be None for healthy FocusDrift windows"
    );
}

/// the GuidingFailed standard trigger ships
/// `rms_retention_secs = default_guiding_rms_retention_secs()` (300s)
/// and `TriggerManager::sync_state_from_config` propagates that value
/// into the shared trigger state on every check_all. A user-tuned value
/// flows through without a sequence reload.
#[tokio::test]
async fn audit_1_21_guiding_rms_retention_propagates_via_sync() {
    let mut manager = TriggerManager::new();
    manager.create_standard_triggers();

    // Find the GuidingFailed trigger and bump its retention.
    let trigger = manager
        .get_trigger_mut("guiding_failed")
        .expect("standard guiding_failed trigger registered");
    if let TriggerType::GuidingFailed {
        rms_retention_secs, ..
    } = &mut trigger.trigger_type
    {
        *rms_retention_secs = 600;
    } else {
        panic!("guiding_failed trigger must be GuidingFailed variant");
    }

    // Synchronise — would be called from check_all in production.
    manager.sync_state_from_config().await;
    let state = manager.state();
    let guard = state.read().await;
    assert_eq!(
        guard.guiding_rms_retention_secs, 600,
        "sync_state_from_config must push rms_retention_secs into TriggerState"
    );
}

// cloud-motion-aware trigger tests

/// CloudArrivingIn fires when both the arrival-time AND coverage gates
/// are satisfied. Without coverage data the trigger stays quiescent.
#[tokio::test]
async fn wave_5_cloud_arriving_in_fires_when_both_gates_satisfied() {
    let mut trigger = Trigger::new(
        "test_cloud_arriving",
        "Test Cloud Arriving",
        TriggerType::CloudArrivingIn {
            minutes_before: 10.0,
            coverage_threshold: 70.0,
        },
        RecoveryAction::PauseAndWaitForClear,
    );
    let mut state = TriggerState::new();

    // No data => no fire.
    assert!(!trigger.check(&state).await);

    // Far away clouds (30 min) but high coverage => no fire (time gate).
    state.update_cloud_motion(Some(80.0), Some(30.0), None, None, None);
    assert!(!trigger.check(&state).await);

    // Reset & close clouds but low coverage => no fire (coverage gate).
    let mut trigger2 = Trigger::new(
        "test_cloud_arriving_2",
        "Test Cloud Arriving 2",
        TriggerType::CloudArrivingIn {
            minutes_before: 10.0,
            coverage_threshold: 70.0,
        },
        RecoveryAction::PauseAndWaitForClear,
    );
    let mut state2 = TriggerState::new();
    state2.update_cloud_motion(Some(50.0), Some(8.0), None, None, None);
    assert!(!trigger2.check(&state2).await);

    // Both gates satisfied => fire.
    let mut trigger3 = Trigger::new(
        "test_cloud_arriving_3",
        "Test Cloud Arriving 3",
        TriggerType::CloudArrivingIn {
            minutes_before: 10.0,
            coverage_threshold: 70.0,
        },
        RecoveryAction::PauseAndWaitForClear,
    );
    let mut state3 = TriggerState::new();
    state3.update_cloud_motion(Some(85.0), Some(8.0), None, None, None);
    assert!(trigger3.check(&state3).await);
}

/// CloudOpeningIn requires the opening to be both within the lead time
/// AND of at-least the configured minimum duration.
#[tokio::test]
async fn wave_5_cloud_opening_in_requires_lead_time_and_duration() {
    let mut trigger = Trigger::new(
        "test_cloud_opening",
        "Test Cloud Opening",
        TriggerType::CloudOpeningIn {
            minutes_before: 5.0,
            minimum_duration_secs: 300.0,
        },
        RecoveryAction::Continue,
    );
    let mut state = TriggerState::new();

    // No data => no fire.
    assert!(!trigger.check(&state).await);

    // Opening in 10 min (too far) but 600s duration => no fire.
    state.update_cloud_motion(Some(80.0), None, Some(10.0), Some(600.0), None);
    assert!(!trigger.check(&state).await);

    // Reset & opening in 3 min but 100s duration (too short) => no fire.
    let mut trigger2 = Trigger::new(
        "test_cloud_opening_2",
        "Test Cloud Opening 2",
        TriggerType::CloudOpeningIn {
            minutes_before: 5.0,
            minimum_duration_secs: 300.0,
        },
        RecoveryAction::Continue,
    );
    let mut state2 = TriggerState::new();
    state2.update_cloud_motion(Some(80.0), None, Some(3.0), Some(100.0), None);
    assert!(!trigger2.check(&state2).await);

    // Both gates satisfied => fire.
    let mut trigger3 = Trigger::new(
        "test_cloud_opening_3",
        "Test Cloud Opening 3",
        TriggerType::CloudOpeningIn {
            minutes_before: 5.0,
            minimum_duration_secs: 300.0,
        },
        RecoveryAction::Continue,
    );
    let mut state3 = TriggerState::new();
    state3.update_cloud_motion(Some(80.0), None, Some(3.0), Some(600.0), None);
    assert!(trigger3.check(&state3).await);

    // Duration unknown => refuse to fire.
    let mut trigger4 = Trigger::new(
        "test_cloud_opening_4",
        "Test Cloud Opening 4",
        TriggerType::CloudOpeningIn {
            minutes_before: 5.0,
            minimum_duration_secs: 300.0,
        },
        RecoveryAction::Continue,
    );
    let mut state4 = TriggerState::new();
    state4.update_cloud_motion(Some(80.0), None, Some(3.0), None, None);
    assert!(!trigger4.check(&state4).await);
}

/// CloudCoverThreshold honours the per-trigger debounce: a single sample
/// above the threshold does not fire until `duration_secs` has elapsed.
#[tokio::test]
async fn wave_5_cloud_cover_threshold_debounces() {
    let mut trigger = Trigger::new(
        "test_cover_threshold",
        "Test Cover Threshold",
        TriggerType::CloudCoverThreshold {
            max_percent: 50.0,
            duration_secs: 60.0,
        },
        RecoveryAction::Pause,
    );
    let mut state = TriggerState::new();

    // Below threshold => no arm.
    state.update_cloud_motion(Some(20.0), None, None, None, None);
    assert!(!trigger.check(&state).await);
    assert!(trigger.cloud_cover_above_threshold_since.is_none());

    // First above-threshold sample arms the debounce timer.
    state.update_cloud_motion(Some(80.0), None, None, None, None);
    assert!(!trigger.check(&state).await);
    assert!(trigger.cloud_cover_above_threshold_since.is_some());

    // duration_secs=0 should fire immediately on the first sample.
    let mut trigger_no_debounce = Trigger::new(
        "test_cover_immediate",
        "Test Cover Immediate",
        TriggerType::CloudCoverThreshold {
            max_percent: 50.0,
            duration_secs: 0.0,
        },
        RecoveryAction::Pause,
    );
    let mut state2 = TriggerState::new();
    state2.update_cloud_motion(Some(80.0), None, None, None, None);
    assert!(trigger_no_debounce.check(&state2).await);
}

/// Cover dropping back below the threshold must reset the debounce
/// timer — otherwise a flapping cover would eventually fire after the
/// total elapsed time crossed the threshold.
#[tokio::test]
async fn wave_5_cloud_cover_threshold_resets_on_drop() {
    let mut trigger = Trigger::new(
        "test_cover_reset",
        "Test Cover Reset",
        TriggerType::CloudCoverThreshold {
            max_percent: 50.0,
            duration_secs: 60.0,
        },
        RecoveryAction::Pause,
    );
    let mut state = TriggerState::new();

    // Above threshold arms.
    state.update_cloud_motion(Some(80.0), None, None, None, None);
    assert!(!trigger.check(&state).await);
    let armed_at = trigger.cloud_cover_above_threshold_since;
    assert!(armed_at.is_some());

    // Drop below threshold clears the arm.
    state.update_cloud_motion(Some(20.0), None, None, None, None);
    assert!(!trigger.check(&state).await);
    assert!(trigger.cloud_cover_above_threshold_since.is_none());
}

/// Trigger respects the per-Trigger cooldown after firing.
#[tokio::test]
async fn wave_5_cloud_arriving_respects_cooldown() {
    let mut trigger = Trigger::new(
        "test_cooldown",
        "Test Cooldown",
        TriggerType::CloudArrivingIn {
            minutes_before: 10.0,
            coverage_threshold: 70.0,
        },
        RecoveryAction::PauseAndWaitForClear,
    )
    .with_cooldown(60);
    let mut state = TriggerState::new();
    state.update_cloud_motion(Some(85.0), Some(8.0), None, None, None);
    assert!(trigger.check(&state).await);
    // Cooldown should suppress the second fire.
    assert!(!trigger.check(&state).await);
}

/// `update_cloud_motion` rejects NaN / Inf and clamps cover to [0,100].
#[tokio::test]
async fn wave_5_update_cloud_motion_sanitises_inputs() {
    let mut state = TriggerState::new();
    state.update_cloud_motion(Some(150.0), Some(-5.0), None, None, None);
    assert_eq!(state.current_cloud_coverage_percent, Some(100.0));
    assert_eq!(state.predicted_cloud_arrival_minutes, Some(0.0));

    state.update_cloud_motion(Some(f64::NAN), Some(f64::INFINITY), None, None, None);
    assert_eq!(
        state.current_cloud_coverage_percent, None,
        "NaN cover must produce None"
    );
    assert_eq!(
        state.predicted_cloud_arrival_minutes, None,
        "Inf arrival must produce None"
    );
}

/// JSON round-trip for the three new TriggerType variants.
#[test]
fn wave_5_cloud_trigger_types_round_trip_through_serde() {
    for original in [
        TriggerType::CloudArrivingIn {
            minutes_before: 12.5,
            coverage_threshold: 65.0,
        },
        TriggerType::CloudOpeningIn {
            minutes_before: 4.0,
            minimum_duration_secs: 420.0,
        },
        TriggerType::CloudCoverThreshold {
            max_percent: 75.0,
            duration_secs: 30.0,
        },
    ] {
        let json = serde_json::to_string(&original).expect("serialize");
        let back: TriggerType = serde_json::from_str(&json).expect("deserialize");
        // We compare via the round-tripped JSON because TriggerType
        // doesn't implement PartialEq.
        let back_json = serde_json::to_string(&back).expect("re-serialize");
        assert_eq!(json, back_json, "trigger type JSON must round-trip");
    }
}

/// JSON round-trip for the two new RecoveryAction variants.
#[test]
fn wave_5_cloud_recovery_actions_round_trip_through_serde() {
    for original in [
        RecoveryAction::PauseAndWaitForClear,
        RecoveryAction::SlewToGapAndContinue,
    ] {
        let json = serde_json::to_string(&original).expect("serialize");
        let back: RecoveryAction = serde_json::from_str(&json).expect("deserialize");
        let back_json = serde_json::to_string(&back).expect("re-serialize");
        assert_eq!(json, back_json, "recovery action JSON must round-trip");
    }
}

// Science — TransparencyDropped trigger tests.

#[tokio::test]
async fn wave_7_transparency_dropped_fires_below_threshold_immediately() {
    let mut trigger = Trigger::new(
        "test_transparency_immediate",
        "Test Transparency Immediate",
        TriggerType::TransparencyDropped {
            below_threshold: 0.7,
            // duration_secs = 0.0 => fire on the first sample below
            // threshold (matches `CloudCoverThreshold` semantics).
            duration_secs: 0.0,
        },
        RecoveryAction::SwitchTargetOrFilter,
    );
    let mut state = TriggerState::new();

    // Above threshold => no fire, no arm.
    state.update_transparency(Some(0.95));
    assert!(!trigger.check(&state).await);
    assert!(trigger.transparency_below_threshold_since.is_none());

    // Below threshold + duration=0 => fires immediately.
    state.update_transparency(Some(0.5));
    assert!(trigger.check(&state).await);
}

#[tokio::test]
async fn wave_7_transparency_dropped_debounces() {
    let mut trigger = Trigger::new(
        "test_transparency_debounce",
        "Test Transparency Debounce",
        TriggerType::TransparencyDropped {
            below_threshold: 0.7,
            duration_secs: 60.0,
        },
        RecoveryAction::SwitchTargetOrFilter,
    );
    let mut state = TriggerState::new();

    // First below-threshold sample arms but does NOT fire.
    state.update_transparency(Some(0.5));
    assert!(!trigger.check(&state).await);
    assert!(trigger.transparency_below_threshold_since.is_some());

    // Drop back above threshold => arm cleared, no fire.
    state.update_transparency(Some(0.9));
    assert!(!trigger.check(&state).await);
    assert!(trigger.transparency_below_threshold_since.is_none());
}

#[tokio::test]
async fn wave_7_transparency_dropped_handles_missing_data() {
    let mut trigger = Trigger::new(
        "test_transparency_no_data",
        "Test Transparency No Data",
        TriggerType::TransparencyDropped {
            below_threshold: 0.7,
            duration_secs: 0.0,
        },
        RecoveryAction::SwitchTargetOrFilter,
    );
    let mut state = TriggerState::new();

    // No transparency telemetry yet — must NOT fire ("no
    // silent fallbacks": absent data is not a trigger condition).
    assert!(!trigger.check(&state).await);
    assert!(trigger.transparency_below_threshold_since.is_none());

    // After Dart pushes None (lock lost), still no fire.
    state.update_transparency(None);
    assert!(!trigger.check(&state).await);
}

#[test]
fn wave_7_update_transparency_drops_non_finite() {
    let mut state = TriggerState::new();
    state.update_transparency(Some(f64::NAN));
    assert_eq!(state.current_transparency, None);
    state.update_transparency(Some(f64::INFINITY));
    assert_eq!(state.current_transparency, None);
    // Valid values flow through.
    state.update_transparency(Some(0.6));
    assert_eq!(state.current_transparency, Some(0.6));
}
