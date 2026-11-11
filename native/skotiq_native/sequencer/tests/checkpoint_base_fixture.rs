//! Checkpoints on users' disks must keep loading.
//!
//! `fixtures/checkpoint_base_c04d55c8d.json` was written by
//! `CheckpointManager::save` at commit c04d55c8d, before the trigger state was
//! split into parts, with every trigger-state field set to a value that is not
//! its default. This test reads it through the public API only, so it holds
//! unchanged across any restructuring of the trigger state.

use skotiq_sequencer::{
    CheckpointManager, ExecutorState, NodeStatus, SafetyFailMode, SessionCheckpoint, TriggerState,
    TriggerStateSnapshot,
};

const FIXTURE: &str = include_str!("fixtures/checkpoint_base_c04d55c8d.json");

/// Every field the trigger-state snapshot carried at c04d55c8d.
const TRIGGER_STATE_FIELDS: [&str; 45] = [
    "baseline_hfr",
    "current_hfr",
    "autofocus_invalidated",
    "autofocus_invalidation_reason",
    "current_hour_angle",
    "pier_side",
    "mount_tracking_limit_time",
    "has_flipped_this_target",
    "current_target_name",
    "guiding_enabled",
    "guide_star_lost",
    "current_humidity",
    "current_altitude",
    "weather_safe",
    "baseline_temperature",
    "current_temperature",
    "baseline_focuser_position",
    "filter_changed",
    "current_filter",
    "dawn_time",
    "observer_latitude",
    "observer_longitude",
    "completed_exposures",
    "last_autofocus_frame",
    "last_dither_frame",
    "last_plate_solve_ra",
    "last_plate_solve_dec",
    "last_plate_solve_pixel_scale",
    "target_ra",
    "target_dec",
    "mount_is_tracking",
    "mount_tracking_expected",
    "mount_tracking_lost",
    "mount_slewing",
    "mount_parked",
    "mount_status_query_failed",
    "tracking_limit_detected_at",
    "meridian_trigger_method",
    "dome_shutter_status",
    "dome_shutter_open_expected",
    "grid_dither_index",
    "safety_fail_mode",
    "triggers_enabled",
    "filter_focus_offsets",
    "last_applied_filter_offset",
];

fn fixture_trigger_state() -> serde_json::Map<String, serde_json::Value> {
    let fixture: serde_json::Value = serde_json::from_str(FIXTURE).unwrap();
    fixture["trigger_state"].as_object().unwrap().clone()
}

fn load_through_the_manager(test: &str) -> SessionCheckpoint {
    let dir = std::env::temp_dir().join(format!(
        "skotiq_checkpoint_base_fixture_{test}_{}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("skotiq_session.checkpoint"), FIXTURE).unwrap();
    let loaded = CheckpointManager::new(&dir)
        .load()
        .expect("the base checkpoint must load")
        .expect("the base checkpoint must be found");
    let _ = std::fs::remove_dir_all(&dir);
    loaded
}

#[test]
fn the_fixture_sets_every_trigger_state_field_to_a_non_default_value() {
    let fields = fixture_trigger_state();
    let mut names: Vec<&str> = fields.keys().map(String::as_str).collect();
    names.sort_unstable();
    let mut expected = TRIGGER_STATE_FIELDS.to_vec();
    expected.sort_unstable();
    assert_eq!(names, expected);

    for (name, value) in &fields {
        let is_default = match value {
            serde_json::Value::Null => true,
            // `triggers_enabled` is on by default, so off is its non-default.
            serde_json::Value::Bool(on) => *on == (name == "triggers_enabled"),
            serde_json::Value::Number(n) => n.as_f64() == Some(0.0),
            serde_json::Value::String(s) => s.is_empty() || s == "FailClosed",
            serde_json::Value::Object(map) => map.is_empty(),
            serde_json::Value::Array(items) => items.is_empty(),
        };
        assert!(
            !is_default,
            "fixture field '{name}' holds a default: {value}"
        );
    }
}

#[test]
fn a_base_checkpoint_loads_with_its_run_position() {
    let loaded = load_through_the_manager("run_position");
    assert_eq!(loaded.version, 3);
    assert_eq!(loaded.sequence.name, "Base fixture");
    assert_eq!(loaded.executor_state, ExecutorState::Running);
    assert!(loaded.is_active);
    assert_eq!(
        loaded.node_statuses.get("node-1"),
        Some(&NodeStatus::Success)
    );
    assert_eq!(loaded.last_completed_node.as_deref(), Some("node-1"));
    assert_eq!(loaded.current_node.as_deref(), Some("node-2"));
    assert_eq!(loaded.camera_id.as_deref(), Some("sim:camera"));
    assert_eq!(loaded.mount_id.as_deref(), Some("sim:mount"));
    assert_eq!(loaded.focuser_id.as_deref(), Some("sim:focuser"));
    assert_eq!(loaded.filterwheel_id.as_deref(), Some("sim:wheel"));
    assert_eq!(loaded.rotator_id.as_deref(), Some("sim:rotator"));
    assert_eq!(loaded.latitude, Some(45.5));
    assert_eq!(loaded.longitude, Some(-122.625));
    assert_eq!(loaded.completed_exposures, 42);
    assert_eq!(loaded.completed_integration_secs, 7560.0);
    assert_eq!(loaded.loop_iterations.get("loop-1"), Some(&3));
    assert_eq!(loaded.ended, None);
}

/// Restore the snapshot into a fresh trigger state, snapshot that state
/// again, and compare with the file field by field. A field that the restore
/// drops, or that the snapshot stops writing, or whose name or level in the
/// JSON changes, shows up as a difference.
#[test]
fn every_trigger_state_field_of_a_base_checkpoint_is_restored() {
    let loaded = load_through_the_manager("trigger_state");
    let snapshot = loaded
        .trigger_state
        .as_ref()
        .expect("the base checkpoint carries trigger state");

    assert_eq!(snapshot.safety_fail_mode, SafetyFailMode::WarnOnly);
    assert!(!snapshot.triggers_enabled);
    assert_eq!(snapshot.filter_focus_offsets.get("Ha"), Some(&42));
    assert_eq!(snapshot.filter_focus_offsets.get("OIII"), Some(&-17));

    let mut state = TriggerState::new();
    snapshot.restore_into(&mut state);
    let again = TriggerStateSnapshot::from_state(
        &state,
        snapshot.safety_fail_mode,
        snapshot.triggers_enabled,
        snapshot.filter_focus_offsets.clone(),
    );
    let again = serde_json::to_value(&again).unwrap();
    let again = again.as_object().unwrap();

    let expected = fixture_trigger_state();
    for name in TRIGGER_STATE_FIELDS {
        assert_eq!(
            again.get(name),
            expected.get(name),
            "trigger-state field '{name}' did not survive the restore"
        );
    }
    assert_eq!(again.len(), expected.len(), "fields: {:?}", again.keys());
}
