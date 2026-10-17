# `.wcs` conformance fixture

Skotiq parses an ASTAP / astrometry.net `.wcs` sidecar **twice**, in two
languages, on two different code paths:

| implementation | file | reached from |
|---|---|---|
| Rust | `native/skotiq_native/imaging/src/platesolve.rs` — `fits_header_cards`, `parse_wcs_file_inner`, `sip_indices`, `sip_layout` | the native solver (`AstapSolver`), i.e. every FFI/network solve |
| Dart | `packages/skotiq_core/lib/src/services/plate_solve_service.dart` — `_fitsHeaderCards`, `_parseWcsFile`, `_parseWcsValue` | the local fallback in `PlateSolveService`, i.e. the path that runs precisely when the native solver has already failed |

Nothing forced those two to agree. They already drifted once, expensively: the
Rust side was fixed to card-split a terminator-free FITS header while the Dart
side still split on newlines, so ASTAP would solve, the Dart parse would report
`CRVAL1` missing, and `Plate Solve & Center` failed every attempt against a
solution the solver had already found — taking the whole run down with it. The
Dart copy was only green because its own test fixture was newline-delimited,
which is the one input shape the broken parser handled.

This directory is the fix for the *class* of that bug: **one** set of golden
headers with the exact parse each implementation produces, consumed by both test
suites.

## Layout

- `cases/<id>.wcs` — golden headers, byte-exact, written the way a solver writes
  them (including the ones with **no line terminators at all**; do not let an
  editor "fix" them by appending a newline).
- `cases.json` — for each case: the expected card split, the expected Dart parse,
  the expected Rust parse, and an explicit note wherever the two genuinely differ.

## Consumers

- Dart: `packages/skotiq_core/test/services/wcs_conformance_test.dart`
- Rust: `native/skotiq_native/imaging/src/platesolve_wcs_conformance_tests.rs`

Both locate this directory by walking up from their own package/crate, so both
suites read the same bytes. Change either parser and one of them goes red.

## Comparison rules

- `ra`, `dec`, `cd1_1`..`cd2_2` and every SIP coefficient are read verbatim out of
  a card, so they are compared for **exact** equality.
- `pixel_scale`, `rotation`, `field_width`, `field_height` are computed, so they
  are compared to within `1e-9` absolute.
- `"nan"` in `cases.json` means "must be NaN" (JSON has no NaN literal).

## The divergences are recorded, not papered over

The two parsers are *not* the same function, and this fixture does not pretend
otherwise. Where they genuinely differ, `cases.json` carries a `divergence`
string naming the difference and why it was left alone. The three that matter:

1. **`cdelt_only_no_cd_matrix` — success vs error on the same solved header.**
   Dart requires only `CRVAL1`/`CRVAL2` and derives scale and rotation from
   `CDELT1`/`CROTA2`. Rust additionally requires all four `CD` terms, because its
   result feeds `SipWcs`, which cannot be built without a CD matrix. The Dart
   path only needs RA/Dec for centering. Both behaviours are deliberate.

2. **`astap_card_stream` — the rotation sign.** Dart returns `CROTA2` verbatim
   (`+1.25`). Rust derives rotation from the CD matrix as
   `atan2(CD2_1, -CD1_1)` (`-1.25`). The golden header builds its CD matrix from
   `CDELT`/`CROTA2` with the standard AIPS relation
   (`CD1_1 = CDELT1·cos`, `CD1_2 = -CDELT2·sin`, `CD2_1 = CDELT1·sin`,
   `CD2_2 = CDELT2·cos`), under which the two results are exact negations.
   Which sign a real ASTAP `.wcs` implies is **not** verifiable from inside this
   repo, so both are pinned as-is and neither parser was changed. Anyone who
   touches either sign convention gets a red build here and has to settle it
   against a real solver output.

3. **`misaligned_equals_column` — card-layout strictness.** Rust reads the
   keyword from columns 0..8 and requires `=` at column 8, so an off-standard
   card is skipped entirely. Dart matches with `startsWith` and splits on the
   first `=`, so it accepts it. Rust is the standard-conformant reader; Dart is
   the lenient one. Tightening Dart would reject headers it reads today, so it
   was left alone.

## Known hazards (pinned, deliberately not fixed here)

`nan_crval1`: the literal `NaN` in a card is accepted by both Rust
`f64::from_str` and Dart `double.tryParse`, so **both** parsers report such a
header as a *successful* solve carrying a NaN position, and nothing downstream of
either rejects it. That is pinned as current behaviour rather than fixed, because
a fix is a behaviour change and needs a reproduction in the running app first.
Pinning it means a future guard has to update both sides at once.

## Adding or changing a case

Edit `cases/*.wcs` and `cases.json` together, then run both suites:

```
cd packages/skotiq_core && flutter test test/services/wcs_conformance_test.dart
cd native/skotiq_native && cargo test -p skotiq_imaging wcs_conformance
```

Expected values must be what the implementations actually produce. If you find
yourself editing an expectation to make a suite pass, you have found a
divergence: record it in the case's `divergence` field, or fix the parser — never
loosen the fixture silently.
