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
| `framing.png` | Plan > Framing on NGC 7331 over the SDSS color survey |
| `planetarium.png` | Plan > Planetarium over Andromeda, Cassiopeia and Perseus |
| `weather.png` | Weather on a clear night: GOES frame and forecast |
| `darkroom.png` | Darkroom > Targets on M31 with its LRGB masters |
| `web-dashboard.png` | Browser dashboard of a headless host running a night on simulators |

### Refreshing screenshots

**Generated.** `packages/skotiq_app/test/golden/public_screenshots_test.dart`
renders every file above except the last. Each one is the real app (router,
shell, screens) over one seeded night: a site in the Eastern time zone, the
author's rig (a 10-inch f/4 Newtonian with an ASI1600MM-Cool on a NYX-101), and
a run on NGC 7331, M31 and M1 at 23:47 on the evening the test runs, with the
app clock stopped there. The run's step times are the app's own plan estimate
from the run's 18:40 start. The frame shown is a raw 30 s sub of M31 from that
rig through the app's own stretch; the Darkroom's previews are single subs from
the same night. The star catalog, the Weather basemap and the Framing survey
cutout are fixtures recorded once (sources and credits in
`packages/skotiq_app/test/fixtures/README.md`). The frame statistics, guiding
and history are generated, not measured. The test writes into this folder only
when you ask it to, in two runs:

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

**Captured from a running host.** `web-dashboard.png`: the browser dashboard is
not a Flutter surface. It is the Linux release bundle running `--headless` with
the built-in simulators connected and a 30 s M31 LRGB run in progress, opened
at `/dashboard/` in headless Chromium at 1600 x 900.

## License

Screenshots you commit should depict **your** equipment and data, or synthetic/demo content you have rights to publish.
