# Skotiq design foundations

Shared palettes, typography, shapes, spacing, and data-color definitions. This
package depends only on Flutter so the planetarium and UI components can share
the same visual language without depending on application or equipment code.

Resolve `context.skotiqColors` for controls, `SkotiqTypography` for text, and
`SkotiqTokens` for dimensions. `ImageOverlayColors` and the plot palettes describe
fixed image/sky data, not selected controls. `FilterColors.forName` resolves
readable filter identities against the current palette.

The `skotiq_ui` package re-exports these types and owns `SkotiqTheme`, Material
control themes, and reusable components. Existing imports remain supported.
Palette values are checked against `docs/design/overhaul/design-tokens.json`.
