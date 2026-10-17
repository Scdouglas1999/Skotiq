# Analytics

The Analytics screen provides comprehensive session analysis, historical data visualization, and equipment statistics to help you understand your imaging performance and improve over time.

## Overview

The Analytics screen has five tabs:
- **Session**: Current session statistics and charts, plus a compact "Tonight's science" KPI row
- **History**: Past session records and analysis
- **Projects**: Multi-night target progress and integration goals
- **Equipment Stats**: Long-term equipment performance metrics
- **Diagnostics**: Engineering-level logs and traces

Science (live photometry, plate-solve health, PSF maps, transparency, residuals, and anomaly detection) is now its own top-level destination at `/science`; see [Science](#science) below.

## Session Tab

### Current Session Summary

Overview of the active imaging session:

**Session Information**
- Session name
- Current status (Active, Paused, Complete)
- Start time
- Duration (real-time update)

**Progress Metrics**
- Exposures: Completed / Total
- Total integration time (accumulated exposure)
- Average HFR (Half-Flux Radius)

### Session Charts

Four charts displayed in a 2×2 grid:

#### HFR Chart

Tracks star sharpness over time:
- Blue line showing HFR values
- Lower values = sharper stars
- Useful for detecting focus drift

**Interpreting HFR**
- < 2.0 px: Excellent focus
- 2.0-2.5 px: Good focus
- 2.5-3.5 px: Acceptable
- > 3.5 px: May need refocus

#### Guiding RMS Chart

Shows guiding accuracy:
- Green line for total RMS
- Values in arcseconds
- Goal: < 1.0 arcsec

#### Focuser Position Chart

Tracks focuser movement:
- Purple line showing position
- Reveals temperature-related drift
- Shows autofocus events

#### Temperature Chart

Monitors environmental temperature:
- Orange line for temperature
- Values in °C
- Correlates with focus changes

### Captured Images Strip

Horizontal scrollable list of captured images:

**Image Cards (120px height)**
- Thumbnail preview
- Color-coded border:
  - Green: Accepted
  - Red: Rejected
- HFR badge with color coding
- Filter name
- Exposure duration

**HFR Badge Colors**
| HFR | Color |
|-----|-------|
| < 2.0 | Green |
| < 2.5 | Light green |
| < 3.5 | Orange |
| > 3.5 | Red |

### Chart Features

All session charts include:
- Line chart with bezier curves
- Auto-scaling with 10% padding
- Interactive tooltip on hover
- Time-based X-axis (minutes/hours)
- Data-driven Y-axis

## History Tab

### Session Filters

Filter historical sessions:

**Search**
- Search by session name
- Real-time filtering

**Time Filter**
- All Time
- This Month
- This Year

**Target Filter**
- All Targets
- Specific targets (M31, M42, NGC 7000, etc.)

### Session List

Cards for each past session:

**Card Information**
- Session name
- Status badge
- Date/time stamp

**Statistics Chips**
- Duration
- Image count
- Total integration time
- Average HFR

### Session Detail Dialog

Click a session card for details:

**Statistics Grid**
- Up to 6 columns of detailed metrics
- All session statistics

**Image Gallery**
- All captured images
- Filter by accepted/rejected
- Preview thumbnails

**Export Options**
- Export as JSON
- Export as CSV
- Share functionality

## Equipment Stats Tab

Long-term performance metrics for each equipment type:

### Camera Statistics

- **Total Exposures**: All-time exposure count
- **Integration Time**: Total hours of integration
- **Average Temperature**: Mean operating temperature

### Mount Statistics

- **Total Slews**: Number of GoTo operations
- **Tracking Time**: Hours of tracking
- **Meridian Flips**: Count of flip operations

### Focuser Statistics

- **Autofocus Runs**: Total AF attempts
- **Average HFR**: Mean achieved HFR
- **Total Movements**: Focuser step count

### Guider Statistics

- **Total Guide Time**: Hours of guiding
- **Average RMS**: Mean guiding accuracy
- **Star Lost Events**: Guide star loss count

## Chart Components

### Generic Session Chart

All charts share common features:
- FL_Chart library rendering
- Smooth bezier curve interpolation
- Auto-scaling Y-axis
- Time-based X-axis

### Chart Variants

**HFR Chart**
- Blue line color
- Y-axis in pixels
- Lower is better

**Temperature Chart**
- Orange line color
- Y-axis in °C
- Reference for focus correlation

**Guiding RMS Chart**
- Green line color
- Y-axis in arcseconds
- Lower is better

**Focuser Position Chart**
- Purple line color
- Y-axis in focuser steps
- Shows drift and corrections

## Data Analysis

### Session Comparison

Compare sessions to track improvement:
- View sessions for same target
- Compare HFR, RMS, integration
- Identify trends over time

### Equipment Trends

Long-term equipment performance:
- Degradation indicators
- Maintenance reminders
- Performance optimization

### Weather Correlation

Relate session quality to conditions:
- Temperature vs. focus stability
- Cloud cover vs. image quality
- Seeing vs. HFR values

## Export and Sharing

### Export Formats

**JSON Export**
- Complete session data
- Machine-readable format
- Preserves all metadata

**CSV Export**
- Tabular format
- Spreadsheet compatible
- Key metrics only

### What's Exported

- Session metadata
- Image list with statistics
- Equipment settings
- Environmental data
- Timing information

## Science

Science is now a top-level destination at `/science` rather than a tab buried in Analytics. The legacy `/analytics?tab=science` deep link redirects there, so old bookmarks and narrator links still work. The Science HUD, the calibration readout, and the photometry anchors are **ungated** — no toggle is required to reach them. The only thing behind a preference is the optional overlay *layers* on the imaging preview, controlled by **Show advanced overlay controls** (Settings → Science).

### On-ramp ladder

The Science destination opens with a five-rung ladder that walks you from "I take pretty pictures" to "I contribute real measurements." Each rung is gated on the one before it, so the next thing to do is the only thing lit up:

1. **Measure your sky** — run a photometric calibration against real catalog stars.
2. **Track a star** — point at a target and let photometry follow it frame to frame.
3. **Build a light curve** — accumulate measurements until the dots become a shape (10 points to start).
4. **Find the period** — fold a repeating curve to recover an orbit, rotation, or pulsation.
5. **Contribute it** — export for the AAVSO or the MPC.

The guide header collapses to stay out of the way once you know the ropes; its state persists via the `science.guide.collapsed` setting.

### Pipeline Status Banner

Sits at the top of the Science screen (and a compact form lives in the Imaging HUD). Tells you exactly what the science processor is doing in real time:

- **Idle (gray)**: Pipeline is waiting. Shows the total number of frames processed so far and how long since the last one.
- **Busy (blue, animated)**: A frame is being processed. Shows the current stage (e.g. "Plate solve…", "Calibration…") and the queue depth.
- **Failure (red)**: The most recent attempt produced at least one failed stage. Surfaces the stage name and the truncated error note so you can see *what* failed without opening the log.

Each frame contributes a row of small status dots on the right side of the banner — one per stage (frame quality, plate solve, calibration, transparency, PSF map, residuals, photometry, moving objects). Hover a dot for the per-stage note ("12 stars matched", "no WCS available", etc.). Colors: green = ok, blue = running, gray = skipped, muted = no data, red = failed.

### Tonight's Science (Session tab)

A compact 4-metric row above the classic Session charts:

- **Plate solves**: `N / M` — how many of this session's light frames produced a WCS solution.
- **Zero point**: The most recent photometric ZP plus the number of catalog stars matched.
- **Transparency**: Latest atmospheric transparency percentage and its quality bucket.
- **Uniformity CV**: Background flatness, plus SNR for context.

Tapping the row opens the Science destination so you can drill into the underlying charts.

### Plate Solve Health Card

Always visible at the top of the Science screen. Shows the success rate as a percentage with a colored progress bar:

- **Excellent (≥90%)**: Most frames are solving — photometry, PSF maps, and residuals all benefit.
- **Acceptable (60–89%)**: Failures are usually transient (clouds, guiding excursions).
- **Struggling (1–59%)**: Many frames failing. Offers a one-click **Configure plate solver** button.
- **No solves yet**: Nothing has solved. Most science products will stay empty until a solver is reachable.

### Time-Series Trends

The Science screen charts how the night evolves — not just the latest value:

- **Light curve** — differential photometry for the selected target (AAVSO export when a session is active).
- **Transparency trend** — atmospheric transparency % across calibrated frames.
- **Zero point over time** — photometric ZP by frame; rising usually means improving sky.
- **Plate-solve rate (rolling)** — sliding window (8 frames) of solve success; dips flag clouds or guiding stress early.
- **HFR over time** — classic star sharpness trend from accepted lights.
- **Uniformity CV** — background flatness from frame-quality maps; values above ~0.28 suggest gradients.

### Target Campaign Strip

When the active session is bound to a planner target, a compact card shows multi-night progress (session count, primary filter, frames captured, % of integration goal). Tap to open the full **Campaign rollup** dialog.

### Image Grader (SGP-class bulk reject)

**Field Quality → Grade frames** opens a threshold dialog with live preview. Adjust HFR, star count, guiding RMS, etc., then reject all failing frames in one action. Rules are persisted and reused by **auto-reject** (Settings → Science → Auto-reject bad frames), which runs after every light frame without deleting files.

### Science Report Export

**Export report** in the Science jump-nav (or the Science Data Export hub) writes a Markdown session report with photometry, transparency, frame quality, solve rate, and equipment notes to your documents folder.

### FITS Header Writeback

Enabled by default (Settings → Science → Write science keywords to FITS). After calibration/transparency, Skotiq stamps `MAGZP`, `MAGZPERR`, `MAGZPSRC`, `TRANSPAR`, and `SKHA_VER` onto the original `.fits` capture so PixInsight, APP, and Siril read Skotiq measurements without the database.

### KPI Strip with Trust Indicators

The four headline KPIs (Calibration, Transparency, Uniformity CV, Moving Objects) now include trust chips so you can decide how much to rely on each value:

- **Calibration**: Catalog used (APASS / Gaia / Tycho), # matched stars (warning under 12), fit RMS (warning above 0.2 mag), solver id.
- **Transparency**: Quality bucket, extinction coefficient `k`, model confidence percentage (warning under 50%).
- **Uniformity**: Frame SNR (warning under 10), high-clip %, low-clip % (warnings above 1.5%).

### Plain-Language Insights

The Insights panel uses a shared rule engine (see `science_insights_engine.dart`) that flags actionable conditions and tells you what to do:

- **Pipeline last failure** — surfaces the most recent failed stage with the truncated error note.
- **Plate solve health** — warns if no frames have solved or fewer than 50% solve.
- **Transparency warming up** — tells you how many more calibrated frames are needed before transparency stabilises (default: 5 frames).
- **Frame conditions** — high/low clipping, uniformity, SNR.
- **Transparency value** — flags sub-75% sky transparency.
- **Calibration quality** — flags high fit RMS and few catalog matches.
- **Optical-train diagnostics** — surfaces top tilt/coma issues.
- **Equipment health** — surfaces top device health insights.

Sorted by severity: errors → warnings → info → success.

### Overlay Composer with Legends

Each overlay chip now has an ⓘ icon (also accessible by long-press). Tapping it opens a dialog explaining what the colours mean, with a three-stop gradient swatch. The active quantitative overlay (Uniformity, Clip High, Clip Low) also renders its inline legend at the bottom of the composer.

### Per-Frame Science Badges

In the Session tab thumbnail strip:

- **Plate-solve checkmark** (bottom-right, green): the frame produced a WCS.
- **ZP chip** (bottom-right, blue): the photometric zero point for this frame. Tooltip shows the matched star count.
- **Long-press / right-click** any thumbnail to flag it as "poor quality" (no auto-delete — frames stay on disk). The flag toggles `isAccepted` in the database via the standard accept/reject pipeline.

### Imaging HUD — Contextual Offers

The Science HUD on the Imaging screen surfaces one-tap suggestions when the session is ready for a feature:

- **Moving-object detection** appears once you have 3+ light frames.
- **Narrowband ratios** appears once Ha, OIII, and SII frames are all present in the session.

Each offer self-suppresses as soon as the corresponding feature is enabled.

### Transparency Unlock Progress

When transparency is enabled but the model hasn't produced its first sample yet, the HUD shows a compact "Transparency unlocks at N / 5 calibrated frames" progress bar so you can see the gating condition instead of staring at a blank field.

## Best Practices

### Session Review

After each imaging session:
1. Review captured images
2. Check HFR trend for focus issues
3. Review guiding performance
4. Note any rejected frames
5. Export session data

### Performance Tracking

Over time:
1. Compare sessions on same targets
2. Track equipment performance trends
3. Identify optimization opportunities
4. Document setup changes

### Quality Improvement

Use analytics to improve:
1. Optimal exposure times
2. Refocus intervals
3. Dither settings
4. Equipment configurations

## Integration

### With Sequencer

Session analytics include:
- Sequence execution data
- Node timing information
- Checkpoint information

### With Imaging

Real-time updates during capture:
- Live HFR tracking
- Continuous guiding stats
- Temperature monitoring

### With Equipment

Equipment stats track:
- Usage patterns
- Performance over time
- Maintenance indicators

## Troubleshooting

### No Data Showing

- Verify session started properly
- Check database connectivity
- Ensure images being saved

### Charts Empty

- Confirm exposure completion
- Check data logging enabled
- Review session status

### Missing Sessions

- Check date filter settings
- Verify session was saved
- Check database backup

## Keyboard Shortcuts

| Key | Action |
|-----|--------|
| Ctrl+E | Export session |
| Ctrl+F | Filter sessions |
| Tab | Switch between tabs |

## Next Steps

- [Imaging Features](imaging.md) - Capture images
- [Sequencing](sequencing.md) - Automated sessions
- [Settings](settings.md) - Configure logging
