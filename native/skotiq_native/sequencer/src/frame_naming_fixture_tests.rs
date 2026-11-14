//! The app's file-naming tokens against the run's.
//!
//! `test_fixtures/frame_naming/run_tokens.json` is held to the app's token
//! table by a Dart test (`naming_pattern_test.dart`) and to the sequencer
//! here, so a placeholder or a label changed on one side fails a test.

use crate::expressions::resolver::{NO_FILTER_LABEL, NO_TARGET_LABEL};
use crate::expressions::{parse_template, variable_catalog, TemplatePart};
use crate::FrameType;

fn fixture() -> serde_json::Value {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../test_fixtures/frame_naming/run_tokens.json"
    );
    serde_json::from_str(&std::fs::read_to_string(path).expect("fixture"))
        .expect("fixture JSON")
}

#[test]
fn every_run_placeholder_names_a_catalog_variable() {
    let placeholders = fixture()["run_placeholders"]
        .as_object()
        .expect("run_placeholders")
        .clone();
    for (token, template) in placeholders {
        let template = template.as_str().expect("template");
        let parts = parse_template(template).expect("placeholder parses");
        for part in parts {
            if let TemplatePart::Variable {
                name, format_spec, ..
            } = part
            {
                let entry = variable_catalog()
                    .iter()
                    .find(|e| e.name == name)
                    .unwrap_or_else(|| panic!("{token}: {name} is not in the catalog"));
                assert!(
                    format_spec.is_none() || entry.supports_format,
                    "{token}: {name} takes no format spec"
                );
            }
        }
    }
}

#[test]
fn a_frame_with_no_filter_or_target_gets_the_app_labels() {
    let fixture = fixture();
    assert_eq!(fixture["no_filter_label"], NO_FILTER_LABEL);
    let labels = fixture["no_target_label"]
        .as_object()
        .expect("no_target_label");
    for (spelling, label) in labels {
        let frame_type = FrameType::from_name(spelling).expect("frame type");
        let expected = if frame_type.is_calibration() {
            frame_type.as_str()
        } else {
            NO_TARGET_LABEL
        };
        assert_eq!(label, expected, "{spelling}");
    }
}
