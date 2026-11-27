//! The extensions the app opens as frames, as the native readers know them.
//! `frame_files_test.dart` reads the same file, so an extension added on one
//! side and not the other fails a test.

use std::collections::BTreeSet;

#[test]
fn the_native_readers_open_exactly_the_listed_extensions() {
    let listed: BTreeSet<String> = serde_json::from_str(include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../test_fixtures/wire_words/frame_file_extensions.json"
    )))
    .expect("the fixture is a JSON list");
    let native: BTreeSet<String> = skotiq_imaging::frame_extensions()
        .into_iter()
        .map(str::to_owned)
        .collect();
    assert_eq!(native, listed);
}
