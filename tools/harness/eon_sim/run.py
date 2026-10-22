#!/usr/bin/env python3
"""End-of-night calibration on the simulators, against the release bundle.

A short guided light run at two exposures ends by completing; the
end-of-night calibration step must then start by itself, stop guiding, send
the mount home, take darks and bias through the wheel's DARK slot with no
dither, autofocus or mount motion, build masters into the dark library, warm
the camera up, and leave masters the calibration matcher picks for the
night's lights.

The autofocus interval is set to 3 frames and the lights dither every 2, so a
calibration run that still counted its frames or acted on the light-frame
triggers would autofocus and dither inside this harness.

    python3 tools/harness/eon_sim/run.py [--port 8481] [--phd2-port 4481]
        [--bundle apps/desktop/build/linux/x64/release/bundle/skotiq]
        [--root ~/.cache/sk-eon]

Exit status is 0 only when every check passes. Artifacts (app log, database,
frames, masters, the guider timeline and a summary) stay under --root.
"""
import argparse
import json
import os
import shutil
import signal
import sqlite3
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, os.path.join(HERE, "..", "sim_night_soak"))
import night_plan  # noqa: E402

TOKEN = "eon-harness-token"
WHEEL = ["L", "R", "G", "B", "Ha", "OIII", "DARK"]
LIGHTS = [("L", 2.0, 4), ("R", 3.0, 3)]
DARK_COUNT = 5
BIAS_COUNT = 6


class Harness:
    def __init__(self, args):
        self.args = args
        self.root = os.path.expanduser(args.root)
        self.db_dir = os.path.join(self.root, "db")
        self.data_dir = os.path.join(self.root, "data")
        self.out_dir = os.path.join(self.root, "captures")
        self.tmp_dir = os.path.join(self.root, "tmp")
        self.base = f"http://127.0.0.1:{args.port}"
        self.app = None
        self.phd2 = None
        self.passed = 0
        self.failed = 0
        self.facts = {}

    # ---- plumbing ---------------------------------------------------------

    def say(self, text):
        print(f"[eon {time.strftime('%H:%M:%S')}] {text}", flush=True)

    def check(self, ok, text):
        if ok:
            self.passed += 1
            self.say(f"  PASS: {text}")
        else:
            self.failed += 1
            self.say(f"  FAIL: {text}")
        return ok

    def api(self, method, path, body=None, timeout=30, ok=(200, 202)):
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(
            self.base + path, data=data, method=method,
            headers={"Authorization": "Bearer " + TOKEN, "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                raw, status = resp.read().decode("utf-8", "replace"), resp.status
        except urllib.error.HTTPError as exc:
            raw, status = exc.read().decode("utf-8", "replace"), exc.code
        try:
            parsed = json.loads(raw) if raw else None
        except ValueError:
            parsed = raw
        if status not in ok:
            raise RuntimeError(f"{method} {path} -> {status}: {raw[:400]}")
        return parsed

    def db(self):
        conn = sqlite3.connect(os.path.join(self.db_dir, "skotiq.db"), timeout=15)
        conn.row_factory = sqlite3.Row
        return conn

    def launch(self):
        env = dict(os.environ)
        env.pop("WAYLAND_DISPLAY", None)
        env.update({
            "SKOTIQ_DATABASE_DIR": self.db_dir,
            "SKOTIQ_DATA_DIR": self.data_dir,
            "TMPDIR": self.tmp_dir,
            "LIBGL_ALWAYS_SOFTWARE": "1",
            "GDK_BACKEND": "x11",
            "DISPLAY": self.args.display,
        })
        env.pop("SKOTIQ_SIM_FAULTS", None)
        log = open(os.path.join(self.root, "app.log"), "ab")
        cmd = [self.args.bundle, "--headless", f"--auth-token={TOKEN}", f"--port={self.args.port}"]
        if self.args.memory_max:
            cmd = ["systemd-run", "--user", "--scope", "-q", "-p",
                   f"MemoryMax={self.args.memory_max}"] + cmd
        self.app = subprocess.Popen(cmd, env=env, stdout=log, stderr=subprocess.STDOUT,
                                    start_new_session=True)
        for _ in range(90):
            time.sleep(1)
            if self.app.poll() is not None:
                raise RuntimeError(f"app exited during launch with {self.app.returncode}")
            try:
                urllib.request.urlopen(self.base + "/api/info", timeout=2).read()
                return
            except (urllib.error.URLError, OSError):
                continue
        raise RuntimeError("API never came up")

    def stop_app(self):
        if not self.app or self.app.poll() is not None:
            return
        os.killpg(self.app.pid, signal.SIGTERM)
        try:
            self.app.wait(timeout=30)
        except subprocess.TimeoutExpired:
            os.killpg(self.app.pid, signal.SIGKILL)
            self.app.wait(timeout=10)

    def start_phd2(self):
        log = open(os.path.join(self.root, "phd2.log"), "ab")
        self.phd2 = subprocess.Popen(
            [sys.executable, os.path.join(HERE, "..", "sim_night_soak", "fake_phd2.py"),
             "--port", str(self.args.phd2_port),
             "--timeline", os.path.join(self.root, "phd2_timeline.jsonl")],
            stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        time.sleep(1.0)
        if self.phd2.poll() is not None:
            raise RuntimeError("fake PHD2 did not start (port busy?)")

    # ---- the night ----------------------------------------------------------

    def prepare(self):
        if os.path.exists(self.root):
            shutil.rmtree(self.root)
        for d in (self.db_dir, self.data_dir, self.out_dir, self.tmp_dir):
            os.makedirs(d)

    def seed_settings(self):
        now = int(time.time() * 1000)
        seeds = {
            "sequencer_autofocus_interval_frames": "3",
            "sequencer_dither_pixels": "3.0",
            "sequencer_dither_settle_pixels": "1.5",
            "sequencer_dither_settle_time": "2.0",
            "sequencer_dither_settle_timeout": "30.0",
            "end_of_night_calibration.enabled": "true",
            "end_of_night_calibration.dark_count": str(DARK_COUNT),
            "end_of_night_calibration.bias_count": str(BIAS_COUNT),
            "end_of_night_calibration.mount": "home",
            "end_of_night_calibration.warm_up": "true",
        }
        conn = self.db()
        for key, value in seeds.items():
            conn.execute("INSERT INTO app_settings(key,value,updated_at) VALUES(?,?,?) "
                         "ON CONFLICT(key) DO UPDATE SET value=excluded.value", (key, value, now))
        conn.commit()
        conn.close()

    def configure(self):
        name, lat, lon = night_plan.pick_site()
        self.facts["site"] = {"name": name, "lat": lat, "lon": lon}
        self.api("POST", "/api/settings", {"settings": {
            "imageOutputPath": self.out_dir, "latitude": lat, "longitude": lon,
            "afAutofocusFilterName": "L", "enableImageGrading": False}})
        self.api("POST", "/api/settings/location", {"location": {
            "latitude": lat, "longitude": lon, "elevation": 2000.0}})
        profile = self.api("POST", "/api/profiles", {"profile": {
            "id": "", "name": "eon-sim-rig", "cameraId": "sim_camera_1",
            "mountId": "sim_mount_1", "filterWheelId": "sim_filterwheel_1",
            "focuserId": "sim_focuser_1", "focalLength": 1000.0, "aperture": 200.0,
            "defaultBinX": 1, "defaultBinY": 1, "filterNames": json.dumps(WHEEL)}})
        self.api("POST", f"/api/profiles/{profile['id']}/load")
        for dtype, did in (("camera", "sim_camera_1"), ("mount", "sim_mount_1"),
                           ("filterWheel", "sim_filterwheel_1"), ("focuser", "sim_focuser_1")):
            self.api("POST", "/api/devices/connect", {"deviceId": did, "deviceType": dtype},
                     timeout=60)
            time.sleep(0.5)
        self.api("POST", "/api/filter-wheel/names",
                 {"deviceId": "sim_filterwheel_1", "names": WHEEL})
        self.api("POST", "/api/phd2/connect",
                 {"host": "127.0.0.1", "port": self.args.phd2_port}, timeout=60)
        self.api("POST", "/api/sequencer/save-path", {"path": self.out_dir})

    def light_plan(self):
        """Cool to -10 C, slew, guide, and take two exposure lengths."""
        _, lat, lon = night_plan.pick_site()
        now = time.time()
        ra = (night_plan.lst_hours(now, lon) + 1.5) % 24.0
        nodes, children = [], []
        nodes.append(night_plan.node("cool", "Cool", {
            "type": "CoolCamera", "target_temp": -10.0, "duration_mins": 1.0}))
        children_target = ["slew", "guide"]
        nodes.append(night_plan.slew("slew"))
        nodes.append(night_plan.start_guiding("guide"))
        for filt, secs, count in LIGHTS:
            nid = f"exp_{filt.lower()}"
            nodes.append(night_plan.node(nid, f"Exposure {filt}", {
                "type": "TakeExposure", "duration_secs": secs, "count": count,
                "frame_type": "Light", "filter": filt, "filter_index": WHEEL.index(filt),
                "gain": 100, "offset": 10, "binning": "One", "dither_every": 2}))
            children_target.append(nid)
        nodes.append(night_plan.target_header("target", "EON Field", ra, lat, children_target))
        children = ["cool", "target"]
        nodes.insert(0, night_plan.node("root", "Night", {
            "type": "Loop", "iterations": 1, "condition": "Count", "condition_value": None},
            children))
        return {"id": "eon-sim-night", "name": "EON sim night", "description": "",
                "root_node_id": "root", "nodes": nodes, "metadata": {}}

    def wait_run(self, timeout):
        last = None
        deadline = time.time() + timeout
        while time.time() < deadline:
            time.sleep(2)
            status = self.api("GET", "/api/sequencer/status") or {}
            state = status.get("state")
            if state != last:
                self.say(f"  run state -> {state}")
                last = state
            if state in ("completed", "failed", "cancelled", "stopped"):
                return state
        return last

    def mount(self):
        return self.api("GET", "/api/mount/status") or {}

    def watch_calibration(self, timeout):
        """Poll the step to its end, sampling the mount while frames are taken."""
        deadline = time.time() + timeout
        phases, mount_samples, last = [], [], None
        while time.time() < deadline:
            time.sleep(1.5)
            body = self.api("GET", "/api/calibration/end-of-night") or {}
            phase = (body.get("status") or {}).get("phase")
            if phase != last:
                self.say(f"  calibration phase -> {phase}")
                phases.append((phase, time.time()))
                last = phase
            if phase == "capturing":
                m = self.mount()
                mount_samples.append(m)
            if phase in ("finished", "failed", "skipped", "cancelled"):
                return body, phases, mount_samples
        return body, phases, mount_samples

    def run(self):
        self.prepare()
        self.say("first boot (schema)")
        self.launch()
        self.stop_app()
        self.seed_settings()
        self.start_phd2()
        self.say("relaunch and configure")
        self.launch()
        self.configure()

        names = (self.api("GET", "/api/filter-wheel/names?deviceId=sim_filterwheel_1") or {})
        self.say(f"  wheel names: {names}")

        definition = self.light_plan()
        with open(os.path.join(self.root, "lights.json"), "w") as fh:
            json.dump(definition, fh, indent=1)
        self.api("POST", "/api/sequencer/load", night_plan.envelope(definition), timeout=30)
        started = time.time()
        self.api("POST", "/api/sequencer/start")
        self.say("light run started")
        state = self.wait_run(900)
        self.check(state == "completed", f"light run completed (state={state})")
        lights_end = time.time()

        body, phases, mount_samples = self.watch_calibration(1200)
        self.facts["phases"] = phases
        self.collect_and_check(body, phases, mount_samples, started, lights_end)

    # ---- checks -------------------------------------------------------------

    def collect_and_check(self, body, phases, mount_samples, started, lights_end):
        report = (body.get("status") or {}).get("report") or {}
        with open(os.path.join(self.root, "report.json"), "w") as fh:
            json.dump(body, fh, indent=1)
        phase_names = [p for p, _ in phases]
        self.check("capturing" in phase_names,
                   f"the step started by itself after the run (phases {phase_names})")
        self.check(report.get("phase") == "finished",
                   f"step finished: {report.get('summary')}")
        self.check(report.get("problems") == [], f"no problems reported: {report.get('problems')}")
        self.check((report.get("darkSlot") or "").startswith("DARK"),
                   f"DARK slot used: {report.get('darkSlot')}")
        self.check("home" in (report.get("mount") or ""), f"mount: {report.get('mount')}")
        self.check(report.get("guiding") == "Guiding stopped", f"guiding: {report.get('guiding')}")
        self.check((report.get("warmUp") or "").startswith("Camera warm-up started")
                   or "cooler" in (report.get("warmUp") or ""),
                   f"warm-up: {report.get('warmUp')}")

        # Frames: the calibration run recorded exactly the planned set, all
        # through DARK.
        run_id = report.get("runId")
        conn = self.db()
        rows = conn.execute(
            "SELECT frame_type, exposure_duration, filter, gain, offset, file_path FROM captured_images "
            "WHERE producing_run_id = ?", (str(run_id),)).fetchall()
        counts = {}
        for r in rows:
            counts[(r["frame_type"], round(r["exposure_duration"], 3))] = \
                counts.get((r["frame_type"], round(r["exposure_duration"], 3)), 0) + 1
        want = {("dark", 2.0): DARK_COUNT, ("dark", 3.0): DARK_COUNT, ("bias", 0.001): BIAS_COUNT}
        self.check(counts == want, f"calibration frames {counts} == {want}")
        self.check({r["filter"] for r in rows} == {"DARK"},
                   f"every calibration frame through DARK: {sorted({r['filter'] for r in rows})}")
        self.check({(r["gain"], r["offset"]) for r in rows} == {(100, 10)},
                   "calibration frames at the lights' gain/offset")

        # No motion and no triggers during the calibration run.
        moving = [m for m in mount_samples if m.get("slewing") or m.get("isSlewing")]
        self.check(not moving, f"mount never slewed while frames were taken ({len(mount_samples)} samples)")
        coords = {(round(m.get("ra", 0) or 0, 3), round(m.get("dec", 0) or 0, 2))
                  for m in mount_samples if m}
        tracking = {m.get("tracking", m.get("isTracking")) for m in mount_samples if m}
        self.say(f"  mount during capture: coords {sorted(coords)[:3]} tracking {tracking}")
        self.check(tracking <= {False, None}, f"mount not tracking during capture: {tracking}")

        capture_start = next((t for p, t in phases if p == "capturing"), lights_end)
        capture_end = next((t for p, t in phases if p in ("buildingMasters", "finished")), time.time())
        dithers = []
        tl = os.path.join(self.root, "phd2_timeline.jsonl")
        if os.path.exists(tl):
            with open(tl) as fh:
                for line in fh:
                    try:
                        ev = json.loads(line)
                    except ValueError:
                        continue
                    text = json.dumps(ev).lower()
                    if "dither" in text:
                        dithers.append(ev)
        light_dithers = [e for e in dithers if e.get("t", 0) < capture_start]
        cal_dithers = [e for e in dithers if capture_start <= e.get("t", 0) <= capture_end]
        self.check(len(light_dithers) > 0, f"the lights dithered ({len(light_dithers)} events): the trigger path is live")
        self.check(not cal_dithers, f"no dither while calibration frames were taken ({len(cal_dithers)})")

        log = open(os.path.join(self.root, "app.log"), errors="replace").read()
        marker = log.find("starting end-of-night")
        tail = log[marker:] if marker >= 0 else ""
        self.check(marker >= 0, "the log names the automatic start")
        fired = [l for l in tail.splitlines() if "Trigger fired" in l or "trigger fired" in l]
        self.check(not fired, f"no trigger fired after the step started: {fired[:3]}")
        af = [l for l in tail.splitlines() if "utofocus" in l and ("start" in l.lower() or "running" in l.lower())]
        self.check(not af, f"no autofocus after the step started: {af[:3]}")
        self.check("Calibration-only run" in tail, "the sequencer recognized the calibration-only run")

        # Masters: U16 FITS with matching keys, in the dark library.
        masters = conn.execute(
            "SELECT file_path, frame_type, exposure_time, gain, offset, temperature, master_frame_count "
            "FROM dark_library WHERE master_dark_path IS NOT NULL").fetchall()
        raws = conn.execute("SELECT count(*) FROM dark_library WHERE master_dark_path IS NULL").fetchone()[0]
        self.check(len(masters) == 3, f"three masters in the dark library: {[dict(m) for m in masters]}")
        self.check(raws == 2 * DARK_COUNT + BIAS_COUNT, f"raw frames registered in the library: {raws}")
        for m in masters:
            hdr = fits_header(m["file_path"])
            ok = (hdr.get("BITPIX") == "16" and hdr.get("BZERO") == "32768"
                  and hdr.get("GAIN") == "100" and hdr.get("OFFSET") == "10"
                  and hdr.get("IMAGETYP", "").startswith("'Master")
                  and "NCOMBINE" in hdr and "CCD-TEMP" in hdr)
            self.check(ok, f"master {os.path.basename(m['file_path'])} is U16 with keys "
                           f"{ {k: hdr.get(k) for k in ('BITPIX', 'IMAGETYP', 'EXPTIME', 'GAIN', 'OFFSET', 'CCD-TEMP', 'NCOMBINE')} }")
        conn.close()

        # The calibration matcher picks the new masters for the lights.
        for filt, secs, _ in LIGHTS:
            match = self.api("POST", "/api/calibration-library/match", {
                "exposureSeconds": secs, "gain": 100, "offset": 10, "temperature": -10.0,
                "filter": filt, "binX": 1, "binY": 1})
            dark = ((match or {}).get("dark") or {}).get("record") or {}
            bias = ((match or {}).get("bias") or {}).get("record") or {}
            self.check("Masters" in (dark.get("filePath") or "") and dark.get("isMaster", True),
                       f"{filt} {secs}s lights match the new dark master: {dark.get('filePath')}")
            self.check("MasterBias" in (bias.get("filePath") or ""),
                       f"{filt} lights match the new bias master: {bias.get('filePath')}")

    def finish(self):
        self.stop_app()
        if self.phd2 and self.phd2.poll() is None:
            self.phd2.terminate()
            try:
                self.phd2.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.phd2.kill()
        with open(os.path.join(self.root, "summary.json"), "w") as fh:
            json.dump({"passed": self.passed, "failed": self.failed, "facts": self.facts}, fh,
                      indent=1, default=str)
        self.say(f"{self.passed} passed, {self.failed} failed; artifacts in {self.root}")


def fits_header(path):
    cards = {}
    with open(path, "rb") as fh:
        while True:
            block = fh.read(2880)
            if len(block) < 2880:
                break
            for i in range(0, 2880, 80):
                card = block[i:i + 80].decode("ascii", "replace")
                key = card[:8].strip()
                if key == "END":
                    return cards
                if card[8:10] == "= ":
                    cards[key] = card[10:].split("/")[0].strip()
    return cards


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=8481)
    ap.add_argument("--phd2-port", type=int, default=4481)
    ap.add_argument("--bundle", default=os.path.join(
        REPO, "apps/desktop/build/linux/x64/release/bundle/skotiq"))
    ap.add_argument("--root", default="~/.cache/sk-eon")
    ap.add_argument("--display", default=":97")
    ap.add_argument("--memory-max", default="6G")
    args = ap.parse_args()
    h = Harness(args)
    try:
        h.run()
    except Exception as exc:  # noqa: BLE001
        h.check(False, f"harness error: {exc}")
    finally:
        h.finish()
    sys.exit(0 if h.failed == 0 and h.passed > 0 else 1)


if __name__ == "__main__":
    main()
