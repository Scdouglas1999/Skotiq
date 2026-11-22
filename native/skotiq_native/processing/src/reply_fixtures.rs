//! Sample replies the app's decoders are held to.
//!
//! Each reply type the bridge hands Dart as JSON text is serialized here from
//! a sample with every field set to a value no decoder default produces, into
//! `test_fixtures/ffi_replies/<name>.json`. The Dart decoder tests read those
//! files, so a key renamed here fails a Dart test instead of decoding as a
//! default. Regenerate after a deliberate change with
//! `SKOTIQ_WRITE_FIXTURES=1 cargo test -p skotiq_processing reply_fixture`.

use serde::Serialize;
use serde_json::Value;

const DIR: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../../test_fixtures/ffi_replies"
);

/// Write `value` as the fixture `name` (with `SKOTIQ_WRITE_FIXTURES`), or
/// check that the committed fixture is what `value` serializes to.
pub(crate) fn check_or_write(name: &str, value: &impl Serialize) {
    let value = serde_json::to_value(value).expect("serialize sample reply");
    let path = format!("{DIR}/{name}.json");
    if std::env::var_os("SKOTIQ_WRITE_FIXTURES").is_some() {
        std::fs::create_dir_all(DIR).expect("fixture dir");
        let mut text = serde_json::to_string_pretty(&value).expect("pretty");
        text.push('\n');
        std::fs::write(&path, text).expect("write fixture");
        return;
    }
    let committed = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{path}: {e}"));
    let committed: Value = serde_json::from_str(&committed).expect("fixture JSON");
    assert_eq!(
        committed, value,
        "the {name} reply changed; regenerate the fixture and update the app's decoder"
    );
}
