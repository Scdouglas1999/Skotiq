//! The operation catalogue the app builds recipes against.
//!
//! `test_fixtures/darkroom_ops/catalog.json` is the catalogue's contract part:
//! each operation's id, version and stage, each parameter's kind, bounds and
//! default, and the recipe schema version. The app's recipe builders are held
//! to it by Dart tests (`live_darkroom_recipe_contract_test.dart`,
//! `recipe_schema_version_test.dart`), so a range moved here and not there
//! fails a test. Regenerate after a deliberate change with
//! `SKOTIQ_WRITE_FIXTURES=1 cargo test -p skotiq_processing catalog_fixture`.

use serde_json::{json, Map, Value};
use skotiq_imaging::recipe::RECIPE_SCHEMA_VERSION;

use super::schema::ops_json;

const FIXTURE: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../../test_fixtures/darkroom_ops/catalog.json"
);

const CONTRACT_KEYS: &[&str] = &[
    "name",
    "kind",
    "required",
    "min",
    "max",
    "length",
    "minLength",
    "maxLength",
    "allowed",
    "default",
];

fn contract() -> Value {
    let ops = ops_json().expect("catalogue");
    let ops: Vec<Value> = ops
        .as_array()
        .expect("array")
        .iter()
        .map(|op| {
            let params: Vec<Value> = op["params"]
                .as_array()
                .expect("params")
                .iter()
                .map(|param| {
                    let mut kept = Map::new();
                    for key in CONTRACT_KEYS {
                        if let Some(value) = param.get(*key) {
                            kept.insert((*key).to_string(), value.clone());
                        }
                    }
                    Value::Object(kept)
                })
                .collect();
            json!({
                "id": op["id"],
                "version": op["version"],
                "stage": op["stage"],
                "params": params,
            })
        })
        .collect();
    json!({ "recipeSchemaVersion": RECIPE_SCHEMA_VERSION, "ops": ops })
}

#[test]
fn the_catalog_fixture_matches_the_catalogue() {
    let mut text = serde_json::to_string_pretty(&contract()).expect("serialize");
    text.push('\n');
    if std::env::var_os("SKOTIQ_WRITE_FIXTURES").is_some() {
        std::fs::write(FIXTURE, &text).expect("write fixture");
        return;
    }
    let committed = std::fs::read_to_string(FIXTURE).expect("fixture");
    let committed: Value = serde_json::from_str(&committed).expect("fixture JSON");
    assert_eq!(
        committed,
        contract(),
        "the catalogue changed; regenerate the fixture and update the app's recipe builders"
    );
}
