# Impl log — C2 / wcs-conformance

Topic: one shared test fixture (golden `.wcs` headers + expected parses) that the
Dart parser tests and the Rust parser tests both consume, including the 80-char
card cases C1 fixed.

Source of the work order: `map/cross-cutting.md` Cluster 5 ("the minimum
acceptable step is a shared conformance test … do that first regardless",
reinforced by "Suggested order of work" item 3) and `map/core-services-devices.md`
§5.1 + `impl/core-services-devices.md` Item 1 (the C1 fix).

## What shipped

New shared fixture, read by both languages:

- `test_fixtures/wcs_conformance/README.md` — the contract, the comparison rules,
  the recorded divergences, and the "never loosen the fixture silently" rule.
- `test_fixtures/wcs_conformance/cases.json` — 9 cases; per case the expected card
  split, the expected Dart parse, the expected Rust parse, and a `divergence`
  string wherever the two genuinely differ.
- `test_fixtures/wcs_conformance/cases/*.wcs` — 9 byte-exact golden headers,
  written the way a solver writes them (three of them with **no line terminators
  at all**).

New consumers:

- `packages/skotiq_core/test/services/wcs_conformance_test.dart` (21 tests).
- `native/skotiq_native/imaging/src/platesolve_wcs_conformance_tests.rs`
  (4 tests), hooked in from `platesolve.rs` as
  `#[cfg(test)] #[path = …] mod wcs_conformance;` — declared inside the module
  because the parsers it pins (`fits_header_cards`, `parse_wcs_file_inner`) are
  private and a `tests/` integration test cannot reach them.

One production-file change, additive and test-only:

- `plate_solve_service.dart` gained `fitsHeaderCardsForTest`, a
  `@visibleForTesting` seam over the existing private `_fitsHeaderCards`. No
  behaviour change; grep confirms the name is used by nothing else in the repo,
  so the barrel re-export cannot collide.

One doc-only change:

- `bridge/src/sim_sky.rs` `read_crval` gained a comment naming it as the third
  `.wcs` reader and saying why it is deliberately not folded in (below).

## The cases

| id | shape | Dart | Rust |
|---|---|---|---|
| `astap_card_stream` | 20 padded 80-char cards, **no terminators**, CD + CDELT + CROTA + NAXIS, negative Dec | ok | ok |
| `astap_crlf_delimited` | same cards, CRLF-delimited | ok | ok |
| `astrometry_net_sip` | unpadded, LF, IMAGEW/IMAGEH, CD with exact-zero off-diagonals, 2nd-order SIP + `A_DMAX` decoy | ok | ok |
| `cdelt_only_no_cd_matrix` | CRVAL + CDELT + CROTA, no CD matrix | ok | `WcsMissingKeyword{CD1_1}` |
| `misaligned_equals_column` | `=` at column 7 instead of 8 | ok | `WcsMissingKeyword{CRVAL1}` |
| `malformed_crval1` | `CRVAL1 = not-a-number` | fail | `WcsParse{CRVAL1,"not-a-number"}` |
| `missing_crval2` | CRVAL2 absent | fail | `WcsMissingKeyword{CRVAL2}` |
| `no_wcs_keywords` | COMMENT-only sidecar | fail | `WcsMissingKeyword{CRVAL1}` |
| `nan_crval1` | literal `NaN` value | **ok (NaN RA)** | **ok (NaN RA)** |

Edge coverage asked for by the charter: negative Dec (`-12.39`, cases 1/2/6/9),
exact zeros (zero off-diagonal CD and zero rotation in `astrometry_net_sip`),
negative SIP coefficients, and NaN (`nan_crval1`). ">24h durations" has no
analogue in a WCS header. Comparison rules: verbatim fields (`ra`, `dec`,
`cd1_1`..`cd2_2`, every SIP coefficient) are compared for **exact** equality
because both sides read them straight out of a card with a correctly-rounded
strtod; derived fields (`pixel_scale`, `rotation`, `field_*`) to 1e-9.

Both suites also assert the C1 invariant directly — *the separator a solver
happens to use must not change a single card* — by splitting
`astap_card_stream.wcs` and `astap_crlf_delimited.wcs` and requiring identical
card lists.

## Every expectation was predicted, then confirmed against the real code

The fixture's expected values were derived from each parser's documented
algorithm before either suite was run. Both suites passed on their first
execution: Dart `+21 All tests passed`, Rust `4 passed; 0 failed`. Nothing was
back-fitted to a failing run.

## Proof that the fixture actually catches drift (not a vacuous green)

Two deliberate mutations, each reverted immediately afterwards:

1. Re-introduced the C1 bug in Dart (`_fitsHeaderCards` → `content.split('\n')`).
   Result: **13 failures**, including `astap_card_stream`, `cdelt_only_no_cd_matrix`
   and `nan_crval1`. Note that `astap_crlf_delimited` kept passing — which is
   exactly the trap the old hand-rolled fixture fell into (it was newline-delimited,
   the one input shape the broken parser handled).
2. Reverted the Rust rotation form to `atan2(cd2_1, cd1_1)` (the pre-fix form its
   own comment names). Result: `astap_card_stream rotation: expected
   -1.2500000000000164, got -178.75`.

Reverts verified by re-running both suites green and by `grep` on both files.

## Divergences: recorded, not unified (the mad_sigma standard)

The two parsers are not the same function and the fixture does not pretend they
are. Each disagreement carries a written reason in `cases.json`, and **both**
suites contain a test (`every divergence from the Rust parser is documented` /
`every_divergence_from_the_dart_parser_is_documented`) that fails if a case's two
sides disagree without one. Position (`ra`/`dec`) is the one field where
cross-side agreement is asserted unconditionally: a solve is the same solve
whichever parser read it.

1. **`cdelt_only_no_cd_matrix` — success vs error on the same solved header.**
   Dart requires only CRVAL1/CRVAL2 and derives scale/rotation from
   CDELT1/CROTA2. Rust additionally requires all four CD terms, because its result
   feeds `SipWcs`, which cannot be built without a CD matrix; the Dart path only
   needs RA/Dec for centering. Both are deliberate. Not unified.

2. **Rotation sign.** Dart returns CROTA2 verbatim (+1.25); Rust derives
   `atan2(CD2_1, -CD1_1)` (−1.25). The golden header builds CD from CDELT/CROTA2
   with the standard AIPS relation, under which the two are exact negations.
   Which sign a real ASTAP `.wcs` implies is **not** verifiable from inside this
   repo (no ASTAP install, and the standing rule forbids fixing from a code-read),
   so both are pinned as-is. Anyone touching either convention now gets a red
   build and has to settle it against real solver output. **This is the one item
   here that may be a live bug and needs an on-rig check.**

3. **Card-layout strictness.** Rust reads the keyword from columns 0..8 and
   requires `=` at column 8; Dart matches with `startsWith` and splits on the
   first `=`. Rust is standard-conformant, Dart is lenient. Tightening Dart would
   reject headers it reads today. Not unified.

4. **Third reader, left alone:** `bridge/src/sim_sky.rs::read_crval` chunks the
   raw bytes by 80 unconditionally and does not honour newlines. It is
   `#[cfg(test)]`-only, all three call sites are `#[ignore]`d hardware tests, and
   its single input is live `astap_cli -wcs` output (never terminated). Folding it
   in would mean exporting a function private to `platesolve` across a crate
   boundary for test-only code. Recorded in a comment at the site instead.

## Known hazard pinned, deliberately not fixed

`nan_crval1`: the literal `NaN` parses as a float in **both** `f64::from_str` and
`double.tryParse`, so both parsers report such a header as a *successful* solve
carrying a NaN position, and nothing downstream of either rejects it. Pinned as
current behaviour rather than fixed — a fix is a behaviour change and needs a
reproduction in the running app first (standing no-fixes-from-code-reads rule).
Pinning means a future guard has to update both sides at once.

## Verification

- `cargo test -p skotiq_imaging wcs_conformance` → 4 passed / 0 failed.
- `cargo test -p skotiq_imaging platesolve` → **41 passed / 0 failed** (the
  8 pre-existing hand-rolled `.wcs` tests still pass unchanged).
- `cargo test -p skotiq_bridge --lib sim_sky` → 16 passed / 0 failed /
  3 ignored (the doc-comment edit).
- `flutter test test/services/wcs_conformance_test.dart` → `+21 All tests passed`.
- `flutter test .../plate_solve_service_test.dart .../plate_solve_service_lifecycle_test.dart`
  plus the conformance suite → `+37 All tests passed` (existing suites unchanged).
- `flutter analyze` (skotiq_core) → 2 issues, both pre-existing
  `deprecated_member_use` infos in `test/database/restore_clears_recovery_marker_test.dart`.
- `dart run tools/production/placeholder_audit.dart --fail-on-new-highrisk …` →
  "No new high-risk markers compared to baseline."
- `dart format` on the two touched Dart files; `rustfmt --edition 2021` on the
  three touched Rust files (`platesolve.rs` and `sim_sky.rs` verified clean with
  `--check`). No repo-wide formatter run.

## Deliberately NOT done

- The existing hand-rolled `.wcs` fixtures in `platesolve.rs`'s `mod tests` and in
  `plate_solve_service_test.dart` were **left in place**. The charter requires
  existing tests to pass unchanged, and they cover parser-local concerns (error
  variants, the RA-degrees unit contract, the 25-field result shape) that are not
  cross-language. The shared fixture is additive and is now the authority for
  anything both parsers do.
- Cluster 5's *other* half — the TAN/SIP projection duplication (Rust
  `wcs_sip.rs::SipWcs` vs Dart `gnomonic_projection.dart::GnomonicProjection`) —
  is **not** covered here. This topic is scoped to "golden WCS headers + expected
  parses". A pixel↔world conformance table over the same fixture is the obvious
  next step and would close Cluster 5 completely; it needs its own topic because
  it touches a different pair of files and a hot per-frame path.
