# b1-brand-assets report — Trails mark pipeline and generated assets

Worktree `skotiq-b1-brand-assets`, base commit `0f14e3843` (verified with
`git rev-parse HEAD` before starting; exit 0). Branch
`rebrand/skotiq-b1-brand-assets`. All work stayed inside the worktree; no
pushes, no other worktrees touched.

## What was built

**Pipeline** — `tools/brand/`:

- `mark.py` — exact port of `brand-ref/trails_reference.py` (`LANES`,
  `LEVELS`, `lane()`, `PALETTES`, the layout transform). Verified by
  rendering every palette × level × tile combination through both
  implementations and diffing: byte-identical. Exposes a small CLI plus the
  helpers `render.py` composes (bare groups, maskable bodies, baked
  coordinate transforms for Android vectors).
- `render.py` — subcommands `masters`, `icons`, `web`, `readme`, `all`.
  Rasters via `rsvg-convert` and ImageMagick 7 (`magick`). Deterministic:
  two consecutive `all` runs produce byte-identical sha256 sets across all
  78 generated files.
- `fonts/` — `Sora[wght].ttf` + `OFL.txt` from `google/fonts` pinned at
  commit `a926665019d3f7f25c8b1212cecbfa871e70de82` (noted in
  `tools/brand/README.md`).
- `README.md` — short design note: the mark, levels, colorways, platform
  conventions, regeneration commands, the font pin, and the two-sentence
  story (skotos = darkness; star trails are what darkness and time draw on
  a long exposure).

**Master SVGs** — `assets/branding/`: `mark-{full,mid,flat}-{violet,light,
red,mono}.svg` (bare) and `icon-{full,mid,flat}.svg` (violet tiles).

**Platform icons** — every frame rendered at its own level (`flat` < 24 px,
`mid` 24–63 px, `full` ≥ 64 px, keyed to the mark's rendered size):

- Windows `app_icon.ico`: 16, 20, 24, 32, 40, 48, 64, 256 px frames, each
  drawn natively.
- Linux `icons/skotiq{,_16,_32,_48,_64,_128,_256,_512}.png` — names kept as
  `my_application.cc` / `CMakeLists.txt` reference them.
- macOS `AppIcon.appiconset`: Apple icon grid — 824 px rounded body on the
  1024 canvas, transparent margin, level by body size.
- iOS `AppIcon.appiconset`: full-bleed square tiles, no rounding, no alpha
  (forced `PNG24`).
- Android: legacy `mipmap-*/ic_launcher.png` (48–192 px, rounded tile), and
  an adaptive icon — `mipmap-anydpi-v26/ic_launcher.xml` on a
  `#0E0C16` `@color/ic_launcher_background`, `drawable/ic_launcher_
  foreground.xml` and `drawable/ic_launcher_monochrome.xml` vector
  drawables with the mark scaled into the 66 dp safe zone. Manifest still
  reads `@mipmap/ic_launcher`; no names changed.

**Web** — `favicon.png` (16 px, flat), `Icon-{192,512}.png` tiles,
`Icon-maskable-{192,512}.png` (full-bleed, mark inside the 80% safe
circle), and `web_run_watch/icons/icon{,-192,-512}.svg` regenerated as
Trails marks (`icon.svg` is the tile; the sized ones keep the manifest's
`any maskable` purpose with a full-bleed ground and 80% mark).

**Repo images** — `logo-512.png` (tile), `social-preview.png` (1280×640
tile + wordmark on `#08070D`), `banner.png` / `banner-light.png`
(1280×400; bare violet mark on `#08070D` / bare light mark on `#F4F2FA`).
Wordmark is "skotiq" in Sora SemiBold 600 at −0.04em; width measured with
fontTools so the lockups center exactly, rendered by rsvg with a scoped
`FONTCONFIG_FILE` so nothing installs system-wide.

**README.md** — only the banner block changed: a `<picture>` element
serving `banner.png` for dark schemes and `banner-light.png` for light.

**Contact sheet** — `reports/rebrand/b1-contact-sheet.png` (72 cells, every
generated size, small frames point-upscaled). Reviewed it: lanes stay
distinct at every size and nothing is clipped.

## Decisions that deviate from the brief

- **Android legacy icons** ship the rounded tile with transparent corners
  rather than the old opaque square — the approved icon is the rounded
  tile. No `ic_launcher_round`: the manifest has no `android:roundIcon`.
- **Adaptive-icon vectors bake the layout transform into the path
  coordinates** instead of relying on nested `<group>` scales, so stroke
  widths are exact regardless of VectorDrawable's transform-order
  semantics.
- **`render.py readme`** covers all repo images (`logo-512`,
  `social-preview`, both banners) — the brief named the subcommands but not
  the grouping.
- **Banners show the bare mark** (tile would read as a button) and the
  social preview shows the tile.
- **Windows frame set** follows the brief exactly (added 20/40, dropped the
  old 128 frame).
- iOS PNGs: two small sizes initially serialized as palette-indexed
  (opaque, valid); forced `PNG24` anyway for uniform truecolor output.

## Commands run (exit codes)

- `git rev-parse HEAD` → `0f14e3843254697dd3ce3d5385a008f1a5342977` (0)
- `curl -sfL -o "Sora[wght].ttf" https://raw.githubusercontent.com/google/fonts/<sha>/ofl/sora/Sora%5Bwght%5D.ttf` (0); same for `OFL.txt` (0)
- reference-vs-port diff: `diff -r ref/ mine/` → IDENTICAL (0)
- `python3 tools/brand/render.py {masters,icons,web,readme,all}` (0 each)
- determinism: `sha256sum` over all generated files before/after rerun →
  `diff` clean (0)
- `magick identify` audits: ICO = 8 frames at the listed sizes; iOS set =
  color-type 2 / no alpha; `Icon-App-83.5x83.5@2x.png` = 167×167 (0)
- `magick montage` contact sheets (0)
- `grep -ril nightshade` over all touched paths → no hits (1 = clean)

`TMPDIR=$HOME/.cache/ns-tmp/b1-brand-assets` was set throughout. `flutter
test` not run — this area touches no Dart code (r-agents own that).

## Unfinished

Nothing. Motion (draw/loading/working/spinner, reduced-motion fallback)
lives in the app widget — that's b2's area, out of scope here.
