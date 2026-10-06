"""Soak scenarios: one compressed night each, with the faults a real night has.

Fields:
  about             one line for --list
  sim_faults        NIGHTSHADE_SIM_FAULTS for the app (key=trigger:effect,...)
  phd2_faults       fake_phd2.py --faults (times are seconds after the first guide)
  actions           operator actions: [{"verb": pause|resume|stop, "at_min": M, "budget_s": S}]
  stop_after_pause_s  if the run pauses on its own, wait this long, then Stop it
  expect_terminal   states the run may truthfully end in
  cause_keywords    a failure the run reports must name one of these (lower case)
  expect_flip       the meridian flip must happen (False when a fault ends the
                    run before the Meridian Field crosses)
  cooling           simulated tube cooling, C per hour (temperature + HFR triggers)
  minutes           planned night length
"""

BASE = {
    "sim_faults": "",
    "phd2_faults": "",
    "actions": [],
    "expect_terminal": ["completed"],
    "cause_keywords": [],
    "expect_flip": True,
    "cooling": 4.0,
    "minutes": 80.0,
    # A run that holds itself for the operator is left held this long (no
    # frame may be taken meanwhile), then Stopped the way an operator would.
    "stop_after_pause_s": 420,
}


def scenario(**kw):
    sc = dict(BASE)
    sc.update(kw)
    return sc


SCENARIOS = {
    "smoke": scenario(
        about="ten-minute plumbing check of the harness itself (no flip expected)",
        expect_flip=False, minutes=10.0),
    "baseline": scenario(
        about="no faults: three targets, flip, handoff, AF/dither/guiding, natural end"),
    "operator": scenario(
        about="pause, resume and stop from the API mid-night; each must take effect promptly",
        actions=[{"verb": "pause", "at_min": 8.0, "budget_s": 30},
                 {"verb": "resume", "at_min": 11.0, "budget_s": 30},
                 {"verb": "stop", "at_min": 22.0, "budget_s": 45}],
        expect_terminal=["stopped", "cancelled", "idle"], expect_flip=False, minutes=30.0),
    "guider_lost_resume_fails": scenario(
        about="PHD2 loses the star mid-exposure and accepts every resume without locking (09-14)",
        phd2_faults="lose_star_at=600,resume_fails",
        # Held (paused or recovering) for longer than the 5-minute recovery
        # ladder before the harness Stops it, so the give-up branch runs.
        stop_after_pause_s=420,
        expect_terminal=["stopped", "cancelled", "failed", "idle"],
        cause_keywords=["guid", "star"], expect_flip=False, minutes=30.0),
    "guider_lost_recovers": scenario(
        about="PHD2 loses the star once; re-acquisition works, the night continues",
        phd2_faults="lose_star_at=600",
        expect_terminal=["completed"], cause_keywords=["guid", "star"]),
    "guider_settle_timeout": scenario(
        about="one dither settle times out",
        phd2_faults="settle_fails_at=500",
        expect_terminal=["completed"], cause_keywords=["settl", "dither"]),
    "phd2_connection_drop": scenario(
        about="PHD2's socket closes mid-night and refuses reconnects for two minutes",
        phd2_faults="drop_at=900", phd2_drop_secs=120, stop_after_pause_s=420,
        expect_terminal=["completed", "stopped", "cancelled", "failed", "idle"],
        cause_keywords=["guid", "phd2", "connect"], minutes=40.0),
    "filterwheel_stall": scenario(
        about="the wheel accepts a move and never arrives (jammed) partway through",
        sim_faults="filterwheel.set_position=every(25):stall", stop_after_pause_s=420,
        expect_terminal=["failed", "stopped", "cancelled", "idle"],
        cause_keywords=["filter", "wheel"], expect_flip=False, minutes=30.0),
    "camera_download_hang": scenario(
        about="one download in 40 hangs 30 s then errors (INDI BLOB timeout shape)",
        sim_faults="camera.download=every(40):delaythenerror(30000)",
        expect_terminal=["completed"], cause_keywords=["download", "camera", "image"]),
    "slew_error_once": scenario(
        about="the first slew fails with a driver error",
        sim_faults="mount.slew=once:error",
        expect_terminal=["completed"], cause_keywords=["slew", "mount"]),
    "focuser_backlash": scenario(
        about="every focuser move lands 60 steps short (mechanical backlash)",
        sim_faults="focuser.move=always:backlash(60)",
        expect_terminal=["completed"]),
    "camera_usb_drop": scenario(
        about="the camera drops off the bus: every download and command after ~150 fails notconnected",
        sim_faults="camera.download=after(150):notconnected,camera.command=after(300):notconnected",
        stop_after_pause_s=420,
        expect_terminal=["failed", "stopped", "cancelled", "idle"],
        cause_keywords=["camera", "connect", "disconnect"], expect_flip=False, minutes=40.0),
    "intermittent_errors": scenario(
        about="every 17th download and every 9th wheel move fail once",
        sim_faults="camera.download=every(17):error,filterwheel.set_position=every(9):error",
        expect_terminal=["completed"], cause_keywords=["download", "filter", "camera", "wheel"]),
}
