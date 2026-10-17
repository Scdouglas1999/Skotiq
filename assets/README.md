# Repository assets

Files in this folder are for **GitHub presentation** (README, social preview, release pages)—not runtime app bundles. App icons live under `apps/desktop/` per platform.

## Branding

| File | Use |
|------|-----|
| `branding/logo-512.png` | README header |
| `branding/social-preview.png` | GitHub **Settings → General → Social preview** (1280×640) |

Upload `assets/branding/social-preview.png` in your repo settings so link previews look polished on GitHub, Discord, and social feeds.

## Screenshots

Published README screenshots live in `assets/screenshots/`. Each file maps to one primary screen:

| File | Screen |
|------|--------|
| `desktop-dashboard.png` | Tonight |
| `equipment.png` | Equipment discovery & profiles |
| `imaging.png` | Imaging / capture |
| `guiding.png` | PHD2 guiding |
| `sequencer.png` | Sequence builder |
| `planetarium.png` | Planetarium sky view |
| `framing.png` | Framing assistant |
| `analytics.png` | Session analytics |
| `flat-wizard.png` | Flat frame wizard |
| `weather.png` | Weather radar |
| `plan-tonight.png` | Plan recommendations |
| `web-dashboard.png` | Browser remote dashboard |
| `settings-equipment-profiles.png` | Equipment profile settings |

### Refreshing screenshots

The images come from three places.

**Generated (eight files).** `packages/skotiq_app/test/golden/public_screenshots_test.dart` pumps each surface with seeded data and writes `desktop-dashboard`, `imaging`, `guiding`, `analytics`, `sequencer`, `equipment`, `framing` and `flat-wizard`. It only writes into this folder when you ask it to:

```bash
cd packages/skotiq_app && \
  SKOTIQ_CAPTURE_ASSETS=1 flutter test --tags golden \
  test/golden/public_screenshots_test.dart
```

Without `SKOTIQ_CAPTURE_ASSETS=1` the test still runs and still proves it produced a real image, but writes to a temp directory and leaves the tracked files alone. CI runs ubuntu-latest, so these are Linux renders and a Linux re-render is the correct baseline. Commit the regenerated PNGs; do not hand-edit one, because the next capture run overwrites it.

**Captured from the running app (three files).** `planetarium`, `plan-tonight` and `weather` cannot be generated: the planetarium needs the HYG star catalogue installed, Plan needs OpenNGC, and the Weather radar needs map tiles off the network. Pumped in a widget test they render "No observing site set", "Install the object catalog" and a blank map. They are driven instead:

```bash
cd apps/desktop && flutter build linux --release
python3 tools/ui_audit/drive_linux.py start --fresh --profile shots
# in the app: Settings -> Location -> Detect location,
#             Settings -> Catalogs -> Download catalogs (HYG + OpenNGC, ~60 MB)
python3 tools/ui_audit/drive_linux.py shot --profile shots --width 1600 out.png
```

`--width 1600` matches the window to the 1600x900 the generated set uses. These three are NOT in the generator's capture list, deliberately — adding them back would overwrite a real capture with an empty state.

**Hand-captured (one file).** `web-dashboard.png`: the browser dashboard is not a Flutter surface, so it is captured from `http://127.0.0.1:8080/dashboard/` on a running headless instance.

`scripts/capture-readme-screenshots.ps1` is the **old** Windows capture path and writes into this same folder. It drives the app by clicking sidebar coordinates (`-NavTop`, `-NavRow`), which the Observatory rail geometry invalidated, and anything it writes is overwritten by the next suite run. Use the test, not the script; the script is kept only for the web-dashboard shot.

## License

Screenshots you commit should depict **your** equipment and data, or synthetic/demo content you have rights to publish.
