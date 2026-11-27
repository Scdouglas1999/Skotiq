//! The device-id grammar against the app's copy.
//!
//! `test_fixtures/device_id/cases.json` records, for each id, what the app's
//! `DeviceId` makes of it (`device_id_fixture_test.dart`) and what
//! [`ParsedDeviceId::parse`] makes of it. The two parsers do not agree on
//! every id (the app tolerates forms the bridge refuses); the fixture states
//! each side's answer so a change on either side is a decision, not a drift.
//! Regenerate the bridge's answers after a deliberate change with
//! `SKOTIQ_WRITE_FIXTURES=1 cargo test -p skotiq_bridge --lib device_id::fixture_tests`.

use super::ParsedDeviceId;
use serde_json::{json, Value};

const FIXTURE: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../../test_fixtures/device_id/cases.json"
);

fn bridge_answer(id: &str) -> Value {
    match ParsedDeviceId::parse(id) {
        Ok(parsed) => {
            let mut value = serde_json::to_value(parsed).expect("serialize");
            if let Some(object) = value.as_object_mut() {
                object.remove("raw_id");
            }
            value
        }
        Err(_) => json!({ "refused": true }),
    }
}

#[test]
fn the_bridge_parses_every_fixture_id_as_recorded() {
    let text = std::fs::read_to_string(FIXTURE).expect("fixture");
    let mut cases: Vec<Value> = serde_json::from_str(&text).expect("fixture JSON");
    assert!(!cases.is_empty());
    if skotiq_wire_fixtures::writing_fixtures() {
        for case in &mut cases {
            let id = case["id"].as_str().expect("id").to_string();
            case["bridge"] = bridge_answer(&id);
        }
        let mut out = serde_json::to_string_pretty(&cases).expect("serialize");
        out.push('\n');
        std::fs::write(FIXTURE, out).expect("write fixture");
        return;
    }
    for case in &cases {
        let id = case["id"].as_str().expect("id");
        assert_eq!(bridge_answer(id), case["bridge"], "{id:?}");
    }
}
