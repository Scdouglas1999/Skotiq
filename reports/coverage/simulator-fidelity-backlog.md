# Simulator fidelity backlog — verified open as of 2026-08-01

Every item below was re-checked at source on 2026-08-01 and is **still open**. They were reported
by the 2026-07-28 no-hardware campaign and never landed. They are listed separately from the sweep
findings because they are not app defects a user sees — they are the reasons a no-hardware audit
cannot see certain app defects. Each one is a blind spot in every sweep until it is closed.

## Confirmed open

**S1 — the simulated mount is never `slewing`.**
`grep -n slewing bridge/src/device_manager/ops/sim_gate.rs` returns only a comment. A slew completes
instantaneously, so nothing that depends on motion-being-in-progress can be exercised: slew progress
UI, abort-during-slew, settle time, and any guard that is supposed to refuse an action while the
mount moves. All of it ships unverified.

**S2 — the bias pedestal is multiplied by the binning factor.**
`sim_frame.rs:278` adds `pedestal` to every source pixel, and `:199` then bins that array with
`bin_region`, which sums blocks (`:361-377`). So a 2x2 binned frame carries 4x the pedestal
(measured previously: 499.5 ADU at bin 1, 1999.5 at bin 2). Real on-chip binning sums charge and
reads out **once**, applying the offset once. Consequence: any calibration or statistics path that
is sensitive to the pedestal is being tested against physically impossible data at bin > 1.

**S3 — `CameraStatus.max_adu` is never used; the saturation ceiling is hardcoded 65024.**
`grep -n max_adu imaging/src/fits.rs` returns nothing; `fits.rs:1482` sets
`saturation_threshold: 65024`. On any sensor whose ADU ceiling is below that — every 12-bit and
14-bit camera — saturation can never be reported at all, and a fully clipped frame is misdiagnosed.
The field the code needs is already on the status struct.

**S4 — the star detector discards every star with eccentricity > 0.70.**
`imaging/src/stats.rs:190` `max_eccentricity: 0.7`, discard at `:309`. The image-grading UI
(`image_grading_settings.dart:190`) recommends 0.8 as the threshold that "catches catastrophic
tracking failure". That threshold can never fire: stars eccentric enough to trip it are dropped
before grading sees them, and a frame with no measurable stars passes. A wind-trailed night is
silently accepted. The usable band is only 0.6-0.7.

**S5 — sequencer-written FITS carries no ALTITUDE and therefore no AIRMASS.** — **FIXED
2026-08-09**, and the cause on file here was not the cause.

The recorded cause (`imaging.rs:3399` passing `altitude: None`) had already been fixed by 565cc1f37:
the field reads `altitude: ctx.mount_altitude_deg`. The keywords were still missing, on hardware and
in simulation, because of the gate UPSTREAM of it — `instructions.rs` derives alt/az only inside
`if let Some(mount_id)`, so the altitude existed only when a mount was connected AND answered the
coordinate read. A mountless rig still wrote `RA`/`DEC` from the target and then dropped the
altitude derived from that identical pointing.

Reproduced twice. Live rig: `C:\src\rigframes\Polaris_1_0001.fits` carried `SITELAT 39.97190`,
`RA 37.95450`, `DEC 89.264` and neither horizon keyword. Linux simulator build, camera connected and
mount deliberately left off: byte-identical header shape. Connecting `sim_mount_1` and re-running
made `OBJCTALT` appear on its own, which isolated the gate.

Fixed by deriving the altitude from the pointing the file is actually labelled with:
`FrameContext::recorded_pointing` / `recorded_altitude_deg`, consumed by `from_frame_context`, so
`OBJCTALT` and the `RA`/`DEC` cards describe one direction by construction. Verified in the running
app after the fix: `OBJCTALT 39.371`, `AIRMASS 1.5736` for Polaris from lat 39.9719 — inside the
39.236–40.708 band that declination allows, and below the plane-parallel sec z of 1.5764 as a
refracting atmosphere requires. Still omitted, deliberately, when no site is configured.

**S6 — two airmass implementations that disagree.** — **STALE, re-checked 2026-08-09. There is one
implementation.**
`sequencer/src/scheduling/astronomy.rs:98` no longer contains a formula: its body is
`skotiq_imaging::calculate_airmass(altitude_deg).unwrap_or(f64::INFINITY)`, and its doc comment
says so. The surviving "31.73 vs infinity" difference is the scheduler's `altitude_deg <= 0 =>
INFINITY` POLICY — a target on the horizon must not be scheduled even though its airmass is finite —
and not a second atmosphere model. `imaging/src/fits.rs` `calculate_airmass` is the single formula,
it is what the `AIRMASS` card is written from, and
`bridge/src/api/imaging.rs::airmass_card_agrees_with_the_scheduler_that_chose_the_target` already
pins the two surfaces together. Nothing to pick; the pick was made in favour of
`skotiq_imaging::calculate_airmass`.

**S7 — no simulator for Switch or Cover Calibrator.** — **CLOSED, re-checked 2026-08-09.**
Was confirmed live on 2026-08-01 ("Discovery complete for Switch: 0 devices"). It has since been
built: `api/discovery.rs:882-883` advertises `sim_switch_1` and `sim_cover_calibrator_1`,
`ops/switch.rs` and `ops/cover.rs` have real `DriverType::Simulator` arms delegating to
`api/devices/simulation.rs`, and `device_manager/mod.rs` exercises both in tests. Anything still
recorded as unreachable "because no Switch device exists on this platform" — including
`screen:equipment/switch_control_card.dart` in `status.json` — is now sweepable and the reason on
file is stale.

**S9 — the simulated camera does not render the sky, so nothing can be plate-solved.** *(found
2026-08-09; the largest of these by reach)*
`sim_frame.rs:322` paints 45 pseudo-random Gaussian stars off a fixed LCG seed and translates the
field as a rigid body with the guide offset. The mount's RA/Dec never reaches the renderer. Plate
solving is **not** special-cased for the simulator — `api/plate_solve.rs` shells out to the real
ASTAP binary — so under simulation every plate-solve-dependent feature fails closed and is
unexercisable: Slew & Center, `screen:imaging/centering_dialog.dart`, the framing wizard, mosaic
tile solving, meridian-flip recentre, blind solve, the catalog overlay and its `details_panel`
(both need a WCS), the plate-solving settings Test button, and polar alignment's solve path.

This one is proven closable rather than merely asserted. `tools/sim_fidelity/plate_solve_probe.py`
renders a gnomonic projection of real catalogue stars onto the simulated sensor geometry and hands
the frame back to ASTAP; measured 2026-08-09 with ASTAP's D05 Gaia set:

| focal | scale | stars | solved centre error |
|---|---|---|---|
| 1000mm | 0.78"/px | 70 | 0.5" |
| 400mm | 1.94"/px | 319 | 1.4" |
| 200mm | 3.88"/px | 615 | 2.6" |
| 135mm | 5.74"/px | 630 | 3.9" |

Sub-pixel throughout. Two findings from that harness are worth keeping. **Catalogue depth is the
limiter, not the projection**: rendered from the app's bundled HYG catalogue (2.9 stars/deg²) a
400mm field holds 6 stars and ASTAP aborts outright, whereas ASTAP's own database (500 stars/deg²)
is both deep enough and, by construction, cannot disagree with what the solver matches against —
and `api/plate_solve.rs` already stores its directory as `catalog_path`, alongside
`telescope_focal_length` in `storage.rs`, so the renderer needs no new Dart plumbing. And **ASTAP's
`.wcs` output is a FITS header** — 80-byte cards with no line terminators — so a `splitlines()`
scan for `CRVAL1` silently finds nothing and reads as "no solve" while ASTAP prints "Solution
found". Four focal lengths were reported as failures on exactly that bug before it was caught.

**S8 — parallactic angle is not implemented anywhere.**
`grep -rin parallactic` across `native/`, `packages/`, `apps/` returns 0 hits. This is a product
gap rather than a simulator gap, but it is what makes rotator-angle correctness unverifiable.

## Checked and found already fixed

- The simulated camera does report `Exposing`/`Reading` (`ops/camera.rs:1288+` maps native state).
- `side_of_pier` is stored rather than re-derived from RA (`sim_gate.rs:591`), so a simulated
  meridian flip can change it.
- The capture loop does check pause (`wait_while_paused`, 18 call sites in `sequencer/src`).
- Simulated binning sums charge rather than averaging (`bin_region`, with a test at `:833`).
