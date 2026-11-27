//! `test_fixtures/wire_words/run_ids.json`: ids the run publishes that the
//! app compares against by value. Regenerate with
//! `SKOTIQ_WRITE_FIXTURES=1 cargo test -p skotiq_sequencer run_ids_fixture`.

use crate::meridian_flip_executor::MERIDIAN_FLIP_INSTRUCTION;
use crate::node::logic::target_header::{
    TARGET_BELOW_FLOOR_TRIGGER_ID, TARGET_END_WHEN_TRIGGER_ID,
};
use crate::triggers::StandardTrigger;

#[test]
fn run_ids_fixture() {
    let value = serde_json::json!({
        "meridianFlipInstruction": MERIDIAN_FLIP_INSTRUCTION,
        "targetBelowFloorTrigger": TARGET_BELOW_FLOOR_TRIGGER_ID,
        "targetEndWhenTrigger": TARGET_END_WHEN_TRIGGER_ID,
        "weatherUnsafeTrigger": StandardTrigger::WeatherUnsafe.spec().id,
    });
    skotiq_wire_fixtures::pin_json(
        "wire_words/run_ids.json",
        &value,
        "an id the app matches changed; regenerate the fixture and update the app",
    );
}

#[test]
fn the_flip_instruction_is_the_meridian_flip_node_name() {
    assert_eq!(
        crate::NodeType::MeridianFlip(Default::default()).wire_name(),
        MERIDIAN_FLIP_INSTRUCTION
    );
}
