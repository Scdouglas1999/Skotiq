//! Rust half of the shared `.wcs` conformance fixture.
//!
//! The golden headers and the expected parses live in
//! `test_fixtures/wcs_conformance/` at the repo root and are read by BOTH this
//! module and
//! `packages/skotiq_core/test/services/wcs_conformance_test.dart`.
//!
//! Skotiq parses a `.wcs` sidecar twice — here (every FFI/network solve) and
//! in `PlateSolveService` on the Dart side (the local fallback that runs
//! precisely when this one has already failed). The two drifted apart once: this
//! parser was fixed to card-split a terminator-free FITS header while the Dart
//! copy still split on newlines, so ASTAP would solve, the Dart parse would
//! report `CRVAL1` missing, and `Plate Solve & Center` failed every attempt
//! against a solution the solver had already found. One fixture, two consumers,
//! so the next drift is a red build instead of a lost night.
//!
//! Where the two parsers genuinely differ, the fixture carries a written
//! `divergence` and neither implementation is changed — see the fixture README.

use super::{fits_header_cards, parse_wcs_file_inner, PlateSolveError};
use serde_json::Value;
use std::path::PathBuf;

fn fixture_root() -> PathBuf {
    PathBuf::from(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../test_fixtures/wcs_conformance"
    ))
}

fn load_cases() -> Vec<Value> {
    let path = fixture_root().join("cases.json");
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("read shared fixture {}: {e}", path.display()));
    let doc: Value = serde_json::from_str(&text).expect("cases.json must be valid JSON");
    assert_eq!(doc["version"], 1, "fixture schema version changed");
    let cases = doc["cases"].as_array().expect("cases array").clone();
    assert!(
        !cases.is_empty(),
        "an empty fixture would make this module vacuously green"
    );
    cases
}

fn header_of(case: &Value) -> String {
    let rel = case["file"].as_str().expect("case.file");
    let path = fixture_root().join(rel);
    std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("read golden header {}: {e}", path.display()))
}

/// `"nan"` stands in for NaN, which JSON cannot express.
fn expected_f64(v: &Value) -> f64 {
    if v == "nan" {
        return f64::NAN;
    }
    v.as_f64()
        .unwrap_or_else(|| panic!("expected a number, got {v}"))
}

/// Verbatim fields are read straight out of a card, so they must match exactly.
fn assert_exact(actual: f64, expected: &Value, label: &str) {
    let want = expected_f64(expected);
    if want.is_nan() {
        assert!(actual.is_nan(), "{label} must be NaN, was {actual}");
        return;
    }
    assert_eq!(actual, want, "{label}");
}

/// Derived fields are computed, so they match to 1e-9.
fn assert_close(actual: f64, expected: &Value, label: &str) {
    let want = expected_f64(expected);
    if want.is_nan() {
        assert!(actual.is_nan(), "{label} must be NaN, was {actual}");
        return;
    }
    assert!(
        (actual - want).abs() <= 1e-9,
        "{label}: expected {want}, got {actual}"
    );
}

#[test]
fn card_split_matches_the_dart_fits_header_cards() {
    for case in load_cases() {
        let id = case["id"].as_str().expect("case.id");
        let content = header_of(&case);
        let cards = fits_header_cards(&content);
        let expected = &case["cards"];

        assert_eq!(
            cards.len() as u64,
            expected["count"].as_u64().expect("cards.count"),
            "{id}: card count drifted; a split boundary moved and every keyword \
             after it changes meaning"
        );
        let max_len = cards.iter().map(|c| c.len()).max().unwrap_or(0);
        assert_eq!(
            max_len as u64,
            expected["max_length"].as_u64().expect("cards.max_length"),
            "{id}: no card may exceed 80 characters"
        );
        for (index, text) in expected["at"].as_object().expect("cards.at") {
            let i: usize = index.parse().expect("card index");
            assert_eq!(
                cards[i],
                text.as_str().expect("card text"),
                "{id}: card {i} is not byte-identical"
            );
        }
    }
}

/// The separator a solver happens to use must not change a single card.
#[test]
fn wcs_conformance_terminator_free_header_splits_like_a_crlf_one() {
    let root = fixture_root();
    let stream = std::fs::read_to_string(root.join("cases/astap_card_stream.wcs"))
        .expect("card-stream golden");
    let crlf =
        std::fs::read_to_string(root.join("cases/astap_crlf_delimited.wcs")).expect("crlf golden");
    assert_eq!(fits_header_cards(&crlf), fits_header_cards(&stream));
}

#[test]
fn parse_matches_the_pinned_rust_expectations() {
    for case in load_cases() {
        let id = case["id"].as_str().expect("case.id");
        let why = case["why"].as_str().unwrap_or("");
        let path = fixture_root().join(case["file"].as_str().expect("case.file"));
        let expected = &case["rust"];
        let outcome = expected["outcome"].as_str().expect("rust.outcome");

        let parsed = parse_wcs_file_inner(&path, 0.42);

        match outcome {
            "ok" => {
                let r =
                    parsed.unwrap_or_else(|e| panic!("{id} must parse ({why}); got error {e:?}"));
                assert!(r.success, "{id}: a returned result is always a success");
                assert_eq!(
                    r.solve_time_secs, 0.42,
                    "{id}: solve time is passed through"
                );

                assert_exact(r.ra, &expected["ra"], &format!("{id} ra"));
                assert_exact(r.dec, &expected["dec"], &format!("{id} dec"));
                assert_exact(r.cd1_1, &expected["cd1_1"], &format!("{id} cd1_1"));
                assert_exact(r.cd1_2, &expected["cd1_2"], &format!("{id} cd1_2"));
                assert_exact(r.cd2_1, &expected["cd2_1"], &format!("{id} cd2_1"));
                assert_exact(r.cd2_2, &expected["cd2_2"], &format!("{id} cd2_2"));

                assert_close(
                    r.pixel_scale,
                    &expected["pixel_scale"],
                    &format!("{id} pixel_scale"),
                );
                assert_close(r.rotation, &expected["rotation"], &format!("{id} rotation"));
                assert_close(
                    r.field_width,
                    &expected["field_width"],
                    &format!("{id} field_width"),
                );
                assert_close(
                    r.field_height,
                    &expected["field_height"],
                    &format!("{id} field_height"),
                );

                for (name, order, coeffs) in [
                    ("a", r.a_order, &r.a_coeffs),
                    ("b", r.b_order, &r.b_coeffs),
                    ("ap", r.ap_order, &r.ap_coeffs),
                    ("bp", r.bp_order, &r.bp_coeffs),
                ] {
                    assert_eq!(
                        order as u64,
                        expected[format!("{name}_order")]
                            .as_u64()
                            .unwrap_or_else(|| panic!("{id}: missing {name}_order")),
                        "{id}: {name}_order"
                    );
                    let want = expected[format!("{name}_coeffs")]
                        .as_array()
                        .unwrap_or_else(|| panic!("{id}: missing {name}_coeffs"));
                    assert_eq!(
                        coeffs.len(),
                        want.len(),
                        "{id}: {name}_coeffs length (SIP layout is row-major i*(order+1)+j, \
                         and empty — not zero-filled — when the header carries no SIP)"
                    );
                    for (i, w) in want.iter().enumerate() {
                        assert_exact(coeffs[i], w, &format!("{id} {name}_coeffs[{i}]"));
                    }
                }
            }
            "parse_error" => match parsed {
                Err(PlateSolveError::WcsParse {
                    keyword, raw_value, ..
                }) => {
                    assert_eq!(
                        keyword,
                        expected["keyword"].as_str().unwrap(),
                        "{id} keyword"
                    );
                    assert_eq!(
                        raw_value,
                        expected["raw_value"].as_str().unwrap(),
                        "{id} raw_value"
                    );
                }
                other => panic!("{id}: expected WcsParse ({why}), got {other:?}"),
            },
            "missing_keyword" => match parsed {
                Err(PlateSolveError::WcsMissingKeyword { keyword, .. }) => {
                    assert_eq!(
                        keyword,
                        expected["keyword"].as_str().unwrap(),
                        "{id} keyword"
                    );
                }
                other => panic!("{id}: expected WcsMissingKeyword ({why}), got {other:?}"),
            },
            other => panic!("{id}: unknown expected outcome {other:?}"),
        }
    }
}

/// A case whose two sides disagree MUST carry a written reason. This is the rule
/// that keeps the fixture honest: an undocumented disagreement is a bug report,
/// not a passing test. Mirrored on the Dart side so neither suite can be the
/// only one enforcing it.
#[test]
fn every_divergence_from_the_dart_parser_is_documented() {
    for case in load_cases() {
        let id = case["id"].as_str().expect("case.id");
        let dart_ok = case["dart"]["success"].as_bool().expect("dart.success");
        let rust_ok = case["rust"]["outcome"] == "ok";

        if dart_ok != rust_ok {
            assert!(
                case["divergence"].is_string(),
                "{id}: Dart says success={dart_ok} and Rust says {}; that has to \
                 be explained in the fixture",
                case["rust"]["outcome"]
            );
            continue;
        }
        if dart_ok && rust_ok {
            // Position is the one thing they must never disagree about: a solve
            // is the same solve whichever parser read it.
            assert_exact(
                expected_f64(&case["rust"]["ra"]),
                &case["dart"]["ra"],
                &format!("{id} ra agreement"),
            );
            assert_exact(
                expected_f64(&case["rust"]["dec"]),
                &case["dart"]["dec"],
                &format!("{id} dec agreement"),
            );
            let same = |a: &Value, b: &Value| {
                let (x, y) = (expected_f64(a), expected_f64(b));
                (x.is_nan() && y.is_nan()) || (x - y).abs() <= 1e-9
            };
            let agree = same(&case["rust"]["pixel_scale"], &case["dart"]["pixel_scale"])
                && same(&case["rust"]["rotation"], &case["dart"]["rotation"]);
            assert!(
                agree || case["divergence"].is_string(),
                "{id}: the two parsers report different scale/rotation and the \
                 fixture does not say why"
            );
        }
    }
}
