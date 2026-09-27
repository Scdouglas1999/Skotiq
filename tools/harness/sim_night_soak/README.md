# Simulated full-night soak

Runs the release build headless through a compressed night on the device
simulators, with faults injected, and checks afterwards what a real night must
not get wrong. Run it before every rig night; every on-sky night so far has
found defects the simulators could not show, and this is the attempt to make
them show more of them.

## What a run is

`soak.py` builds a scratch install under `~/.cache/ns-soak/<scenario>/`,
launches the release bundle headless against it, and drives it only through the
HTTP API, the way a remote client or the web dashboard does:

1. A first boot creates the database. With the app stopped, the operator's
   sequencer settings are written into `app_settings` (autofocus cadence,
   dither, meridian-flip settings), because a real night reads them from there.
2. `fake_phd2.py` starts on a local port. It speaks PHD2's JSON-RPC and event
   protocol, guides a make-believe star, and can lose the star, refuse to
   re-lock, fail a settle or drop the connection on a schedule. It writes a
   timeline of what the guider really did.
3. The app is relaunched with the scenario's `NIGHTSHADE_SIM_FAULTS` and a
   cooling night (`NIGHTSHADE_SIM_NIGHT_COOLING_C_PER_HOUR`, which moves best
   focus as the tube cools so the temperature and HFR refocus triggers have
   something to do). The site is a real observatory where it is currently
   about 23:00 local solar time, so the executor's Sun check passes and no dawn
   logic arms.
4. It configures a simulator profile (camera, mount, 7-slot wheel
   L/R/G/B/Ha/OIII/SII, focuser), ASTAP from `~/.local/share/nightshade-audit/astap/bin`
   when present, connects everything and PHD2, loads the night and starts it.
5. While the run goes it polls the status every 2 s, performs any scheduled
   operator actions (pause, resume, stop) and times them, and samples the app
   process every 30 s into `resources.csv`: RSS, open fds, threads, database
   and WAL size, log size, temp dir size, captures size.
6. When the run ends (or holds itself for the operator and the scenario says to
   Stop it after a while), it collects the API state, the database rows and the
   files, shuts the app down with SIGTERM and runs the invariants.

The night (`night_plan.py`) has three targets:

- "Meridian Field" starts 12 minutes east of the meridian and crosses it, so the
  meridian-flip trigger must fire mid-target. It slews, centers, starts guiding
  and runs a Smart Exposure node cycling Ha/OIII/SII on the same wheel autofocus
  wants "L" on -- the contention that lost the 2026-09-14 night.
- "Setting Field" sinks in the west and ends at an altitude it reaches partway
  through (`end_when: AltitudeBelow`), so the run has to hand off to the next
  target. It centers without a slew first, so its first solve is far off.
- "Rising Field", LRGB, fixed counts, the end of the night.

Lights are 15 s and autofocus frames 8 s, so an 80-minute night takes a few
hundred frames. Shorter exposures do not work on the simulated sky: it renders
the real ASTAP catalogue field, which at 0.78"/px is faint, and below about 5 s
the measured HFR stops following focus at all (measured: 2 s frames read 9-10 px
mean HFR whatever the focuser position). The grading HFR ceiling is raised to
5.5 px for the same reason; a 15 s frame in focus measures about 3.7 px.

## Running it

Build first. `flutter build linux --release` does not rebuild the Rust bridge,
so after any native change build the bridge and copy it into the bundle:

    cd native/nightshade_native
    CARGO_TARGET_DIR=... cargo build --release -p nightshade_bridge
    cp $CARGO_TARGET_DIR/release/libnightshade_bridge.so \
       ../../apps/desktop/build/linux/x64/release/bundle/lib/

Then:

    python3 tools/harness/sim_night_soak/soak.py --list
    python3 tools/harness/sim_night_soak/soak.py --scenario baseline
    python3 tools/harness/sim_night_soak/soak.py --scenario guider_lost_resume_fails \
        --port 8472 --phd2-port 4472

Give parallel runs their own `--port` and `--phd2-port` (the scratch directory
is per scenario already). Each instance takes ~300 MB and a CPU core for the
simulated frames and ASTAP; two or three in parallel are fine on a 30 GB machine
that is not also building. `--recheck` re-runs the invariants over an existing
scratch directory without running the night again.

The exit status is 0 only when no invariant failed. `results.json` in the
scratch directory holds everything the checks saw; `timeline.jsonl` is the
state and action timeline, `phd2_timeline.jsonl` the guider's own, and
`app.log` / `data/logs/` the app's logs.

## The invariants

Each is PASS, FAIL or SKIP (the run never reached the situation it is about;
never counted as a pass).

- `app_survived`: no crash, no hang past the deadline, SIGTERM shutdown under 30 s.
- `frames_disk_eq_db`: every light FITS on disk has exactly one `captured_images`
  row and every row has its file, joined by path.
- `vitals_eq_db`: `runVitals.framesCaptured`/`framesRejected` equal the database's
  light and rejected counts.
- `terminal_state_truthful`: the run ended in a state the scenario allows, and
  the API and `sequence_runs` agree once the run is over.
- `no_frames_while_guider_dead`: no frame started more than 20 s into an interval
  in which the fake guider had lost its star or its connection (from
  `phd2_timeline.jsonl` against each frame's `DATE-OBS`).
- `no_unrequested_park`: the mount is not parked at the end and no park, cover
  or dome close appears in the logs. None of the scenarios opts in to parking.
- `failures_name_a_cause`: every error the run reported names a cause, not just
  "Error" or "Operation cancelled"; with a fault injected, at least one names it.
- `operator_actions_prompt`: pause, resume and stop took effect within their budget.
- `meridian_flip_once_on_time`: the flip happened once, 3-12 minutes past the
  meridian (the setting is 5 minutes past).
- `autofocus_from_below_verified`: every autofocus final approach ran up from
  below, and each completion reports a measured (verification-frame) HFR.
- `fits_unique_no_strays`: no two lights share DATE-OBS and filter; no partial files.
- `fits_headers_sane`: FILTER and EXPTIME match the row, OBJECT is a planned
  target, and RA/DEC are within 3' of that target's J2000 position.
- `no_monotonic_resource_growth`: after the first third of the run, none of RSS,
  fds, threads, WAL, temp or logs grows faster than a per-hour limit that would
  matter over a 10-hour night (RSS 150 MB/h; the 2026-09-13 hang sat at 3.2 GB).

## The simulated mount is a JNow mount

Real mounts take and report coordinates of date; the simulator used to store
raw J2000 and so could never show a J2000/of-date mix. It now behaves like an
of-date mount by default (`NIGHTSHADE_SIM_MOUNT_FRAME=j2000` restores the old
behavior) and the simulated camera renders the J2000 field the of-date pointing
looks at. See `native/nightshade_native/bridge/src/device_manager/epoch.rs`.
