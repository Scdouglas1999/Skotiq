//! Test support for the files under the repository's `test_fixtures/` that
//! Rust tests write and the app's tests read: the words, keys and shapes the
//! two languages must agree on. A dev-dependency only.

use std::path::PathBuf;

use serde_json::Value;

/// The environment variable that makes [`pin_json`] write the fixture instead
/// of comparing against it.
pub const WRITE_FIXTURES_ENV: &str = "SKOTIQ_WRITE_FIXTURES";

/// The path of `relative` under the repository's `test_fixtures/`.
pub fn fixture_path(relative: &str) -> PathBuf {
    PathBuf::from(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../test_fixtures"
    ))
    .join(relative)
}

/// Whether this test run regenerates the fixtures.
pub fn writing_fixtures() -> bool {
    std::env::var_os(WRITE_FIXTURES_ENV).is_some()
}

/// Hold `value` to the committed fixture `relative` (under `test_fixtures/`),
/// or write it there when [`WRITE_FIXTURES_ENV`] is set. `changed` is the
/// failure message: what changed and what to update with it.
pub fn pin_json(relative: &str, value: &Value, changed: &str) {
    pin_json_by(relative, value, Value::clone, changed);
}

/// [`pin_json`] comparing only what `compare` keeps of the committed fixture
/// and of `value` (a shape, or the keys a reader depends on). The whole of
/// `value` is what gets written.
pub fn pin_json_by(
    relative: &str,
    value: &Value,
    compare: impl Fn(&Value) -> Value,
    changed: &str,
) {
    let path = fixture_path(relative);
    if writing_fixtures() {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).expect("fixture dir");
        }
        let mut text = serde_json::to_string_pretty(value).expect("pretty");
        text.push('\n');
        std::fs::write(&path, text).expect("write fixture");
        return;
    }
    let committed =
        std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    let committed: Value = serde_json::from_str(&committed).expect("fixture JSON");
    assert_eq!(compare(&committed), compare(value), "{changed}");
}

/// The JSON kinds and keys of `value` without its numbers and strings: the
/// comparison for a sample taken from a real run, whose measured figures may
/// differ in the last bits between machines.
pub fn json_shape(value: &Value) -> Value {
    match value {
        Value::Object(map) => Value::Object(
            map.iter()
                .map(|(key, value)| (key.clone(), json_shape(value)))
                .collect(),
        ),
        Value::Array(items) => Value::Array(items.iter().map(json_shape).collect()),
        Value::Number(_) => Value::String("number".to_string()),
        Value::String(_) => Value::String("string".to_string()),
        other => other.clone(),
    }
}

/// Asserts that `$all` names every variant of its enum once, in the order
/// listed. The match has no wildcard arm, so a variant added to the enum
/// without being listed here fails to compile, and one listed here but left
/// out of `$all` fails the assertion.
#[macro_export]
macro_rules! assert_lists_every_variant {
    ($all:expr, [$($variant:pat_param),+ $(,)?]) => {{
        let listed: ::std::vec::Vec<&'static str> = $all
            .iter()
            .map(|value| match value {
                $($variant => stringify!($variant),)+
            })
            .collect();
        let expected: ::std::vec::Vec<&'static str> = ::std::vec![$(stringify!($variant)),+];
        assert_eq!(listed, expected, "the list must name every variant once, in this order");
    }};
}

#[cfg(test)]
mod tests {
    #[derive(Debug, Clone, Copy)]
    enum Phase {
        Waiting,
        Done,
    }

    #[test]
    fn a_full_list_passes() {
        assert_lists_every_variant!([Phase::Waiting, Phase::Done], [Phase::Waiting, Phase::Done]);
    }

    #[test]
    #[should_panic(expected = "every variant")]
    fn a_short_list_fails() {
        assert_lists_every_variant!([Phase::Waiting], [Phase::Waiting, Phase::Done]);
    }
}
