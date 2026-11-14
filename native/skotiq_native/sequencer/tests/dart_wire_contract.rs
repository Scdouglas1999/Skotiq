//! The Dart side's sequence wire, read by the Rust types that receive it.
//!
//! `sequencerLoadJson` (bridge `api_sequencer_load_json`) is a plain
//! `serde_json::from_str::<SequenceDefinition>`: whatever Dart emits must
//! satisfy this crate's serde schema. The Dart node-codec golden test
//! (`packages/skotiq_core/test/services/node_codec_goldens`) writes what
//! `SequenceSerializer` produces for every node type, with every field at its
//! default and with every field set. This test reads the same files, so one
//! set of documents pins both sides.
//!
//! A field renamed or removed here still deserializes when it has a serde
//! default, and the value Dart sent is dropped without a word. So each
//! document is also written back out and compared: everything Dart sent must
//! come back as it was sent.

use std::path::PathBuf;

use serde_json::Value;
use skotiq_sequencer::{NodeDefinition, SequenceDefinition};

fn golden(name: &str) -> Value {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../packages/skotiq_core/test/services/node_codec_goldens/goldens")
        .join(name);
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("cannot read {}: {error}", path.display()));
    serde_json::from_str(&text).unwrap_or_else(|error| panic!("{name} is not JSON: {error}"))
}

/// Where `sent` holds something `kept` does not hold the same way.
///
/// Rust may add fields Dart leaves out, and writes an absent option as
/// `null`; neither is a difference. Numbers compare by value, so `4` and
/// `4.0` are the same.
fn lost(path: &str, sent: &Value, kept: &Value, out: &mut Vec<String>) {
    match (sent, kept) {
        (Value::Object(sent), Value::Object(kept)) => {
            for (key, value) in sent {
                let at = format!("{path}.{key}");
                match kept.get(key) {
                    Some(kept) => lost(&at, value, kept, out),
                    None if value.is_null() => {}
                    None => out.push(format!("{at}: sent {value}, not read")),
                }
            }
        }
        (Value::Array(sent), Value::Array(kept)) if sent.len() == kept.len() => {
            for (index, (sent, kept)) in sent.iter().zip(kept).enumerate() {
                lost(&format!("{path}[{index}]"), sent, kept, out);
            }
        }
        (Value::Number(sent), Value::Number(kept)) if sent.as_f64() == kept.as_f64() => {}
        _ if sent == kept => {}
        _ => out.push(format!("{path}: sent {sent}, read back as {kept}")),
    }
}

fn assert_nothing_lost(what: &str, sent: &Value, kept: &Value) {
    let mut differences = Vec::new();
    lost(what, sent, kept, &mut differences);
    assert!(
        differences.is_empty(),
        "the Dart wire and the Rust schema disagree:\n{}",
        differences.join("\n")
    );
}

/// Every node of a `wire_nodes_*.json` golden: node id to wire node.
fn assert_nodes_read(name: &str) {
    let Value::Object(nodes) = golden(name) else {
        panic!("{name} must be an object of nodes");
    };
    let mut read = 0;
    for (id, sent) in &nodes {
        // The golden also records the serializer's warnings beside the nodes.
        if id == "warnings" {
            continue;
        }
        let node: NodeDefinition = serde_json::from_value(sent.clone())
            .unwrap_or_else(|error| panic!("{name} {id} does not deserialize: {error}"));
        let kept = serde_json::to_value(&node).expect("a node serializes");
        assert_nothing_lost(&format!("{name} {id}"), sent, &kept);
        read += 1;
    }
    assert!(read > 0, "{name} holds no nodes");
}

#[test]
fn every_dart_node_with_default_fields_is_read_whole() {
    assert_nodes_read("wire_nodes_defaults.json");
}

#[test]
fn every_dart_node_with_every_field_set_is_read_whole() {
    assert_nodes_read("wire_nodes_full.json");
}

#[test]
fn the_dart_sequence_document_is_read_whole() {
    let sent = golden("wire_sequence_document.json");
    let definition: SequenceDefinition =
        serde_json::from_value(sent.clone()).expect("the Dart sequence document must deserialize");
    assert!(!definition.nodes.is_empty());
    let kept = serde_json::to_value(&definition).expect("a sequence serializes");
    assert_nothing_lost("wire_sequence_document.json", &sent, &kept);
}

/// The autofocus wire config as `SequenceSerializer` emits it, including the
/// per-focuser backlash figure the calibration measures.
///
/// `measured_backlash_in` is `#[serde(default)]`, so both halves of the
/// contract need pinning: a document that carries it must round-trip the
/// value, and a document from a build that predates it — or from a focuser
/// that has never been calibrated — must deserialize to `None` rather than
/// fail. The second half is what keeps an older client working.
#[test]
fn the_autofocus_wire_config_carries_the_measured_backlash() {
    let with_figure = serde_json::json!({
        "step_size": 75,
        "steps_out": 4,
        "exposure_duration": 0.5,
        "backlash_compensation": 0,
        "measured_backlash_in": 105,
    });
    let config: skotiq_sequencer::AutofocusConfig =
        serde_json::from_value(with_figure).expect("the Dart autofocus config must deserialize");

    assert_eq!(config.measured_backlash_in, Some(105));
    assert_eq!(
        config.backlash_compensation, 0,
        "the operator's own figure must stay separate from the measured one"
    );

    let without_figure = serde_json::json!({
        "step_size": 75,
        "steps_out": 4,
        "exposure_duration": 0.5,
    });
    let uncalibrated: skotiq_sequencer::AutofocusConfig = serde_json::from_value(without_figure)
        .expect("a document with no measured figure must still deserialize");
    assert_eq!(uncalibrated.measured_backlash_in, None);

    // Null is what Dart emits for a focuser with no stored calibration, and it
    // must mean the same thing as the key being absent.
    let explicit_null = serde_json::json!({
        "step_size": 75,
        "steps_out": 4,
        "exposure_duration": 0.5,
        "measured_backlash_in": serde_json::Value::Null,
    });
    let null_figure: skotiq_sequencer::AutofocusConfig =
        serde_json::from_value(explicit_null).expect("an explicit null must deserialize");
    assert_eq!(null_figure.measured_backlash_in, None);
}
