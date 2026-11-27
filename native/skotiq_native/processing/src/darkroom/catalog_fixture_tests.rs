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

const FIXTURE: &str = "darkroom_ops/catalog.json";

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
    skotiq_wire_fixtures::pin_json(
        FIXTURE,
        &contract(),
        "the catalogue changed; regenerate the fixture and update the app's recipe builders",
    );
}

/// The Live Darkroom recipes the app wrote at 2e4b3fe02
/// (`test_fixtures/darkroom_live/base_recipes.json`, held to the app's builder by
/// `live_darkroom_recipe_contract_test.dart`). Live recipes are saved as recipe
/// rows, so every one must still read and validate.
#[test]
fn every_base_written_live_recipe_still_validates() {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../test_fixtures/darkroom_live/base_recipes.json"
    );
    let recipes: Map<String, Value> =
        serde_json::from_str(&std::fs::read_to_string(path).expect("fixture")).expect("JSON");
    assert!(!recipes.is_empty());
    let registry = super::state::registry().expect("registry");
    for (name, recipe) in recipes {
        let recipe = super::render::parse_recipe(&recipe.to_string())
            .unwrap_or_else(|e| panic!("{name}: {e}"));
        skotiq_imaging::recipe::validate(&recipe, registry)
            .unwrap_or_else(|e| panic!("{name}: {e}"));
    }
}
