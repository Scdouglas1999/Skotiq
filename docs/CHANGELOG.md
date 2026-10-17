# Changelog

All notable changes to Skotiq are documented in this file.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Engineering cross-references in the form `(§N.M)` point at the
`docs/plans/2026-05-09-v250-audit-fixes.md` v2.5.0 pre-release audit and are
intended for code reviewers rather than end users.

## [7.1.0] (build 28, 2026-09-19)

Most of the user interface rewritten on one shared set of components, three new
features, and a batch of fixes for problems found using the app on a telescope
in September. Full notes in `docs/release/v7.1.0.md`.

### Added

- Every screen rebuilt on the same component library, so controls behave the
  same wherever you are. Covers Tonight, Plan, Analytics, Weather, Equipment,
  Guiding, Settings, Onboarding, Imaging, the Sequencer, the Darkroom, the polar
  alignment and flat wizards, and pairing. Each screen has a proper page header,
  there is a new navigation rail, and the bottom navigation bar stays on screen
  below 768 px.
- Three display densities for the sequence tree, switched from the toolbar and
  remembered. Repeated steps collapse into one row with a count, the branch
  currently running stays pinned while you scroll, and a gutter marker shows
  where you are in the run. Step details gained Settings, Activity and Notes
  tabs. The toolbox Queue tab is now Targets.
- DepthLock. Draw a box around part of your target and another over nearby empty
  sky, set a depth, and the app measures that region on every matching exposure
  from then on, across nights. It reports how much each filter still needs, and
  says when more time will not help because calibration error is the limit.
- Focuser backlash measurement. Two focus sweeps, one from below and one from
  above, fitted and differenced, saved per focuser. The wizard says how long the
  run takes and how many moves it needs before starting.
- Wi-Fi positioning with separate permission per accuracy level and the accuracy
  radius shown. "Detect location" falls back to an internet lookup in one click.

### Fixed

- Sequences died about a second and a half after starting: the arrival check
  compared J2000 target coordinates against the mount's current-epoch position,
  which never match.
- Polar alignment never worked running west. The rotation axis fit picked the
  opposite point on the sky, so the correction pointed the wrong way. It also
  now re-reads declination each step and solves alignment frames with a position
  hint from the mount rather than blind.
- The app froze the first time a plate solve succeeded, because the annotation
  code read an 896 MB galaxy catalogue line by line on the UI thread. Star
  matching against the catalogue was also quadratic, and an image texture leaked.
- When the guider failed, exposures carried on and the app then parked the mount
  with someone standing next to it. Exposures now stop, and parking after a
  failed recovery is opt-in.
- A failed INDI reconnection left the client marked as restarting, which is a
  state the retry logic refuses to act on, so the app never tried again.
- Thumbnails decoded full-resolution FITS on the UI thread instead of reading
  the small preview files that already exist.
- Autofocus: focus now lands from below and is confirmed with a real frame; the
  outlier filter was discarding the points nearest focus on good sweeps; the
  star count reports stars detected rather than the limit on stars used; the
  backlash model was wrong.
- Camera sensor specifications now come from one place, and the fuzzy name
  matching used to identify your camera was picking the wrong sensor.
- The Profiles tab in Equipment had no detail pane, so clicking a profile did
  nothing.
- ASCOM mount site and time go through the COM worker thread rather than a lock,
  and the app asks which to use when the mount and computer disagree.
- The NYX mount answers the timezone query with `+05:00` rather than `+05`.
- Session reports lead with what went wrong rather than whatever failed last
  during shutdown.
- Dropdown menus open on the button you clicked instead of mid-screen. Text is
  in sentence case. Red night mode covers the imaging canvas and weather map.

### Changed

- The default focuser backlash is now 0 rather than 350. The 350 was invented
  and was reaching both Settings and the autofocus API.
- The catalogue prompt at startup is gone; the Tonight checklist handles it.
- The mount position poll no longer repaints the whole window.

## [7.0.0] — Darkroom (build 27, 2026-09-07)

Wake up to a finished image you can still change your mind about. The dawn
autopilot integrates the night into per-filter linear masters, composes a
first-draft **recipe**, renders a draft, and delivers everything where you want
to work in the morning — and every step it took is editable, reorderable and
discardable, because the draft is data, not a baked file. Proven against
simulators on Linux by a committed live harness (64 assertions across three
legs); on-sky and Windows validation are owed. See `docs/release-notes.md`.

### Added

- **Darkroom** — a non-destructive recipe engine (eight v1 operations, schema
  v58/v59) with an editor whose step cards keep three truths separate: what the
  recipe says, what validation says, and what the render actually did, including
  *why* a step was skipped. Branch any recipe at its shared prefix and compare
  branches side-by-side or blinking with a shared zoom/pan. "Reset to linear"
  always exists and never destroys anything.
- **Dawn autopilot** — on sequence completion, calibrate, register and integrate
  accepted frames into per-filter linear masters, then compose and render a
  first-draft recipe (gradient removal, denoise, colour calibration where the
  data supports it, an auto-fitted stretch, an edge crop).
- **Delivery engine** — watched folder (NAS included), SFTP over the system
  OpenSSH with key auth, or a paired desktop that pulls a signed manifest with
  resumable downloads. Copy, never move; atomic writes, checksum verification,
  bounded retries that survive a rig reboot, and a journal whose every status
  line derives from a recorded fact.
- **Export at any stage** — the linear master, the image after step N, or the
  final render. FITS carries the full recipe as provenance (HISTORY cards plus a
  `.nsrecipe` sidecar); a raster export of a still-linear stage is a visible
  screen-transfer choice, never a silent auto-stretch.
- **Honest calibration reporting** — every master states which darks/flats/bias
  were applied, per slot, with match quality and staleness, in the result, the
  FITS HISTORY and a `CALWARN` card. A missing master is an explicit entry.
- **Live release harness** (`tools/harness/d1_sim_night/`) — a full simulated
  night from fresh install to checksummed delivery, a crash leg that kills the
  process mid-job, and a two-nights leg, all run against the release bundle.

### Changed

- **Stacking normalisation follows PixInsight's default** (additive with
  scaling). The 6.2.0 background-pair OLS fit erased stars; frame retention went
  from 0.08% to 100%. v1 accumulating-master sidecars are refused at
  `MASTER_STATE_VERSION 2` — **masters produced by 6.2.0 are void and must be
  re-integrated.**
- **The behavioural audit register is at zero open findings** for the first
  time: every silent-behaviour site fixed or documented with the mechanism that
  makes it safe.
- **Observer location is explicitly unknown** until you set one; the backend is
  told null rather than 0/0/0. Simulation mode's dead toggle is gone.
- `SKOTIQ_DATA_DIR` is the root of everything Dart writes — one resolver,
  52 call sites.
- Colour calibration is labelled for what it is: a Johnson B−V regression
  against the shipped catalogs. It is not SPCC and refuses mono input loudly.
- Catalog downloads: the three tiers were a placebo. One dataset, stated once,
  with HYG's real depth.

### Fixed

- **Three-point polar alignment rotated in the wrong frame.** The step target
  was built from the *solved* coordinates, so the mount absorbed the very
  misalignment being measured — a two-axis swing toward the pole instead of a
  10° step in RA. The target is now built in the mount's own frame, a step that
  would cross the meridian is refused, and the settle wait polls the driver's
  `slewing` flag instead of sleeping five seconds.
- **A finished node says so** — `NodeCompleted` now answers every
  `NodeStarted`, so spinners stop when the run does.
- **Idle frame rate was the number of clock phases, not the clock rate.** Every
  1 Hz clock is aligned to the epoch-second boundary, and an urgent status dot
  pulses for twenty seconds then holds instead of costing a third of a core
  forever.
- **Calibration frames count** — a 3-frame dark run no longer reports 0/0
  frames and 100% downtime, and it leaves the mount parked.
- **Meridian handling** — the trigger reads the target's sky, not the mount's
  pointing; a parked or non-tracking mount does not arm the flip; preflight
  warns when the flip would re-centre without a solver.
- **Plate-solver verification is bounded and reaps a hung probe** — an ASTAP
  GUI build opens a window instead of exiting on `--help`. The CLI executable is
  now preferred wherever both are installed, and verification is no longer a
  synchronous bridge call on the UI thread.
- **USB hot-plug re-probes after a bus event** (~3 s, ~13 s, ~43 s). A single
  immediate probe cached "nothing here" while Windows was still installing the
  driver, leaving the device invisible until the five-minute fallback.
- **Windows runner lifecycle** — the Flutter controller is torn down while the
  window and COM apartment are still alive, a font-change broadcast during
  teardown no longer dereferences a released controller, and a `GetMessage`
  failure is reported as one.
- **Database migrations** cannot brick the library: a backup first, then an
  atomic upgrade.
- **A missing SQLite busy-timeout** let any external reader holding a read
  transaction kill the daemon at startup.
- **Weather map** — labels above the clouds, honest zoom, tiles that retry, one
  `saveLayer` per tile, and a basemap that is not a wall of "API KEY REQUIRED".
- 120+ further defects from the six Darkroom break-waves (30, 21, 33, 22,
  unrecorded and 14 findings by their own commit subjects) and the wave 7–19 fix
  fleets, each reproduced against the running build before it was fixed.

### Security

- Darkroom delivery egress is scoped to control; credential files are `0600`.
- `--allow-unauthenticated` no longer outranks a configured token.

## [6.2.0] — The Tightening Pass (build 26, 2026-08-14)

A commercial-grade hardening cycle: every subsystem mapped, the running app
adversarially reviewed by agents driving the real release build, and every fix
batch re-driven live and attacked by independent refuters until a wave came
back dry. Ground truth: `reports/release-pass/RELEASE-PASS-2026-08-11.md`.

### Added

- **"Autopilot paused — resume?"** — stopping a run the autopilot dispatched now
  pauses the autopilot with a visible resume affordance instead of silently
  re-dispatching the next target 44 seconds later. A safety abort does NOT
  pause it: the autopilot rides out clouds and re-evaluates, its own safety
  gating deciding when dispatching is sane again.
- **Stop notifications with their true cause** — safety aborts and autopilot
  stops push to your phone as info ("Stopped: …"); your own press stays
  silent. A failed interval autofocus pushes "the sequence continues on the
  restored last-good focus" instead of ending the night or crying wolf.
- **FITS stacked masters** — the live-stack master saves as FITS with
  synthesized EXPTIME (total integration) and DATE-OBS (first frame).
- **Mosaic panel resume is real** — the wizard checkpoint sink is wired into
  production (and the executor's streaming checkpoints no longer erase panel
  state); on-rig validation still owed.

### Changed

- Removing a target from the scheduler now makes it fully ineligible for
  autopilot selection — removal means what the button says.
- Autopilot plans unpark the mount only when it actually reports parked.
- A failed interval autofocus restores the pre-sweep focuser position and
  CONTINUES the run with a decision row, deferring the next attempt by a full
  cadence. Explicitly-configured autofocus nodes keep their own failure
  actions.
- The imaging screen's Frame Count label counts the current loop's frames
  while looping, resetting per loop; guide-step counting is unchanged where
  RMS gating depends on it.

### Removed

- Roughly 13,700 lines of code that could never run in a shipped
  configuration: the Dart fallback device clients (PHD2, Alpaca, ASCOM) and
  their retry/circuit-breaker utilities, the unimplemented alternative native
  backend, the `SKOTIQ_COMPANION_UI` mobile dashboard, and orphaned
  device-service and profile-connect paths. The bridge policy comment now
  states the truth: Rust is the only device path.

### Fixed

- **Stopping a sequence tells the truth, end to end.** One press of Stop is one
  feed row reading "Stopped by request" — not three rows and a red error toast.
  Stops name their true author: the operator's press, "Stopped by autopilot"
  for a scheduler re-plan, and cause-neutral for safety aborts (weather, dome,
  disk). The executor records the caller's origin on every stop path —
  operator, scheduler, failed-launch rollback, disk watchdog — and the one
  decision proving a human acted can no longer be silenced by the
  replay-logging preference. Stopped events carry their run id, so the feed
  can never merge two runs' endings or lose an old stop from the night's
  record. The whole contract is pinned by a 19-case conformance suite.
- **Two sequence nodes of the same type now both render.** Adding a second
  "Take Exposures" (or a second target) beside the first silently showed only
  one card in release builds — a duplicate-GlobalKey element theft the debug
  assert masks. Coach-mark anchors now attach to the first node of each type
  only.
- The floating dashboard prompts ("Plan tonight", "Skip this step") reserve
  the space they actually occupy — measured after layout, tracking text-scale
  and locale rewraps — so the last dashboard row can always scroll clear of
  them, and dismissing one prompt cannot collapse the reserve under the other.
- Operator stops are no longer pushed to your phone as critical FAILURES.
- A completed run shows one completion row (the wire's duplicate terminal echo
  no longer renders as "Sequence complete ×2").
- The "No active target — load a sequence to begin." glance line no longer
  instructs you to load a sequence while one is visibly running.
- Meridian-flip, autofocus, and recenter triggers wait for the in-flight
  exposure via a camera claim instead of stomping it; Pause and Park never
  wait.
- The stacked preview renders with the shared screen-transfer stretch instead
  of a linear one that showed every sky as black.
- Plate-solve centering: the `.wcs` parser read only the first header card,
  no field-scale hint was passed to the solver, and an interval-autofocus
  fired mid-run at frame 25 — all three fixed.

### Changed

- ~100 duplicated call sites consolidated onto single implementations
  (sidereal time ×14, coordinate formatting ×39, duration formatting ×30),
  each pinned by exact-equality parity tests; 118 oversized files split into
  reviewable modules; the generated bridge bindings regenerated to mirror the
  new module tree.
- PHD2 is visible to the connected-devices API, ending false "guider
  disconnected" warnings while PHD2 was guiding.
- The coverage ledger now counts every shipped tree, including the hub server
  (1,182 units / 3,826 interactive controls).

## [6.0.0] — Make It Real / Collaborative Sky (build 24)

Everything since 5.0.0: a reliability substrate for rigs left running unattended,
coordinated multi-rig imaging through a self-hosted hub, and an extended
validation pass against real imaging hardware.

### Added

- **Collaborative Sky** — shared calibration libraries with provenance and
  consent, claimable distributed mosaic panels, and live co-imaging sessions
  through a self-hosted hub.
- **Headless unattended services** — auto-connect bootstrap, a bounded
  shutdown coordinator, and a scriptable HTTP surface covering the desktop
  feature set.
- **Windows ASCOM STA worker** so unattended ASCOM work no longer hangs on COM
  apartment behaviour.
- Signed OTA update machinery, dormant until keys are provisioned.
- Run history gains an `interrupted` state for runs a dead process left behind,
  with a filter for it alongside `stopped` and `paused-stopped`.

### Changed

- Weather and SafeRig refuse to report "safe" when they do not know, rather
  than defaulting to safe.
- Sequencer lifecycle reports the truth mid-stop and mid-finalize instead of
  publishing a terminal state early.
- Backend errors reaching a client are mapped to operator-readable sentences;
  the mapping is exhaustive, so a new error variant breaks the build rather
  than leaking its constructor form.
- Stop/abort endpoints distinguish "stopped something" from "there was nothing
  to stop" while remaining idempotent.
- A successful pairing clears the bearer-token failure lockout.

### Fixed

Approximately sixty defects found by driving running software on real hardware.
The dominant class was the application reporting something untrue:

- Out-of-range camera gain/offset were silently clamped by the SDK but reported
  back as requested, poisoning FITS `GAIN`/`OFFSET` keywords and dark-library
  matching.
- Device capabilities served volatile state (cooler, filter position, safety)
  from a five-minute cache.
- Out-of-bounds subframes were silently relocated and reported as success.
- Overlapping exposures destroyed both frames and returned a generic 500.
- An unattended run could deadlock indefinitely on a rig with no focuser.
- Untargeted runs aborted the exposure after the shutter had opened, discarding
  real photons.
- Stop could wait forever on a terminal event the bridge may legitimately drop.
- Automatic recovery could command mount tracking on a parked mount.
- Analytics under-reported total integration time by a factor of nearly eight
  because session counters were lost when a session did not end cleanly.
- Runs left `running` by a crashed process were never reconciled, so the run
  list contradicted the sequencer's own idle state.
- The weather endpoints returned HTTP 500 on a clear night, because the
  "no cloud front" sentinel is infinite and has no JSON encoding.
- The dashboard reported darkness as ~21 hours away while the sun was 30°
  below the horizon.
- Settings, sequencer, dashboard and polar alignment surfaces overflowed at
  1024×768 and below, including at the large font-size setting.

### Verification and limitations

- Validated against a Windows host with an ASCOM Pegasus NYX-101 mount, a native
  ZWO ASI1600MM-Cool and a ZWO EFW, plus simulator and GUI drives. The mount was
  never commanded to move.
- **Not validated: imaging under a real night sky.** A real frame was captured
  through the optics at the parked pointing, but contained no stellar field.
- Mount motion (slew, sync, park/unpark, homing, meridian flip) is unexercised
  against this hardware.
- No switch device exists on either test machine, so that capability path is
  unverified.
- macOS and iOS remain unbuilt and untested.
- Long-duration unattended soak, live S3/MinIO/B2 restore and production signing
  evidence remain owner-gated.

## [5.0.0] — Living Sky (build 23)

Everything since 4.3.0: a personal growing atlas, First Light discovery and
reporting, a self-hosted Constellation swarm, desktop master/slave control,
automation-core unification, S3-compatible backup, and extensive security,
correctness, accessibility, and release-packaging hardening.

### Added

- Your Sky atlas persistence, First Light transient review, real TNS bot-API
  submission, and manual AAVSO/MPC export.
- Self-hosted Constellation hub with scoped auth, additive tile fusion,
  retraction, trust weighting, follow-the-night scheduling, and dedicated CI.
- Desktop master/slave mode with remote-aware profiles, plans, session state,
  histories, observing lists, calibration libraries, and atlas surfaces.
- S3-compatible backup targets for AWS S3, MinIO, and Backblaze B2.

### Changed

- Unified automatic-imaging entry points and shared scoring, safety,
  sidereal-time, mosaic, calibration, and focus-temperature contracts.
- Database schema advanced from v51 to v55 through additive migrations. The
  release gate migrates and verifies a profile database generated by the
  tagged v4.3.0 implementation.
- Official Windows packages are portable, unsigned betas. Vendor SDK binaries
  are not redistributed; native paths require user-installed vendor support.
- Official 5.0.0 packages are manual-update-only. OTA code remains fail-closed
  for operator builds but no updater/key/server is shipped publicly.
- Desktop archives and release assets now include Skotiq and third-party
  license notices.

### Verification and limitations

- Static analysis and automated Dart, Flutter, Rust, hub, contract, migration,
  compatibility, and packaging checks are release-gated.
- New Living Sky, automation, and desktop master/slave paths still require a
  supervised physical-rig / second-machine validation before unattended use.
- Android remains a debug-signed sideload beta; macOS has no shipped artifact.

Full notes: `docs/release/v5.0.0.md`. Detailed evidence:
`docs/release-evidence/5.0.0.md`.

## [4.1.0] — Solid from the couch. (build 20)

A hardening follow-up to 4.0: the catalog experience was rebuilt, the remote and
appliance paths got sturdier, a real-time insight feed and a new weather source
landed, and a long tail of crashes and races was fixed. Full notes:
`docs/release/v4.1.0.md`. What's actually been run on real hardware versus
code-only: `docs/release-evidence/4.1.0.md`.

### Added

- **Night Narrator** — a real-time, plain-language session insight feed surfaced
  across the relevant screens.
- Narrower `skotiq_core` barrels
  (`skotiq_core_{models,backend,database,services,providers}.dart`) alongside
  the retained aggregate barrel, so new imports can pull a single layer.
- Headless API: more desktop-parity endpoints (defect mapping, post-session,
  live-stacking, session-science, sequencer/planetarium handlers) and an
  always-on `/api/system/version` route.

### Changed

- **Catalog management rebuilt:** downloads stage to a temp file and swap in only
  once complete and verified, cancel mid-flight, stream multi-gigabyte files
  (and count objects) straight to disk, and keep their progress when you leave
  the screen; catalog cards now show size, version, object count, depth, and use.
- More reliable mDNS discovery and pairing; updated Avahi/systemd packaging for
  the dedicated-box appliance; smoother mobile reconnect to a known rig.
- Headless API fails closed on unknown auth scopes; `/api/info` advertises every
  registered route; handler errors are logged explicitly instead of swallowed.
- Headless settings now persist through the DB-backed settings store (full
  round-trip) instead of the 7-field bridge subset.
- Self-contained Linux bundle: ubuntu-22.04 glibc floor, bundled libraw and
  sqlite, `$ORIGIN` RUNPATH.

### Fixed

- Autopilot/sequencer hardening across autofocus, exposure, meridian-flip, and
  fault-recovery.
- Catalog download no longer truncates the installed catalog on a dropped
  connection; the planner empty-state no longer falsely reports a catalog as not
  installed.
- LX200 serial-handle leak on probe-timeout that locked the COM port against
  later connects.
- Device-name control-character sanitization on discovery; a missing `deviceId`
  now returns a structured 400 instead of an opaque 500.

### Known limitations

- Fully-unattended **headless** acquisition on real ASCOM hardware is still being
  hardened — headless COM-session issues (the desktop GUI path works for the same
  operations). See `docs/release-evidence/4.1.0.md` and `docs/known-limitations.md`.
  Supervise early nights.

## [4.0.0] — From your couch. Wake up to a finished image. (build 17)

The headline release: run your whole rig from your phone like an ASIAIR — but
with any gear, a real autopilot, a built-in planetarium, and a master that's
finished, diagnosed, and labelled by morning. See
`docs/4.0-activation-checklist.md` for the three external steps (iOS publish,
cellular-push keys, on-sky tuning) that flip the gated bits live.

### Science & photometry audit (2026-06-10)

- **Catalog-anchored photometric transform.** The calibration wizard now
  fits the transform against the bundled HYG catalog (real V magnitudes,
  exposure-normalized instrumental magnitudes) with a degeneracy-aware
  2-/1-parameter fallback when color can't be solved from a single frame.
  Transforms saved before this build were fit on raw flux and should be
  re-run.
- **Camera gain & saturation settings.** New Science → Camera rows for gain
  (e⁻/ADU) and saturation level (ADU) feed the star-measurement saturation
  limit and an electron-correct limiting-magnitude noise model. Common
  white levels (4095 for 12-bit, 16383 for 14-bit) are noted in-line.
- **Image Grader FWHM/eccentricity sliders.** The grader dialog gained Max
  FWHM and Max eccentricity rules driven by per-frame PSF-tile medians; the
  auto-grader sources FWHM/ecc from the same PSF tiles. A null metric skips
  its rule by contract.
- **One projection for all astrometry.** Sky↔pixel math is consolidated
  onto a single gnomonic projection; duplicate implementations were removed
  from three science files.
- **Honest provenance.** AAVSO export computes comparison/check magnitudes
  from flux and stamps the real app version; the EXTINCT FITS keyword is
  only written for a real airmass-fit value; the photometric catalog 'auto'
  source resolves to local HYG with recorded zeropoint provenance;
  moving-object measurements use the mid-stack epoch; science frame
  processing is serialized.

### Science & photometry — online catalog & auto-config (2026-06-10)

- **Online APASS catalog.** Opt-in APASS DR9 cone search via VizieR (cached
  to disk on a 0.2° pointing grid, HYG fallback when offline) gives the
  calibration wizard real B−V colors and stamps `LOCALAPASS` provenance.
  Toggle in Science → Catalog.
- **Multi-frame calibration.** Select several frames so the airmass spread
  makes atmospheric extinction fittable; also fixes a bug where the wizard
  passed a null frame context and local calibration always failed.
- **AAVSO check star.** With three or more inlier comparisons, the star
  closest in flux to the target is promoted to a check star with its own
  differential magnitude.
- **Moving-object magnitudes (schema v47).** Moving-object candidates now
  carry a magnitude and band; the MPC export fills the magnitude columns
  (band V). Migration is idempotent and column-existence-guarded.
- **Automatic camera config.** A new service syncs the Science → Camera
  values (gain, saturation, read noise) from the connected camera/profile;
  opt out with `science.camera.auto_managed`, and any manual edit turns the
  auto-management off.

### Release hardening (2026-06-10)

- **Fleet UI/UX audit.** ~60 fixes across every screen: narrow-width and
  phone overflow bugs (app-shell SafeArea, dialog viewport constraints,
  bottom-nav labels, panel toolbars), ~25 raw-exception error states
  replaced with clean themed messages, icon-button tooltips, an
  autofocus-overlay crash on sub-360dp phones, a cooling-panel temperature
  parse that never matched, and a sweep of 483 corrupted UTF-8 sequences
  across 57 files.
- **Relay connections persist.** "Connect via Relay" now saves to the
  mobile saved-servers list (RELAY badge) and reconnects with the stored
  token — no nightly re-pairing. Tokens stay in secure storage.
- **Guider knobs explained.** Every built-in guider tuning setting carries
  a plain-language description of what it does on a bad-seeing night.
- **Android release APK builds again.** The desktop→mobile e2e seam test
  moved to a test-only `apps/mobile_e2e` package; the desktop dev-dependency
  no longer leaks a desktop plugin into the Android release registrant.
- **Trustworthy test baseline.** The 12 long-standing imaging_service_test
  failures are fixed (test-lifecycle issue, not pipeline bugs); golden
  pixel tests are tag-gated out of default CI runs with an opt-in
  `melos run test:golden` (baselines are Windows-rendered); CI pins Flutter
  3.44.1 everywhere and the repo is formatted with the Dart 3.12 formatter.

### Couch-release feature expansion (2026-06-10)

- **Turnkey appliance packaging.** Hardened systemd unit + installer,
  Docker/compose deployment with API healthcheck, and a Raspberry Pi
  (arm64) image builder with first-boot Wi-Fi hotspot provisioning
  (`packaging/appliance/`). Release-enablement playbooks for iOS publish,
  FCM/APNs credentials, and a 7-night on-sky validation campaign live in
  `docs/release/`.
- **Remote access relay.** Self-hostable relay (`tools/skotiq_relay`):
  the appliance dials out over WebSocket, phones connect through a
  multiplexed tunnel — no VPN or port forwarding. End-to-end auth stays the
  existing HMAC pairing token; the relay never sees credentials. Desktop
  `--relay-url` flag, mobile "Connect via Relay" flow; live view falls back
  WebRTC→WebSocket automatically.
- **Built-in multi-star guider, grown up.** Star selection now rejects
  saturated/elongated/edge stars; offsets are sigma-clipped, flux-weighted
  means that shrug off a single jumping star; calibration derives axis
  angles, rates, orthogonality, and measured Dec backlash (compensated once
  per direction reversal); dither walks a golden-angle spiral scaled by
  recent RMS. Per-star weights ride the existing telemetry into the UI.
- **Dual-rig synchronized imaging (v1).** A piggyback secondary camera runs
  its own capture loop with a native dither barrier: the secondary is never
  mid-exposure when the primary dithers (complete-if-short or abort policy),
  and a stuck secondary can never stall the primary past a bounded wait.
  Frames share the naming/metadata pipeline, tagged `NS-RIG`. Opt-in
  "Secondary Rig" dashboard tile; headless routes for mobile/web monitoring.
  Same-mount only; no secondary guiding/solving/AF by design.
- **Calibration library manager.** Browse/filter/tag every dark, flat, bias,
  and defect-map master with age indicators; transparent auto-matching
  (exact gain/offset for darks, temp tolerance, exposure scaling, flats by
  filter + recency) now drives unpinned master selection in post-session
  integration, with staleness warnings surfaced. Settings UI with
  matching-preview panel, `/api/calibration-library` routes, FITS-header
  enrichment, schema v46.
- **Device hot-plug recovery.** Reconnect of a yanked USB camera or serial
  mount now re-applies cooling setpoint and tracking state (drivers lose
  both across a physical reconnect); disconnect/reconnect continue to flow
  through heartbeat debounce → recovery loop → push notification.
- **Deep-star catalog tier + live minor-planet refresh (planetarium).**
  Downloadable tiled deep-star catalog (SKDT format, hash-verified,
  LRU-cached) renders below 8° FOV with clean HYG handoff; MPC element
  refresh unions fresh comet/asteroid elements into the overlay and omnibox
  search, offline-safe with last-updated indicator. Catalog prep tooling in
  `tools/catalog_prep/`.
- **Home Assistant auto-discovery.** Opt-in MQTT discovery publishes the
  observatory as one HA device: safety/sequence/guiding/cooling binary
  sensors, target/progress/HFR/RMS/weather/sun-altitude sensors, online
  availability via last-will, and (default-off) pause/resume/abort controls
  routed through the same code paths as the UI.
- **Cloud backup & sync.** WebDAV (Nextcloud-compatible) or S3-compatible
  object storage (AWS S3, MinIO, Backblaze B2) push/pull of the existing
  backup bundles with SHA-256 manifests, retention pruning, keyring-stored
  credentials (the S3 secret key, like the WebDAV password, never touches
  the settings database), opt-in auto-push after the daily backup cycle, and
  a remote-browser restore flow (restore replaces local config — bundle-based,
  no merging). Pick the provider in Settings > Backup & Sync; existing WebDAV
  configurations are preserved unchanged.
- **Weather verdict abstain channel, proven.** The disabled/snoozed/fail-open
  safety paths push an explicit abstain (never "safe") to the native
  executor; an exhaustive verdict × hardware gate-matrix test now pins that
  an abstain can never suppress an unsafe signal.
- **Planner = autopilot, guaranteed.** The Planner headline is a read-only
  preview of the live `SchedulerEngine` scoring, so the target shown is the
  target imaged; suggestion data is re-scoped to advisory night-outlook
  columns. Notification router eager-mounts at startup with a
  no-double-subscribe guard test.
- **Localization pass.** Wizard/tour/settings/planner/equipment chrome
  extracted (43 new keys, full Spanish coverage), translation-completeness
  test added, contributor guide at `docs/i18n-contributing.md`.

### Full-stack imaging-night audit (2026-06-09)

A ten-subsystem deep trace (camera/cooling, slew-center-solve, meridian flip,
filter wheel, autofocus, sequencer engine, guiding, monitoring, planning,
native device layer) with every finding verified against the code before
fixing. Fixed:

- **Resume-from-checkpoint never actually resumed.** All three resume paths
  (crash-recovery dialog, mosaic resume, executor provider) called the
  native prepare step but nothing issued the `sequencerStart()` that walks
  the restored tree — the UI showed "running" while the executor sat idle.
  Resume now prepares, re-seeds current settings over the snapshot
  (location for the W1 daylight gate and hour-angle math, safety fail mode,
  AF cadence, dither, grading), creates a session/run row so stats attach,
  restarts the settings watchers + sky-brightness poll, and starts.
- **Pre-exposure meridian gate (N.I.N.A.-style).** A frame that would still
  be exposing when the flip trigger fires is now held until the flip
  completes instead of being ruined mid-exposure by the flip slew. Also
  fixes `meridian_trigger_method` never being stamped into trigger state in
  production (the MountTrackingLost→OnTrackingLimitHit deferral never
  engaged).
- **Autofocus fail-soft.** A wrong-way parabola / degenerate fit or
  over-aggressive outlier rejection now falls back to the minimum-HFR
  sampled position (R²=0, warned) instead of aborting AF and leaving the
  focuser at the sweep edge.
- **Native centering: 180 s plate-solve timeout** — a hung solver process
  can no longer stall an unattended centering loop indefinitely.
- **Camera warm-up race.** `Timer.periodic` with an async body could land a
  stale `cameraSetCooling(enabled: true)` *after* the completion tick
  disabled the cooler, leaving it silently re-enabled forever. Now a
  self-rescheduling tick with per-tick error containment and a device-id
  guard. Cooler is also best-effort disabled on intentional camera
  disconnect (ASCOM/INDI coolers outlive the client connection).
- **Exposure timeout honesty.** On an exposure-event timeout the interactive
  capture path aborts the (possibly still-running) exposure and discards
  stale prior-frame images instead of saving them under new metadata.
- **Twilight solver rewrite.** Crossing search is now direction-aware
  (coarse bracket + bisection) and anchored on the *site's* solar noon, so
  high-latitude sites (sunset past local midnight) and rigs far from the
  controlling machine's timezone get correct, same-night dusk/dawn times;
  previously these returned null or mixed events from different solar
  days. New cross-latitude regression suite (18 cases vs brute force).
- **Filter focus offsets (interactive path).** Offset moves are now
  verified against actual focuser position before being recorded (a
  stalled move used to poison all subsequent delta bookkeeping), the
  per-wheel baseline is seeded on connect (reconnect used to double-apply
  the current filter's offset), and a failed offset raises a toast, not
  just a log line.
- **Monitoring**: the run-dashboard HFR sparkline now includes rejected
  frames (warning dots) with a min–max scale label — a focus collapse that
  causes rejections is visible in the trend again; guide-graph history
  extended 100→400 samples; mobile camera tab gained a glanceable
  HFR / star count / eccentricity / guide-RMS row.
- **Guiding**: `dither()` now pre-checks that guiding is active (clear
  error instead of an opaque PHD2 RPC failure).
- Archived the stale `NOT_IMPLEMENTED_FIXES.md` — the audit confirmed all
  ~38 "not implemented for driver type" device ops it listed are now fully
  implemented across ASCOM/Alpaca/INDI/Native/Simulator.

Verified-clean during the same audit (no action needed): exposure
abort/cancel semantics, the W1 daylight gate logic itself, settle-failure
fail-closed dither path, native star-lost trigger + re-acquire recovery,
reject-storm pause/escalation, live-stacking stats wiring, per-filter
focus offsets in the native sequencer, and the full device-op × driver
matrix.

### Audit follow-up: remaining-gaps closure (2026-06-09, same day)

- **Standalone meridian flip now actually flips.** New
  `api_perform_meridian_flip` bridge call runs the canonical
  `MeridianFlipExecutor` outside a sequence (refusing while one runs), so
  the standalone monitor executes the flip — pause guiding, slew, verify
  pier, re-center, refocus, resume — instead of only alerting while the
  mount tracked into the pier. Wired through FFI/network/disconnected
  backends, a new `/api/sequencer/meridian-flip` headless route, and the
  monitor itself. The headless `/checkpoint/resume` route also got the
  "actually start" fix from the main audit.
- **J2000 → of-date conversion at the mount boundary.** Slew and sync
  inputs are precessed (rigorous Meeus 21.3/21.4, validated against the
  Meeus 21.b worked example) for ASCOM/Alpaca/INDI/Native mounts —
  initial GOTOs land ~22′ closer in 2026. Reads stay in the mount's
  native frame so hour-angle/flip math is untouched; the Simulator is
  exempt (epoch-agnostic tests).
- **PHD2 crash auto-relaunch.** On link loss that was not user-initiated
  (and with guider auto-reconnect enabled), the controller now relaunches
  PHD2 via the launcher and reconnects with 5/15/30 s backoff, surfacing
  a clear error if all attempts fail — previously it sat at
  "Connecting…" until morning.
- **Predictive AF is visible.** The focus-model card shows the last
  consultation: filter, confidence band (training / low / medium / high),
  predicted position, R², and predicted-vs-actual error after the sweep.
- **Night Doctor tilt/collimation detector implemented** — drives the
  existing `OpticalTrainDiagnosticsService` (PSF field tiles + astrometric
  residuals) so the morning report and the equipment optical-health card
  share one engine; silently-skipped detectors now leave a log trace.
- **Session report SNR is real when possible** — prefers the science
  pipeline's photometric SNR per filter; the background/noise proxy is
  the fallback and is explicitly footnoted in exports.
- Session-optimizer insights were found fully implemented and wired
  (the audit's "DTO-only" claim was a false positive); guide-graph
  history extended and the interactive dither precondition added in the
  same pass.

### Smart Morning Report & finishing
- **Night Doctor** — a plain-language, evidence-backed diagnosis of the night
  (focus drift, cloud/transparency loss, guiding-correlated trailing, dew/HFR
  collapse, moon gradient) with a 0–100 score and "next time" advice.
- **Marginal-SNR optimizer** — the integration-improvement curve that *proves*
  the cull ("use best 46 of 64, +4.2% SNR") with the cut marked.
- **Pristine master by default** — out of the box, integration outputs *only* an
  unmodified **linear master FITS** (+ a stretched preview); no destructive
  processing is applied, so you can import it into PixInsight / APP / Siril and
  start from scratch. Everything below is opt-in and writes *sibling* files,
  never touching the master.
- **Catalog-powered finishing (opt-in)** — plate-solve the master, then
  **photometric colour calibration** and **auto-annotation** from the built-in
  HYG + OpenNGC catalogs (no external downloads), plus background extraction.
- **Algorithm muscle wired end-to-end** — drizzle (+ Bayer), Richardson-Lucy
  deconvolution, star reduction, and SHO/HOO narrowband palette mixing.
- **Living multi-night project** — growth curve, best-night, a durable campaign
  table, and a target-SNR deficit fed back into tonight's plan.
- Layered **narrative + workbench** Session Review; a real progress bar.

### Couch-grade control
- **One-tap "Tonight"** — pick the best target, frame, plan and GO in a single
  action; the deep sequencer stays one tap away.
- **Cellular push (FCM + APNs)** — "guiding lost / master ready / clouds rolled
  in — and here's what I did" reaches your phone anywhere (server-side complete;
  needs cloud keys to go live). **iOS companion build-ready.**
- Built-in multi-star **guider UI** (per-star list), capture filter-wheel
  control, guide-star finder overlay, web-dashboard light/dark + layout.

### Autopilot & safety (unattended-night)
- Adaptive **target swapping** on by default; in-sequence horizon mask.
- Residual hardware-safety hardening: ASCOM exposure-param apply, real **Pause**
  for parallel/target-header subtrees, disconnect-retry, reject-storm → pause,
  meridian-flip dry-run. Manual **OTA rollback**.
- **Structural daylight gate (W1 backstop)** — the native executor now refuses to
  slew-to-target or expose a science frame while the Sun is above the darkness
  limit, independent of the Dart autopilot. Defaults to −12° (nautical dark),
  exactly the Dart scheduler's limit, so *any* executor-run sequence — including
  raw, non-autopilot ones — inherits the no-daylight-imaging guarantee.

### Automated mosaics (planner → capture → stitch)
- **Plan a tiled panorama, capture it unattended, wake up to one seamless
  master.** Lay out an N×M mosaic in the planner (panel grid, overlap, rotation)
  and commit it to a durable **mosaic project** (DB v45). Each panel becomes its
  own catalog target, so its subs are attributed and pooled **per panel** —
  neighbours never cross-contaminate.
- **Panels run under the full autopilot** — sequenced like any other target, under
  the same W1 daylight gate, fail-closed weather gate, and park-at-dawn safety as
  a single-target night.
- **Per-panel pristine master → native WCS stitch** — each panel integrates to its
  own unmodified linear master (WCS stamped from its reference frame); the native
  stitcher then reprojects every panel onto a common gnomonic-TAN canvas with
  global least-squares photometric normalization and feather blending, emitting a
  single seamless **master + coverage map + preview**. Pristine by default — the
  stitched output is linear, for your own processing; nothing destructive applied.
- **Mosaic project review UI** — a live panel grid (per-panel capture progress and
  integration state) plus the stitched result, reachable at `/mosaic`.

> Honest scope: every native algorithm is synthetic-tested; the first clear
> night is a tuning pass (all finishing steps are fail-soft). iOS build/publish
> and live cellular push require an Apple Developer account + Firebase/APNs keys.

## [Unreleased] — Code-Quality Hardening (2026-05-09 to 2026-05-16)

A code-quality cycle following the v2.5.0 release. ~84 commits drove five
read-only architecture, test, Rust, Dart, and observability audits to
closure. Highlights:

- The structured FFI error pipeline is no longer a placebo —
  `SkotiqException._parseJson` actually decodes the Rust-side `ErrorInfo`
  payload, and every typed `SkotiqError` variant survives across the
  boundary with `device_id`, `error_code`, `is_recoverable`, and
  `should_reconnect` intact.
- All six previously-detached `tokio::spawn` tasks (sequencer execution,
  event bridges, polar-alignment monitor, imaging worker loops) are now
  panic-supervised — a crash in any one logs and either restarts the loop
  or surfaces the failure instead of silently killing its feature.
- The `bridge/src/api.rs` and `bridge/src/devices.rs` monoliths (18,624 LOC
  combined) have been split into `bridge/src/api/` (37 files) and
  `bridge/src/device_manager/` along their natural section boundaries.
- The top-3 monolithic Dart screens
  (`imaging_screen.dart` / `dashboard_screen.dart` / `planetarium_screen.dart`)
  retain their entry classes but have widget tests for the first time, and the
  shared `pumpAppScreen()` harness with `FakeNativeBridge` unlocks regression
  coverage on 100k+ LOC of UI.

### Architecture and renames

- Split `native/skotiq_native/bridge/src/api.rs` (9,770 LOC) into
  `bridge/src/api/` (37 files) across three sub-PRs grouped by domain.
- Split `native/skotiq_native/bridge/src/devices.rs` (8,854 LOC) into
  `bridge/src/device_manager/` with per-device `ops/` modules.
- Split `native/skotiq_native/ascom/src/windows_impl.rs` (3,756 LOC)
  into per-device modules under `ascom/src/windows/`.
- Split `providers/equipment_provider.dart` (1,540 LOC, 11 notifiers)
  into per-device-type files.
- Split `providers/sequence_provider.dart` (3,533 LOC): extract
  `SequenceExecutor`, validation, defaults, and node-palette modules.
- Split `screens/equipment/tabs/connections_tab.dart` (2,723 LOC) into
  per-device cards and fixed three `use_build_context_synchronously`
  violations (§8 #6).
- Split `screens/framing/framing_screen.dart` (4,688 LOC) into canvas,
  controls, painters, and overlay modules.
- Resolved UI → bridge layering violation in
  `skotiq_ui/.../polar_alignment_wizard.dart`
  (the worst-finding layering bug).
- Rename + collision resolution: framing `MosaicConfig/Panel` →
  `FramingMosaic*`, planetarium duplicates → `PlanetariumMosaic*`,
  core `CameraState` → `CameraStateSnapshot`, `FocusDataPoint` →
  `FocusHistoryPoint`, plus `DeviceType` dedup, `ObserverLocation`
  rename, `MobileNotificationService`, `queueProgressProvider`,
  `AppSettingsState`, `sequenceTargetSearchProvider`. Each rename
  removed a barrel `hide` clause.
- `PlateSolveResult` consolidated to the FRB-canonical type; both
  hand-written copies deleted.
- `CapturedImage` and `EquipmentProfile` now alias-exported from the
  `skotiq_core` barrel; 4 `src/` bypass imports removed.

### Test Infrastructure

- New `FakeNativeBridge` in `packages/skotiq_bridge/test/fakes/`
  with controllable event streams + canned response maps.
- New `pumpAppScreen()` widget-test harness in
  `packages/skotiq_app/test/harness/` wiring `FakeNativeBridge`,
  in-memory drift DB, and `MockBackend` via `ProviderScope.overrides`.
- New `AscomConnectionBackend` trait with `mockall` scaffolding so the
  3,756-LOC `ascom/windows_impl.rs` is testable for the first time.
- New `FakeSkotiqNetworkClient` and `NetworkBackend` unit tests.
- Smoke and behavior widget tests landed for `imaging_screen`,
  `dashboard_screen`, `planetarium_screen`, and `settings_screen`.
- Required CI gates promoted: `audit:placeholders --fail-on-new-highrisk`,
  Windows-host `test-rust` job, `cargo` duplicate check, `pre-commit`
  hooks for `dart format` + `cargo fmt`, `linguist-generated=true` for
  generated files.
- `libraw.dll` is auto-copied to `target/debug/deps` so
  `cargo test --package skotiq_bridge` works out of the box.
- `flutter_lints` upgraded from `^3.0.1` to `^5.0.0` across all
  packages; analyzer options tuned.

### Observability

- Restored the structured FFI error pipeline: `_parseJson` now actually
  `jsonDecode`s the Rust `ErrorInfo` payload instead of unconditionally
  returning `null`.
- Closed 13 fail-closed handler violations across the headless API
  (auxiliary, flat_wizard, backup, mosaic, science, device handlers) —
  no more `'status': 'failed'` with HTTP 200 or `e.toString()` leaks.
- Resolved the `ffi_backend:2064` UnimplementedError for the all-sky
  polar-alignment path.
- Bearer token in `main_headless.dart` startup banner is redacted in
  log output.
- `LoggingService` migration: ~477 `print` / `debugPrint` sites
  replaced across `apps/desktop/lib/main.dart` (134), `bridge_stub.dart`
  (103), `catalog_manager.dart` (37), `network_backend.dart` (32),
  `auto_save_service.dart` (21), and the residual long tail (~232
  in the final sweep). `main.dart` was split into bootstrap +
  `desktop_app_bootstrap.dart` + `desktop_logging_init.dart`.
- 10+ Dart notifier/widget `dispose()` hooks now cancel held
  `Timer` / `StreamSubscription` resources;
  `SequenceExecutionNotifier` and 9 device notifiers in
  `equipment_provider.dart` got explicit `dispose()` overrides.
- 14 `Future`-holding Dart `catch (_)` swallows audited:
  log via `dart:developer` or replaced with explicit `// Why:` rationale.
- 5 long-running futures wrapped in supervised wrappers.
- SQLite corruption recovery: Drift `integrity_check` +
  backup-and-recreate path with UI marker for first-launch on a
  corrupt `app_settings.db`.
- New operational `RUNBOOK.md` covering frozen startup, plate-solve
  failures, OTA rollback, sequence-resume, and headless-unreachable
  scenarios.
- New diagnostic-dump service + screen bundles
  logs / profile / sequence / system info into a single zip.
- Behavioral markers (planetarium, ui, plugins, core, app, apps,
  native crates) now registered + audited via a final residual sweep.

### Rust hardening

- All 6 previously-detached `tokio::spawn` tasks
  (`sequencer/executor.rs:658`, `bridge/api.rs:6489` + `:7755`,
  `imaging_ops.rs:61` + `:627`, `bridge/devices.rs:7186`) are now
  panic-supervised with logging + restart for the worker loops.
- `UNIFIED_IMAGE_STORAGE` is now LRU-bounded with eviction events;
  `ALPACA_CLIENTS` lifecycle audited.
- 288 `unwrap_or_*` silent-fallback sites swept across alpaca client +
  telescope, phd2 + imaging processing + stats, device_capabilities
  (80), alpaca devices + bridge dispatch (47), and indi + sequencer +
  imaging residuals. Each remaining site now carries a `// Why:`
  rationale or has been converted to `?`.
- ~400 `// SAFETY:` comments added across `native/src/vendor/*.rs`
  (qhy, atik, player_one, moravian, svbony, fujifilm, touptek);
  `clippy::undocumented_unsafe_blocks` promoted to `-D warnings`.
- All `as` casts hardened at the Dart↔Rust FFI boundary
: new `safelyCast<T>` helper plus
  vendor SDK + imaging buffer-math boundaries (W12), and the
  remaining sequencer + indi + imaging tail (W13).
- Cargo duplicate semvers unified: `windows-rs`, `base64`, and
  `thiserror` versions consolidated.
- `cargo clippy --all-features -- -D warnings` is green on Rust 1.91.

### Dart hygiene (plus later const-constructor work)

- Migrated 144 deprecated typedef callers
  (`DriverBackend` → `DriverType`, `AvailableDevice` → `DeviceInfo`,
  `SkotiqDeviceType` → `DeviceType`, `TargetGroupNode` →
  `TargetHeaderNode`); deleted the typedef shims.
- Riverpod aligned to `^2.5.1` across all 9 packages.
- Confirmed-dead code deleted: `skotiq_exception.dart`,
  `paginated_image_loader.dart`, `catalog_service.dart`, three
  weather providers, `annotation_catalog_dialog.dart`,
  duplicate `Phd2Status` / `SequencerStatus` core copies, 2 dead
  `TutorialKeys`, `Plugin.initialize()/dispose()` deprecated methods.
- `prefer_const_constructors` enabled and fixed across
  `skotiq_ui`, `skotiq_bridge`, `skotiq_plugins`,
  `skotiq_updater`, and `skotiq_app`.
- `MediaQuery.of(context)` replaced with granular
  `.sizeOf` / `.orientationOf` accessors at 26 sites.
- Fixed-height `ListView.builder` calls now carry `itemExtent`;
  off-screen `Timer`s are paused.
- `SequenceNode` hierarchy converted to a Dart 3 `sealed class` for
  exhaustive switches across 12 downstream `is`-chain call sites.
- `autoDispose` audit: applied to 14 page-scoped providers, with
  documented keep-alive rationale for the 15th.

## [2.5.0] - 2026-05-11

This is the v2.5.0 hardening release. The headline change is the merge of two
previously parallel HTTP servers into a single, secure, fully-featured headless
API: the GUI and headless desktop modes now expose the same endpoint surface,
the same authentication flow, and the same web dashboard. A 7-agent pre-release
audit (see `docs/plans/2026-05-09-v250-audit-fixes.md`) drove a wide sweep of
silent-failure fixes across the sequencer, drivers, OTA updater, FITS pipeline,
and headless API. Highlights:

- The internal "fake" plate solver that returned commanded RA/Dec verbatim has
  been removed from the public solve path. Plate solving now requires ASTAP or
  astrometry.net, and the UI guides users through configuring one.
- The OTA updater no longer silently skips locked files, partial backups have
  been replaced with full move-then-copy backups, post-install hash
  verification has been added, and `cleanup_staging` no longer deletes its
  backup-bearing parent directory.
- The headless API now reports correct HTTP status codes on failure
  (no more `200 OK` with `{"status":"failed"}` bodies) and validates all
  request payloads through a shared helper that returns structured 400s
  instead of leaking stack traces in 500 responses.
- Mobile QR pairing now schema-validates payloads and shows a fingerprint
  confirmation sheet before connecting. The mobile auth token is now stored
  in Keychain / EncryptedSharedPreferences instead of plaintext
  `SharedPreferences`.
- The web dashboard now has a real pairing flow in headless mode, press-and-
  hold mount controls (the old single-click slewed indefinitely), an HttpOnly +
  CSRF "remember me" path, a phone layout, and a full accessibility pass.

### Differentiator features (Batch 3)

This batch covers four feature-parity items that the 7-agent audit flagged
as user-visible gaps versus NINA / SGP / SkyGuard. They ship in v2.5.0
alongside the hardening work above. Each is feature-complete on the
end-user surface; known follow-ups are listed under "Limitations / known
follow-ups" with the audit slot that will close them in v2.5.x.

#### Dynamic scheduler (RoboTarget-class)

A target-selection engine that runs an unattended imaging session over
multiple objects in one slot — choosing what to expose right now from a
queue of candidate targets, re-evaluating on a fixed cadence and on
weather / guiding / mount events, and switching only when the new
winner clearly beats the current one.

- Where users find it: top-level **Scheduler** screen (side-nav and
  mobile bottom-nav entry), routed at `/scheduler`. Per-target editors
  open from the queue table.
- Per-target **integration goals** by filter (e.g. `L: 4h`, `R/G/B: 2h
  each`, `Ha: 6h`) and per-target **constraints**:
  - Time window (UTC start/end or "after astronomical twilight").
  - Moon illumination cap and minimum moon separation.
  - Custom **horizon profile** (samples-based, separate from the legacy
    8-point compass mask) so tree-lines and roof obstructions are
    honoured.
- **Hysteresis-stable target selection**: a challenger only displaces
  the running target when its weighted score exceeds the current
  target's by the configured `hysteresisRatio` (default 1.20×).
  Eliminates the "ping-pong between two equally-good targets" pattern.
- **Automatic re-evaluation** on the EventBus channels for weather,
  guiding, and mount-state changes — not just on a wall-clock timer —
  so a guiding excursion or an incoming cloud bank can flip targets
  inside the next decision tick.
- Decision panel surfaces the full scoring breakdown (per-factor value,
  weight, weighted contribution) and the runner-up, so the user can see
  why the scheduler chose what it chose. **Force re-evaluate**, scoring
  weights expansion, and a countdown to the next eval are all on the
  same panel.
- 20 new tests cover engine selection / hysteresis / lifecycle, the
  Meeus JD references and NOAA sun-alt-az path in `sky_calculations`,
  and the two `SchedulerScreen` widget states.

Limitations / known follow-ups:

- The hysteresis ratio compares the final `totalScore` of both
  candidates, which folds in the scoring-weight defaults
  (`scheduler_engine.dart:348`). The audit flagged that the
  `userPriority` weight may need tuning so user priority alone can flip
  the hysteresis without help from other factors (W6-SCHED-FINISH
  follow-up item 1). The default weights ship as a workable starting
  point; tuning lands in v2.5.x.

#### Defect-map cosmetic correction

A bad-pixel / dust-spot repair pipeline that lets users image **without
dark frames** while still hiding hot pixels, cold pixels, and small dust
shadows in the final integration.

- Where users find it: **Imaging screen → Image calibration** section
  (`widgets/calibration_section.dart`). Build, toggle "apply during
  capture", clear, and last-rebuild status all live here.
- Builds a defect map from a small stack of dark frames (minimum 5 by
  default; fewer is a structured error, not a silent fallback) and
  stores it as a persistent `.ndm` file keyed by camera + sensor size +
  temperature bucket.
- **Multi-temperature buckets** so a -10 °C cooled run and a +5 °C
  cooled run don't share the same hot-pixel list. The lookup uses
  `temperatureBucketDecicelsius` (tenths of a degree) so a 1-degree
  rebuild interval is meaningful.
- **Neighborhood-median repair** at capture time: defective pixels are
  replaced by the median of their valid neighbours before the frame is
  written out, so lights are clean as they leave the camera and
  downstream stacking sees no artefacts.
- The imaging-screen panel disables every control with an explanatory
  tooltip when the camera is disconnected, sensor dimensions are
  unknown, or no cooler telemetry has arrived yet — so the user gets a
  real reason, not a stuck UI.
- 12 new Rust unit tests cover the defect-detection statistics
  (`cargo test -p skotiq_imaging --lib defect_map`).

Limitations / known follow-ups:

- The `PlatformInt64 lastRebuiltUnixSeconds` field returned by the
  bridge is assigned straight into a Dart `int` in
  `DefectMapService._fromBridge`
  (`packages/skotiq_core/lib/src/services/calibration/defect_map_service.dart:85`).
  This is safe on desktop and mobile (Dart `int` is 64-bit there) but
  would not compile under web (`int` is JavaScript number, `PlatformInt64`
  becomes `BigInt`). Web is not a supported target in v2.5.0; tracked
  as W6-DEFECT-FINISH item 2 follow-up.

#### Plate-solver detection & setup UX

A first-class plate-solver configuration surface designed to eliminate
the "why doesn't plate solve work?" friction that dominated v2.4 support
threads.

- Where users find it: **Settings → Plate Solving** (`/settings/
  plate-solving`). Reusable `PlateSolverRequiredBanner` also appears in
  the centering, framing, and polar-alignment flows when no solver is
  reachable, with a `go_router` CTA straight to the settings screen.
- **Auto-detect ASTAP and Astrometry.net** across every standard install
  path on Windows, macOS, and Linux — including ASTAP CLI / GUI builds,
  Homebrew `astrometry.net`, and Cygwin-installed `solve-field`. Catalog
  presence is detected separately so "binary OK, no catalog" is a
  distinct state from "not installed".
- **Verify-solve button** runs the configured binary to confirm it
  actually works on this machine — catches stale binaries, missing
  dependencies, and wrong-architecture downloads at settings-save time
  rather than mid-sequence.
- **Auto-fallback chain**: when both solvers are installed and the user
  picks "Auto", a failure on one falls back to the other for that solve
  attempt only (the next attempt restarts from the preferred solver).
- The previous "ASTAP not found" snackbar in `CenteringDialog` has been
  replaced with the required-banner + settings CTA so the user is never
  stranded.
- Widget + model tests cover the four detection states (no solver /
  ready / catalog missing / verify error) and the `PlateSolverChoice`
  / `PlateSolverDetection` round-trips.

Limitations / known follow-ups:

- The **Verify** button runs `astap --help` (or `solve-field --help`)
  as a binary-health smoke check
  (`native/skotiq_native/imaging/src/platesolve.rs:294-313`). It is
  not a real plate-solve against a synthetic field. The orchestrator
  sketched a 200×200 three-cluster fixture for an end-to-end verify
  path; that approach was skipped because ASTAP needs a real star field
  matched against its catalog to solve. A true end-to-end verify path
  is on the v2.5.x list (W6-SOLVER-UX-FINISH note).

#### NINA / SGP sequence import

Drop-in migration from the two competitor sequencers users are most
likely to be coming from.

- Where users find it: **Sequencer screen → Import sequence** (toolbar).
  Opens a file picker, runs format auto-detection, then a summary
  dialog showing the node-mapping table before the user persists.
- **Auto-format detection** by file extension and content sniffing
  (`.json`/`$type:NINA…` → NINA; `.sgf` / SGP JSON shape → SGP). Wrong
  extension still resolves to the right parser when the contents are
  unambiguous.
- **Node mapping table** in the summary dialog (source type → Skotiq
  type → count) so the user sees exactly what's about to be imported
  before they commit.
- **Force-import on unsupported override**: the default behaviour is to
  raise a structured `UnsupportedNodeError` (with the offending node
  type) so the user can decide. Toggling "import anyway" preserves the
  raw scalar fields of the unsupported node and continues — no silent
  data loss, no silent drop.
- **Two persistence destinations**: "Open in editor" (load into the
  active sequencer for tweaking) and "Save to library" (persist via
  `SequenceRepository` without disturbing the current edit). Both
  paths persist; only "Open in editor" also calls
  `currentSequenceProvider`.
- New `docs/sequence-import-formats.md` documents the NINA `$type` table,
  the SGP key table, drop / unsupported semantics, and two worked
  examples for support troubleshooting.

Limitations / known follow-ups:

- The test fixtures
  (`packages/skotiq_core/test/services/import/fixtures/nina_basic.json`,
  `nina_unsupported.json`) were authored from the NINA public Advanced-
  Sequencer documentation, not from a verbatim recent NINA export. The
  finisher agent recommends a verification pass against a real Advanced
  Sequencer JSON export from a current NINA release before we make any
  marketing claim of "imports NINA sequences losslessly"
  (W6-NINA-IMPORT-FINISH follow-up 1).

### Added

#### Authentication, pairing and security
- HttpOnly + `SameSite=Strict` cookie auth path with per-session CSRF token
  for the dashboard "remember me" flow. Replaces the previous
  `localStorage`-backed bearer token storage (§2.5).
- Real pairing flow in headless mode: `POST /api/pairing/start` and
  `POST /api/pairing/verify` are now part of `HeadlessApiServer`, and
  `info.pairingSupported` is `true`. First-run web onboarding no longer
  requires reading the bearer token from the console (§2.1).
- Pairing-attempt LRU eviction map so the rate-limit data structure cannot
  grow unbounded under attack (§2.20).
- WebSocket auth via short-lived one-time tickets issued by
  `POST /api/ws/ticket`. Eliminates the previous `?token=…` query-string
  WebSocket auth that ended up in HTTP access logs (§2.28). The legacy
  `?token=` form is still accepted with a deprecation warning and will be
  removed in v2.6.
- Constant-time bearer-token comparison shared across the headless API and
  the LAN-push receiver via `apps/desktop/lib/headless_api/auth/timing.dart`
  (§2.22).
- Explicit CORS allow-list. `Access-Control-Allow-Origin` is no longer
  reflected from the request `Origin` header on high-risk POSTs (§2.27).
- Mobile QR-pairing payload schema validation, RFC1918 / link-local /
  `.local` host check, and a fingerprint-confirmation sheet before
  persisting any pairing (§3.1).
- Mobile auth-token migration to `flutter_secure_storage` (Keychain on iOS,
  EncryptedSharedPreferences on Android). First launch migrates the token
  out of plaintext SharedPreferences (§3.3).

#### Dashboard and headless API
- Web-dashboard phone layout (`.layout--phone`) with bottom-tab navigation
  (Devices / Mount / Camera / Sequencer / Log) at ≤ 600 px, and ≥ 48 px tap
  targets across all dashboard controls (§2.13, §2.7).
- Accessibility pass on the dashboard: `aria-label` on every icon button,
  `aria-live="polite"` toast region, keyboard d-pad navigation (§2.15).
- Per-device-type panel-enable state based on `state.connectedDevices`
  with `aria-disabled` + tooltip when the relevant device is absent (§2.12).
- Initial-connect retry with exponential backoff (250 ms / 1 s / 4 s)
  with progress surfaced to the user (§2.16).
- Headless API request-validation helper (`requireString`, `requireInt`,
  `requireDouble`, `optionalString`, ...) with a `BadRequestError` →
  HTTP 400 middleware. Used across every handler under
  `apps/desktop/lib/headless_api/handlers/` (§2.21).
- `/api/files/browse` path allow-list (Documents, configured save path,
  configured backup dir, configured calibration-library dir). Paths that
  do not canonicalize under one of those roots are rejected (§2.24).
- Stable backup IDs: backups now carry a UUID stamped into the filename
  (`skotiq-backup-{timestamp}-{uuid}.zip`) so REST delete/download
  cannot collide across processes (§2.25).
- Per-device-type discovery error aggregation in `/api/discovery`:
  failures are no longer swallowed by a bare `catch (_)`; the response
  now contains a `discoveryErrors` map alongside the discovered devices
  (§2.26).

#### Sequencer
- `RecoveryAction::Dither(DitherConfig)` and `RecoveryAction::Recenter`
  variants. Standard "Dither Interval" and "Drift Limit" triggers now use
  them (§1.5, §1.11).
- `TriggerType::DriftLimit { max_pixels: f64 }` plate-solve drift trigger.
  Wired into the trigger monitor; default action is `Recenter` (§1.11).
- `RecoveryAction::Retry { max_attempts }` is now a real implementation
  for triggers (was a silent no-op). The default "Guiding Failure" trigger
  now actually retries (§1.5).
- `TriggerState::on_pier_side_observed` and `clear_flipped_state` to
  correctly reset `has_flipped_this_target` when an observable pier-side
  change indicates a second meridian crossing (§1.9).
- Shared `Arc<RwLock<RuntimeConfig>>` for dither config, location, and
  filter offsets. `UpdateDitherConfig`, `UpdateLocation`, and
  `UpdateFilterOffsets` runtime commands now take effect immediately
  (previously they only `tracing::info!`'d) (§1.8).
- `terminate_with(triggers, reason)` helper in `executor.rs` so every
  trigger-monitor exit path sets `is_cancelled = true` consistently (§1.18).

#### Drivers and bridge
- `VendorSdk` trait and `load_vendor_sdk!` macro consolidating the ~80%
  duplicated FFI-loading boilerplate across vendor wrappers (ZWO migrated
  first as proof-of-pattern; 12 vendor migrations queued for v2.5.1) (§5.20).
- `bridge/src/dispatch/{ascom,alpaca,indi,native}.rs` split of the
  previously 9355-line `bridge/src/devices.rs`. The top-level dispatch
  file is now a thin router (§5.21).
- Alpaca `ImageBytes` binary protocol support with JSON fallback. The
  binary path sends `Accept: application/imagebytes` and parses the v3
  binary header; ~10× throughput improvement over JSON for large frames
  (§5.13).
- `MountStatus::availability` map exposing `FieldAvailability` per status
  field (`Available` / `Unsupported` / `Error(reason)`) so the UI can
  distinguish "mount reports X" from "unsupported by driver" from
  "transient read error" (§5.4).
- Per-EAF-model focuser step size in the vendor quirks database keyed by
  USB VID/PID. Replaces the previous hardcoded `8.0 µm` that was wrong
  on EAF-S / EAF-2 hardware (§5.8).

#### Desktop UI
- `SkotiqDialog` scaffold in `skotiq_ui` (header, body, close
  button, consistent corner radius and border). Replaces hand-rolled
  one-off dialogs across equipment / sequencer / imaging screens (§4.6,
  §4.20, §4.32).
- `BreakpointTokens` in `skotiq_ui` replacing every raw `< 1100`,
  `< 1024`, etc. comparison with named tokens (§4.32).
- `CollapsibleSidebar` in `skotiq_ui`, consolidating the duplicate
  animation logic that equipment and sequencer each carried (§4.32).
- `EmptyState` widget in `skotiq_ui` adopted by the analytics tab,
  diagnostics tab, and other screens that previously stacked many
  "no data" cards (§4.12, §4.24).
- Shimmer / `SkeletonBox` loading states for every Riverpod
  `loading: () =>` arm in the screens directory (§4.29).
- Visibility-aware periodic timers across screen-level dashboards
  (framing, discovery) — timers suspend when the route is hidden (§4.33).
- Keyboard focus rings on custom interactive widgets (draggable nodes,
  profile sidebar rows, dashboard tiles) (§4.31).
- Tooltips on every icon-only `IconButton` across the desktop UI (§4.30).

#### Mobile
- iOS background-limit honest banner: when a sequence starts on iOS the
  app shows "iOS may pause monitoring while this app is in the
  background. Keep the app foreground or rely on push from desktop." A
  real `UIBackgroundModes` solution is tracked as a v2.6 item (§3.2).
- WebSocket-driven mobile liveness with a 30 s grace window before
  declaring a disconnect. Replaces the previous 5-second / 3-strike poll
  that dropped in-flight session control on transient network blips
  (§3.6).
- Mobile token field is now `obscureText: true` with a visibility toggle
  (§3.4).
- Notification deep-links: tapping a `sequence_complete` /
  `sequence_failed` / `image_ready` push notification now navigates to
  the relevant screen via `go_router` deep-link (§3.8).
- Android immersive mode is now a user setting (default: `leanBack`)
  instead of forced `immersiveSticky` (§3.13).

#### Plate solving and imaging
- WCS keyword parse errors now propagate. CRVAL1/CRVAL2/CD1_1/CD1_2/CD2_1/
  CD2_2 are no longer `unwrap_or(0.0)`'d; malformed values surface as
  `PlateSolveError::WcsParse` (§6.4).
- XBAYROFF / YBAYROFF support for correct subframe Bayer pattern
  composition when crop offsets are odd (§6.6).

#### OTA updater
- Hash verification of every file in the staging manifest after apply.
  The boot-time `verifyPendingInstall` step now re-hashes the executable
  against the recorded post-install hash and refuses to mark the update
  verified on mismatch.
- File-lock at `<install_dir>/updates/.updater.lock` prevents concurrent
  updater runs.
- LAN-push package size cap (1 GiB, configurable) enforced before
  manifest signature verification can write any byte.
- LAN-push receiver refuses to start if no
  `SKOTIQ_UPDATE_PUBLIC_KEY` was compiled in, and logs an actionable
  message telling the user to rebuild with the dart-define.
- ZIP archives are now stream-extracted via `archive`'s `InputFileStream`
  instead of being loaded whole into memory.
- `staged_verified.marker` written after manifest + package SHA-256
  verification. `_bootstrapUpdater` refuses to copy `updater.exe` unless
  the marker matches the current manifest.

#### Production audit tooling
- `behavioral_audit.dart` and `placeholder_audit.dart` now scan via path
  globs over runtime locations instead of the previous hardcoded
  17-file allowlist. New patterns: `catch (_)`, `?? null|0|false|''|""`,
  `let _ =`, `.unwrap_or_default()`, `.ok();`, comment patterns
  (`// best effort`, `// silently ignore`, `// for now`, etc.).
- `fail_closed_check.dart` is now driven by
  `docs/production-readiness/fail_closed_rules.yaml` and applies its
  rules to all matching files instead of a hardcoded list.
- CI baseline assertions (`--min-files` flag) so accidental reductions
  in audit coverage are detected.

### Changed

- ASCOM camera `CameraStatus.exposure_remaining` is now computed from
  `PercentCompleted` instead of always being `None` — sequence ETA
  display is now accurate (§5.19).
- `MountStatus.at_home`, `sidereal_time`, `pier_side`, `tracking_rate`,
  `alt`, `az` are now `Option<T>` and accompanied by an
  `availability` map. Previously fabricated `false` / `0.0` /
  `Sidereal` / `Unknown` on read failure (§5.4).
- `MountStatus.sideOfPier` is now nullable across Dart bridge bindings
  (FRB-regenerated). UI consumers display "—" for `null` / "unsupported"
  / an error icon as appropriate.
- ZWO / QHY / Player One cameras now track real cooler state via
  `Mutex<CoolerState>` in the device struct. Status reads return the
  actual cooler-on value instead of hardcoded `false` (§5.7).
- INDI mount methods (`is_parked`, `is_tracking`, `is_slewing`) now
  return `Result<bool, IndiError>`. A disconnected INDI client no longer
  reads as "not parked, not tracking" (§5.15).
- Alpaca `download_image_data_typed` reuses the pooled HTTP client.
  Per-request timeouts are now applied via `RequestBuilder::timeout(...)`
  instead of constructing a fresh `reqwest::Client` per image (§5.12).
- FWHM / HFR formulas are now internally consistent. `calculate_hfr_at_point`
  computes the true encircled-energy 50% half-flux radius (matching
  NINA / SGP / PixInsight convention) and FWHM uses `2.0 × HFR`. The
  previously-reported FWHM was ~25% over-stated (§6.11).
- Auto-stretch (STF) is now MAD-based (median ± `2.8 × 1.4826 × MAD`)
  matching the PixInsight reference instead of the previous hardcoded
  0.001 / 0.999 percentile clip. Faint nebula and LRGB integrations no
  longer peg to bright stars (§6.9).
- Web-dashboard mount d-pad is now press-and-hold (`pointerdown` /
  `pointerup` / `pointerleave` / `pointercancel`) instead of `click`-and-
  slew-forever (§2.7).
- Web-dashboard image fetch is now driven only by `exposure_complete` /
  `image_ready` events. The hardcoded `setTimeout(exposureTime + 2s)`
  fallback has been removed (image fetch will retry once if the event
  is missed within `exposureTime + 30s`) (§2.8).
- Web-dashboard pier-side display now uses a centralized
  `formatPierSide(value)` helper: `1 → "East"`, `0 → "West"`,
  `-1 → "Unknown"`. Previously rendered the raw integer (§2.9).
- Web-dashboard 3 s polling has been replaced with WebSocket-driven
  panel state. Polling remains only as a fallback when the WebSocket has
  been disconnected for > 10 s (§2.10).
- Dashboard CSP `connect-src` restricted to `'self' ws: wss:`. The
  previous `http://*:* https://*:*` allow-anything policy is gone (§2.4).
- Web-dashboard guide-graph WebSocket payload field names unified
  (`raPx` / `decPx`) and documented in `docs/api/web-server-api.md` (§2.14).
- Sequencer trigger-state writes are now `state.write().await` instead
  of `try_write()`. Updates to target name, target RA/Dec, HFR baseline,
  exposure count, plate-solve drift baseline, autofocus invalidation,
  and completed-integration counter no longer drop silently under
  contention (§1.1).
- Sequencer HFR "median" is now a real sorted-array median (NaN- and
  zero-filtered) instead of the previous exponentially-weighted moving
  average that was labelled "median" (§1.2).
- `SessionCheckpoint` now persists the full `TriggerStateSnapshot`
  (`last_autofocus_frame`, `last_dither_frame`, `baseline_hfr`,
  `has_flipped_this_target`, `tracking_limit_detected_at`,
  `current_filter`, `grid_dither_index`, `triggers_enabled`,
  `safety_fail_mode`, `filter_focus_offsets`). Resume no longer can cause
  a double meridian flip on the same target. `CHECKPOINT_VERSION` bumped
  with backward-compat default-on-missing migration (§1.3).
- Single `CheckpointManager` is now shared via `Arc` between the executor
  and the streaming-checkpoint task. UI staleness on
  `has_recoverable_checkpoint` is fixed (§1.16).
- `MeridianFlipExecutor` is now the canonical meridian-flip engine.
  `instructions::execute_meridian_flip` is a thin wrapper. Pier-side
  fallback to RA/Dec comparison, tracking-restore on cancel, autofocus
  parameters from the user equipment profile, and plate-solve-failure
  warning behaviour have all been backported into the executor (§1.6).
- `AutofocusConfig` user-facing struct now carries
  `backlash_compensation`, `outlier_rejection_sigma`,
  `use_temperature_prediction`, and `max_star_count_change`. Backlash
  no longer silently uses a hardcoded 50 steps regardless of user input
  (§1.7).
- `MeridianFlipExecutor::wait_settle` honours executor cancellation.
  Stop-during-settle returns immediately instead of waiting for settle
  completion (§1.17).
- Streaming-checkpoint cadence is now a dedicated 30 s
  `tokio::time::interval` task owned by the executor. Checkpoints no
  longer stop being written when `triggers_enabled = false` (§1.14).
- `apps/desktop/lib/headless_api_server.dart` is now the GUI-mode HTTP
  server too. `packages/skotiq_webrtc/lib/src/web_server.dart` has
  been deleted and `apps/desktop/lib/main.dart` routes both modes through
  `HeadlessApiServer` (§2.2).
- `secure_discovery.dart` now uses a structured JSON wire format
  everywhere. The previous `message.split(':')[1]` parse-by-position
  approach broke on device IDs that legitimately contain `:`
  (`native:vendor:idx`, `native:touptek:brand:idx`) (§3.11).
- Updater apply step is now move-then-copy: each destination file is
  renamed to `*.old` before the new file is written. On any failure all
  `*.old` files are renamed back; on success they are deleted. Previously
  the partial backup could not restore files added or modified outside
  the hardcoded backup set.
- `Process.start` → `exit(0)` race on updater launch hardened: the app
  verifies `pid != 0`, sleeps briefly, flushes the logger, and on
  `Process.start` exception restores the staged-update status.
- `behavioral_audit` rule definitions now live in YAML
  (`docs/production-readiness/fail_closed_rules.yaml`) instead of
  being hardcoded in the Dart program.
- INDI client jitter seeding is now per-instance via
  `fastrand::Rng::with_seed` instead of time-seed (§5.23).

### Fixed

#### Critical (data integrity, hardware risk, deceptive behaviour)
- Internal plate solver no longer returns the commanded RA/Dec / FITS-
  header coordinates verbatim and labels the result `success: true`.
  `solve_internal` has been removed from the public solve path. ASTAP
  and astrometry.net are now the only paths, and `is_solver_available()`
  reflects reality by checking for those binaries (§6.1, §6.2).
- FITS BSCALE/BZERO round-trip. Reading no longer leaves stale source
  BSCALE/BZERO entries in `header.keywords` after applying them to the
  data buffer. Writing emits only the freshly-computed BSCALE/BZERO for
  the chosen output BITPIX. COMMENT and HISTORY cards are emitted as
  proper standard cards instead of malformed `COMMENT_<n> = ...` value
  cards. String values are padded to ≥8 chars per FITS 4.2.1.1.
  `NAXIS > 3` is now rejected explicitly with
  `FitsError::Unsupported4DCube` instead of silently dropping planes
  (§6.3, §6.5).
- OTA updater no longer silently skips locked files with a same-size
  optimization. Locked files now retry up to 3 times, then either
  schedule a delayed-until-reboot replace or fail the update non-zero
  with an actionable message ("Update could not replace foo.dll because
  it is in use. Please close Skotiq and try again."). The previous
  same-size optimization could silently corrupt installs with
  different-content-same-size files.
- OTA updater backup now covers every file the apply step touches via
  move-then-copy `*.old` rename strategy. Previously the hardcoded
  3-file backup could not restore files added or modified outside that
  set.
- `cleanup_staging` now deletes `staging_dir` itself, not its parent.
  The previous behaviour wiped `backup/`, `pending_install.json`, and any
  future-staged update in one shot.
- `device_id.rs` `valid_vendors` allow-list is now generated from a
  single registry (`SUPPORTED_NATIVE_VENDORS` in `native/src/lib.rs`).
  Saved profiles for `playerone`, `meade`, `onstep`, `losmandy`,
  `10micron`, `fujifilm`, `gphoto2`, `qhy_cfw`, `fli_focuser`, `fli_fw`,
  `zwo:eaf`, `zwo:efw`, and 4-part Touptek IDs no longer get rejected
  on app start (§5.1, §5.2).
- Alpaca image-array download no longer silently substitutes `0` for
  pixel JSON values that fail to parse. Errors now surface as
  `AlpacaError::ParseError { offset, found }`. `Rank` is read from the
  JSON header and dispatched correctly so color-sensor frames (rank 3)
  no longer have a channel dimension silently dropped (§5.3).
- Sequencer HFR "median" now sorts and picks the true median.
  Previously the `((a+b)/2 + c)/2 + d)/2` shape was an exponentially-
  weighted moving average labelled "median"; HFR-degraded triggers
  fired on single bad frames (§1.2).
- Session-checkpoint resume no longer loses trigger state. A target
  that already flipped no longer flips a second time after resume.
  Autofocus and dither intervals no longer misfire after resume (§1.3).

#### Drivers
- `mount_get_status` no longer fabricates `at_home: false`,
  `sidereal_time: 0.0`, `alt/az: (0, 0)`, `tracking_rate: Sidereal`, or
  `pier_side: Unknown` on read failure. Each field is now `Option<T>`
  with an availability marker; the UI distinguishes "off" from "broken"
  from "unsupported by driver" (§5.4).
- SkyWatcher mount no longer returns `Ok()` on
  `set_tracking_rate(Sidereal)` or hardcoded values for
  `get_tracking_rate` / `get_side_of_pier` / `get_alt_az` /
  `get_sidereal_time`. The minimum-viable fix returns
  `Err(NativeError::NotSupported)` so the sequencer refuses to schedule a
  meridian flip on this driver. Encoder-based decode of pier-side and
  alt/az is queued for a follow-up (§5.5).
- ZWO / QHY / Player One cameras `cooler_on` status now reflects reality
  instead of always-`false`. Dashboard no longer lies after
  `set_cooler(true)` (§5.7).
- ASCOM wrapper `cam.camera_x_size().unwrap_or(1)` and heuristic
  bit-depth substitution have been replaced with error propagation.
  Transient COM errors no longer produce 1×1 images with wrong bit
  depth; the bridge marks the camera disconnected instead (§5.9).
- ASCOM filter wheel `Names` property errors no longer get silently
  swallowed by `unwrap_or_default()`. The device is now marked unusable
  until reconnect; the UI does not show a 0-filter wheel (§5.11).
- LX200 `is_parked` returns `Err(NativeError::NotSupported)` for non-
  OnStep / non-Meade variants instead of always-`false`. Sequencer no
  longer believes a parked Losmandy / 10Micron mount is alive (§5.6).
- INDI client XML parser now uses a depth/parent stack
  (`Vec<(device, property, element)>`) instead of three flat current-*
  strings. Malformed streams with unbalanced `def*` no longer attribute
  element values to the wrong property. `Event::Empty` (self-closing) is
  now handled (§5.18).
- INDI camera `get_binning` / `get_frame` / `get_max_bin_x` now return
  `Result<Option<T>, IndiError>` distinguishing "not yet defined" from
  a real value. Callers wait briefly for property definition with a
  logged warning on fallback (§5.10).
- ASCOM `Drop` no longer races the COM apartment thread. The bridge
  wrapper preserves STA ownership on drop; `AscomCamera::Drop` defuses
  the connected flag and lets the STA worker perform the actual
  `disconnect` (§5.22).

#### Sequencer
- `RecoveryAction::Retry` and `Continue` and `CustomBranch` are no
  longer silently dropped by the trigger handler's `_ => {}` fallthrough.
  The default "Guiding Failure" trigger now actually retries (§1.5).
- `FlipFailureAction::AbortAndPark` no longer drops the park error with
  `let _ = mount_park(...)`. Park failures are now logged at `error!`,
  retried up to N times, emit a `CriticalSafetyEvent`, and propagate the
  error if retries exhaust (§1.10).
- `has_flipped_this_target` now also resets on an observable pier-side
  change back to the pre-flip side. Long single-target sessions that
  cross two meridians no longer silently skip the second flip (§1.9).
- `Arc::try_unwrap` failure on tree children no longer silently "leaves
  it out". Tree-corruption invariants now return `Failed` with a clear
  event (§1.12).
- Filename derivation no longer silently substitutes `"image"` for a
  missing target name or `"L"` for a missing filter. Missing
  fields return a configuration error; safe defaults are logged at
  `warn!` (§1.15).
- Dither RA-only fallback magic threshold (`dec_offset.abs() < 0.01`) no
  longer hijacks grid mode. Grid mode now always picks the nearest grid
  cell (§1.13).
- Retry-delay magic 60.0 in
  `meridian_flip_executor.rs:185-187` replaced with a clear configuration
  error when the user-supplied `retry_delays_secs` array is too short
  (§1.20).

#### Headless API
- 130 unsafe `payload['x'] as String` / `(x as num).toDouble()` casts
  across `apps/desktop/lib/headless_api/handlers/` now go through a
  `validatePayload` helper. Missing or wrong-type fields return HTTP 400
  with `{"error":"missing_field","field":"deviceId","expected":"string"}`
  instead of HTTP 500 with `e.toString()` leaking stack traces and
  internal types (§2.21).
- HTTP 200 with `{"status":"failed"}` is gone across backup, flat-wizard,
  mosaic, sequence-management, dome, safety-monitor, focus-model,
  session, guiding, auxiliary, filesystem, weather, transient,
  analytics, suggestion, profile, scheduler, planetarium, framing,
  target, imaging, sequencer, equipment, and device handlers. Failures
  now return non-2xx codes with a structured error body (§2.23).
- `_resolveAllowedOrigin` no longer reflects same-host CORS origins on
  high-risk POSTs. CORS now uses an explicit allow-list (§2.27).
- Error response bodies no longer include `e.toString()`. Internal
  errors return `{"error":"internal_error","requestId":"<uuid>"}` and
  the full exception goes only to the structured log (§2.29).

#### Imaging
- WCS keyword parse errors no longer silently produce a solve at
  RA=0/Dec=0/scale=0. CRVAL1/CRVAL2/CD* failures now propagate (§6.4).
- VNG debayer threshold has been corrected from `min_g + (max_g - min_g) *
  3 / 2` (always greater than max → no edge preservation) to the
  intended `(min_g * 3) / 2`. Every OSC frame now keeps edge detail
  instead of silently degenerating to 8-direction averaging (§6.12).
- Plate-solve `detect_local_maxima` threshold floor now uses
  `N_sigma × background_sigma_estimate` from the existing background
  estimator instead of a fixed 250-ADU floor that was meaningless on
  10-bit cameras and pre-stretched images (§6.15).
- XISF `Creator` / `CreationTime` now use the real package version
  instead of hardcoded `"Skotiq 2.0"` (§6.22).
- XISF boolean parse now accepts `True` / `TRUE` per spec (§6.21).
- PHD2 `get_app_state` unknown states now map to `Phd2State::Unknown(String)`
  with a warning log instead of silently being treated as `Connected`.
  `GuidingPaused` and `StarFound` have explicit variants (§6.23).
- RAW `CString::new` failures for bad-pixels / dark-frame paths now
  return `RawError::InvalidPath { which, source }` instead of being
  silently ignored (§6.25).
- Stale RAW comment about "located by sRGB gamma defaults" removed; the
  code uses `skotiq_libraw_apply_config` correctly (§6.24).
- Pickering airmass at altitudes below 10° no longer silently uses an
  out-of-validity-range formula. Altitudes below 0° now return `Err`
  (object below horizon) and the wider altitude range uses Young's 1994
  formula (§6.14).

#### Desktop UI
- The "future update" placeholder dialog on every connected device
  card's settings IconButton has been removed. Camera / focuser /
  mount / filter wheel / rotator gears now route to real per-driver
  settings; device types without settings (covercalibrator, switch,
  dome) hide the gear icon entirely (§4.1).
- Centering dialog now has an "Abort" `SkotiqButton` (destructive
  style) that calls the centering service's stop method,
  `barrierDismissible: false`, and `SkotiqColors` styling. The
  previous dialog had a disabled X with no Cancel/Abort path and broke
  the Red Night theme (§4.2).
- Build-side side effects removed from `imaging_screen.dart:351`,
  `sequencer_screen.dart:96-99 / :658-665`, `framing_screen.dart:67-69`.
  First-run dialogs no longer duplicate under rapid window resize / hot
  reload (§4.3).
- Flat wizard capture wait now subscribes to the `cameraImageReady`
  event instead of `Future.delayed(exposureTime + 500ms)`. Slow USB /
  large-sensor captures no longer false-error with "image not ready"
  (§4.4).
- Sequencer auto-collapse no longer writes back to user prefs. A
  derived `effectiveCollapsed = userPref || isSpaceTight` value is used
  instead, and a thin draggable rail remains visible below the minimum-
  width threshold so drag-and-drop still works (§4.7).
- Sequencer toolbar overflow menu replaces the previous 5-threshold
  hide-each-button cascade. On 1024×768 New/Open no longer silently
  disappear (§4.8).
- Imaging-screen control sections (Display / Filter / Exposure /
  Capture) now use a wrapping `Wrap` grid instead of horizontal scroll.
  Critical controls no longer scroll off the right edge unnoticed (§4.9).
- Planetarium filter sidebar uses `SkotiqColors.surface` /
  `surfaceOverlay` instead of raw `Colors.grey[900]`. Red Night theme
  now inherits correctly. Collapsed sidebar shows small status dots for
  each filter category (§4.15).
- Polar-alignment screen pulse animation only runs when
  `state.isRunning`. Battery / GPU no longer ticks every frame on a
  static dashboard (§4.23).

#### Mobile
- Manual-connect path no longer synthesizes `DiscoveredServer` with
  hardcoded `version: '2.0.0'` and `signalingPort: 45678` before the
  `/api/info` round-trip succeeds. Persisted last-server is reordered to
  fetch first, persist on success (§3.7).
- Disconnect detection moved out of `Consumer.builder`'s
  `addPostFrameCallback`. Cycle-under-fast-rebuilds is gone (§3.10).
- `_onNotificationTapped` no longer only `debugPrint`s the payload.
  `image_ready`, `sequence_complete`, `sequence_failed` now navigate
  via `go_router` deep-links (§3.8).
- Foreground-service notification text now includes
  `($percent%)`; the previous `_percentComplete` field was masked by
  `// ignore_for_file: unused_field` (§3.9).
- WebRTC discovery `Timer.periodic(2s)` is now tracked and cancelled
  on `stop()` / `socket.close()`. The previous unbounded timer leaked
  one per `startBroadcasting` call (§3.11).
- WebRTC discovery uses distinct fixed server port + ephemeral client
  port. Loopback datagram unreliability on Windows is gone (§3.11).

#### Production audit tooling
- Behavioral and placeholder audits no longer have a 17-file
  false-confidence blind spot. The expanded glob coverage applies to
  every new headless handler, the LAN-push receiver, the updater Rust
  binary, the OTA updater Dart code, and `apps/desktop/lib/widgets/
  update_manager.dart`.
- Excluded directory tokens are now name-anchored (`test`, `tests`,
  `example`, `samples`) instead of substring-matched. Production
  modules whose paths happen to contain those tokens are no longer
  silently skipped.

### Security

- **HttpOnly cookie + CSRF token on dashboard "remember me".** Token
  is no longer reachable from `localStorage` and therefore cannot be
  stolen by an XSS vulnerability on the dashboard origin (§2.5).
- **Constant-time bearer-token comparison** across the headless API
  and the LAN-push receiver. Timing-side-channel extraction of tokens
  character-by-character on a slow link is mitigated. Token-bucket
  rate-limit on comparison failures prevents DoS via the comparison
  loop cost (§2.22).
- **CORS allow-list, no reflection.** `Access-Control-Allow-Origin` is
  now set only for origins in an explicit allow-list (typically just
  the bound `http://127.0.0.1:<port>` dashboard). A malicious local
  process on `127.0.0.1` can no longer script high-risk POSTs (§2.27).
- **WebSocket auth via short-lived ticket.** WS connects via
  `?ticket=<60s-lifetime, one-time>` instead of `?token=<bearer>`.
  Tokens no longer end up in HTTP access logs, browser history, or
  proxy logs (§2.28).
- **`/api/files/browse` path allow-list.** Admin-scoped enumeration of
  the entire readable filesystem is no longer possible; paths must
  canonicalize under an explicit allow-list (Documents, configured
  save / backup / calibration-library dirs) (§2.24).
- **Mobile QR pairing schema validation + fingerprint confirmation.**
  Arbitrary JSON-shaped payloads pointing at attacker-controlled hosts
  are rejected; a confirmation sheet shows host + short-hash
  fingerprint before any pairing is persisted (§3.1).
- **Mobile auth token in secure storage.** Tokens are now in Keychain
  (iOS) or EncryptedSharedPreferences (Android). A lost phone no
  longer leaks full mount/camera control via `/data/data/.../shared_prefs/
  *.xml` or an unencrypted plist (§3.3).
- **LAN-push manifest signature verified before any byte is written.**
  1 GiB pre-signature size cap. LAN-push receiver refuses to start at
  all if `SKOTIQ_UPDATE_PUBLIC_KEY` was not compiled in, with a
  clear error rather than a silent-disabled state.
- **Updater file lock** at `<install_dir>/updates/.updater.lock`
  prevents concurrent updater runs racing on `pending_install.json`.
- **Dashboard CSP `connect-src` restricted to `'self' ws: wss:`.**
  Previous `http://*:* https://*:* ws://*:* wss://*:*` is gone (§2.4).
- **Dashboard startup warning when bound on a non-loopback address.**
  Operators who run `--bind 0.0.0.0` now see an explicit STDOUT banner:
  "Skotiq API listening on ALL interfaces. Anyone on your network
  can attempt to authenticate. Press Ctrl+C now if this is wrong."
  (§2.6).
- **`infile_select` / `dst_path` canonicalization** across the
  headless API path-accepting endpoints, not only `/api/files/browse`
  (§2.24).

### Deprecated

- Legacy WebSocket auth via `?token=<bearer>` query parameter. Still
  accepted for backward compatibility with v2.4 mobile clients, but
  emits a deprecation warning to the structured log. Will be removed in
  v2.6. Migrate clients to `POST /api/ws/ticket` then
  `?ticket=<short-lived>` (§2.28).
- `skotiq_webrtc` package name. Functionality has been narrowed to
  the discovery / collaboration / auth / database layers; the
  WebRTC-specific signaling and peer-connection code has been removed
  in this release. The package name is preserved for v2.5.0 binary
  compatibility and will be renamed to `skotiq_remote_api` in v2.6
  (§2.3).

### Removed

- `packages/skotiq_webrtc/lib/src/web_server.dart` (4,746 LOC). The
  GUI-mode HTTP server has been consolidated into
  `apps/desktop/lib/headless_api_server.dart`. GUI and headless modes
  now expose the same endpoint surface and the same dashboard (§2.2).
- `packages/skotiq_webrtc/lib/src/peer_connection.dart`,
  `signaling.dart`, and `signaling/secure_signaling_server.dart`. The
  WebRTC peer-connection / signaling stack was exported but never
  imported outside the package; live image preview still uses the
  polled-image endpoint. WebRTC for the image-preview path is queued for
  a v2.6+ design discussion (§2.3).
- `flutter_webrtc` dependency from `apps/desktop` and `apps/mobile`.
  Build time and APK / DMG size reduced accordingly (§2.3).
- Internal plate solver `solve_internal` from the public solve path.
  ASTAP and astrometry.net are now the only solvers; a real geometric
  matcher (4-star quad hashing or Tycho-2/Gaia-DR3 subset) is on the
  v2.6 roadmap (§6.1).
- Hardcoded `currentVersion: '2.0.0'` fallback in
  `skotiq_updater`'s update provider. A missing version-provider
  now logs at `error!` and refuses to start update polling per the
  "errors are a feature" ground rule.
- Bridge `device_id.rs` hardcoded `valid_vendors` duplicate. The
  registry now lives in `native/skotiq_native/native/src/lib.rs`
  (§5.1).
- Dead `escapeHtml` helper in the web dashboard (rendering uses
  `textContent` / `appendChild` correctly) (§2.18).

---

[2.5.0]: https://github.com/scdouglas1999/skotiq/releases/tag/v2.5.0
