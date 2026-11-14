# `.wcs` conformance fixture

Golden ASTAP / astrometry.net `.wcs` sidecars and the exact parse Skotiq makes of
them: `parse_wcs_file_inner` in `native/skotiq_native/platesolve/src/lib.rs` reads
the text as a FITS header (`skotiq_imaging::header_from_text`) and its astrometry
with the frame reader's own `SipWcs::from_header`, so a solve and a solved frame
are read by one set of rules. It reads every solve, local or on a linked host.

The headers are byte-exact as solvers write them, including ones with **no line
terminators at all**: a real ASTAP `.wcs` is fixed-width 80-character cards packed
end to end, and a parser that splits on newlines sees only `SIMPLE`. Do not let
an editor "fix" them by appending a newline.

## Layout

- `cases/<id>.wcs` — golden headers, byte-exact.
- `cases.json` — for each case: why it exists, the expected card split, and the
  expected parse (`rust`).

## Consumer

- `native/skotiq_native/platesolve/src/wcs_conformance_tests.rs`, which finds this
  directory by walking up from its crate.

## Comparison rules

- `ra`, `dec`, `cd1_1`..`cd2_2` and every SIP coefficient are compared for
  **exact** equality: read verbatim out of a card, or for a CDELT/CROTA header
  the CD matrix as `SipWcs::from_header` computes it.
- `pixel_scale`, `rotation`, `field_width`, `field_height` are computed, so they
  are compared to within `1e-9` absolute.
- `"nan"` in `cases.json` means "must be NaN" (JSON has no NaN literal).

## Known hazards (pinned, deliberately not fixed here)

`nan_crval1`: the literal `NaN` in a card is accepted by `f64::from_str`, so the
parser reports such a header as a *successful* solve carrying a NaN position, and
nothing downstream rejects it. That is pinned as current behaviour rather than
fixed, because a fix is a behaviour change and needs a reproduction in the
running app first.

## Adding or changing a case

Edit `cases/*.wcs` and `cases.json` together, then run:

```
cd native/skotiq_native && cargo test -p skotiq_platesolve wcs_conformance
```

Expected values must be what the parser actually produces. If you find yourself
editing an expectation to make the suite pass, either the parser changed on
purpose (say why in the commit) or it is wrong; never loosen the fixture silently.
