# Screen token-migration map (value-preserving)

> **Archived 2026-09-09.** This map records the value-preserving pass that moved the
> screens off raw literals in 7.0.0. It is history, not guidance: the Observatory overhaul
> folded the value-named `radiusInline*` / `fontSizeNN` tokens onto the semantic scale and
> deleted them. For the values in force, read
> [`../03-tokens.md`](../03-tokens.md) — radii are 4 / 6 / 8 / 12 and nothing else.

This is the canonical "literal value → named token" mapping for the per-directory
migration of `packages/skotiq_app/lib/screens` onto the `skotiq_ui` design
system. Every mapping below is **exact-valued**: replacing the literal with the
named token produces **zero visual change**. The goal of the first migration pass
is to kill the magic numbers without altering pixels; a later design pass can fold
the `*Inline*` / `fontSizeNN` value-named tokens onto the semantic scale.

Baseline (run `dart tools/production/design_tokens_audit.dart`): **2008** flagged
sites — radii **1154**, inline `TextStyle(fontSize:)` **583**, raw `Colors.*` **271**.

## Border radius — `BorderRadius.circular(n)` → token

Tokens live on `SkotiqTokens` (`packages/skotiq_ui/lib/src/theme/skotiq_tokens.dart`).
Use the `double` token inside `BorderRadius.circular(...)`, or the convenience
`borderRadius*` object where a `BorderRadius` is wanted directly.

| literal | sites | double token            | BorderRadius object             |
|---------|-------|-------------------------|---------------------------------|
| `2`     | 29    | `radiusInline2`         | `borderRadiusInline2`           |
| `3`     | 23    | `radiusXs`              | `borderRadiusXs`                |
| `4`     | 215   | `radiusInline4`         | `borderRadiusInline4`           |
| `5`     | 7     | `radiusSm`              | `borderRadiusSm`                |
| `6`     | 240   | `radiusMd`              | `borderRadiusMd`                |
| `7`     | 3     | `radiusButton`          | `borderRadiusButton`            |
| `8`     | 523   | `radiusInline8`         | `borderRadiusInline8`           |
| `9`     | 1     | `radiusInline9`         | `borderRadiusInline9`           |
| `10`    | 103   | `radiusLg`              | `borderRadiusLg`                |
| `11`    | 1     | `radiusInline11`        | `borderRadiusInline11`          |
| `999`   | 9     | `radiusFull`            | `borderRadiusFull`              |

Note: `13` (`radiusXl`) is a valid token but is not currently used as a raw
`BorderRadius.circular(13)` in the screens — it is reached via `borderRadiusXl`.

The `radiusInline2/4/8/9/11` tokens are documented in-code as "in-use value,
pending scale consolidation": they exist only to make the migration mechanical and
look-preserving. Do **not** add fresh call sites at those values — prefer the
semantic scale (`radiusXs`..`radiusXl`).

## Font size — `fontSize: n` → token

Tokens live on `SkotiqTypography`
(`packages/skotiq_ui/lib/src/theme/skotiq_typography.dart`).

**Prefer adopting a full named style** when the inline `TextStyle` matches one
(same family/weight/height). The named styles and their sizes:

- `fontSize10` ↔ `overline` (10, w600, uppercase) / `statLabel`-adjacent
- `fontSize11` ↔ `labelQuiet` / `captionSm` / `monoXs` (11)
- `fontSize12` ↔ `h6` / `labelSm` / `caption` / `monoSm` / `statLabel` (12)
- `fontSize13` ↔ `bodySm` / `label` / `buttonSm` (13)
- `fontSize14` ↔ `body` / `h5` / `mono` / `button` / `input` (14)
- `fontSize16` ↔ `h4` / `bodyLg` (16)
- `fontSize18` ↔ `monoLg` / `telemetryMd` (18)
- `fontSize20` ↔ `h3` (20)
- `fontSize22` ↔ `telemetryLg` (22)
- `fontSize24` ↔ `h2` (24)

When the surrounding properties (custom weight/height/color/letterSpacing) do
**not** line up with a named style, use the bare numeric token to preserve the
exact size while removing the magic number:

| literal  | token          | | literal  | token          |
|----------|----------------|-|----------|----------------|
| `8`      | `fontSize8`    | | `13`     | `fontSize13`   |
| `9`      | `fontSize9`    | | `14`     | `fontSize14`   |
| `9.5`    | `fontSize9_5`  | | `15`     | `fontSize15`   |
| `10`     | `fontSize10`   | | `16`     | `fontSize16`   |
| `11`     | `fontSize11`   | | `17`     | `fontSize17`   |
| `11.5`   | `fontSize11_5` | | `18`     | `fontSize18`   |
| `12`     | `fontSize12`   | | `20`     | `fontSize20`   |
| `12.5`   | `fontSize12_5` | | `22`     | `fontSize22`   |
| `13`     | `fontSize13`   | | `24`     | `fontSize24`   |
|          |                | | `26`     | `fontSize26`   |
|          |                | | `28`     | `fontSize28`   |

(Sizes `26`/`28` have no named style and only the numeric token; `32` = `h1`,
`36` = `statValue` are reachable as named styles and not used as raw literals in
the screens.)

### Inline `TextStyle(fontSize:, fontWeight:)` combo → named role

The first migration pass swapped raw `fontSize: N` for `fontSize: fontSizeNN`.
The **next** pass folds a whole inline `TextStyle(fontSize: …, fontWeight: …)`
onto a single **named role** where the (size + weight) pair has one. Map the
recurring combos found across the screens as follows — apply the call-site color
via `.copyWith(color:)` / `.colored(…)`:

| inline combo (size + weight) | sites | named role | exact? |
|------------------------------|-------|------------|--------|
| `14` + `w600`                | 32    | `h5`         | yes |
| `12` + `w600`                | 27    | `h6`         | yes |
| `16` + `w600`                | 15    | `h4`         | yes |
| `13` + `w500`                | 11    | `label`      | yes |
| `12` + `w500`                | 12    | `labelSm`    | yes |
| `11` + `w500`                | 13    | `labelQuiet` | yes |
| `13` + `w600`                | 27    | `labelStrong`   | adopts family height/tracking |
| `11` + `w600`                | 29    | `labelStrongSm` | adopts family height/tracking |

`labelStrong` (13/w600) and `labelStrongSm` (11/w600) are **new** roles added for
this pass — they fill the semibold-small gap the screens reached for most. They
carry the `label` family's `height`/`letterSpacing`; a bare inline
`TextStyle(fontSize: 13, fontWeight: w600)` has neither, so folding onto the role
adds the family line-height/tracking. At semibold small sizes that is an
intended, imperceptible refinement — **not** a guaranteed pixel-identical swap.
If a call site must stay pixel-exact (e.g. inside a tight golden), keep the
numeric `fontSizeNN` token instead.

**Fold a combo onto a role only when the rest of the inline style matches** the
role (no custom `height`/`letterSpacing`/`fontFamily` that the role lacks); when
it carries extra properties, keep the numeric `fontSizeNN` token and leave the
inline `fontWeight`. Mono/tabular combos belong to the `mono*` / `telemetry*`
roles, not these.

## Colors — `Colors.*` → semantic

The semantic palette (`SkotiqColors.of(context)`) is **complete** for the
standard roles. Map raw Material colors as follows:

| raw                    | sites | maps to                                    |
|------------------------|-------|--------------------------------------------|
| `Colors.red`           | 5     | `colors.error`                             |
| `Colors.redAccent`     | 6     | `colors.error`                             |
| `Colors.amber`         | 4     | `colors.warning`                           |
| `Colors.blue`          | 3     | `colors.info` (or `SkotiqChartColors.seriesBlue` in charts) |
| `Colors.blueAccent`    | 4     | `colors.info`                              |
| `Colors.lightBlue`     | 3     | `colors.info` / `SkotiqChartColors.seriesBlue` |
| `Colors.grey`          | 2     | `colors.textMuted` / `colors.border`       |

Data-series / domain hues already have homes — do **not** map them to generic
semantics:
- chart lines/areas → `SkotiqChartColors.series*` (blue/violet/green/amber/indigo/deepBlue/red/orange)
- catalog object types → `AnnotationTypeColors`
- pipeline status → `AnnotationStatusColors`
- driver backends → `BackendProtocolColors`

### Genuinely ambiguous — handle PER-FILE (do NOT invent a global semantic):

- **`Colors.transparent`** (108): a structural non-color, not a theme color. It is
  red-night-safe (transparent stays transparent). Leave as `Colors.transparent`;
  the audit flags it but it needs no token. (A future audit refinement could stop
  flagging it.)
- **`Colors.white`** (104) / **`Colors.black`** (32): mostly overlay scrims and
  labels drawn over the image/planetarium canvas (e.g. `Colors.white.withValues(alpha:)`).
  Some are intentionally **absolute** (a HUD label over a star field), others
  should follow the theme (`colors.textPrimary` / `colors.background`). This is a
  per-call-site judgment. **Do not** add a global `white`/`black` semantic — that
  would defeat red-night dark-adaptation. Decide each site: theme-relative →
  `colors.textPrimary` / `colors.background` / `colors.surface`; truly
  canvas-absolute → keep raw with a one-line `// absolute: over image canvas`
  comment so the audit-skip is intentional and reviewable.

This is the only category that is NOT a mechanical swap. Radii and font sizes are
fully mechanical via the tables above.
