# Skotiq 9.0.0 Linux performance assessment

Measured on 13–14 November 2026. This is an assessment of a fresh Linux desktop
release with normal networking and simulated equipment. It is not a Windows,
physical-telescope, or uninterrupted overnight certification. The 240 Hz target
is **not met**: the stock Linux engine schedules at approximately 60 Hz, and
some measured workloads also exceed either frame-stage budget.

## Target and method

The desktop display is 5120 × 1440 at 239.999 Hz, with a Ryzen 9 7900X and NVIDIA
RTX 4080. Both a 1600 × 900 window and a maximized window were exercised on the
actual Wayland desktop using NVIDIA EGL, not a software-rendered test display.
The corresponding frame-stage target is 4.167 ms. Build and raster work are
reported separately; pipeline latency is also retained. Raster duration is
raster-thread elapsed time, including CPU rendering, driver/submission work
and possible synchronization or scheduling delays. It is not a GPU execution
timer. GTK/compositor presentation happens later and was not instrumented.
See the [engine timing implementation](https://github.com/flutter/flutter/blob/c416acfeb8126e097f758c664aaa3da929e27da0/engine/src/flutter/flow/frame_timings.cc#L185)
and [Linux presentation path](https://github.com/flutter/flutter/blob/c416acfeb8126e097f758c664aaa3da929e27da0/engine/src/flutter/shell/platform/linux/fl_view.cc#L265).
A static screen is allowed to stop drawing, so idle frame gaps are not counted
as dropped frames.

Opt-in frame timing records retain individual engine timestamps, display rate,
build/raster duration and wall-clock completion times. OS samples record process
CPU, RSS, I/O and cgroup events every second. CPU percentages use one-core units:
100% is one logical CPU. Capture CPU includes simulator generation/replay,
image processing and explicit FITS saves, not only UI rendering. The app's
250% CPU quota and 3/4 GiB memory high/max limits did not throttle any scored run. Other user applications were left open;
owned builds and tests were stopped before the release comparisons.

Evidence, scripts, raw frame assignments, fixture provenance, test output and
immutable analysis snapshots are in
`~/.cache/ns-untangle/notes/codex-performance-20261113/`. Baseline release source
is `bd50db6d9d16dc967dbb54af3563b8d2543f5ca7`; this adds measurement to the weather
and location corrections already in that branch. The baseline and follow-up
logs identify the exact source or saved source patch used by each binary.

## Confirmed platform limit

The installed Flutter 3.44.1 Linux embedder does not supply a vsync callback.
Its engine uses a fallback timer fixed at 60 Hz. The display metadata correctly
reports 240 Hz, but a continuously animated planetarium selection produced
16.667 ms engine-vsync intervals (median, p95 and p99). This is engine scheduling
evidence, not a compositor presentation or dropped-frame measurement.

Official Flutter 3.50.0, released 11 November 2026, was also checked at its exact
engine revision `371f77202a73e8dff57a8b3bff75bca55c090aee`. Its Linux embedder still
omits that callback and its fallback remains 1/60 second. An ordinary stable SDK
upgrade therefore does not establish 240 Hz operation. A maintained engine
change and physical presentation validation remain necessary for that target.
Sources: [official release metadata](https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json),
[Linux engine initialization](https://github.com/flutter/flutter/blob/371f77202a73e8dff57a8b3bff75bca55c090aee/engine/src/flutter/shell/platform/linux/fl_engine.cc#L866-L908),
and [fallback scheduling](https://github.com/flutter/flutter/blob/371f77202a73e8dff57a8b3bff75bca55c090aee/engine/src/flutter/shell/common/vsync_waiter_fallback.cc#L34-L55).

## Baseline observations

| Workload | Finding |
| --- | --- |
| Tonight idle, 30 seconds | Average CPU 0.80% of one core; RSS about 503 MiB; no throttling. |
| Guide-camera preview | Build p95 2.093 ms; raster p95 1.056 ms. No guide corrections or populated guide-history graph were benchmarked in this phase. |
| Eight 26 MP captures, histogram hidden | Build p95 2.806 ms; raster p95 1.382 ms. One 133 ms delay before build started. |
| Raw histogram on 26 MP frames | Repeated 41–44 ms builds, including 42.224 ms on initial enable. |
| Weather zoom, 1600 × 900 | Raster p95 9.896 ms; 80/210 frames exceed the 240 Hz stage budget. |
| Weather zoom, 5120 × 1440 | Raster p95 14.586 ms; seven frames exceed 16.667 ms. Includes first-open work. |
| Planetarium selected-object pulse, maximized | Build p95 0.851 ms; raster p95 1.222 ms; CPU 60.5% of one core; scheduling about 60 Hz. |
| Six planetarium catalog recenters | Isolated raster frames of 53.443 and 27.148 ms, despite a 1.173 ms p95. |
| Ten remote 1280 × 856 JPEG previews | All HTTP 200; mean response 412.9 ms, range 349.1–476.9 ms. CPU during concurrent planetarium animation 156.6% of one core. Loopback transport, not a Wi-Fi benchmark. |

The large-image fixture contains 26,091,648 synthetic 16-bit pixels (6248 ×
4176). Every saved FITS header was checked for the real dimensions. Captures use
two-second exposures through the normal manual capture/save API; they do not
measure sequencer throughput. The user's NGC 1245 plan was neither replaced nor
started, and the workload verifies unchanged plan/settings/profile snapshots.

Across the baseline large-frame run, sampled RSS peaked at 1550 MiB and the
kernel high-water mark was 1648 MiB. Later phases released memory; this run does
not establish a leak or an overnight memory bound. One maximized capture had
299 ms between engine vsync and build start. Low build/raster durations do not
erase that delay.

## Changes and follow-up evidence

The raw histogram now counts every pixel in bounded asynchronous batches,
caches by raw-buffer identity, cancels obsolete work and keeps the displayed
axis consistent with the counts. No raw pixels or scientific measurements are
changed. In an eight-capture release retest, the repeated 41–44 ms builds were
absent: maximum build was 11.759 ms, with zero builds over 16.667 ms. There were
still 66/1310 builds above 4.167 ms. The maximum pipeline latency was 21.071 ms.

A weather-only removal of decorative background blur was tested. The small
window's raster p95 was 7.981 ms, but maximized raster p95 remained 14.421 ms.
Different tile/loading states limit the comparison. Actual GUI review also
found sharp map labels showing through forecast text, so the blur removal was
reverted. The accepted build retains the original panel rendering; these
blur-only measurements are experimental, not its final performance result.

Profile-mode CPU and timeline capture identified synchronous copying of the
full 104 MB RGBA preview into Flutter's ImmutableBuffer during post-frame
callbacks. Two callbacks spent 21–29 ms on that copy, after the reported frame
build had ended. Those source-attribution traces ran under test/build load and
are not release benchmark numbers. Concurrent GC work was not mistaken for a
UI pause. This remains a known issue in the accepted release.

The accepted changes are histogram `264991ade` and the four instantaneous
tile-display settings from `1dd762b37`, which remove 100 ms tile-opacity
animations. Final source is `a6ca40442`: `6e617c105` rejects the preview
experiment and `a6ca40442` restores the weather panels. The net production diff
is the histogram helper/provider/HUD and four tile-display settings. The final
quiet release measurements follow below.

A viewport-size preview experiment was rejected after actual GUI testing.
Area-weighted minification preserved narrow stars and reduced the immutable
copy from 104 MB to 3 MB, but the initial scheduler took 3.158 seconds in a
quiet profile run. A revised scheduler reduced resize time to 478.715 ms and
submitted the paint at 502.358 ms. Its immutable copy took only 0.245 ms, but
that improvement did not justify the added preview delay and CPU work. These
are profile-mode stage measurements, not release FPS results. The experiment
was reverted by `6e617c105`; its production tree is identical to `1dd762b37`.
No preview downscaling or image-quality change is included in the accepted build.

The remaining image-copy fix should prepare a faithful display preview from
the native stored frame before transfer to Dart, with exact frame identity,
stretch-state handling and full-resolution access. Existing grayscale JPEG
thumbnails do not preserve the same rendering. That work is not claimed done.

## Final quiet release measurements

Source `a6ca40442`, with owned builds/tests stopped. The app used the same real
Wayland/NVIDIA display, normal networking and simulator profile. Warm zoom
phases contain four plus/minus cycles; page entry and maximizing the window are
separate phases. All 3,504 raw frames in the immutable final snapshot are
accounted for: 2,147 inside the seven phases and 1,357 outside them. Warmup under
regression-test load is outside the scored phases.

| Workload | Build p95 / p99 / max, ms | Raster p95 / p99 / max, ms | Maximum pipeline latency, ms |
| --- | --- | --- | --- |
| Warm weather zoom, 1600 × 900 | 0.993 / 1.744 / 5.209 | 8.837 / 11.122 / 12.318 | 16.750 |
| Warm weather zoom, 5120 × 1440 | 4.333 / 7.270 / 7.426 | 12.566 / 19.496 / 20.794 | 56.606 |
| Weather maximize and settle | 1.171 / 5.634 / 5.634 | 10.449 / 15.109 / 15.109 | 57.126 |
| Imaging page entry, maximized | 7.332 / 33.466 / 33.466 | 12.690 / 13.369 / 13.369 | 45.723 |
| Eight 26 MP captures, histogram visible, maximized | 2.451 / 8.418 / 11.890 | 1.724 / 2.445 / 14.542 | **412.879** |
| Three 26 MP captures with guide-camera preview, 1600 × 900 | 2.265 / 4.481 / 5.166 | 1.122 / 1.666 / 2.168 | 7.635 |

The repeated histogram build stalls remain eliminated in the final build:
0/1,330 capture-phase builds exceed 16.667 ms; 65 exceed 4.167 ms. This does not
mean capture is free of stalls. One frame had **411.344 ms before build began**,
with only 0.295 ms build and 1.209 ms raster. It overlaps the sixth capture's
explicit save request; timing correlation does not establish its cause. The
baseline already contained 133 and 299 ms pre-build delays, so no claim is made
that the histogram change caused or fixed this separate problem.

Source review found that the save request sends small metadata, not image
pixels. Both API and GUI call the same asynchronous Rust save method, whose
file writing uses `spawn_blocking`. The API starts preview publication after
saving; GUI capture publishes before saving. The HTTP interval can therefore
overlap preview processing. This is neither a proven synchronous file-write
bug nor established as a benchmark-only defect; attribution requires a trace
of that delayed frame's UI tasks, image transfer and garbage collection.

Weather remains a weak area: 86/164 normal-window raster spans and 127/153
maximized spans exceed 4.167 ms. Two maximized spans exceed 16.667 ms. The final
p95 values are lower than the earlier baseline observations, but tile content,
cache/load state and phase coverage differ. This is not a controlled proof of
a percentage speedup from instantaneous tile display.

The simultaneous workload used manual API captures while the guide UI remained
in **Looping** state; its visible frame count advanced from 7 to 28. Three FITS
files were verified as 6248 × 4176. No guide calibration/corrections or active
sequencer run is claimed. All eight main captures and all three simultaneous
captures preserved the plan, settings and active profile.

Capture-phase CPU averaged 85.2% of one logical core. The simultaneous guide
preview/capture phase averaged 26.6%; the main imaging page was not visible in
that phase, so those figures do not compare identical rendering workloads.
Across the final 179-second sampler, RSS peaked at 1,876 MiB (kernel high-water
mark 1,911 MiB). No CPU throttling, memory-high, memory-max or OOM events occurred.
The short run does not establish an overnight memory bound.

After the measurements, the normal release was restarted with profiling and
large-image replay disabled. Seven simulator devices were connected, the API
responded, the sequencer was idle, and the original editor-plan hash matched.
The histogram was returned to its original hidden setting and stretch stayed
on. A fresh 30-second idle sample used **0.33% of one CPU core** and approximately
**501–509 MiB RSS**, without throttling or memory-limit events.

Final evidence: `run5/final-20261114T053303Z/` and `normal-final/` beneath the
evidence directory above. The report preserves maximum values and the delayed
frame's timestamp decomposition rather than summarizing only percentiles.

## Verification

| Check | Result |
| --- | --- |
| Full core suite | 8,141 passed, 14 skipped. Final core source is unchanged from the tested histogram implementation. |
| Full desktop suite | 1,458 passed, including opt-in raw frame timing. Final desktop source is unchanged from this tested version. |
| Full app suite | **5,482 passed, one skipped**, exit 0, on final source `a6ca4044203efafd75ed4feddeca66f48e2d6fd7`. |
| Production analysis | Passed with zero errors and zero warnings. Existing informational findings remain. |
| Architecture / bridge boundary | Both passed on final source. |
| Linux release build | Passed on final source in 91 seconds. |

The accepted changes also had independent source review. Interrupted suites are
explicitly marked partial/superseded in the evidence and are not counted as
passes. The rejected preview's 22 focused tests and 5,497-test app pass did not
override its failed runtime acceptance. The reverted blur experiment's 721-test
UI pass likewise did not override the actual panel-readability problem.

Only the host-built Linux desktop bundle was rebuilt by this performance pass;
the previously recorded portable Linux archive and Android APK are unchanged.

## Remaining work before claiming the refresh-rate target

| Area | Required next evidence or change |
| --- | --- |
| Linux display scheduling | Integrate the display clock through the engine/embedder and validate compositor presentation. A stable SDK upgrade alone does not supply this. |
| Large-frame pipeline | Attribute the 411 ms pre-build delay; separately remove the known full-buffer UI copy through a faithful native preview path. Retest both API saves and normal GUI capture, retaining full-resolution access and star fidelity. |
| Maximized weather | Profile raster-thread submission and tile work while retaining readable controls. Repeat matched warm/cold zoom workloads against both 4.167 and 16.667 ms budgets. |
| Cold navigation and planetarium recentering | Account for the measured 33–53 ms outliers rather than relying on steady-state percentiles. |
| Remote preview | Investigate the approximately 0.4-second loopback JPEG response cost; test a real companion network before extrapolating to Wi-Fi. |
| Coverage | Larger sensors, populated science/library workspaces, live stacking, an overnight run, Windows and physical hardware remain unverified. |

## Supplementary checks and scope

The existing chart paint-recording benchmark exercised 300 guide points and
192 analytics points after 60 warmups, with 300 timed iterations. Median CPU
recording cost was 100 and 85 microseconds respectively. It excludes layout,
GPU rasterization and presentation, and cannot establish a chart frame rate.

The separate Flutter-test planetarium benchmark exercised 14,000 stars, 900
DSOs, 18 constellations, 2,448 Milky Way points and four planets over 180 scripted
pan/zoom/time frames after eight warmups. CPU paint plus raster/readback p50 was
10.789 ms, p95 21.669 ms and p99 25.953 ms. This is a test-renderer diagnostic,
not the RTX 4080 desktop's frame-rate result.

Navigation was exercised across the main pages, including equipment, flat
wizard, sequencer, settings, Darkroom, analytics and planning. Empty/lightly
populated pages do not certify large libraries, a populated science workspace,
live stacking, or a complete imaging-night workload. Native keyboard/scroll
automation was unavailable, so no continuous manual-pan or 600 ms fly-to result
is claimed. Mouse-driven map zoom, catalog recentering and continuous selection
animation were verified visually.

The current evidence does **not** certify “display refresh rate all the time.”
The engine ceiling, occasional cold/recenter costs, remaining map raster cost,
full-resolution image-copy behavior and unavailable real hardware must remain
visible in any release decision.
