# Repository assets

Files in this folder are for **GitHub presentation** (README, social preview, release pages)—not runtime app bundles. App icons live under `apps/desktop/` per platform.

## Branding

| File | Use |
|------|-----|
| `branding/logo-512.png` | README header |
| `branding/social-preview.png` | GitHub **Settings → General → Social preview** (1280×640) |

Upload `assets/branding/social-preview.png` in your repo settings so link previews look polished on GitHub, Discord, and social feeds.

## Screenshots

Published README screenshots live in `assets/screenshots/`.

| File | Screen |
|------|--------|
| `tonight.png` | Tonight during a run (M31, LRGB) |
| `tonight-focus.png` | Tonight, Focus tab: the last autofocus V-curve |
| `tonight-guide.png` | Tonight, Guide tab |
| `plan-best-tonight.png` | Plan > Best tonight |
| `plan-targets.png` | Plan > Targets with goals and progress |
| `sequencer.png` | Sequencer > Builder, three-target LRGB plan |
| `imaging.png` | Imaging > Live view |
| `guiding.png` | Guiding with PHD2 |
| `equipment.png` | Equipment > Devices, rig connected |
| `analytics.png` | Analytics > Session for one night |
| `analytics-history.png` | Analytics > History |
| `night-page.png` | A night page in Analytics > History |
| `flat-wizard.png` | Flat wizard after a batch of LRGB flats |
| `phone-tonight.png` | Tonight on a phone |
| `phone-plan-targets.png` | Plan > Targets on a phone |
| `framing.png` | Framing (captured from the running app, October 2026) |
| `planetarium.png` | Planetarium (captured from the running app, October 2026) |
| `weather.png` | Weather radar (captured from the running app, October 2026) |
| `darkroom-draft.png` | Darkroom (captured from the running app, October 2026) |
| `web-dashboard.png` | Browser remote dashboard (hand-captured, older build) |

### Refreshing screenshots

**Generated.** `packages/skotiq_app/test/golden/public_screenshots_test.dart`
renders every file above except the last five. Each one is the real app (router,
shell, screens) over one seeded night: a site in the Eastern time zone, an
Esprit 100 with an ASI2600MM on an EQ6-R, and a run on NGC 7331, M31 and M1 at
23:47 on the evening the test runs. The frame shown is M31 from the Digitized
Sky Survey (`packages/skotiq_app/test/fixtures/README.md`); the frame
statistics, guiding and history are generated from that night, not measured.
The test writes into this folder only when you ask it to, in two runs:

```bash
cd packages/skotiq_app
TZ=America/New_York SKOTIQ_CAPTURE_ASSETS=1 \
  flutter test --tags golden test/golden/public_screenshots_test.dart
TZ=America/New_York SKOTIQ_CAPTURE_ASSETS=1 SKOTIQ_SYSTEM_DECORATIONS=1 \
  flutter test --tags golden test/golden/public_screenshots_test.dart
```

The first run renders the desktop set at 1920 x 1080; the second renders the
phone set at 390 x 844 (three times that in pixels) without the desktop window
controls. Without `SKOTIQ_CAPTURE_ASSETS=1` the test writes to a temporary
directory and leaves the tracked files alone. Commit the regenerated PNGs; do
not hand-edit one, because the next capture run overwrites it.

A few readouts count from the wall clock rather than the night's 23:47 (the
Imaging and Analytics run duration, the History row of the running night and
the Sequencer's ETA column); they agree with the rest of the set only when the
capture runs close to 23:47.

**Captured from the running app.** `framing`, `planetarium`, `weather` and
`darkroom-draft` need survey tiles, the star catalog, radar imagery or built
masters that a widget test does not have. They are driven instead:

```bash
cd apps/desktop && flutter build linux --release
python3 tools/ui_audit/drive_linux.py start --fresh --profile shots
python3 tools/ui_audit/drive_linux.py shot --profile shots --width 1920 out.png
```

**Hand-captured.** `web-dashboard.png`: the browser dashboard is not a Flutter
surface, so it is captured from `http://127.0.0.1:8080/dashboard/` on a running
headless instance.

## License

Screenshots you commit should depict **your** equipment and data, or synthetic/demo content you have rights to publish.
