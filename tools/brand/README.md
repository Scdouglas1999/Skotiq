# Skotiq brand assets

*Skotos* is Greek for darkness, and star trails are what darkness and time
draw on a long exposure. The mark — an S made of five concentric star trails
with staggered ends, around a pole star — is generated, not drawn: one
procedural source emits every icon and image in the repo, and nothing
downstream is edited by hand.

## Files

- `mark.py` — the mark's geometry (lanes, levels, palettes), ported exactly
  from the approved reference implementation. Can emit SVG for any level,
  colorway, tile or no tile, and size:

      python3 tools/brand/mark.py --palette violet --level full --size 512
      python3 tools/brand/mark.py --palette mono --level flat --bare -o s.svg

- `render.py` — regenerates every committed asset. Subcommands:

      python3 tools/brand/render.py masters      # assets/branding/*.svg
      python3 tools/brand/render.py icons        # Windows, Linux, macOS, iOS, Android
      python3 tools/brand/render.py web          # web icons + run-watch SVGs
      python3 tools/brand/render.py readme       # logo, social preview, banners
      python3 tools/brand/render.py banner-anim  # animated README banners (GIF)
      python3 tools/brand/render.py all          # everything

  Requires `rsvg-convert` and ImageMagick 7 (`magick`), plus `fontTools` for
  the wordmark metrics. Output is deterministic: rerunning produces identical
  files.

- `banner_anim.py` — the animated banner (`assets/branding/banner{,-light}.gif`,
  960×300, 100 frames at 50 ms, looping). Each frame reproduces the app's
  `SkotiqMarkMotion` timings from `skotiq_mark.dart` exactly: the `draw` pass
  (five lanes staggering on 90 ms apart under cubic-bezier(.22,.7,.2,1), the
  pole star's 1.25× overshoot pop), a settle beat, then one `working` glint
  sweep (the synced white dash on a 2.6 s cycle). Partial arcs use SVG
  `pathLength` so dash offsets are the same path fractions the CustomPainter
  extracts. Runs standalone (`python3 tools/brand/banner_anim.py`) or through
  `render.py banner-anim`.

## Levels

The same centerlines at every size, with fewer and heavier lanes as the mark
shrinks, so the trails never merge:

- `full` — 64 px and up: five lanes, stroke 3.0, pole star r=2.2
- `mid` — 24–63 px: three lanes, stroke 4.6, pole star r=3.0
- `flat` — below 24 px: two lanes, stroke 6.4, no pole star

## Colorways

Lane colors run from the outermost trail to the innermost (the last is the
warm accent); the pole star takes the fourth lane's color.

- `violet` — the primary colorway, on the `#0E0C16` tile
- `light` — for light backgrounds
- `red` — red night mode, on `#000`
- `mono` — every lane one color (`#EDEAF7` here; `currentColor` in the app)

Master SVGs live in `assets/branding/`: `mark-{full,mid,flat}-{violet,light,
red,mono}.svg` are the bare marks, `icon-{full,mid,flat}.svg` the tiles.

## Platform notes

- **Windows** (`app_icon.ico`) — frames at 16, 20, 24, 32, 40, 48, 64 and
  256 px, each rendered at its own level rather than downscaled.
- **macOS** — Apple's icon grid: an 824 px rounded body centered on the
  1024 canvas with a transparent margin.
- **iOS** — full-bleed square tiles with no rounding and no alpha; iOS
  applies its own mask.
- **Android** — legacy `mipmap-*/ic_launcher.png` plus an adaptive icon:
  `mipmap-anydpi-v26/ic_launcher.xml` on a solid `#0E0C16` background, the
  mark inside the 66 dp safe zone, and a monochrome layer for Android 13
  themed icons. The manifest reads `@mipmap/ic_launcher`; don't rename it.
- **Web** — `favicon.png`, `Icon-{192,512}.png`, and `Icon-maskable-*` with
  the mark inside the 80% safe circle. The run-watch icons stay SVG.

## The wordmark

"skotiq", lowercase, in Sora SemiBold (600) at −0.04em letter-spacing. The
banners and social preview set it with the variable font pinned in
`tools/brand/fonts/`:

- `Sora[wght].ttf`, `OFL.txt` — from `google/fonts` at commit
  `a926665019d3f7f25c8b1212cecbfa871e70de82`, licensed under the SIL OFL 1.1.

`render.py` scopes a fontconfig file at `fonts/` so Sora resolves without
installing anything; the wordmark's advance width is measured with fontTools
so the lockups center exactly.
