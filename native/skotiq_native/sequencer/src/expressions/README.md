# Sequencer Variable Interpolation Engine

This module powers `${...}` template interpolation across the sequencer.

## Where templates are honoured

| Surface | Field | Behaviour |
| --- | --- | --- |
| `RunScript` | `script_path`, every `arguments[i]` | Interpolated before the child process is spawned. Failures abort the node. |
| `RunScript` | (env vars) | Every catalog variable is exported as `SKOTIQ_<UPPER_SNAKE>` to the child process. Missing data → variable simply not set. |
| `Notification` | `title`, `message` | Interpolated before the notification fires. Failures abort the node. |
| `TakeExposure` | `save_to` | Interpolated per-frame; result is a relative or absolute path (directories created on demand). Default template `${target.name}_${filter}_${frame:04}.fits`. |
| All nodes | `name` (display label) | Best-effort interpolation for Run Dashboard / tree labels. Failures fall back to the raw template (non-fatal). |

## Syntax

```
${path}              → resolve "path" using the variable catalog
${path:spec}         → resolve "path" then apply format spec
                       (e.g. ${frame:04}, ${target.alt:.1f})
$${                  → literal "${" (the doubled $ escapes interpolation)
```

Format specs supported:
- `0N` (e.g. `04`) — integer zero-pad to width N.
- `.Nf` (e.g. `.1f`) — fixed-point with N decimal places.

Bare `$` not followed by `{` is a literal `$`. A trailing `${` without `}` is a syntax error.

## Variable catalog

Single source of truth: [`catalog.rs::variable_catalog`](./catalog.rs).
Dart mirror: [`interpolation_catalog.dart`](../../../../../packages/skotiq_core/lib/src/models/sequence/interpolation_catalog.dart).

| Variable | Description | Example |
| --- | --- | --- |
| `target.name` | Name of the active target | `M42` |
| `target.id` | Stable internal identifier of the active target | `tgt-7c3a` |
| `target.ra` | Right ascension (hours) | `5.59` |
| `target.dec` | Declination (degrees) | `-5.39` |
| `target.rotation` | Position-angle rotation (degrees) | `45.0` |
| `target.alt` | Current altitude (degrees) | `42.7` |
| `target.az` | Current azimuth (degrees, 0 = N) | `138.2` |
| `filter` | Current filter name | `Ha` |
| `filter.position` | Filter-wheel position (1-based) | `3` |
| `frame` | Current frame within the burst | `8` |
| `frame.total` | Total frames in the burst | `30` |
| `session.id` | Unique session identifier | `5f9a-…-83b1` |
| `session.date` | Session UTC date | `2026-01-15` |
| `session.start` | Session ISO-8601 UTC start | `2026-01-15T22:14:33Z` |
| `time.now` | Current UTC timestamp | `2026-01-15T22:47:12Z` |
| `time.local` | Current local timestamp (with offset) | `2026-01-15 17:47:12 -05:00` |
| `time.date` | Current UTC date | `2026-01-15` |
| `moon.phase` | Moon illuminated fraction | `0.42` |
| `moon.separation` | Target-to-moon angular separation (deg) | `67.3` |
| `weather.temp_c` | Ambient temperature (°C) | `12.4` |
| `weather.humidity` | Relative humidity (%) | `67` |
| `sqm` | Sky-quality reading (mag/arcsec²) | `21.2` |
| `observer.name` | Observer name | `Alice` |
| `observer.lat` | Observer latitude (deg) | `40.7128` |
| `observer.lon` | Observer longitude (deg) | `-74.0060` |
| `observer.elevation` | Observer elevation (m) | `150` |
| `equipment.camera` | Active camera make + model | `ZWO ASI2600MM` |
| `equipment.telescope` | Telescope name | `TS-Optics 130/910 APO` |
| `equipment.focal_length` | Focal length (mm) | `910` |
| `equipment.aperture` | Aperture (mm) | `130` |
| `exposure.duration` | Current burst exposure duration (s) | `180` |
| `exposure.gain` | Current burst gain | `100` |
| `exposure.offset` | Current burst offset | `10` |
| `exposure.binning` | Current burst binning | `1x1` |
| `exposure.temp_c` | Cooler set-point (°C) | `-10` |
| `exposure.total` | Burst total integration (minutes) | `30` |

## Error handling

Unknown variables produce a typed `InterpolationError::UnknownVariable`. There is no silent fallback to empty string anywhere in the engine. Callers (run_script, notification, expose) translate the error into a hard `NodeStatus::Failure` so the user is forced to fix their template rather than discover hours later that frames were saved with `image__0001.fits` filenames.

For the cosmetic display-name path (Run Dashboard labels), interpolation failure logs at `debug!` and falls back to the raw template — a broken label is annoying but never load-bearing.

## Adding a new variable

1. Append a `VariableEntry { name, description, group, example, supports_format }` to `variable_catalog()` in `catalog.rs`.
2. Add the matching arm in `resolve_variable()` in `resolver.rs`.
3. Mirror the entry in `interpolation_catalog.dart` (the Dart picker reads from this list).
4. Run `cargo test --test interpolation_smoke` and `flutter test` to verify.

The unit test `catalog_and_resolver_agree_for_every_entry` will fail if step 2 is missed — it iterates the catalog and asserts every name resolves (or fails with `Unresolvable`, never with `UnknownVariable`).
