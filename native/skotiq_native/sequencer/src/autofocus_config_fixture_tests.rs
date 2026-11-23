//! The app's autofocus config against the engine's.
//!
//! `test_fixtures/autofocus_config/cases.json` holds the config the app's
//! sequence serializer sends for a set of settings (checked by
//! `autofocus_config_fixture_test.dart`). Here the engine reads each one: a
//! key the app sends must be a field of [`AutofocusConfig`] with the value the
//! app meant, and every field the app does not send is named below, so a
//! field added or renamed on either side fails a test.

use crate::{AutofocusConfig, NodeType};
use std::collections::BTreeSet;

/// Fields the app never sends; the engine's serde default applies.
const ENGINE_ONLY_FIELDS: &[&str] = &[
    "gain",
    "offset",
    "min_star_count",
    "outlier_rejection_sigma",
];

fn cases() -> Vec<serde_json::Value> {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../test_fixtures/autofocus_config/cases.json"
    );
    serde_json::from_str(&std::fs::read_to_string(path).expect("fixture")).expect("fixture JSON")
}

fn engine_fields() -> BTreeSet<String> {
    serde_json::to_value(AutofocusConfig::default())
        .expect("serialize")
        .as_object()
        .expect("object")
        .keys()
        .cloned()
        .collect()
}

#[test]
fn the_fixture_has_cases() {
    assert!(!cases().is_empty());
}

#[test]
fn every_sent_config_reads_as_the_app_meant() {
    for case in cases() {
        let name = case["name"].as_str().expect("name");
        let sent = case["config"].as_object().expect("config");
        let node: NodeType = serde_json::from_value(case["config"].clone())
            .unwrap_or_else(|e| panic!("{name}: the engine refuses the config: {e}"));
        let NodeType::Autofocus(config) = node else {
            panic!("{name}: not an Autofocus node");
        };
        let read = serde_json::to_value(&config).expect("serialize");
        for (key, value) in sent {
            if key == "type" {
                continue;
            }
            assert!(
                read.get(key).is_some(),
                "{name}: the app sends `{key}`, which is not an AutofocusConfig field"
            );
            assert_eq!(&read[key], value, "{name}: `{key}` reads differently");
        }
    }
}

#[test]
fn every_engine_field_is_sent_or_named_engine_only() {
    let engine = engine_fields();
    for case in cases() {
        let name = case["name"].as_str().expect("name");
        let sent: BTreeSet<String> = case["config"]
            .as_object()
            .expect("config")
            .keys()
            .filter(|k| *k != "type")
            .cloned()
            .collect();
        let mut covered = sent.clone();
        covered.extend(ENGINE_ONLY_FIELDS.iter().map(|f| f.to_string()));
        assert_eq!(
            covered, engine,
            "{name}: fields neither sent nor engine-only"
        );
        for field in ENGINE_ONLY_FIELDS {
            assert!(
                !sent.contains(*field),
                "{name}: `{field}` is sent; drop it from ENGINE_ONLY_FIELDS"
            );
        }
    }
}
