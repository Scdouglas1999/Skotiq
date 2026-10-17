# t1-theme — default colors, warm brand token, scheme-following logo

Branch: `rebrand/skotiq-t1-theme` @ b1105ed2e (verified at session start).

The brand violet is now the app's default accent on dark and light; a new
`brandWarm` token carries the logo's peach into a short, approved list of
"now" moments; and `SkotiqMark`/`SkotiqLockup` default to a new
`SkotiqMarkTone.theme` that derives its cool lanes from the user's accent and
its warm lane + pole star from `brandWarm`.

## Token changes (before → after)

### design-tokens.json / SkotiqColors.dark

| Token | Before | After | Why |
|---|---|---|---|
| `primary` | `#6EB3EC` (blue) | `#A48CF2` (violet) | Brand violet becomes the default accent. Started from the already-contrast-checked swatch, not the logo's `#8F7BEA`, because it must clear 4.5:1 as link text — it measures 6.63:1 worst-surface. |
| `accent` | `#8FC7F5` | `#B9ABFF` | Hover step moves with primary; also the brand's own lane-3 violet. |
| `info` | `#6EB3EC` | `#6EB3EC` (unchanged) | **Deliberate:** info stays blue. It is a status color (informational callouts, the minimap's position needle); letting it follow selection would blur status and selection into one hue. |
| `brandWarm` | — | `#FFD9A8` | New token; the logo's peach verbatim. |
| swatch order | blue first | violet first | `#A48CF2 #6EB3EC #43B67A #E0A53E #E86A6A #E77FB3 #4FC3C8` |

### design-tokens.json / SkotiqColors.light

| Token | Before | After | Why |
|---|---|---|---|
| `primary` | `#256E99` | `#6A4FD1` | Deep violet clearing the light-theme floors (5.27:1 as text). |
| `accent` | `#1F85C0` | `#5B41C4` | Hover step moves with primary. |
| `info` | `#256E99` | `#256E99` (unchanged) | Blue status, as above. |
| `brandWarm` | — | `#B43B00` | The "now" label in NightBand is text, so the token clears the 4.5:1 text floor (4.87:1 worst-surface), not just the 3:1 graphic floor the brief asked for. Same hue family as the peach, deepened for a light ground. |
| swatch order | blue first | violet first | `#6A4FD1 #256F9E #277549 #8F5D14 #BC3838 #B03A7A #1B7278` |

### design-tokens.json / SkotiqColors.redNight

| Token | Before | After | Why |
|---|---|---|---|
| `brandWarm` | — | `#FF9A9A` | Red-axis warm: the wavelength rule bends every non-red hue to the red axis, so the warm marker follows rather than breaking dark adaptation. |

`redNight` primary/accent untouched, per the brief.

## Accent persistence and the migration

`kDefaultAccentColorHex` moved `'#6EB3EC'` → `'#A48CF2'`. The constant seeds
`app_settings.accent_color` at install (`default_settings.dart`) and is the
fallback in the stored-snapshot and remote mappings, so fresh installs boot
violet.

For existing installs the seed is indistinguishable from a choice: every
database carries `accent_color='#6EB3EC'` whether the operator picked it or
never opened Appearance. **Schema v62** (`migration_v62.dart`, schemaVersion
61 → 62) rewrites the row `WHERE value = '#6EB3EC'` to the new default once,
at upgrade. An operator who deliberately picked the old blue moves with it —
the two cases are not separable in the stored data — and can re-pick it (blue
stays the second swatch). Every other stored value is a real choice and is
untouched. A unit test drives both cases through `onUpgrade` from a real
v61 database file.

`resolveSkotiqThemeData` also treats "accent == the palette's own primary" as
the designed theme rather than `withAccent(...)`: the stored default then
gets the designed hover step (`#B9ABFF`) and ink pick instead of a derived
approximation.

## Scheme-following logo

- `SkotiqMarkTone.theme` added; it is the default on `SkotiqMark` and
  `SkotiqLockup` (explicit `violet | light | red | mono` remain for
  fixed-brand contexts such as an about page).
- `themeTrailsRamp(primary, {brandWarm, lightGround})` builds four cool lanes
  in OKLCH — the accent's hue and chroma at four fixed lightness stops, dark
  ground `(0.542,1.22)→(0.915,0.31)` / light ground `(0.429,0.91)→(0.284,0.34)`
  — plus the warm lane = `brandWarm`. The stops were fitted to reproduce both
  approved colorways from their primaries; a unit test asserts ΔE00 < 2 per
  lane against the approved values, so no special-casing was needed.
- Red night maps `theme` (and explicit `violet`, as before) to the fixed
  `red` colorway — the wavelength constraint outranks the accent.
- `mono` still follows ambient `IconTheme`/`DefaultTextStyle` or an explicit
  `color`.
- `themeAccent` on mark/lockup renders a candidate accent without it being
  the ambient one — used by the Appearance swatches, which now paint a still
  30 px `SkotiqMark` in each candidate color.

## brandWarm placements (the complete list)

| Place | Before | After |
|---|---|---|
| `SkotiqMark` warm lane + pole star (all tones incl. `theme`) | `trailsPalettes[tone][4]`/`warm` | `colors.brandWarm` under `theme`; explicit palettes keep their fixed warms |
| Night timeline "now" marker (`night_timeline.dart`) | `colors.primary` (halo, stem, cap, label) | `colors.brandWarm` |
| NightBand "now" label + caret (`night_band.dart`) | `colors.link` | `colors.brandWarm` |
| Sequencer minimap running block (`sequence_minimap.dart`) | `colors.primary` | `colors.brandWarm` |
| Ledger row running tint, left marker, progress bar (`ledger_row.dart`) | `colors.primary` | `colors.brandWarm` |
| Node item progress detail + bar (`node_item.dart`) | `colors.primary` | `colors.brandWarm` |
| Cockpit "This frame" countdown + progress bar (`cockpit_now_imaging.dart`) | `colors.warning` / `colors.primary` | `colors.brandWarm` |

Left alone deliberately: the 'Running' status chip in `ledger_row`
(`colors.primary` tone — a status label, not the "now" mark), the minimap
selection ring and viewport (selection = primary by rule), the
`NodeStatus.running` status tint (`colors.info` — real status semantics),
and every link/button/selected surface.

## Docs and tooling

- `check_tokens.py` gained a CIEDE2000 implementation plus two checks per
  theme: `brandWarm` ≥ 3:1 on every surface (non-text graphic floor) and
  ΔE00(`brandWarm`, `warning`) ≥ 15. Results: dark 11.12:1 / ΔE 15.61, light
  4.87:1 / ΔE 16.86, redNight 8.26:1 / ΔE 18.34.
- `design-tokens.json` bumped to v2.1.0; `tokens.css` regenerated by the
  checker.
- `03-tokens.md` documents `brandWarm`, the violet defaults, blue `info`,
  and the violet-first swatch order.
- `design_tokens_sync_test.dart` mirrors `brandWarm` JSON ↔ Dart.
- `example/brand_preview.dart` gained a `theme` row so the derived colorway
  is reviewable under every motion.

## Golden tests that now fail because of the color change

`flutter test --tags golden --concurrency=4` in `packages/skotiq_app`:
22 tests, 1 failure.

- `test/screens/framing/framing_registration_test.dart`:
  `framing_canvas_golden` — the FOV reticle and its labels paint
  `colors.primary` (`framing_painters.dart`), so blue → violet pixels.
  Expected; regenerate after the branches merge.

No golden-tagged tests exist in `skotiq_ui`.

## Commands run (unpiped, exit codes)

- `git rev-parse HEAD` → `b1105ed2eee08622582b90668af15540f9a5ec19`, EXIT=0
- `melos bootstrap` → 11 packages, EXIT=0
- `python3 docs/design/overhaul/tools/check_tokens.py` → "all checks passed", EXIT=0
- `dart analyze` in `packages/skotiq_ui`, `packages/skotiq_core`, `packages/skotiq_app` → 0 errors (pre-existing info lints only), EXIT=0 each
- `dart format --output=none --set-exit-if-changed` on all touched paths → clean after formatting two files, EXIT=0
- `flutter test test/components/brand/skotiq_mark_test.dart --concurrency=4` (skotiq_ui) → +29 all passed, EXIT=0
- `flutter test --exclude-tags golden --concurrency=4` (skotiq_ui) → +576 all passed, EXIT=0
- `flutter test test/services/database_migration_test.dart --concurrency=4` (skotiq_core) → +19 all passed, EXIT=0
- `flutter test test/screens/settings/… test/screens/sequencer/ --concurrency=4` (skotiq_app) → +794 −1 where the −1 was a mistyped nonexistent path (`appearance_settings_test.dart` does not exist; not a code failure), all real tests passed
- `flutter test --tags golden --concurrency=4` (skotiq_app) → +22 −1, the failure listed above, EXIT=1
- `python3 tools/rebrand/rebrand.py --check` → 0 leftover mentions, EXIT=0

## Notes / deviations

- Light `brandWarm` is `#B43B00`, deeper than a 3:1 graphic floor requires,
  because the NightBand "now" marker is text (4.5:1 applies). Same hue
  family; documented in 03-tokens.md.
- The cockpit `_FrameChip` (countdown + thin bar for the in-flight exposure)
  was taken as the run-dashboard instance of "the step that is running now";
  the sequencer-side minimap/ledger/node-item running highlights were
  changed for the same "now" role per the approved placement list.
- Users who explicitly picked the old default blue cannot be told apart from
  never-picked in the stored row; v62 migrates both (see above). This is the
  only feasible resolution of the seeded-default ambiguity.
