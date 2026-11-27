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

/// Write `value` as the fixture `name` (with `SKOTIQ_WRITE_FIXTURES`), or
/// check that the committed fixture is what `value` serializes to.
pub(crate) fn check_or_write(name: &str, value: &impl Serialize) {
    check(name, value, |v| v.clone());
}

/// [`check_or_write`] for a real reply whose measured numbers may differ in
/// the last bits between machines: the committed fixture must have the same
/// keys, nesting and value kinds, not the same numbers.
pub(crate) fn check_or_write_shape(name: &str, value: &impl Serialize) {
    check(name, value, skotiq_wire_fixtures::json_shape);
}

fn check(name: &str, value: &impl Serialize, compare: fn(&Value) -> Value) {
    let value = serde_json::to_value(value).expect("serialize sample reply");
    skotiq_wire_fixtures::pin_json_by(
        &format!("ffi_replies/{name}.json"),
        &value,
        compare,
        &format!("the {name} reply changed; regenerate the fixture and update the app's decoder"),
    );
}
